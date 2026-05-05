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

// MARK: - Summary

print("")
if failed == 0 {
    print("✓ All \(passed) tests passed")
} else {
    print("✗ \(failed) failed, \(passed) passed")
    exit(1)
}
