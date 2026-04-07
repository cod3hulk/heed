import ScreenCaptureKit
import CoreMedia
import os

// MARK: - Stream Output Delegate

/// Receives SCStream callbacks on an arbitrary thread — must be @unchecked Sendable.
final class SystemAudioCollector: NSObject, SCStreamOutput, @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock()
    private var samples: [Float] = []
    private var _level: Float = 0
    private var _sampleRate: Double = 48000

    var level: Float {
        lock.withLock { _level }
    }

    var sampleRate: Double {
        lock.withLock { _sampleRate }
    }

    func stream(_ stream: SCStream,
                didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .audio else { return }
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }

        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else { return }
        let asbd = asbdPtr.pointee

        let frameCount = Int(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frameCount > 0 else { return }

        let channelCount = Int(asbd.mChannelsPerFrame)
        let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let isInterleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) == 0

        guard isFloat else { return } // SCStream always delivers Float32

        var dataLength = 0
        var dataPointer: UnsafeMutablePointer<CChar>? = nil
        CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &dataLength, dataPointerOut: &dataPointer)
        guard let ptr = dataPointer else { return }

        let floatCount = dataLength / MemoryLayout<Float>.size
        let floats = UnsafeBufferPointer(start: ptr.withMemoryRebound(to: Float.self, capacity: floatCount) { $0 }, count: floatCount)

        var mono = [Float](repeating: 0, count: frameCount)

        if isInterleaved && channelCount > 1 {
            // Interleaved: L R L R … → average channels
            for i in 0..<frameCount {
                var sum: Float = 0
                for ch in 0..<channelCount {
                    let idx = i * channelCount + ch
                    if idx < floatCount { sum += floats[idx] }
                }
                mono[i] = sum / Float(channelCount)
            }
        } else if channelCount > 1 {
            // Non-interleaved: channel planes → average first two
            let samplesPerChannel = floatCount / channelCount
            for i in 0..<frameCount {
                var sum: Float = 0
                let chCount = min(channelCount, 2)
                for ch in 0..<chCount {
                    let idx = ch * samplesPerChannel + i
                    if idx < floatCount { sum += floats[idx] }
                }
                mono[i] = sum / Float(chCount)
            }
        } else {
            for i in 0..<frameCount {
                if i < floatCount { mono[i] = floats[i] }
            }
        }

        let actualRate = asbd.mSampleRate
        let captured = mono
        lock.withLock {
            if _sampleRate != actualRate && actualRate > 0 { _sampleRate = actualRate }
            samples.append(contentsOf: captured)
            if !captured.isEmpty {
                var sum: Float = 0
                for s in captured { sum += s * s }
                _level = min(1.0, sqrtf(sum / Float(captured.count)) * 10)
            }
        }
    }

    func drain() -> [Float] {
        lock.withLock {
            let result = samples
            samples = []
            return result
        }
    }

    func reset() {
        lock.withLock { samples = []; _level = 0; _sampleRate = 48000 }
    }
}

// MARK: - System Audio Capture

@MainActor
final class SystemAudioCapture: NSObject, SCStreamDelegate {
    private var stream: SCStream?
    private let collector = SystemAudioCollector()

    /// Called on the main actor when the stream stops unexpectedly (e.g., permission revoked).
    var onError: ((Error) -> Void)?

    // MARK: - SCStreamDelegate

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.stream = nil
            print("System audio stream stopped with error: \(error)")
            self.onError?(error)
        }
    }

    // MARK: - Public API

    var isCapturing: Bool { stream != nil }

    var currentLevel: Float { collector.level }

    /// Start capturing all system audio (excludes this process's own audio output).
    /// Throws if ScreenCaptureKit is unavailable or permission is denied.
    func startCapture() async throws {
        guard stream == nil else { return }
        collector.reset()

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)

        // Capture all displays (we only want audio, display is minimised)
        guard let display = content.displays.first else {
            throw SystemAudioError.noDisplay
        }

        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        // Explicitly request 48kHz stereo — without this macOS may pick the
        // system output device's native rate (44100, 96000, …) and our
        // resampler would use the wrong ratio.
        config.sampleRate = 48000
        config.channelCount = 2
        // Minimise video overhead — 2×2 is the smallest allowed
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1) // 1 fps
        config.showsCursor = false

        let scStream = SCStream(filter: filter, configuration: config, delegate: self)
        try scStream.addStreamOutput(collector, type: .audio, sampleHandlerQueue: .global(qos: .userInteractive))
        // Assign stream BEFORE awaiting startCapture so stopCapture() can clean up
        // even if called concurrently during the async startup.
        self.stream = scStream
        try await scStream.startCapture()
        print("System audio capture started")
    }

    /// Stop capturing and return raw samples at the captured sample rate.
    func stopCapture() async -> [Float] {
        guard let scStream = stream else { return [] }
        self.stream = nil

        try? await scStream.stopCapture()
        let raw = collector.drain()
        print("System audio: captured \(raw.count) raw samples")
        return raw
    }

    var nativeSampleRate: Double { collector.sampleRate }
}

enum SystemAudioError: Error {
    case noDisplay
}
