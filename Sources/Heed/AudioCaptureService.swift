@preconcurrency import AVFoundation
import HeedCore
import os

enum AudioCaptureError: Error {
    case engineStopped
    case maxRecoveriesExceeded
}

@MainActor
final class AudioCaptureService {
    private enum EngineState {
        case stopped
        case running
        case restarting
        case failed(Error)

        var isRunning: Bool {
            if case .running = self { return true }
            return false
        }
    }

    private var micEngine: AVAudioEngine?
    let micCollector = AudioSampleCollector()
    private var inputSampleRate: Double = 48000
    private var configChangeObserver: Any?
    // Samples already resampled to 16kHz from segments before device changes
    private var preResampledSamples: [Float] = []

    private var engineState: EngineState = .stopped
    private var recoveryAttempts = 0
    private let maxRecoveryAttempts = 3
    private var healthCheckTimer: Timer?
    var onRecordingFailed: ((String) -> Void)?

    var currentLevel: Float {
        micCollector.level
    }

    var isRecording: Bool {
        switch engineState {
        case .running, .restarting: return true
        case .stopped, .failed: return false
        }
    }

    var engineHealth: String? {
        switch engineState {
        case .restarting: return "Reconnecting audio device..."
        case .failed(let error): return "Audio unavailable: \(error.localizedDescription)"
        default: return nil
        }
    }

    func startRecording() throws {
        micCollector.reset()
        preResampledSamples = []
        engineState = .stopped

        let engine = AVAudioEngine()
        installTap(on: engine)

        // When audio hardware changes (AirPods, headphones, USB devices) AVAudioEngine
        // stops and its tap silently goes dead. Re-establish the tap immediately so
        // recording continues without dropping samples.
        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.handleEngineConfigurationChange() }
        }

        engine.prepare()
        try engine.start()
        self.micEngine = engine
        engineState = .running

        // Health check every 2 seconds to detect silent engine failures
        healthCheckTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) {
            [weak self] _ in
            Task { @MainActor [weak self] in
                self?.checkEngineHealth()
            }
        }
    }

    func stopRecording() -> [Float] {
        engineState = .stopped

        healthCheckTimer?.invalidate()
        healthCheckTimer = nil

        if let observer = configChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            configChangeObserver = nil
        }
        micEngine?.inputNode.removeTap(onBus: 0)
        micEngine?.stop()
        micEngine = nil

        let rawSamples = micCollector.drain()
        print("Recording stopped, captured \(rawSamples.count) raw samples at \(inputSampleRate) Hz")

        // Resample to 16kHz on the main thread where it's safe
        let currentSegment = resampleTo16k(rawSamples, fromRate: inputSampleRate)
        let allSamples = preResampledSamples + currentSegment
        preResampledSamples = []
        return allSamples
    }

    private func handleEngineConfigurationChange() {
        guard let engine = micEngine else { return }
        print("Audio device configuration changed — re-establishing mic tap")

        // Drain and resample whatever was collected before the device change,
        // so samples collected at the old rate aren't mixed with the new rate.
        let rawSamples = micCollector.drain()
        if !rawSamples.isEmpty {
            let resampled = resampleTo16k(rawSamples, fromRate: inputSampleRate)
            preResampledSamples.append(contentsOf: resampled)
        }

        engine.inputNode.removeTap(onBus: 0)
        installTap(on: engine)

        do {
            engine.prepare()
            try engine.start()
            recoveryAttempts = 0  // Reset on success
            print("Mic tap restored at \(inputSampleRate) Hz, \(engine.inputNode.outputFormat(forBus: 0).channelCount) ch")
        } catch {
            print("Failed to restart audio engine after device change: \(error)")
            engineState = .failed(error)
            attemptRecovery()
        }
    }

    private func checkEngineHealth() {
        guard let engine = micEngine, engineState.isRunning else { return }

        if !engine.isRunning {
            print("⚠ Engine stopped unexpectedly")
            engineState = .failed(AudioCaptureError.engineStopped)
            attemptRecovery()
        }
    }

    private func attemptRecovery() {
        guard recoveryAttempts < maxRecoveryAttempts else {
            engineState = .failed(AudioCaptureError.maxRecoveriesExceeded)
            notifyRecordingFailed()
            return
        }

        recoveryAttempts += 1
        engineState = .restarting

        // Preserve samples collected before failure
        let rawSamples = micCollector.drain()
        if !rawSamples.isEmpty {
            let resampled = resampleTo16k(rawSamples, fromRate: inputSampleRate)
            preResampledSamples.append(contentsOf: resampled)
        }

        guard let engine = micEngine else { return }

        engine.inputNode.removeTap(onBus: 0)
        installTap(on: engine)

        do {
            engine.prepare()
            try engine.start()
            engineState = .running
            recoveryAttempts = 0
            print("✓ Audio engine recovered (attempt \(recoveryAttempts))")
        } catch {
            print("✗ Recovery attempt \(recoveryAttempts) failed: \(error)")

            // Retry after delay with exponential backoff
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(recoveryAttempts) * 0.5) {
                [weak self] in self?.attemptRecovery()
            }
        }
    }

    private func notifyRecordingFailed() {
        let message: String
        switch engineState {
        case .failed(let error):
            message = "Recording stopped: \(error.localizedDescription)"
        default:
            message = "Recording stopped due to audio device error"
        }
        onRecordingFailed?(message)
    }

    private func installTap(on engine: AVAudioEngine) {
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        inputSampleRate = inputFormat.sampleRate
        let collector = micCollector

        // The tap closure runs on a realtime audio thread.
        // We MUST NOT reference any actor-isolated state or types here.
        // Just copy raw floats into the collector.
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { buffer, _ in
            guard let channelData = buffer.floatChannelData else { return }
            let frameCount = Int(buffer.frameLength)
            let channelCount = Int(buffer.format.channelCount)

            // Mix all channels to mono by averaging
            var monoSamples = [Float](repeating: 0, count: frameCount)
            for ch in 0..<channelCount {
                let channel = channelData[ch]
                for i in 0..<frameCount {
                    monoSamples[i] += channel[i]
                }
            }
            if channelCount > 1 {
                let scale = 1.0 / Float(channelCount)
                for i in 0..<frameCount {
                    monoSamples[i] *= scale
                }
            }

            collector.append(monoSamples, updateLevel: true)
        }

        print("Recording started at \(inputFormat.sampleRate) Hz, \(inputFormat.channelCount) ch")
    }

    private func resampleTo16k(_ samples: [Float], fromRate: Double) -> [Float] {
        AudioUtilities.resampleTo16k(samples, fromRate: fromRate)
    }
}
