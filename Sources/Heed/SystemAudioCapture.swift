import ScreenCaptureKit
import CoreMedia
import os

// MARK: - Stream Output Delegate

/// Receives SCStream callbacks on an arbitrary thread — must be @unchecked Sendable.
final class SystemAudioCollector: NSObject, SCStreamOutput, @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock()
    private var samples: [Float] = []

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

        let captured = mono
        lock.withLock { samples.append(contentsOf: captured) }
    }

    func drain() -> [Float] {
        lock.withLock {
            let result = samples
            samples = []
            return result
        }
    }

    func reset() {
        lock.withLock { samples = [] }
    }
}

// MARK: - System Audio Capture

@MainActor
final class SystemAudioCapture {
    private var stream: SCStream?
    private let collector = SystemAudioCollector()
    private var capturedSampleRate: Double = 48000

    // MARK: - Public API

    var isCapturing: Bool { stream != nil }

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
        // Minimise video overhead — 2×2 is the smallest allowed
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1) // 1 fps
        config.showsCursor = false

        // SCStream delivers audio at its native rate (usually 48kHz)
        capturedSampleRate = 48000

        let scStream = SCStream(filter: filter, configuration: config, delegate: nil)
        try scStream.addStreamOutput(collector, type: .audio, sampleHandlerQueue: .global(qos: .userInteractive))
        try await scStream.startCapture()

        self.stream = scStream
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

    var nativeSampleRate: Double { capturedSampleRate }
}

enum SystemAudioError: Error {
    case noDisplay
}
