import Foundation

enum LLMProviderType: String, CaseIterable, Codable, Sendable {
    case ollama = "Ollama"
    case claudeCLI = "Claude CLI"
    case geminiCLI = "Gemini CLI"
}

@MainActor
@Observable
final class ConfigManager {
    static let shared = ConfigManager()

    var selectedProvider: LLMProviderType {
        didSet { save() }
    }

    var ollamaEndpoint: String {
        didSet { save() }
    }

    var ollamaModel: String {
        didSet { save() }
    }

    var summaryPrompt: String {
        didSet { save() }
    }

    var feedbackPrompt: String {
        didSet { save() }
    }

    private static let defaultSummaryPrompt = """
        Summarize the following meeting transcript. Include:
        - Key discussion points
        - Decisions made
        - Action items with owners (if mentioned)
        Keep the summary concise and well-structured.
        """

    private static let defaultFeedbackPrompt = """
        Review the following meeting transcript and provide feedback on:
        - Meeting effectiveness and structure
        - Clarity of communication
        - Whether goals/agenda items were addressed
        - Suggestions for improvement
        """

    private init() {
        let defaults = UserDefaults.standard
        self.selectedProvider = LLMProviderType(rawValue: defaults.string(forKey: "selectedProvider") ?? "") ?? .ollama
        self.ollamaEndpoint = defaults.string(forKey: "ollamaEndpoint") ?? "http://localhost:11434"
        self.ollamaModel = defaults.string(forKey: "ollamaModel") ?? "llama3.2"
        self.summaryPrompt = defaults.string(forKey: "summaryPrompt") ?? Self.defaultSummaryPrompt
        self.feedbackPrompt = defaults.string(forKey: "feedbackPrompt") ?? Self.defaultFeedbackPrompt
    }

    private func save() {
        let defaults = UserDefaults.standard
        defaults.set(selectedProvider.rawValue, forKey: "selectedProvider")
        defaults.set(ollamaEndpoint, forKey: "ollamaEndpoint")
        defaults.set(ollamaModel, forKey: "ollamaModel")
        defaults.set(summaryPrompt, forKey: "summaryPrompt")
        defaults.set(feedbackPrompt, forKey: "feedbackPrompt")
    }

    func createProvider() -> any LLMProvider {
        switch selectedProvider {
        case .ollama:
            OllamaProvider(
                endpoint: URL(string: ollamaEndpoint) ?? URL(string: "http://localhost:11434")!,
                model: ollamaModel
            )
        case .claudeCLI:
            ClaudeCLIProvider()
        case .geminiCLI:
            GeminiCLIProvider()
        }
    }

    func prompt(for action: PostTranscriptionAction) -> String {
        switch action {
        case .summarize: summaryPrompt
        case .meetingFeedback: feedbackPrompt
        }
    }
}
