@preconcurrency import AVFoundation
import HeedCore
import os

enum AudioCaptureError: Error {
    case engineStopped
    case maxRecoveriesExceeded
    case invalidInputFormat
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

        var isRestarting: Bool {
            if case .restarting = self { return true }
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
    private var isHandlingConfigChange = false
    private var pendingRecoveryWorkItem: DispatchWorkItem?
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
        recoveryAttempts = 0
        pendingRecoveryWorkItem?.cancel()
        pendingRecoveryWorkItem = nil
        isHandlingConfigChange = false
        engineState = .stopped

        let engine = AVAudioEngine()
        try installTap(on: engine)

        // When audio hardware changes (AirPods, headphones, USB devices) AVAudioEngine
        // stops and its tap silently goes dead. Re-establish the tap immediately so
        // recording continues without dropping samples.
        // NOTE: observe without a specific object — during device changes the notification
        // may arrive with a nil object, which would filter out if we bound to `engine`.
        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: nil,
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

    /// Return everything captured so far, resampled to 16kHz, without stopping the engine.
    /// Safe to call from the main actor while recording continues.
    func snapshotSamples() -> [Float] {
        let raw = micCollector.snapshot()
        let currentSegment = resampleTo16k(raw, fromRate: inputSampleRate)
        return preResampledSamples + currentSegment
    }

    func stopRecording() -> [Float] {
        engineState = .stopped

        healthCheckTimer?.invalidate()
        healthCheckTimer = nil

        // Cancel any pending recovery so it doesn't fire after the user stopped.
        pendingRecoveryWorkItem?.cancel()
        pendingRecoveryWorkItem = nil
        isHandlingConfigChange = false

        if let observer = configChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            configChangeObserver = nil
        }
        if let engine = micEngine {
            if engine.isRunning {
                engine.inputNode.removeTap(onBus: 0)
            }
            engine.stop()
        }
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
        // Ignore late notifications after stopRecording().
        guard engineState.isRunning || engineState.isRestarting else { return }
        // Coalesce bursts: macOS can fire multiple config-change notifications
        // in rapid succession while a device transitions.
        guard !isHandlingConfigChange else { return }
        isHandlingConfigChange = true
        defer { isHandlingConfigChange = false }

        print("Audio device configuration changed — re-establishing mic tap")
        engineState = .restarting

        // Drain and resample whatever was collected before the device change,
        // so samples collected at the old rate aren't mixed with the new rate.
        let rawSamples = micCollector.drain()
        if !rawSamples.isEmpty {
            let resampled = resampleTo16k(rawSamples, fromRate: inputSampleRate)
            preResampledSamples.append(contentsOf: resampled)
        }

        // Fully tear down the existing engine — reusing it after a hardware change
        // can leave its input node bound to a stale format, which crashes
        // installTap() with an ObjC exception that Swift cannot catch.
        if let old = micEngine {
            if old.isRunning {
                old.inputNode.removeTap(onBus: 0)
            }
            old.stop()
        }
        micEngine = nil

        let engine = AVAudioEngine()
        do {
            try installTap(on: engine)
            engine.prepare()
            try engine.start()
            micEngine = engine
            engineState = .running
            recoveryAttempts = 0
            print("Mic tap restored at \(inputSampleRate) Hz, \(engine.inputNode.outputFormat(forBus: 0).channelCount) ch")
        } catch {
            print("Failed to restart audio engine after device change: \(error)")
            engineState = .failed(error)
            attemptRecovery()
        }
    }

    private func checkEngineHealth() {
        // Only check when we believe we're actively running. If we're currently
        // restarting (config change in progress) skip — a stale engine.isRunning
        // read here would double-trigger recovery.
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

        // Rebuild the engine from scratch — the old one may be in a bad state.
        if let old = micEngine {
            if old.isRunning {
                old.inputNode.removeTap(onBus: 0)
            }
            old.stop()
        }
        micEngine = nil

        let engine = AVAudioEngine()

        do {
            try installTap(on: engine)
            engine.prepare()
            try engine.start()
            micEngine = engine
            engineState = .running
            let attempt = recoveryAttempts
            recoveryAttempts = 0
            print("✓ Audio engine recovered (attempt \(attempt))")
        } catch {
            print("✗ Recovery attempt \(recoveryAttempts) failed: \(error)")

            // Retry after delay with exponential backoff. Track the work item
            // so stopRecording() can cancel a pending retry.
            let work = DispatchWorkItem { [weak self] in
                Task { @MainActor [weak self] in
                    self?.pendingRecoveryWorkItem = nil
                    self?.attemptRecovery()
                }
            }
            pendingRecoveryWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(recoveryAttempts) * 0.5, execute: work)
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

    private func installTap(on engine: AVAudioEngine) throws {
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        // During a device change (unplug/replug, Bluetooth handoff) macOS can briefly
        // report a zero sample rate or zero channel count. Passing such a format to
        // installTap raises an ObjC exception ("required condition is false:
        // IsFormatSampleRateAndChannelCountValid(format)") that Swift cannot catch,
        // which manifests as a hard crash. Bail out and let the recovery path retry.
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            print("⚠ Input node reported invalid format (\(inputFormat.sampleRate) Hz, \(inputFormat.channelCount) ch) — deferring tap install")
            throw AudioCaptureError.invalidInputFormat
        }

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
