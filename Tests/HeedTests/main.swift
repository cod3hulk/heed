import Foundation
import HeedCore

// Minimal test harness — no XCTest/Testing dependency needed
var passed = 0
var failed = 0

func assert(_ condition: Bool, _ message: String, file: String = #file, line: Int = #line) {
    if condition {
        passed += 1
    } else {
        failed += 1
        print("  FAIL [\(file):\(line)] \(message)")
    }
}

func assertEqual<T: Equatable>(_ a: T, _ b: T, _ message: String = "", file: String = #file, line: Int = #line) {
    if a == b {
        passed += 1
    } else {
        failed += 1
        print("  FAIL [\(file):\(line)] expected \(b), got \(a). \(message)")
    }
}

func assertEqual(_ a: Float, _ b: Float, accuracy: Float, _ message: String = "", file: String = #file, line: Int = #line) {
    if abs(a - b) <= accuracy {
        passed += 1
    } else {
        failed += 1
        print("  FAIL [\(file):\(line)] expected \(b) ± \(accuracy), got \(a). \(message)")
    }
}

// MARK: - resampleTo16k Tests

print("▸ AudioUtilities.resampleTo16k")

do {
    let input: [Float] = [0.1, 0.2, 0.3, 0.4, 0.5]
    let output = AudioUtilities.resampleTo16k(input, fromRate: 16000.0)
    assertEqual(output, input, "idempotent at 16kHz")
}

do {
    let input: [Float] = [0.1, 0.2, 0.3]
    let output = AudioUtilities.resampleTo16k(input, fromRate: 16000.5)
    assertEqual(output, input, "near target rate passes through")
}

do {
    let count = 48000
    let input = (0..<count).map { Float(sin(Double($0) * 0.01)) }
    let output = AudioUtilities.resampleTo16k(input, fromRate: 48000.0)
    assertEqual(output.count, 16000, "48kHz→16kHz produces 1/3 samples")
}

do {
    let count = 8000
    let input = (0..<count).map { Float(sin(Double($0) * 0.01)) }
    let output = AudioUtilities.resampleTo16k(input, fromRate: 8000.0)
    assertEqual(output.count, 16000, "8kHz→16kHz produces 2x samples")
}

do {
    let count = 48000
    let input = (0..<count).map { Float(sin(Double($0) * 0.01)) }
    let correctOutput = AudioUtilities.resampleTo16k(input, fromRate: 48000.0)
    let doubleResampled = AudioUtilities.resampleTo16k(correctOutput, fromRate: 48000.0)
    assertEqual(correctOutput.count, 16000, "first resample correct")
    assertEqual(doubleResampled.count, 16000 / 3,
                "REGRESSION: double resampling 16kHz as 48kHz produces 1/3 samples (the bug)")
}

do {
    let output = AudioUtilities.resampleTo16k([], fromRate: 48000.0)
    assert(output.isEmpty, "empty input → empty output")
}

do {
    // Generate 1 second of 440Hz sine at 48kHz
    let srcRate = 48000.0
    let freq = 440.0
    let count = Int(srcRate)
    let input = (0..<count).map { Float(sin(2.0 * .pi * freq * Double($0) / srcRate)) }

    let output = AudioUtilities.resampleTo16k(input, fromRate: srcRate)

    // Verify amplitude preserved (peak should be ~1.0)
    let peak = output.max() ?? 0
    assert(peak > 0.95 && peak <= 1.0, "amplitude preserved after resample: peak=\(peak)")

    // Verify frequency via zero-crossings: a 440Hz sine has 880 crossings/sec
    var crossings = 0
    for i in 1..<output.count {
        if (output[i - 1] < 0 && output[i] >= 0) || (output[i - 1] >= 0 && output[i] < 0) {
            crossings += 1
        }
    }
    let expectedCrossings = Int(freq * 2)
    let crossingError = abs(crossings - expectedCrossings)
    assert(crossingError <= 2, "440Hz sine intact after 48k→16k: crossings=\(crossings), expected≈\(expectedCrossings)")
}

do {
    // 44.1kHz — non-integer ratio (2.75625)
    let srcRate = 44100.0
    let freq = 440.0
    let count = Int(srcRate) // 1 second
    let input = (0..<count).map { Float(sin(2.0 * .pi * freq * Double($0) / srcRate)) }

    let output = AudioUtilities.resampleTo16k(input, fromRate: srcRate)

    // Expected output count: Int(44100 / (44100/16000)) = 16000
    assertEqual(output.count, 16000, "44.1kHz→16kHz produces 16000 samples")

    // Verify signal integrity via zero-crossings
    var crossings = 0
    for i in 1..<output.count {
        if (output[i - 1] < 0 && output[i] >= 0) || (output[i - 1] >= 0 && output[i] < 0) {
            crossings += 1
        }
    }
    let expectedCrossings = Int(freq * 2)
    let crossingError = abs(crossings - expectedCrossings)
    assert(crossingError <= 2, "440Hz sine intact after 44.1k→16k: crossings=\(crossings), expected≈\(expectedCrossings)")

    // Amplitude check
    let peak = output.max() ?? 0
    assert(peak > 0.95 && peak <= 1.0, "amplitude preserved after 44.1k resample: peak=\(peak)")
}

// MARK: - mixAudio Tests

print("▸ AudioUtilities.mixAudio")

do {
    let mic: [Float] = [0.5, 0.6, 0.7]
    let output = AudioUtilities.mixAudio(mic: mic, system: [])
    assertEqual(output, mic, "empty system → mic passthrough")
}

do {
    let mic: [Float] = [1.0, 0.0]
    let system: [Float] = [0.0, 1.0]
    let output = AudioUtilities.mixAudio(mic: mic, system: system)
    assertEqual(output[0], 0.6, accuracy: 0.001, "60% mic")
    assertEqual(output[1], 0.4, accuracy: 0.001, "40% system")
}

do {
    let mic: [Float] = [1.0, -1.0]
    let system: [Float] = [1.0, -1.0]
    let output = AudioUtilities.mixAudio(mic: mic, system: system)
    assertEqual(output[0], 1.0, accuracy: 0.001, "clamp to 1.0")
    assertEqual(output[1], -1.0, accuracy: 0.001, "clamp to -1.0")
}

do {
    let mic: [Float] = [0.5, 0.5, 0.8, 0.9]
    let system: [Float] = [0.5, 0.5]
    let output = AudioUtilities.mixAudio(mic: mic, system: system)
    assertEqual(output.count, 4, "appends mic remainder")
    assertEqual(output[2], 0.8, accuracy: 0.001, "remainder preserved")
    assertEqual(output[3], 0.9, accuracy: 0.001, "remainder preserved")
}

do {
    let mic: [Float] = [0.5]
    let system: [Float] = [0.5, 0.7, 0.9]
    let output = AudioUtilities.mixAudio(mic: mic, system: system)
    assertEqual(output.count, 3, "appends system remainder")
    assertEqual(output[1], 0.7, accuracy: 0.001, "remainder preserved")
    assertEqual(output[2], 0.9, accuracy: 0.001, "remainder preserved")
}

// MARK: - AudioSampleCollector Tests

print("▸ AudioSampleCollector")

do {
    let collector = AudioSampleCollector()
    collector.append([0.1, 0.2, 0.3])
    collector.append([0.4, 0.5])
    let result = collector.drain()
    assertEqual(result, [0.1, 0.2, 0.3, 0.4, 0.5], "append + drain")
}

do {
    let collector = AudioSampleCollector()
    collector.append([0.1, 0.2])
    _ = collector.drain()
    let result = collector.drain()
    assert(result.isEmpty, "drain clears buffer")
}

do {
    let collector = AudioSampleCollector()
    collector.append([0.5, 0.5, 0.5, 0.5], updateLevel: true)
    assert(collector.level > 0, "level updates with updateLevel:true")
}

do {
    let collector = AudioSampleCollector()
    collector.append([0.5, 0.5, 0.5, 0.5], updateLevel: false)
    assertEqual(collector.level, 0, accuracy: 0.001, "level stays 0 with updateLevel:false")
}

do {
    let collector = AudioSampleCollector()
    collector.append([0.5, 0.5], updateLevel: true)
    collector.reset()
    assert(collector.drain().isEmpty, "reset clears samples")
    assertEqual(collector.level, 0, accuracy: 0.001, "reset clears level")
}

do {
    let collector = AudioSampleCollector()
    collector.append([0.1, 0.2, 0.3])
    let snap = collector.snapshot()
    assertEqual(snap, [0.1, 0.2, 0.3], "snapshot returns buffered samples")
    let drained = collector.drain()
    assertEqual(drained, [0.1, 0.2, 0.3], "snapshot doesn't clear buffer")
}

do {
    let collector = AudioSampleCollector()
    collector.append([0.1, 0.2])
    _ = collector.snapshot()
    collector.append([0.3, 0.4])
    let snap2 = collector.snapshot()
    assertEqual(snap2, [0.1, 0.2, 0.3, 0.4], "snapshot reflects appends after prior snapshot")
}

do {
    // A held snapshot must not alias the collector's internal buffer: a later
    // append must not mutate the previously-returned array.
    let collector = AudioSampleCollector()
    collector.append([0.1, 0.2])
    let held = collector.snapshot()
    collector.append([0.3, 0.4])
    assertEqual(held, [0.1, 0.2], "held snapshot is a distinct copy, unaffected by later appends")
}

do {
    let collector = AudioSampleCollector()
    collector.append([0.1, 0.2, 0.3])
    let drained = collector.drainKeepingLevel()
    assertEqual(drained, [0.1, 0.2, 0.3], "drainKeepingLevel returns buffered samples")
    assert(collector.drain().isEmpty, "drainKeepingLevel clears buffer")
}

do {
    let collector = AudioSampleCollector()
    collector.append([0.5, 0.5, 0.5, 0.5], updateLevel: true)
    let levelBefore = collector.level
    assert(levelBefore > 0, "precondition: level is non-zero")
    _ = collector.drainKeepingLevel()
    assertEqual(collector.level, levelBefore, accuracy: 0.001,
                "drainKeepingLevel preserves the level meter (no waveform flicker)")
}

// MARK: - Summary

print("")
if failed == 0 {
    print("✓ All \(passed) tests passed")
} else {
    print("✗ \(failed) failed, \(passed) passed")
    exit(1)
}
