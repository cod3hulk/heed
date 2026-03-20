import AppKit

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let stateMachine = RecorderStateMachine()
    private let audioCaptureService = AudioCaptureService()
    private let transcriptionService = TranscriptionService()
    private var overlayWindow: OverlayWindow!
    private let settingsController = SettingsWindowController()
    private let shortcutManager = GlobalShortcutManager()
    private var recordingMenuItem: NSMenuItem!
    private var currentTranscript: String = ""

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        setupOverlay()
        setupShortcuts()
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "record.circle", accessibilityDescription: "Heed")
            button.title = " Heed"
        }

        let menu = NSMenu()

        recordingMenuItem = NSMenuItem(title: "Start Recording ⇧⌘R", action: #selector(toggleRecording), keyEquivalent: "")
        recordingMenuItem.target = self
        menu.addItem(recordingMenuItem)

        menu.addItem(NSMenuItem.separator())

        let settingsItem = NSMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        statusItem.menu = menu
    }

    private func setupOverlay() {
        overlayWindow = OverlayWindow(stateMachine: stateMachine)
    }

    @objc private func toggleRecording() {
        if stateMachine.state == .idle {
            startRecording()
        } else if stateMachine.state.isRecording {
            stopRecording()
        }
    }

    private func startRecording() {
        stateMachine.toggleRecording()
        updateMenuState()
        updateOverlayVisibility()

        Task {
            do {
                try await audioCaptureService.startCapture()
            } catch {
                stateMachine.fail(message: "Failed to start capture: \(error)")
                updateMenuState()
                updateOverlayVisibility()
            }
        }
    }

    private func stopRecording() {
        stateMachine.toggleRecording()
        updateMenuState()
        updateOverlayVisibility()

        Task {
            let samples = await audioCaptureService.stopCapture()

            do {
                let transcript = try await transcriptionService.transcribe(samples: samples)
                currentTranscript = transcript
                stateMachine.transcriptionComplete(text: transcript)
                updateOverlayVisibility()
            } catch {
                stateMachine.fail(message: "Transcription failed: \(error)")
                updateMenuState()
                updateOverlayVisibility()
            }
        }
    }

    func handleAction(_ action: PostTranscriptionAction) {
        stateMachine.selectAction(action)
        updateOverlayVisibility()

        let config = ConfigManager.shared
        let provider = config.createProvider()
        let prompt = config.prompt(for: action)
        let transcript = currentTranscript

        Task {
            do {
                let result = try await provider.process(transcript: transcript, prompt: prompt)
                stateMachine.processingComplete(result: result)
                updateOverlayVisibility()
            } catch {
                stateMachine.fail(message: "LLM processing failed: \(error)")
                updateMenuState()
                updateOverlayVisibility()
            }
        }
    }

    private func setupShortcuts() {
        shortcutManager.register(
            onToggleRecording: { [weak self] in
                self?.toggleRecording()
            },
            onAction: { [weak self] action in
                self?.handleAction(action)
            }
        )
    }

    @objc private func openSettings() {
        settingsController.show()
    }

    private func updateMenuState() {
        if stateMachine.state.isRecording {
            recordingMenuItem.title = "Stop Recording ⇧⌘R"
            statusItem.button?.image = NSImage(systemSymbolName: "record.circle.fill", accessibilityDescription: "Heed — Recording")
        } else {
            recordingMenuItem.title = "Start Recording ⇧⌘R"
            statusItem.button?.image = NSImage(systemSymbolName: "record.circle", accessibilityDescription: "Heed")
        }
    }

    private func updateOverlayVisibility() {
        switch stateMachine.state {
        case .idle:
            overlayWindow.orderOut(nil)
        default:
            overlayWindow.orderFront(nil)
        }
    }
}
