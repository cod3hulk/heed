import AppKit

// MARK: - KeyBinding

struct KeyBinding: Codable, Equatable {
    var keyCode: UInt16
    var modifierFlags: UInt  // NSEvent.ModifierFlags device-independent rawValue

    // MARK: Defaults

    static let discard   = KeyBinding(keyCode: 53, modifierFlags: 0)  // ESC
    static let copy      = KeyBinding(keyCode: 36, modifierFlags: 0)  // Return
    static let summarize = KeyBinding(keyCode: 18, modifierFlags: NSEvent.ModifierFlags.command.rawValue)  // ⌘1
    static let feedback  = KeyBinding(keyCode: 19, modifierFlags: NSEvent.ModifierFlags.command.rawValue)  // ⌘2

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

    // Covers the key codes users are likely to configure
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

    // Returns true if this key code is a bare modifier key (Shift, Cmd, etc.)
    static func isModifierKeyCode(_ code: UInt16) -> Bool {
        [54, 55, 56, 57, 58, 59, 60, 61, 62, 63].contains(code)
    }
}

// MARK: - ConfigManager

@MainActor
final class ConfigManager: ObservableObject {
    static let shared = ConfigManager()

    @Published var discardBinding:   KeyBinding
    @Published var copyBinding:      KeyBinding
    @Published var summarizeBinding: KeyBinding
    @Published var feedbackBinding:  KeyBinding

    private init() {
        discardBinding   = Self.load(key: "keyBinding.discard",   default: .discard)
        copyBinding      = Self.load(key: "keyBinding.copy",      default: .copy)
        summarizeBinding = Self.load(key: "keyBinding.summarize", default: .summarize)
        feedbackBinding  = Self.load(key: "keyBinding.feedback",  default: .feedback)
    }

    func save() {
        store(discardBinding,   key: "keyBinding.discard")
        store(copyBinding,      key: "keyBinding.copy")
        store(summarizeBinding, key: "keyBinding.summarize")
        store(feedbackBinding,  key: "keyBinding.feedback")
    }

    func resetToDefaults() {
        discardBinding   = .discard
        copyBinding      = .copy
        summarizeBinding = .summarize
        feedbackBinding  = .feedback
    }

    // MARK: Private

    private static func load(key: String, default fallback: KeyBinding) -> KeyBinding {
        guard let data = UserDefaults.standard.data(forKey: key),
              let binding = try? JSONDecoder().decode(KeyBinding.self, from: data) else {
            return fallback
        }
        return binding
    }

    private func store(_ binding: KeyBinding, key: String) {
        if let data = try? JSONEncoder().encode(binding) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
