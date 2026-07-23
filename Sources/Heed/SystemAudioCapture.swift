import ScreenCaptureKit
import CoreMedia
import HeedCore
import os

// MARK: - Stream Output Delegate

/// Receives SCStream callbacks on an arbitrary thread — must be @unchecked Sendable.
final class SystemAudioCollector: NSObject, SCStreamOutput, @unchecked Sendable {
    // Separate locks prevent waveform timer (60fps) from blocking on drain()
    private let sampleLock = OSAllocatedUnfairLock()
    private let levelLock = OSAllocatedUnfairLock()
    private var samples: [Float] = []
    private var _level: Float = 0
    private var _sampleRate: Double = 48000

    var level: Float {
        levelLock.withLock { _level }
    }

    var sampleRate: Double {
        sampleLock.withLock { _sampleRate }
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

        // Acquire locks separately to minimize contention
        sampleLock.withLock {
            if _sampleRate != actualRate && actualRate > 0 { _sampleRate = actualRate }
            samples.append(contentsOf: captured)
        }

        if !captured.isEmpty {
            var sum: Float = 0
            for s in captured { sum += s * s }
            let rms = min(1.0, sqrtf(sum / Float(captured.count)) * 10)

            levelLock.withLock {
                _level = rms
            }
        }
    }

    /// Copy the buffered samples and current sample rate without clearing.
    /// Safe to call while the stream continues to deliver audio.
    ///
    /// Returns a *distinct* allocation (not a COW alias of `samples`). Returning
    /// `samples` directly leaves the buffer shared (refcount 2), so the next
    /// `append` on ScreenCaptureKit's sampleHandlerQueue copy-on-writes the whole
    /// buffer under the lock. On a long recording that stalls the handler enough
    /// that SCStream drops/stops delivering audio — system audio silently dies
    /// for the rest of the recording. `withUnsafeBufferPointer { Array($0) }`
    /// forces the copy here so the capture callback stays cheap.
    func snapshot() -> (samples: [Float], sampleRate: Double) {
        sampleLock.withLock { (samples.withUnsafeBufferPointer { Array($0) }, _sampleRate) }
    }

    func drain() -> [Float] {
        let result = sampleLock.withLock {
            let r = samples
            samples = []
            return r
        }

        levelLock.withLock {
            _level = 0
        }

        return result
    }

    /// Drain the buffered samples and current sample rate without resetting the
    /// level. Used for periodic compaction *during* recording so the raw buffer
    /// doesn't grow unbounded; leaves `_level` untouched so the live waveform
    /// meter doesn't flicker to zero every tick.
    func drainKeepingLevel() -> (samples: [Float], sampleRate: Double) {
        sampleLock.withLock {
            let r = samples
            samples = []
            return (r, _sampleRate)
        }
    }

    func reset() {
        sampleLock.withLock {
            samples = []
            _sampleRate = 48000
        }
        levelLock.withLock {
            _level = 0
        }
    }
}

// MARK: - System Audio Capture

@MainActor
final class SystemAudioCapture: NSObject, SCStreamDelegate {
    private enum StreamState {
        case stopped
        case running
        case restarting
        case failed(Error)

        var isRunning: Bool {
            if case .running = self { return true }
            return false
        }
    }

    private var stream: SCStream?
    private let collector = SystemAudioCollector()
    private var streamState: StreamState = .stopped
    private var restartAttempts = 0
    private let maxRestartAttempts = 3
    private var healthCheckTimer: Timer?
    // Samples already resampled to 16kHz from segments before stream failures
    private var preResampledSamples: [Float] = []

    /// Called on the main actor when the stream stops unexpectedly (e.g., permission revoked).
    var onError: ((Error) -> Void)?

    // MARK: - SCStreamDelegate

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor [weak self] in
            guard let self else { return }

            // Check if user explicitly stopped recording (race condition guard)
            guard case .running = self.streamState else {
                print("Stream stopped after user explicitly ended recording")
                return
            }

            self.stream = nil
            print("System audio stream stopped with error: \(error)")

            // Auto-restart if we're mid-recording
            if self.restartAttempts < self.maxRestartAttempts {
                self.restartAttempts += 1
                self.streamState = .restarting
                print("Attempting to restart system audio capture (attempt \(self.restartAttempts))...")

                // Preserve samples collected before failure
                let rawSamples = self.collector.drain()
                if !rawSamples.isEmpty {
                    let resampled = self.resampleTo16k(rawSamples, fromRate: self.collector.sampleRate)
                    self.preResampledSamples.append(contentsOf: resampled)
                    print("Preserved \(rawSamples.count) samples during restart")
                }

                // Exponential backoff
                let delay = UInt64(Double(self.restartAttempts) * 0.5 * 1_000_000_000)
                try? await Task.sleep(nanoseconds: delay)

                do {
                    try await self.startCapture()
                    print("✓ System audio restarted")
                    self.restartAttempts = 0
                    self.streamState = .running
                } catch {
                    print("✗ System audio restart failed: \(error)")
                    if self.restartAttempts >= self.maxRestartAttempts {
                        self.streamState = .failed(error)
                        self.onError?(error)
                    }
                }
            } else {
                self.streamState = .failed(error)
                self.onError?(error)
            }
        }
    }

    // MARK: - Public API

    var isCapturing: Bool {
        switch streamState {
        case .running, .restarting: return true
        case .stopped, .failed: return false
        }
    }

    var currentLevel: Float { collector.level }

    var streamHealth: String? {
        switch streamState {
        case .restarting: return "Reconnecting system audio..."
        case .failed(let error): return "System audio unavailable: \(error.localizedDescription)"
        default: return nil
        }
    }

    /// Start capturing all system audio (excludes this process's own audio output).
    /// Throws if ScreenCaptureKit is unavailable or permission is denied.
    func startCapture() async throws {
        guard stream == nil else { return }

        // Only reset on user-initiated start, not on auto-restart
        if case .stopped = streamState {
            collector.reset()
            preResampledSamples = []
            restartAttempts = 0
        }

        streamState = .running

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

        // Health check every 2 seconds to detect silent stream failures.
        // Also compacts the raw buffer to 16kHz so it doesn't grow unbounded.
        healthCheckTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) {
            [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.checkStreamHealth()
                self.compactBuffer()
            }
        }
    }

    /// Drain the live raw buffer, resample it to 16kHz, and fold it into
    /// `preResampledSamples`. Called on a timer during capture so the raw
    /// 48kHz buffer never accumulates more than one interval's worth of audio.
    /// Skipped unless running so a segment isn't resampled at a stale rate
    /// during a restart (the restart path already drains before switching).
    private func compactBuffer() {
        guard streamState.isRunning else { return }
        let (raw, rate) = collector.drainKeepingLevel()
        guard !raw.isEmpty else { return }
        preResampledSamples.append(contentsOf: resampleTo16k(raw, fromRate: rate))
    }

    private func checkStreamHealth() {
        guard streamState.isRunning else { return }

        // SCStream doesn't expose isRunning, but we can detect if it's been set to nil
        // while we think we're still running
        if stream == nil {
            print("⚠ Stream stopped unexpectedly without error callback")
            streamState = .failed(SystemAudioError.streamStopped)
            attemptRecovery()
        }
    }

    private func attemptRecovery() {
        guard restartAttempts < maxRestartAttempts else {
            streamState = .failed(SystemAudioError.maxRecoveriesExceeded)
            onError?(SystemAudioError.maxRecoveriesExceeded)
            return
        }

        restartAttempts += 1
        streamState = .restarting

        // Preserve samples collected before failure
        let rawSamples = collector.drain()
        if !rawSamples.isEmpty {
            let resampled = resampleTo16k(rawSamples, fromRate: collector.sampleRate)
            preResampledSamples.append(contentsOf: resampled)
            print("Preserved \(rawSamples.count) samples during recovery")
        }

        Task { @MainActor in
            // Exponential backoff
            let delay = UInt64(Double(self.restartAttempts) * 0.5 * 1_000_000_000)
            try? await Task.sleep(nanoseconds: delay)

            do {
                try await self.startCapture()
                print("✓ System audio recovered (attempt \(self.restartAttempts))")
                self.restartAttempts = 0
                self.streamState = .running
            } catch {
                print("✗ Recovery attempt \(self.restartAttempts) failed: \(error)")
                if self.restartAttempts >= self.maxRestartAttempts {
                    self.streamState = .failed(error)
                    self.onError?(error)
                } else {
                    self.attemptRecovery()
                }
            }
        }
    }

    /// Return everything captured so far, resampled to 16kHz, without stopping the stream.
    func snapshotSamples() -> [Float] {
        let (raw, rate) = collector.snapshot()
        let currentSegment = resampleTo16k(raw, fromRate: rate)
        return preResampledSamples + currentSegment
    }

    /// Stop capturing and return resampled samples at 16kHz.
    func stopCapture() async -> [Float] {
        streamState = .stopped

        healthCheckTimer?.invalidate()
        healthCheckTimer = nil

        guard let scStream = stream else {
            // Already stopped, just return preserved samples
            let result = preResampledSamples
            preResampledSamples = []
            return result
        }
        self.stream = nil

        try? await scStream.stopCapture()
        let raw = collector.drain()
        print("System audio: captured \(raw.count) raw samples")

        // Resample final segment and combine with preserved samples
        let finalSegment = resampleTo16k(raw, fromRate: collector.sampleRate)
        let allSamples = preResampledSamples + finalSegment
        preResampledSamples = []

        print("System audio: total \(allSamples.count) samples at 16kHz")
        return allSamples
    }

    private func resampleTo16k(_ samples: [Float], fromRate: Double) -> [Float] {
        AudioUtilities.resampleTo16k(samples, fromRate: fromRate)
    }
}

enum SystemAudioError: Error {
    case noDisplay
    case streamStopped
    case maxRecoveriesExceeded
}
