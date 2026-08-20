import Foundation

public enum AudioUtilities {
    public static func resampleTo16k(_ samples: [Float], fromRate: Double) -> [Float] {
        let targetRate = 16000.0
        if abs(fromRate - targetRate) < 1.0 { return samples }
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

    /// How many leading channels to average when folding a multi-channel input to mono.
    ///
    /// Always just the first channel for any multi-channel device. Multi-input USB
    /// interfaces expose channels that carry no voice, and even a 2-channel interface
    /// like a Focusrite Scarlett Solo puts the XLR mic on ch1 while ch2 is the (usually
    /// empty) instrument jack. Averaging ch1 with a silent ch2 halves the mic (≈ −6 dB);
    /// wider interfaces attenuate further and can fold system audio back in through a
    /// loopback pair — the recording keeps running but comes out unusably quiet, with no
    /// error to show for it.
    ///
    /// - 1 channel  → that channel
    /// - 2+ channels → the first channel only (the primary mic input on every interface tested)
    public static func downmixChannelCount(forInputChannelCount count: Int) -> Int {
        1
    }

    /// Fold a non-interleaved multi-channel buffer down to mono, using only the channels
    /// `downmixChannelCount(forInputChannelCount:)` selects.
    ///
    /// Takes raw channel pointers so it is callable from an `AVAudioEngine` tap on the
    /// realtime audio thread (see the Swift 6 concurrency note in CLAUDE.md).
    public static func downmixToMono(
        channelData: UnsafePointer<UnsafeMutablePointer<Float>>,
        channelCount: Int,
        frameCount: Int
    ) -> [Float] {
        guard channelCount > 0, frameCount > 0 else { return [] }

        let used = min(downmixChannelCount(forInputChannelCount: channelCount), channelCount)
        var mono = [Float](repeating: 0, count: frameCount)
        for ch in 0..<used {
            let channel = channelData[ch]
            for i in 0..<frameCount { mono[i] += channel[i] }
        }
        if used > 1 {
            let scale = 1.0 / Float(used)
            for i in 0..<frameCount { mono[i] *= scale }
        }
        return mono
    }

    public static func mixAudio(mic: [Float], system: [Float]) -> [Float] {
        guard !system.isEmpty else { return mic }
        let count = min(mic.count, system.count)
        var mixed = [Float](repeating: 0, count: count)
        for i in 0..<count {
            let s = mic[i] * 0.6 + system[i] * 0.4
            mixed[i] = max(-1.0, min(1.0, s))
        }
        if mic.count > count {
            mixed.append(contentsOf: mic[count...])
        } else if system.count > count {
            mixed.append(contentsOf: system[count...])
        }
        return mixed
    }
}
