import AppKit
import SwiftUI

// MARK: - Window Controller

@MainActor
final class SettingsWindowController: NSWindowController {
    convenience init() {
        let vm = SettingsViewModel()
        let view = SettingsView(vm: vm)
        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.title = "Heed Settings"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 440, height: 270))
        self.init(window: window)
        vm.onClose = { [weak self] in self?.close() }
    }

    func show() {
        window?.center()
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - View Model

@MainActor
final class SettingsViewModel: ObservableObject {
    enum Field { case discard, copy, summarize, feedback }

    @Published var discard:   KeyBinding
    @Published var copy:      KeyBinding
    @Published var summarize: KeyBinding
    @Published var feedback:  KeyBinding
    @Published var recordingField: Field? = nil

    var onClose: (() -> Void)?

    private var monitor: Any?

    init() {
        let cfg = ConfigManager.shared
        discard   = cfg.discardBinding
        copy      = cfg.copyBinding
        summarize = cfg.summarizeBinding
        feedback  = cfg.feedbackBinding
    }

    func startRecording(_ field: Field) {
        stopRecording()
        recordingField = field
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            // Ignore bare modifier key presses
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

    func saveAndClose() {
        stopRecording()
        let cfg = ConfigManager.shared
        cfg.discardBinding   = discard
        cfg.copyBinding      = copy
        cfg.summarizeBinding = summarize
        cfg.feedbackBinding  = feedback
        cfg.save()
        onClose?()
    }

    func cancelAndClose() {
        stopRecording()
        onClose?()
    }

    func resetToDefaults() {
        discard   = .discard
        copy      = .copy
        summarize = .summarize
        feedback  = .feedback
    }
}

// MARK: - Settings View

struct SettingsView: View {
    @ObservedObject var vm: SettingsViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Key Bindings")
                .font(.headline)

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
                Button("Reset to Defaults") { vm.resetToDefaults() }
                    .foregroundColor(.secondary)
                Spacer()
                Button("Cancel") { vm.cancelAndClose() }
                    .keyboardShortcut(.escape, modifiers: [])
                Button("Save") { vm.saveAndClose() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 440)
        .onDisappear { vm.stopRecording() }
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
