import Foundation
import FluidAudio
import HeedCore

@MainActor
final class SpeakerDiarizationService {
    static let shared = SpeakerDiarizationService()

    private let manager = OfflineDiarizerManager()
    private var prepareTask: Task<Bool, Never>?

    func diarize(samples16k: [Float]) async -> [SpeakerSegment] {
        guard samples16k.count >= 16_000 else { return [] }

        let prepared = await ensurePrepared()
        guard prepared else { return [] }

        do {
            let started = Date()
            let result = try await manager.process(audio: samples16k)
            let elapsed = Date().timeIntervalSince(started)
            print("Diarization produced \(result.segments.count) segments in \(String(format: "%.2f", elapsed))s")
            return result.segments.map { segment in
                SpeakerSegment(
                    speakerID: normalizedSpeakerID(segment.speakerId),
                    startTime: TimeInterval(segment.startTimeSeconds),
                    endTime: TimeInterval(segment.endTimeSeconds),
                    confidence: segment.qualityScore
                )
            }
        } catch {
            print("Speaker diarization unavailable: \(error)")
            return []
        }
    }

    private func ensurePrepared() async -> Bool {
        if let prepareTask { return await prepareTask.value }

        let task = Task { [manager] () -> Bool in
            do {
                try await manager.prepareModels()
                return true
            } catch {
                print("Could not prepare diarization models: \(error)")
                return false
            }
        }
        prepareTask = task
        return await task.value
    }

    private func normalizedSpeakerID(_ raw: String) -> String {
        guard raw.lowercased().hasPrefix("speaker") else { return raw }
        let suffix = raw.drop { !$0.isNumber }
        if let number = Int(suffix) { return "speaker_\(number)" }
        return raw
    }
}
