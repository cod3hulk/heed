import AppKit
import SwiftUI

// MARK: - Window Controller

@MainActor
final class SettingsWindowController: NSWindowController {
    private let vm: SettingsViewModel

    init() {
        let vm = SettingsViewModel()
        let hosting = NSHostingController(rootView: SettingsView(vm: vm))
        let window = NSWindow(contentViewController: hosting)
        window.title = "Heed Settings"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        self.vm = vm
        super.init(window: window)
        vm.onClose = { [weak self] in self?.close() }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show() {
        vm.syncFromConfig()  // reset to saved config, discarding any prior unsaved edits
        window?.center()
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - View Model

@MainActor
final class SettingsViewModel: ObservableObject {
    enum RecordingField { case discard, copy, summarize, feedback }

    // Key bindings
    @Published var discard:   KeyBinding
    @Published var copy:      KeyBinding
    @Published var summarize: KeyBinding
    @Published var feedback:  KeyBinding
    @Published var recordingField: RecordingField? = nil

    // LLM
    @Published var llmProvider: LLMProvider
    @Published var claudeCLIPath: String
    @Published var geminiCLIPath: String
    @Published var ollamaEndpoint: String
    @Published var ollamaModel: String

    // Prompts
    @Published var summaryPrompt: String
    @Published var feedbackPrompt: String

    var onClose: (() -> Void)?
    private var monitor: Any?

    init() {
        let cfg = ConfigManager.shared
        discard       = cfg.discardBinding
        copy          = cfg.copyBinding
        summarize     = cfg.summarizeBinding
        feedback      = cfg.feedbackBinding
        llmProvider    = cfg.llmProvider
        claudeCLIPath  = cfg.claudeCLIPath
        geminiCLIPath  = cfg.geminiCLIPath
        ollamaEndpoint = cfg.ollamaEndpoint
        ollamaModel    = cfg.ollamaModel
        summaryPrompt  = cfg.summaryPrompt
        feedbackPrompt = cfg.feedbackPrompt
    }

    // MARK: Key recording

    func startRecording(_ field: RecordingField) {
        stopRecording()
        recordingField = field
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if KeyBinding.isModifierKeyCode(event.keyCode) { return event }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).rawValue
            let binding = KeyBinding(keyCode: event.keyCode, modifierFlags: flags)
            switch field {
            case .discard:   self.discard   = binding
            case .copy:      self.copy      = binding
            case .summarize: self.summarize = binding
            case .feedback:  self.feedback  = binding
            }
            self.stopRecording()
            return nil
        }
    }

    func stopRecording() {
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        recordingField = nil
    }

    // MARK: Actions

    func saveAndClose() {
        stopRecording()
        let cfg = ConfigManager.shared
        cfg.discardBinding   = discard
        cfg.copyBinding      = copy
        cfg.summarizeBinding = summarize
        cfg.feedbackBinding  = feedback
        cfg.llmProvider     = llmProvider
        cfg.claudeCLIPath   = claudeCLIPath
        cfg.geminiCLIPath   = geminiCLIPath
        cfg.ollamaEndpoint  = ollamaEndpoint
        cfg.ollamaModel     = ollamaModel
        cfg.summaryPrompt   = summaryPrompt
        cfg.feedbackPrompt   = feedbackPrompt
        cfg.save()
        onClose?()
    }

    func cancelAndClose() {
        stopRecording()
        onClose?()
    }

    /// Re-load values from the saved config. Called each time the window is shown
    /// so that a previous cancel doesn't leave stale unsaved values on screen.
    func syncFromConfig() {
        let cfg = ConfigManager.shared
        discard        = cfg.discardBinding
        copy           = cfg.copyBinding
        summarize      = cfg.summarizeBinding
        feedback       = cfg.feedbackBinding
        llmProvider    = cfg.llmProvider
        claudeCLIPath  = cfg.claudeCLIPath
        geminiCLIPath  = cfg.geminiCLIPath
        ollamaEndpoint = cfg.ollamaEndpoint
        ollamaModel    = cfg.ollamaModel
        summaryPrompt  = cfg.summaryPrompt
        feedbackPrompt = cfg.feedbackPrompt
    }
}

// MARK: - Root Settings View

struct SettingsView: View {
    @ObservedObject var vm: SettingsViewModel
    @State private var selectedTab = 0

    var body: some View {
        VStack(spacing: 0) {
            // Tab selector — segmented control avoids TabView's title-bar clipping issue
            Picker("", selection: $selectedTab) {
                Text("Key Bindings").tag(0)
                Text("LLM").tag(1)
                Text("Prompts").tag(2)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 12)

            Divider()

            Group {
                switch selectedTab {
                case 0: KeyBindingsTab(vm: vm)
                case 1: LLMTab(vm: vm)
                default: PromptsTab(vm: vm)
                }
            }
            .frame(width: 500, height: 340)

            Divider()

            HStack {
                Spacer()
                Button("Cancel") { vm.cancelAndClose() }
                    .keyboardShortcut(.escape, modifiers: [])
                Button("Save") { vm.saveAndClose() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .onDisappear { vm.stopRecording() }
    }
}

// MARK: - Key Bindings Tab

struct KeyBindingsTab: View {
    @ObservedObject var vm: SettingsViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(spacing: 0) {
                BindingRow(
                    label: "Discard",
                    binding: vm.discard,
                    isRecording: vm.recordingField == .discard,
                    onRecord: { vm.startRecording(.discard) }
                )
                Divider()
                BindingRow(
                    label: "Copy Transcript",
                    binding: vm.copy,
                    isRecording: vm.recordingField == .copy,
                    onRecord: { vm.startRecording(.copy) }
                )
                Divider()
                BindingRow(
                    label: "Summarize",
                    binding: vm.summarize,
                    isRecording: vm.recordingField == .summarize,
                    onRecord: { vm.startRecording(.summarize) }
                )
                Divider()
                BindingRow(
                    label: "Meeting Feedback",
                    binding: vm.feedback,
                    isRecording: vm.recordingField == .feedback,
                    onRecord: { vm.startRecording(.feedback) }
                )
            }
            .background(Color(NSColor.controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(NSColor.separatorColor), lineWidth: 0.5))

            HStack {
                Button("Reset to Defaults") {
                    vm.discard   = .discard
                    vm.copy      = .copy
                    vm.summarize = .summarize
                    vm.feedback  = .feedback
                }
                .foregroundColor(.secondary)
                Spacer()
            }

            Spacer()
        }
        .padding(20)
    }
}

struct BindingRow: View {
    let label: String
    let binding: KeyBinding
    let isRecording: Bool
    let onRecord: () -> Void

    var body: some View {
        HStack {
            Text(label)
                .frame(width: 160, alignment: .leading)
            Spacer()
            Button(action: onRecord) {
                Text(isRecording ? "Press keys…" : binding.displayString)
                    .frame(minWidth: 90)
                    .foregroundColor(isRecording ? .secondary : .primary)
            }
            .help(isRecording ? "Press the key combination you want to use" : "Click to record a new shortcut")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

// MARK: - LLM Tab

struct LLMTab: View {
    @ObservedObject var vm: SettingsViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Provider picker
            VStack(alignment: .leading, spacing: 6) {
                Text("Provider")
                    .font(.headline)
                Picker("", selection: $vm.llmProvider) {
                    ForEach(LLMProvider.allCases) { provider in
                        Text(provider.rawValue).tag(provider)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .fixedSize()

                Text(vm.llmProvider.description)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            // Provider-specific config
            switch vm.llmProvider {
            case .claudeCLI:
                VStack(alignment: .leading, spacing: 6) {
                    Text("Binary Path")
                        .font(.headline)
                    TextField("/opt/homebrew/bin/claude", text: $vm.claudeCLIPath)
                        .textFieldStyle(.roundedBorder)
                    Text("Leave blank to resolve claude via your $PATH (recommended). Set an explicit path if the app cannot find it.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            case .geminiCLI:
                VStack(alignment: .leading, spacing: 6) {
                    Text("Binary Path")
                        .font(.headline)
                    TextField("/opt/homebrew/bin/gemini", text: $vm.geminiCLIPath)
                        .textFieldStyle(.roundedBorder)
                    Text("Leave blank to resolve gemini via your $PATH (recommended). Set an explicit path if the app cannot find it.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            case .ollama:
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Endpoint URL")
                            .font(.headline)
                        TextField("http://localhost:11434", text: $vm.ollamaEndpoint)
                            .textFieldStyle(.roundedBorder)
                        Text("Leave blank to use the default local address.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Model")
                            .font(.headline)
                        TextField("llama3", text: $vm.ollamaModel)
                            .textFieldStyle(.roundedBorder)
                        Text("Must match a model you have pulled in Ollama (e.g. llama3, mistral, phi3).")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }

            Spacer()
        }
        .padding(20)
    }
}

// MARK: - Prompts Tab

struct PromptsTab: View {
    @ObservedObject var vm: SettingsViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Summarize (⌘1)")
                    .font(.headline)
                TextEditor(text: $vm.summaryPrompt)
                    .font(.system(size: 12))
                    .frame(height: 90)
                    .scrollContentBackground(.hidden)
                    .background(Color(NSColor.controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(NSColor.separatorColor), lineWidth: 0.5))
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Meeting Feedback (⌘2)")
                    .font(.headline)
                TextEditor(text: $vm.feedbackPrompt)
                    .font(.system(size: 12))
                    .frame(height: 90)
                    .scrollContentBackground(.hidden)
                    .background(Color(NSColor.controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(NSColor.separatorColor), lineWidth: 0.5))
            }

            HStack {
                Button("Reset to Defaults") { vm.summaryPrompt = ConfigManager.defaultSummaryPrompt; vm.feedbackPrompt = ConfigManager.defaultFeedbackPrompt }
                    .foregroundColor(.secondary)
                Spacer()
            }
        }
        .padding(20)
    }
}
