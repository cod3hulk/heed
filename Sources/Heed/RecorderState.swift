import Foundation

enum RecorderState: Equatable {
    case idle
    case recording
    case transcribing
    case actionSelection
    case processing
    case done(result: String)
    case error(message: String)

    var label: String {
        switch self {
        case .idle: "Ready"
        case .recording: "Recording..."
        case .transcribing: "Transcribing..."
        case .actionSelection: "Select Action"
        case .processing: "Processing..."
        case .done: "Done"
        case .error: "Error"
        }
    }

    var isRecording: Bool {
        self == .recording
    }
}
