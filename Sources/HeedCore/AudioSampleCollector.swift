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

    public func reset() {
        sampleLock.withLock {
            samples = []
        }
        levelLock.withLock {
            _level = 0
        }
    }
}
