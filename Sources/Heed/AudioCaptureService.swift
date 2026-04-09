@preconcurrency import AVFoundation
import os

/// Thread-safe buffer for collecting audio samples from realtime callbacks
final class AudioSampleCollector: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock()
    private var samples: [Float] = []
    private var _level: Float = 0

    var level: Float {
        lock.withLock { _level }
    }

    func append(_ newSamples: [Float], updateLevel: Bool = false) {
        lock.withLock {
            samples.append(contentsOf: newSamples)
            if updateLevel && !newSamples.isEmpty {
                var sum: Float = 0
                for s in newSamples { sum += s * s }
                let rms = sqrtf(sum / Float(newSamples.count))
                _level = min(1.0, rms * 10)
            }
        }
    }

    func drain() -> [Float] {
        lock.withLock {
            let result = samples
            samples = []
            _level = 0
            return result
        }
    }

    func reset() {
        lock.withLock {
            samples = []
            _level = 0
        }
    }
}

@MainActor
final class AudioCaptureService {
    private var micEngine: AVAudioEngine?
    let micCollector = AudioSampleCollector()
    private var inputSampleRate: Double = 48000
    private var configChangeObserver: Any?
    // Samples already resampled to 16kHz from segments before device changes
    private var preResampledSamples: [Float] = []

    var currentLevel: Float {
        micCollector.level
    }

    var isRecording: Bool {
        micEngine != nil
    }

    func startRecording() throws {
        micCollector.reset()
        preResampledSamples = []

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
    }

    func stopRecording() -> [Float] {
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
            print("Mic tap restored at \(inputSampleRate) Hz, \(engine.inputNode.outputFormat(forBus: 0).channelCount) ch")
        } catch {
            print("Failed to restart audio engine after device change: \(error)")
        }
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

    /// Simple linear interpolation resampling — no AVAudioConverter needed
    private func resampleTo16k(_ samples: [Float], fromRate: Double) -> [Float] {
        let targetRate = 16000.0
        if abs(fromRate - targetRate) < 1.0 {
            return samples // Already at target rate
        }

        let ratio = fromRate / targetRate
        let outputCount = Int(Double(samples.count) / ratio)
        guard outputCount > 0 else { return [] }

        var output = [Float](repeating: 0, count: outputCount)
        for i in 0..<outputCount {
            let srcIndex = Double(i) * ratio
            let idx = Int(srcIndex)
            let frac = Float(srcIndex - Double(idx))

            if idx + 1 < samples.count {
                output[i] = samples[idx] * (1.0 - frac) + samples[idx + 1] * frac
            } else if idx < samples.count {
                output[i] = samples[idx]
            }
        }

        return output
    }
}
