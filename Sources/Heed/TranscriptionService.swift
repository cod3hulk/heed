@preconcurrency import AVFoundation

@MainActor
final class TranscriptionService {
    private static let chunkDurationSeconds: Double = 90.0
    private static let sampleRate: Double = 16000.0

    func transcribe(buffers: [AVAudioPCMBuffer]) async throws -> String {
        let merged = mergeBuffers(buffers)
        let chunks = chunkAudio(merged)

        var fullTranscript = ""
        for chunk in chunks {
            let text = try await transcribeChunk(chunk)
            if !fullTranscript.isEmpty {
                fullTranscript += " "
            }
            fullTranscript += text
        }

        return fullTranscript
    }

    // MARK: - Audio Processing

    private func mergeBuffers(_ buffers: [AVAudioPCMBuffer]) -> [Float] {
        var samples: [Float] = []
        for buffer in buffers {
            guard let channelData = buffer.floatChannelData?[0] else { continue }
            let count = Int(buffer.frameLength)
            samples.append(contentsOf: UnsafeBufferPointer(start: channelData, count: count))
        }
        return samples
    }

    private func chunkAudio(_ samples: [Float]) -> [[Float]] {
        let chunkSize = Int(Self.chunkDurationSeconds * Self.sampleRate)
        var chunks: [[Float]] = []
        var offset = 0

        while offset < samples.count {
            let end = min(offset + chunkSize, samples.count)
            chunks.append(Array(samples[offset..<end]))
            offset = end
        }

        return chunks
    }

    // MARK: - Inference

    private func transcribeChunk(_ samples: [Float]) async throws -> String {
        // TODO: Integrate Parakeet TDT 0.6B V3 Core ML model
        // The model expects 16kHz mono Float32 audio
        // First run will trigger a one-time model download (~478 MB)
        //
        // For now, return a placeholder indicating the chunk was processed
        // This will be replaced with actual Core ML inference
        throw TranscriptionError.modelNotLoaded
    }
}

enum TranscriptionError: Error, CustomStringConvertible {
    case modelNotLoaded
    case inferenceFailed(String)

    var description: String {
        switch self {
        case .modelNotLoaded:
            "Transcription model not loaded. Please ensure the Parakeet TDT model is available."
        case .inferenceFailed(let reason):
            "Transcription failed: \(reason)"
        }
    }
}
