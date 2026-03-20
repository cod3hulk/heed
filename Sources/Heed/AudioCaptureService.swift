@preconcurrency import AVFoundation
@preconcurrency import ScreenCaptureKit

@MainActor
final class AudioCaptureService {
    private var systemAudioStream: SCStream?
    private var micEngine: AVAudioEngine?
    private var capturedBuffers: [AVAudioPCMBuffer] = []
    private var systemAudioDelegate: SystemAudioDelegate?
    private let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!

    func startCapture() async throws {
        capturedBuffers = []

        // Try system audio + mic simultaneously
        // Fall back to mic-only if system audio unavailable within 500ms
        _ = await startSystemAudioCapture()
        try startMicCapture()
    }

    func stopCapture() async -> [AVAudioPCMBuffer] {
        await stopSystemAudioCapture()
        stopMicCapture()

        let buffers = capturedBuffers
        capturedBuffers = []
        return buffers
    }

    // MARK: - System Audio (ScreenCaptureKit)

    private func startSystemAudioCapture() async -> Bool {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)

            guard let display = content.displays.first else {
                return false
            }

            let filter = SCContentFilter(display: display, excludingWindows: [])
            let config = SCStreamConfiguration()
            config.capturesAudio = true
            config.excludesCurrentProcessAudio = true
            config.sampleRate = 48000
            config.channelCount = 1

            let stream = SCStream(filter: filter, configuration: config, delegate: nil)
            let delegate = SystemAudioDelegate { [weak self] buffer in
                self?.handleSystemAudioBuffer(buffer)
            }
            self.systemAudioDelegate = delegate
            try stream.addStreamOutput(delegate, type: .audio, sampleHandlerQueue: .main)

            try await stream.startCapture()

            self.systemAudioStream = stream
            return true
        } catch {
            return false
        }
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
                self.capturedBuffers.append(resampled)
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
                    self.capturedBuffers.append(resampled)
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

    // MARK: - Resampling

    private nonisolated func resample(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!

        guard let converter = AVAudioConverter(from: buffer.format, to: targetFormat) else {
            return nil
        }

        let capacity = AVAudioFrameCount(
            Double(buffer.frameLength) * (targetFormat.sampleRate / buffer.format.sampleRate)
        )
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
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
