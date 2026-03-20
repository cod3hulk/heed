import Foundation

@MainActor
@Observable
final class RecorderStateMachine {
    private(set) var state: RecorderState = .idle

    func toggleRecording() {
        switch state {
        case .idle:
            state = .recording
        case .recording:
            state = .transcribing
            // TODO: trigger actual transcription
        default:
            break
        }
    }

    func transcriptionComplete(text: String) {
        guard state == .transcribing else { return }
        state = .actionSelection
    }

    func selectAction(_ action: PostTranscriptionAction) {
        guard state == .actionSelection else { return }
        state = .processing
        // TODO: send to LLM
    }

    func processingComplete(result: String) {
        guard state == .processing else { return }
        state = .done(result: result)
    }

    func fail(message: String) {
        state = .error(message: message)
    }

    func reset() {
        state = .idle
    }
}

enum PostTranscriptionAction {
    case summarize
    case meetingFeedback
}
