@preconcurrency import AVFoundation
@preconcurrency import ScreenCaptureKit

@MainActor
final class AudioCaptureService {
    private var systemAudioStream: SCStream?
    private var micEngine: AVAudioEngine?
    private var systemAudioSamples: [Float] = []
    private var micSamples: [Float] = []
    private var systemAudioDelegate: SystemAudioDelegate?

    func startCapture() async throws {
        systemAudioSamples = []
        micSamples = []

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

        let mixed = mixSamples(system: systemAudioSamples, mic: micSamples)
        systemAudioSamples = []
        micSamples = []
        return mixed
    }

    // MARK: - Mixing

    /// Mix system audio and mic by summing and clamping
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
        // 500ms timeout per spec: fall back to mic-only if system audio unavailable
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
        config.channelCount = 2  // Stereo source, resampled to mono

        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        let delegate = SystemAudioDelegate { [weak self] buffer in
            self?.handleSystemAudioBuffer(buffer)
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

    nonisolated private func handleSystemAudioBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard let pcmBuffer = sampleBuffer.asPCMBuffer() else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let resampled = self.resample(pcmBuffer) {
                self.appendSamples(from: resampled, to: &self.systemAudioSamples)
            }
        }
    }

    // MARK: - Microphone (AVAudioEngine)

    private func startMicCapture() throws {
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let resampled = self.resample(buffer) {
                    self.appendSamples(from: resampled, to: &self.micSamples)
                }
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

    // MARK: - Helpers

    private func appendSamples(from buffer: AVAudioPCMBuffer, to samples: inout [Float]) {
        guard let channelData = buffer.floatChannelData?[0] else { return }
        let count = Int(buffer.frameLength)
        samples.append(contentsOf: UnsafeBufferPointer(start: channelData, count: count))
    }

    // MARK: - Resampling (any format → 16kHz mono)

    private nonisolated func resample(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!

        guard buffer.format != targetFormat else { return buffer }
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
