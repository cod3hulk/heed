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
    /// Deliberately never *all* of them. Multi-input USB interfaces expose channels that
    /// carry no voice: a Focusrite Scarlett Solo 4th Gen reports 4 input channels where
    /// ch1 is the XLR mic, ch2 the (usually empty) instrument jack and ch3/4 a loopback
    /// pair. Averaging across all four divides the mic by 4 (≈ −12 dB) and folds system
    /// audio back in through the loopback — the recording keeps running but comes out
    /// unusably quiet, with no error to show for it.
    ///
    /// - 1 channel → that channel
    /// - 2 channels → both, averaged (a genuine stereo mic)
    /// - 3+ channels → the first channel only (the primary input on every interface tested)
    public static func downmixChannelCount(forInputChannelCount count: Int) -> Int {
        count == 2 ? 2 : 1
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
