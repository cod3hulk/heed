import Foundation
import os

/// Thread-safe buffer for collecting audio samples from realtime callbacks
public final class AudioSampleCollector: @unchecked Sendable {
    private let sampleLock = OSAllocatedUnfairLock()
    private let levelLock = OSAllocatedUnfairLock()
    private var samples: [Float] = []
    private var _level: Float = 0

    public init() {}

    public var level: Float {
        levelLock.withLock { _level }
    }

    public func append(_ newSamples: [Float], updateLevel: Bool = false) {
        sampleLock.withLock {
            samples.append(contentsOf: newSamples)
        }

        if updateLevel && !newSamples.isEmpty {
            var sum: Float = 0
            for s in newSamples { sum += s * s }
            let rms = sqrtf(sum / Float(newSamples.count))

            levelLock.withLock {
                _level = min(1.0, rms * 10)
            }
        }
    }

    /// Copy the buffered samples without clearing. Safe to call while
    /// the tap/stream is still writing.
    ///
    /// Returns a *distinct* allocation (not a COW alias of `samples`). If we
    /// returned `samples` directly, the collector's buffer would be shared
    /// (refcount 2) and the next `append` from the realtime capture thread
    /// would trigger a full copy-on-write of the entire buffer under the lock —
    /// on a long recording that's a multi-hundred-MB memcpy on the audio thread.
    /// `withUnsafeBufferPointer { Array($0) }` forces the copy here, on the
    /// caller's thread, leaving `samples` uniquely referenced so the writer
    /// stays cheap.
    public func snapshot() -> [Float] {
        sampleLock.withLock { samples.withUnsafeBufferPointer { Array($0) } }
    }

    public func drain() -> [Float] {
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

    /// Drain the buffered samples without resetting the level. Used for periodic
    /// compaction *during* recording — unlike `drain()` it leaves `_level`
    /// untouched so the live waveform meter doesn't flicker to zero every tick.
    public func drainKeepingLevel() -> [Float] {
        sampleLock.withLock {
            let r = samples
            samples = []
            return r
        }
    }

    public func reset() {
        sampleLock.withLock {
            samples = []
        }
        levelLock.withLock {
            _level = 0
        }
    }
}
