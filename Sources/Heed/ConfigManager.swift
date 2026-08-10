import AppKit

extension Notification.Name {
    /// Posted after Settings saves so the meeting detector can start/stop live.
    static let autoDetectMeetingsChanged = Notification.Name("autoDetectMeetingsChanged")
}

// MARK: - KeyBinding

struct KeyBinding: Codable, Equatable {
    var keyCode: UInt16
    var modifierFlags: UInt  // NSEvent.ModifierFlags device-independent rawValue

    // MARK: Defaults

    static let discard   = KeyBinding(keyCode: 53, modifierFlags: 0)  // ESC
    static let copy      = KeyBinding(keyCode: 36, modifierFlags: 0)  // Return
    static let summarize = KeyBinding(keyCode: 18, modifierFlags: NSEvent.ModifierFlags.command.rawValue)  // ⌘1
    static let feedback  = KeyBinding(keyCode: 19, modifierFlags: NSEvent.ModifierFlags.command.rawValue)  // ⌘2
    static let ask       = KeyBinding(keyCode: 49, modifierFlags: NSEvent.ModifierFlags.option.rawValue)   // ⌥Space

    // MARK: Display

    var displayString: String {
        var s = ""
        let flags = NSEvent.ModifierFlags(rawValue: modifierFlags)
        if flags.contains(.control) { s += "⌃" }
        if flags.contains(.option)  { s += "⌥" }
        if flags.contains(.shift)   { s += "⇧" }
        if flags.contains(.command) { s += "⌘" }
        s += Self.keyNames[keyCode] ?? "[\(keyCode)]"
        return s
    }

    private static let keyNames: [UInt16: String] = [
        // Special
        53: "⎋", 36: "↵", 76: "↩", 51: "⌫", 117: "⌦", 48: "⇥", 49: "Space",
        // Arrows
        126: "↑", 125: "↓", 123: "←", 124: "→",
        // Top-row digits
        18: "1", 19: "2", 20: "3", 21: "4", 23: "5",
        22: "6", 26: "7", 28: "8", 25: "9", 29: "0",
        // Letters
         0: "A",  1: "S",  2: "D",  3: "F",  4: "H",  5: "G",  6: "Z",  7: "X",
         8: "C",  9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y",
        17: "T", 31: "O", 32: "U", 34: "I", 35: "P", 37: "L", 38: "J", 40: "K",
        45: "N", 46: "M",
        // F-keys
        122: "F1", 120: "F2",  99: "F3", 118: "F4",  96: "F5",  97: "F6",
         98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
    ]

    static func isModifierKeyCode(_ code: UInt16) -> Bool {
        [54, 55, 56, 57, 58, 59, 60, 61, 62, 63].contains(code)
    }
}

// MARK: - LLM Provider

enum LLMProvider: String, Codable, CaseIterable, Identifiable {
    case claudeCLI = "Claude CLI"
    case geminiCLI = "Gemini CLI"
    case ollama    = "Ollama"

    var id: String { rawValue }

    var description: String {
        switch self {
        case .claudeCLI: return "Runs the claude CLI binary, piping the transcript via stdin."
        case .geminiCLI: return "Runs the gemini CLI binary, piping the transcript via stdin."
        case .ollama:    return "Sends requests to a local Ollama HTTP server (/api/generate)."
        }
    }
}

// MARK: - ConfigManager

@MainActor
final class ConfigManager: ObservableObject {
    static let shared = ConfigManager()

    // Key bindings
    @Published var discardBinding:   KeyBinding
    @Published var copyBinding:      KeyBinding
    @Published var summarizeBinding: KeyBinding
    @Published var feedbackBinding:  KeyBinding
    @Published var askBinding:       KeyBinding

    // LLM
    @Published var llmProvider: LLMProvider
    @Published var claudeCLIPath: String   // empty = resolve via $PATH in zsh login shell
    @Published var geminiCLIPath: String   // empty = resolve via $PATH in zsh login shell
    @Published var ollamaEndpoint: String  // empty = http://localhost:11434
    @Published var ollamaModel: String     // empty = qwen3:4b-instruct-2507-q4_K_M

    // Prompts
    @Published var summaryPrompt: String
    @Published var feedbackPrompt: String
    @Published var qaPrompt: String

    // General
    @Published var autoDetectMeetings: Bool

    static let defaultSummaryPrompt =
        "Summarize this meeting transcript concisely. List key discussion topics, decisions made, and action items. Be brief and use bullet points."

    static let defaultFeedbackPrompt =
        "Analyze this meeting transcript and provide structured feedback covering: key decisions made, action items with owners (if mentioned), unresolved questions, overall sentiment, and suggested follow-ups."

    static let defaultQAPrompt =
        "You are answering a follow-up question about a meeting that is currently in progress. Use only the transcript below as your source of truth. If the answer isn't there, say so briefly. Keep the answer short and specific."

    private init() {
        discardBinding   = Self.loadCodable(key: "keyBinding.discard",   default: .discard)
        copyBinding      = Self.loadCodable(key: "keyBinding.copy",      default: .copy)
        summarizeBinding = Self.loadCodable(key: "keyBinding.summarize", default: .summarize)
        feedbackBinding  = Self.loadCodable(key: "keyBinding.feedback",  default: .feedback)
        askBinding       = Self.loadCodable(key: "keyBinding.ask",       default: .ask)

        llmProvider   = Self.loadCodable(key: "llm.provider",  default: .claudeCLI)
        claudeCLIPath  = UserDefaults.standard.string(forKey: "llm.claudeCLIPath")   ?? ""
        geminiCLIPath  = UserDefaults.standard.string(forKey: "llm.geminiCLIPath")   ?? ""
        ollamaEndpoint = UserDefaults.standard.string(forKey: "llm.ollamaEndpoint") ?? ""
        ollamaModel    = UserDefaults.standard.string(forKey: "llm.ollamaModel")    ?? ""

        summaryPrompt  = UserDefaults.standard.string(forKey: "prompt.summary")  ?? Self.defaultSummaryPrompt
        feedbackPrompt = UserDefaults.standard.string(forKey: "prompt.feedback") ?? Self.defaultFeedbackPrompt
        qaPrompt       = UserDefaults.standard.string(forKey: "prompt.qa")       ?? Self.defaultQAPrompt

        // Default ON. Plain bool(forKey:) returns false for an unset key, so nil-check the object.
        autoDetectMeetings = (UserDefaults.standard.object(forKey: "autoDetectMeetings") as? Bool) ?? true
    }

    func save() {
        storeCodable(discardBinding,   key: "keyBinding.discard")
        storeCodable(copyBinding,      key: "keyBinding.copy")
        storeCodable(summarizeBinding, key: "keyBinding.summarize")
        storeCodable(feedbackBinding,  key: "keyBinding.feedback")
        storeCodable(askBinding,       key: "keyBinding.ask")

        storeCodable(llmProvider, key: "llm.provider")
        UserDefaults.standard.set(claudeCLIPath,   forKey: "llm.claudeCLIPath")
        UserDefaults.standard.set(geminiCLIPath,   forKey: "llm.geminiCLIPath")
        UserDefaults.standard.set(ollamaEndpoint,  forKey: "llm.ollamaEndpoint")
        UserDefaults.standard.set(ollamaModel,     forKey: "llm.ollamaModel")

        UserDefaults.standard.set(summaryPrompt,  forKey: "prompt.summary")
        UserDefaults.standard.set(feedbackPrompt, forKey: "prompt.feedback")
        UserDefaults.standard.set(qaPrompt,       forKey: "prompt.qa")

        UserDefaults.standard.set(autoDetectMeetings, forKey: "autoDetectMeetings")
    }

    func resetKeyBindings() {
        discardBinding   = .discard
        copyBinding      = .copy
        summarizeBinding = .summarize
        feedbackBinding  = .feedback
        askBinding       = .ask
    }

    func resetPrompts() {
        summaryPrompt  = Self.defaultSummaryPrompt
        feedbackPrompt = Self.defaultFeedbackPrompt
        qaPrompt       = Self.defaultQAPrompt
    }

    // MARK: Private

    private static func loadCodable<T: Codable>(key: String, default fallback: T) -> T {
        guard let data = UserDefaults.standard.data(forKey: key),
              let value = try? JSONDecoder().decode(T.self, from: data) else { return fallback }
        return value
    }

    private func storeCodable<T: Codable>(_ value: T, key: String) {
        if let data = try? JSONEncoder().encode(value) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
