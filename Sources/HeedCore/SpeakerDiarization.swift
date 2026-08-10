import Foundation

public struct SpeakerSegment: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public var speakerID: String
    public var displayName: String
    public var startTime: TimeInterval
    public var endTime: TimeInterval
    public var confidence: Float

    public var duration: TimeInterval { max(0, endTime - startTime) }

    public init(
        id: UUID = UUID(),
        speakerID: String,
        displayName: String? = nil,
        startTime: TimeInterval,
        endTime: TimeInterval,
        confidence: Float = 1.0
    ) {
        self.id = id
        self.speakerID = speakerID
        self.displayName = displayName ?? SpeakerDiarizationFormatter.defaultDisplayName(for: speakerID)
        self.startTime = startTime
        self.endTime = endTime
        self.confidence = confidence
    }
}

public struct TranscriptToken: Codable, Equatable, Sendable {
    public var text: String
    public var startTime: TimeInterval
    public var endTime: TimeInterval
    public var confidence: Float

    public init(text: String, startTime: TimeInterval, endTime: TimeInterval, confidence: Float = 1.0) {
        self.text = text
        self.startTime = startTime
        self.endTime = endTime
        self.confidence = confidence
    }
}

public struct SpeakerTurn: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public var speakerID: String
    public var displayName: String
    public var startTime: TimeInterval
    public var endTime: TimeInterval
    public var text: String
    public var confidence: Float

    public init(
        id: UUID = UUID(),
        speakerID: String,
        displayName: String,
        startTime: TimeInterval,
        endTime: TimeInterval,
        text: String,
        confidence: Float
    ) {
        self.id = id
        self.speakerID = speakerID
        self.displayName = displayName
        self.startTime = startTime
        self.endTime = endTime
        self.text = text
        self.confidence = confidence
    }
}

public enum SpeakerDiarizationFormatter {
    /// Minimum confidence before we show a speaker label as certain. Lower-quality output keeps
    /// the time range but uses an explicit fallback label so users do not over-trust it.
    public static let uncertainConfidenceThreshold: Float = 0.35

    public static func defaultDisplayName(for speakerID: String) -> String {
        let digits = speakerID.reversed().prefix { $0.isNumber }.reversed()
        if !digits.isEmpty { return "Speaker \(String(digits))" }
        return speakerID.isEmpty ? "Unknown speaker" : speakerID
    }

    public static func makeTurns(
        transcript: String,
        tokens: [TranscriptToken],
        speakerSegments: [SpeakerSegment],
        speakerNames: [String: String] = [:]
    ) -> [SpeakerTurn] {
        let orderedSegments = mergeShortGaps(in: speakerSegments.sorted { $0.startTime < $1.startTime })
        guard !orderedSegments.isEmpty else { return [] }
        guard !tokens.isEmpty else {
            return orderedSegments.map { segment in
                SpeakerTurn(
                    speakerID: segment.speakerID,
                    displayName: displayName(for: segment, speakerNames: speakerNames),
                    startTime: segment.startTime,
                    endTime: segment.endTime,
                    text: transcript,
                    confidence: segment.confidence
                )
            }
        }

        var turns: [SpeakerTurn] = []
        for segment in orderedSegments {
            let segmentTokens = tokens.filter { token in
                let midpoint = (token.startTime + token.endTime) / 2.0
                return midpoint >= segment.startTime && midpoint <= segment.endTime
            }
            let text = normalizeTokenText(segmentTokens.map(\.text).joined())
            guard !text.isEmpty else { continue }
            turns.append(SpeakerTurn(
                speakerID: segment.speakerID,
                displayName: displayName(for: segment, speakerNames: speakerNames),
                startTime: segment.startTime,
                endTime: segment.endTime,
                text: text,
                confidence: segment.confidence
            ))
        }
        return turns
    }

    public static func format(
        transcript: String,
        tokens: [TranscriptToken],
        speakerSegments: [SpeakerSegment],
        speakerNames: [String: String] = [:]
    ) -> String {
        let turns = makeTurns(transcript: transcript, tokens: tokens, speakerSegments: speakerSegments, speakerNames: speakerNames)
        guard !turns.isEmpty else { return transcript }

        if tokens.isEmpty {
            let timeline = turns.map { "[\(timestamp($0.startTime))–\(timestamp($0.endTime))] \($0.displayName)" }.joined(separator: "\n")
            return "\(timeline)\n\n\(transcript)"
        }

        return turns.map { turn in
            let label = turn.confidence < uncertainConfidenceThreshold ? "Unknown speaker" : turn.displayName
            return "[\(timestamp(turn.startTime))–\(timestamp(turn.endTime))] \(label): \(turn.text)"
        }.joined(separator: "\n\n")
    }

    public static func applySpeakerName(_ name: String, to speakerID: String, in segments: [SpeakerSegment]) -> [SpeakerSegment] {
        segments.map { segment in
            var copy = segment
            if copy.speakerID == speakerID { copy.displayName = name }
            return copy
        }
    }

    private static func displayName(for segment: SpeakerSegment, speakerNames: [String: String]) -> String {
        speakerNames[segment.speakerID] ?? segment.displayName
    }

    private static func mergeShortGaps(in segments: [SpeakerSegment], maxGap: TimeInterval = 0.25) -> [SpeakerSegment] {
        var merged: [SpeakerSegment] = []
        for segment in segments {
            if var last = merged.last, last.speakerID == segment.speakerID, segment.startTime - last.endTime <= maxGap {
                last.endTime = max(last.endTime, segment.endTime)
                last.confidence = min(last.confidence, segment.confidence)
                merged[merged.count - 1] = last
            } else {
                merged.append(segment)
            }
        }
        return merged
    }

    private static func normalizeTokenText(_ text: String) -> String {
        text
            .replacingOccurrences(of: "▁", with: " ")
            .replacingOccurrences(of: "Ġ", with: " ")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func timestamp(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
