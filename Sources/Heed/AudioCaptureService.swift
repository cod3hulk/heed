@preconcurrency import AVFoundation
@preconcurrency import ScreenCaptureKit
import os

/// Thread-safe buffer for collecting audio samples from realtime callbacks
private final class AudioSampleCollector: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock()
    private var samples: [Float] = []
    private var _level: Float = 0

    var level: Float {
        lock.withLock { _level }
    }

    func append(_ buffer: AVAudioPCMBuffer, updateLevel: Bool = false) {
        guard let channelData = buffer.floatChannelData?[0] else { return }
        let count = Int(buffer.frameLength)
        let newSamples = Array(UnsafeBufferPointer(start: channelData, count: count))
        lock.withLock {
            samples.append(contentsOf: newSamples)
            if updateLevel {
                var sum: Float = 0
                for s in newSamples { sum += s * s }
                let rms = sqrtf(sum / max(1, Float(count)))
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
    private var systemAudioStream: SCStream?
    private var micEngine: AVAudioEngine?
    private let systemCollector = AudioSampleCollector()
    private let micCollector = AudioSampleCollector()
    private var systemAudioDelegate: SystemAudioDelegate?

    /// Current mic audio level (0.0–1.0) for waveform visualization
    var currentLevel: Float {
        micCollector.level
    }

    func startCapture() async throws {
        systemCollector.reset()
        micCollector.reset()

        // Try system audio + mic simultaneously
        // Fall back to mic-only if system audio unavailable within 500ms
        let systemAvailable = await startSystemAudioWithTimeout()
        if !systemAvailable {
            print("System audio unavailable, falling back to mic-only")
        }
        try startMicCapture()
    }

    /// Returns mixed 16kHz mono Float32 samples
    func stopCapture() async -> [Float] {
        await stopSystemAudioCapture()
        stopMicCapture()
        let systemSamples = systemCollector.drain()
        let micSamples = micCollector.drain()
        return mixSamples(system: systemSamples, mic: micSamples)
    }

    // MARK: - Mixing

    private func mixSamples(system: [Float], mic: [Float]) -> [Float] {
        if system.isEmpty { return mic }
        if mic.isEmpty { return system }

        let length = max(system.count, mic.count)
        var mixed = [Float](repeating: 0, count: length)
        for i in 0..<length {
            let s = i < system.count ? system[i] : 0
            let m = i < mic.count ? mic[i] : 0
            mixed[i] = max(-1.0, min(1.0, s + m))
        }
        return mixed
    }

    // MARK: - System Audio (ScreenCaptureKit)

    private func startSystemAudioWithTimeout() async -> Bool {
        do {
            return try await withThrowingTaskGroup(of: Bool.self) { group in
                group.addTask {
                    try await self.startSystemAudioCapture()
                }
                group.addTask {
                    try await Task.sleep(for: .milliseconds(500))
                    throw CancellationError()
                }
                let result = try await group.next() ?? false
                group.cancelAll()
                return result
            }
        } catch {
            return false
        }
    }

    private func startSystemAudioCapture() async throws -> Bool {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)

        guard let display = content.displays.first else {
            return false
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48000
        config.channelCount = 2

        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        let collector = systemCollector
        let delegate = SystemAudioDelegate { sampleBuffer in
            guard let pcmBuffer = sampleBuffer.asPCMBuffer() else { return }
            if let resampled = AudioCaptureService.resample(pcmBuffer) {
                collector.append(resampled)
            }
        }
        self.systemAudioDelegate = delegate
        try stream.addStreamOutput(delegate, type: .audio, sampleHandlerQueue: .main)

        try await stream.startCapture()

        self.systemAudioStream = stream
        return true
    }

    private func stopSystemAudioCapture() async {
        guard let stream = systemAudioStream else { return }
        try? await stream.stopCapture()
        systemAudioStream = nil
        systemAudioDelegate = nil
    }

    // MARK: - Microphone (AVAudioEngine)

    private func startMicCapture() throws {
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        let collector = micCollector

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { buffer, _ in
            if let resampled = AudioCaptureService.resample(buffer) {
                collector.append(resampled, updateLevel: true)
            }
        }

        engine.prepare()
        try engine.start()
        self.micEngine = engine
    }

    private func stopMicCapture() {
        micEngine?.inputNode.removeTap(onBus: 0)
        micEngine?.stop()
        micEngine = nil
    }

    // MARK: - Resampling (any format → 16kHz mono)

    private nonisolated static func resample(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!

        guard buffer.format.sampleRate != targetFormat.sampleRate || buffer.format.channelCount != targetFormat.channelCount else {
            return buffer
        }
        guard let converter = AVAudioConverter(from: buffer.format, to: targetFormat) else {
            return nil
        }

        let capacity = AVAudioFrameCount(
            Double(buffer.frameLength) * (targetFormat.sampleRate / buffer.format.sampleRate)
        )
        guard capacity > 0, let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
            return nil
        }

        var error: NSError?
        let inputBuffer = buffer
        nonisolated(unsafe) var consumed = false
        converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return inputBuffer
        }

        if error != nil {
            return nil
        }
        return outputBuffer
    }

}

// MARK: - SCStream Audio Output Delegate

private final class SystemAudioDelegate: NSObject, SCStreamOutput, @unchecked Sendable {
    private let handler: @Sendable (CMSampleBuffer) -> Void

    init(handler: @escaping @Sendable (CMSampleBuffer) -> Void) {
        self.handler = handler
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        handler(sampleBuffer)
    }
}

// MARK: - CMSampleBuffer to PCMBuffer

extension CMSampleBuffer {
    func asPCMBuffer() -> AVAudioPCMBuffer? {
        guard let formatDescription = formatDescription,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else {
            return nil
        }

        guard let format = AVAudioFormat(streamDescription: asbd),
              let blockBuffer = CMSampleBufferGetDataBuffer(self) else {
            return nil
        }

        let frameCount = CMSampleBufferGetNumSamples(self)
        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)) else {
            return nil
        }
        pcmBuffer.frameLength = AVAudioFrameCount(frameCount)

        var dataPointer: UnsafeMutablePointer<Int8>?
        var lengthAtOffset: Int = 0
        var totalLength: Int = 0

        let status = CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: &lengthAtOffset, totalLengthOut: &totalLength, dataPointerOut: &dataPointer)
        guard status == noErr, let data = dataPointer else {
            return nil
        }

        memcpy(pcmBuffer.floatChannelData?[0], data, totalLength)
        return pcmBuffer
    }
}
