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

    var currentLevel: Float {
        micCollector.level
    }

    var isRecording: Bool {
        micEngine != nil
    }

    func startRecording() throws {
        micCollector.reset()

        let engine = AVAudioEngine()
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

        engine.prepare()
        try engine.start()
        self.micEngine = engine
        print("Recording started at \(inputFormat.sampleRate) Hz, \(inputFormat.channelCount) ch")
    }

    func stopRecording() -> [Float] {
        micEngine?.inputNode.removeTap(onBus: 0)
        micEngine?.stop()
        micEngine = nil

        let rawSamples = micCollector.drain()
        print("Recording stopped, captured \(rawSamples.count) raw samples")

        // Resample to 16kHz on the main thread where it's safe
        return resampleTo16k(rawSamples, fromRate: inputSampleRate)
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
