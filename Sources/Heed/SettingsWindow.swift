import AppKit
import SwiftUI

final class SettingsWindowController {
    private var window: NSWindow?

    @MainActor
    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let settingsView = SettingsView(config: ConfigManager.shared)
        let hostingController = NSHostingController(rootView: settingsView)

        let window = NSWindow(contentViewController: hostingController)
        window.title = "Heed Settings"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.setContentSize(NSSize(width: 480, height: 520))
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        self.window = window
    }
}

struct SettingsView: View {
    @Bindable var config: ConfigManager

    var body: some View {
        TabView {
            Tab("LLM", systemImage: "cpu") {
                llmSettings
            }
            Tab("Prompts", systemImage: "text.quote") {
                promptSettings
            }
        }
        .padding()
        .frame(minWidth: 450, minHeight: 400)
    }

    private var llmSettings: some View {
        Form {
            Picker("Provider", selection: $config.selectedProvider) {
                ForEach(LLMProviderType.allCases, id: \.self) { provider in
                    Text(provider.rawValue).tag(provider)
                }
            }

            if config.selectedProvider == .ollama {
                TextField("Endpoint", text: $config.ollamaEndpoint)
                    .textFieldStyle(.roundedBorder)
                TextField("Model", text: $config.ollamaModel)
                    .textFieldStyle(.roundedBorder)
            }

            if config.selectedProvider == .claudeCLI {
                Text("Uses the `claude` CLI tool. Make sure it's installed and available in PATH.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if config.selectedProvider == .geminiCLI {
                Text("Uses the `gemini` CLI tool. Make sure it's installed and available in PATH.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
    }

    private var promptSettings: some View {
        Form {
            Section("Summary Prompt (⌘1)") {
                TextEditor(text: $config.summaryPrompt)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 120)
            }

            Section("Feedback Prompt (⌘2)") {
                TextEditor(text: $config.feedbackPrompt)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 120)
            }
        }
        .padding()
    }
}
