import AppKit
import AVFoundation
import HeedCore
import ScreenCaptureKit

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let audioService = AudioCaptureService()
    private let systemAudio = SystemAudioCapture()
    private let shortcutManager = GlobalShortcutManager()
    private let overlay = OverlayWindow()
    private let meetingDetector = MeetingDetector()
    private let meetingPrompt = MeetingPromptWindow()
    private var recordingMenuItem: NSMenuItem!
    private lazy var settingsWindowController = SettingsWindowController()

    private enum AppPhase { case idle, recording, transcribing, done, processing }
    private var appPhase: AppPhase = .idle
    private var pendingTranscript = ""

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMainMenu()
        setupStatusItem()
        requestPermissionsUpfront()
        setupGlobalShortcut()
        setupMeetingDetector()
        overlay.onStopRecording = { [weak self] in
            self?.toggleRecording()
        }
        overlay.onDismiss = { [weak self] in
            self?.appPhase = .idle
            self?.recordingMenuItem.title = "Start Recording"
        }
        overlay.onSummarize = { [weak self] in
            self?.startSummarization()
        }
        overlay.onMeetingFeedback = { [weak self] in
            self?.startMeetingFeedback()
        }
        overlay.onAsk = { [weak self] question, exchangeID in
            self?.answerLiveQuestion(question: question, exchangeID: exchangeID)
        }
        // Defer past applicationDidFinishLaunching — runModal() inside this
        // delegate method crashes AppKit's autorelease pool later.
        DispatchQueue.main.async { self.checkModelAvailability() }
    }

    private func checkModelAvailability() {
        ModelManager.shared.ensureModelAvailable { available in
            if available {
                print("Parakeet model ready")
            } else {
                print("Parakeet model not yet downloaded — transcription will be unavailable")
            }
        }
    }

    private func setupGlobalShortcut() {
        shortcutManager.onToggleRecording = { [weak self] in
            self?.toggleRecording()
        }
        shortcutManager.onAsk = { [weak self] in
            self?.overlay.toggleQA()
        }
        shortcutManager.start()
    }

    private func setupMeetingDetector() {
        // Offer to start recording when idle, or offer to stop when a recording is in progress —
        // never interrupt transcription/processing.
        meetingDetector.shouldPrompt = { [weak self] in
            guard let self else { return false }
            return self.appPhase == .idle || self.appPhase == .recording
        }
        meetingDetector.onMeetingDetected = { [weak self] in
            guard let self, self.appPhase == .idle else { return }
            self.meetingPrompt.show(
                kind: .offerStart,
                onConfirm: { [weak self] in
                    self?.meetingPrompt.hide()
                    self?.toggleRecording()
                },
                onDismiss: { [weak self] in
                    self?.meetingPrompt.hide()
                }
            )
        }
        meetingDetector.onMeetingEnded = { [weak self] in
            guard let self else { return }
            if self.appPhase == .recording {
                self.meetingPrompt.show(
                    kind: .offerStop,
                    onConfirm: { [weak self] in
                        self?.meetingPrompt.hide()
                        self?.toggleRecording()
                    },
                    onDismiss: { [weak self] in
                        self?.meetingPrompt.hide()
                    }
                )
            } else {
                // Auto-dismiss a still-open start-prompt if the meeting ended before the user answered.
                self.meetingPrompt.hide()
            }
        }

        if ConfigManager.shared.autoDetectMeetings {
            meetingDetector.start()
        }

        // Pick up the Settings toggle live (posted from SettingsViewModel.saveAndClose()).
        NotificationCenter.default.addObserver(
            forName: .autoDetectMeetingsChanged, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if ConfigManager.shared.autoDetectMeetings {
                    self.meetingDetector.start()
                } else {
                    self.meetingDetector.stop()
                    self.meetingPrompt.hide()
                }
            }
        }
    }

    // A hidden main menu is required for copy/paste (Cmd+C/V/X/A) to work in
    // text fields in LSUIElement apps. The menu bar is never shown to the user,
    // but AppKit routes edit shortcuts through NSApp.mainMenu's responder chain.
    private func setupMainMenu() {
        let main = NSMenu()

        let editItem = NSMenuItem()
        main.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        editItem.submenu = edit
        edit.addItem(NSMenuItem(title: "Cut",        action: #selector(NSText.cut(_:)),       keyEquivalent: "x"))
        edit.addItem(NSMenuItem(title: "Copy",       action: #selector(NSText.copy(_:)),      keyEquivalent: "c"))
        edit.addItem(NSMenuItem(title: "Paste",      action: #selector(NSText.paste(_:)),     keyEquivalent: "v"))
        edit.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        edit.addItem(.separator())
        edit.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        edit.addItem(NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "Z"))

        NSApp.mainMenu = main
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "ear.fill", accessibilityDescription: "Heed")
        }

        let menu = NSMenu()

        recordingMenuItem = NSMenuItem(title: "Start Recording", action: #selector(toggleRecording), keyEquivalent: "r")
        recordingMenuItem.keyEquivalentModifierMask = [.command, .shift]
        recordingMenuItem.target = self
        menu.addItem(recordingMenuItem)

        menu.addItem(NSMenuItem.separator())

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.keyEquivalentModifierMask = .command
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        statusItem.menu = menu
    }

    private func requestPermissionsUpfront() {
        // Request mic permission on launch so the app restart happens
        // before the user tries to record, not during recording
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                print("Microphone permission \(granted ? "granted" : "denied")")
            }
        case .denied, .restricted:
            print("Microphone permission denied. Please enable in System Settings > Privacy & Security > Microphone.")
        case .authorized:
            print("Microphone permission already granted")
        @unknown default:
            break
        }

        // Screen recording permission is requested naturally when the user starts
        // recording (startCapture calls SCShareableContent at that point). We don't
        // pre-warm it here because that caused a spurious picker at launch — before
        // the user is about to record — and the macOS 14+ privacy picker has a
        // "Capture system audio" toggle that defaults to OFF. Showing it at the
        // right moment (when recording starts) makes it clearer what to enable.
    }

    private func saveWAV(samples: [Float], sampleRate: Int, to url: URL) {
        let bytesPerSample = 2 // 16-bit PCM
        let dataSize = samples.count * bytesPerSample
        let fileSize = 44 + dataSize

        var data = Data()

        // RIFF header
        data.append(contentsOf: "RIFF".utf8)
        data.append(contentsOf: withUnsafeBytes(of: UInt32(fileSize - 8).littleEndian) { Array($0) })
        data.append(contentsOf: "WAVE".utf8)

        // fmt chunk
        data.append(contentsOf: "fmt ".utf8)
        data.append(contentsOf: withUnsafeBytes(of: UInt32(16).littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Array($0) }) // PCM
        data.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Array($0) }) // mono
        data.append(contentsOf: withUnsafeBytes(of: UInt32(sampleRate).littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: UInt32(sampleRate * bytesPerSample).littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: UInt16(bytesPerSample).littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: UInt16(16).littleEndian) { Array($0) }) // bits per sample

        // data chunk
        data.append(contentsOf: "data".utf8)
        data.append(contentsOf: withUnsafeBytes(of: UInt32(dataSize).littleEndian) { Array($0) })

        for sample in samples {
            let clamped = max(-1.0, min(1.0, sample))
            let int16 = Int16(clamped * 32767)
            data.append(contentsOf: withUnsafeBytes(of: int16.littleEndian) { Array($0) })
        }

        try? data.write(to: url)
    }

    @objc private func openSettings() {
        settingsWindowController.show()
    }

    @objc private func toggleRecording() {
        switch appPhase {
        case .idle:
            startRecording()
        case .recording:
            stopRecordingAndTranscribe()
        case .transcribing, .processing:
            break // ignore presses while processing
        case .done:
            overlay.hide()
            appPhase = .idle
            recordingMenuItem.title = "Start Recording"
        }
    }

    private func startRecording() {
        do {
            audioService.onRecordingFailed = { [weak self] message in
                Task { @MainActor [weak self] in
                    self?.handleRecordingFailure(message: message)
                }
            }
            try audioService.startRecording()
            systemAudio.onError = { [weak self] error in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    print("System audio error: \(error)")
                    self.openScreenRecordingSettings()
                }
            }
            Task {
                do {
                    try await systemAudio.startCapture()
                } catch {
                    print("System audio capture unavailable: \(error) — mic only")
                    openScreenRecordingSettings()
                }
            }
            overlay.show(audioService: audioService, systemAudio: systemAudio)
            shortcutManager.registerAskShortcut(binding: ConfigManager.shared.askBinding)
            recordingMenuItem.title = "Stop Recording"
            appPhase = .recording
        } catch {
            print("Failed to start recording: \(error)")
        }
    }

    private func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    private func handleRecordingFailure(message: String) {
        shortcutManager.unregisterAskShortcut()
        overlay.hide()
        appPhase = .idle
        recordingMenuItem.title = "Start Recording"

        let alert = NSAlert()
        alert.messageText = "Recording Stopped"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func warnSystemAudioNotCaptured() {
        let alert = NSAlert()
        alert.messageText = "System audio not captured"
        alert.informativeText = """
            When the permission dialog appeared, the "Also capture audio from this Mac" toggle \
            must be enabled. Start a new recording — when the dialog appears, turn on that toggle \
            before clicking Continue.
            """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func stopRecordingAndTranscribe() {
        shortcutManager.unregisterAskShortcut()
        let micSamples = audioService.stopRecording()
        appPhase = .transcribing
        recordingMenuItem.title = "Transcribing…"
        overlay.transitionTo(.transcribing)

        Task {
            let sysSamples16k = await stopSystemAudio()
            if sysSamples16k.isEmpty {
                warnSystemAudioNotCaptured()
            }
            let mixed = mixAudio(mic: micSamples, system: sysSamples16k)

            let supportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Heed")
            try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
            let wavURL = supportDir.appendingPathComponent("recording_\(formatter.string(from: Date())).wav")
            saveWAV(samples: mixed, sampleRate: 16000, to: wavURL)
            print("Saved recording to \(wavURL.path)")

            guard ModelManager.shared.isReady else {
                print("Model not ready — skipping transcription")
                overlay.hide()
                appPhase = .idle
                recordingMenuItem.title = "Start Recording"
                return
            }

            print("Transcribing \(String(format: "%.1f", Double(mixed.count) / 16000))s of audio…")
            let transcript = await ModelManager.shared.transcribe(mixed) ?? ""
            print("Transcript: \(transcript)")

            let displayText = transcript.isEmpty ? "(no speech detected)" : transcript
            pendingTranscript = transcript
            overlay.transitionTo(.done(displayText))
            appPhase = .done
            recordingMenuItem.title = "Start Recording"
        }
    }

    private func stopSystemAudio() async -> [Float] {
        return await systemAudio.stopCapture()
    }

    private func startSummarization() {
        guard appPhase == .done, !pendingTranscript.isEmpty else { return }

        // Check cache first
        if let cached = overlay.getCachedSummary() {
            let hasFeedback = overlay.getCachedFeedback() != nil
            overlay.transitionTo(.result(cached, title: "Summary", hasSummary: true, hasFeedback: hasFeedback))
            return
        }

        appPhase = .processing
        recordingMenuItem.title = "Summarizing…"
        overlay.transitionTo(.processing(label: "SUMMARIZING"))

        // Capture all config synchronously on the main actor before entering the Task.
        let transcript = pendingTranscript
        let prompt     = ConfigManager.shared.summaryPrompt
        let provider   = ConfigManager.shared.llmProvider

        Task {
            let summary = await runLLM(transcript: transcript, prompt: prompt, provider: provider)
            let result  = summary ?? "(summarization failed)"
            let hasFeedback = overlay.getCachedFeedback() != nil
            overlay.transitionTo(.result(result, title: "Summary", hasSummary: true, hasFeedback: hasFeedback))
            appPhase = .done
            recordingMenuItem.title = "Start Recording"
        }
    }

    private func startMeetingFeedback() {
        guard appPhase == .done, !pendingTranscript.isEmpty else { return }

        // Check cache first
        if let cached = overlay.getCachedFeedback() {
            let hasSummary = overlay.getCachedSummary() != nil
            overlay.transitionTo(.result(cached, title: "Meeting Feedback", hasSummary: hasSummary, hasFeedback: true))
            return
        }

        appPhase = .processing
        recordingMenuItem.title = "Analyzing…"
        overlay.transitionTo(.processing(label: "ANALYZING"))

        let transcript = pendingTranscript
        let prompt     = ConfigManager.shared.feedbackPrompt
        let provider   = ConfigManager.shared.llmProvider

        Task {
            let result  = await runLLM(transcript: transcript, prompt: prompt, provider: provider)
            let display = result ?? "(feedback failed)"
            let hasSummary = overlay.getCachedSummary() != nil
            overlay.transitionTo(.result(display, title: "Meeting Feedback", hasSummary: hasSummary, hasFeedback: true))
            appPhase = .done
            recordingMenuItem.title = "Start Recording"
        }
    }

    // MARK: - Live Q&A

    private func answerLiveQuestion(question: String, exchangeID: UUID) {
        guard appPhase == .recording else { return }

        let micSnapshot = audioService.snapshotSamples()
        let systemSnapshot = systemAudio.snapshotSamples()
        let mixed = AudioUtilities.mixAudio(mic: micSnapshot, system: systemSnapshot)

        let prompt   = ConfigManager.shared.qaPrompt
        let provider = ConfigManager.shared.llmProvider

        Task { [weak self] in
            guard let self else { return }
            guard ModelManager.shared.isReady else {
                self.overlay.completeExchange(id: exchangeID, answer: "(transcription model not ready)")
                return
            }

            let transcript = await ModelManager.shared.transcribe(mixed) ?? ""
            if transcript.isEmpty {
                self.overlay.completeExchange(id: exchangeID, answer: "(no speech captured yet)")
                return
            }

            let composed = "\(prompt)\n\nQuestion: \(question)\n\nTranscript so far:"
            let answer = await self.runLLM(transcript: transcript, prompt: composed, provider: provider)
            self.overlay.completeExchange(id: exchangeID, answer: answer ?? "(no answer)")
        }
    }

    // MARK: - LLM dispatch

    private func runLLM(transcript: String, prompt: String, provider: LLMProvider) async -> String? {
        switch provider {
        case .claudeCLI:
            let path = ConfigManager.shared.claudeCLIPath.trimmingCharacters(in: .whitespaces)
            let binary = path.isEmpty ? "claude" : path
            return await runClaudeCLI(transcript: transcript, prompt: prompt, binary: binary)
        case .geminiCLI:
            let path = ConfigManager.shared.geminiCLIPath.trimmingCharacters(in: .whitespaces)
            let binary = path.isEmpty ? "gemini" : path
            return await runClaudeCLI(transcript: transcript, prompt: prompt, binary: binary)
        case .ollama:
            let endpoint = ConfigManager.shared.ollamaEndpoint.trimmingCharacters(in: .whitespaces)
            let model    = ConfigManager.shared.ollamaModel.trimmingCharacters(in: .whitespaces)
            return await runOllama(transcript: transcript, prompt: prompt,
                                   endpoint: endpoint.isEmpty ? "http://localhost:11434" : endpoint,
                                   model:    model.isEmpty    ? "llama3"                 : model)
        }
    }

    private func runClaudeCLI(transcript: String, prompt: String, binary: String) async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                // Run via zsh login shell so Claude gets its full environment
                // (Node.js path, auth tokens, etc.) — pipe transcript via stdin.
                let escapedPrompt = prompt.replacingOccurrences(of: "'", with: "'\\''")
                let shellCommand  = "\(binary) -p '\(escapedPrompt)'"

                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/zsh")
                process.arguments = ["-l", "-c", shellCommand]

                let inputPipe  = Pipe()
                let outputPipe = Pipe()
                let errorPipe  = Pipe()
                process.standardInput  = inputPipe
                process.standardOutput = outputPipe
                process.standardError  = errorPipe

                do {
                    try process.run()
                    inputPipe.fileHandleForWriting.write(transcript.data(using: .utf8) ?? Data())
                    inputPipe.fileHandleForWriting.closeFile()
                    process.waitUntilExit()

                    let errData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                    if let errText = String(data: errData, encoding: .utf8), !errText.isEmpty {
                        print("Claude CLI stderr: \(errText)")
                    }

                    let data   = outputPipe.fileHandleForReading.readDataToEndOfFile()
                    let output = String(data: data, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    print("Claude CLI exit: \(process.terminationStatus), output: \(output?.count ?? 0) chars")
                    continuation.resume(returning: output?.isEmpty == false ? output : nil)
                } catch {
                    print("Claude CLI launch failed: \(error)")
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    private func runOllama(transcript: String, prompt: String,
                            endpoint: String, model: String) async -> String? {
        guard let url = URL(string: "\(endpoint)/api/generate") else {
            print("Ollama: invalid endpoint URL '\(endpoint)'")
            return nil
        }
        let body: [String: Any] = [
            "model":  model,
            "prompt": "\(prompt)\n\n\(transcript)",
            "stream": false,
        ]
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else { return nil }

        var request = URLRequest(url: url, timeoutInterval: 300)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = bodyData

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            if let json     = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let response = json["response"] as? String {
                let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
            print("Ollama: unexpected response: \(String(data: data, encoding: .utf8) ?? "<binary>")")
            return nil
        } catch {
            print("Ollama request failed: \(error)")
            return nil
        }
    }

    private func mixAudio(mic: [Float], system: [Float]) -> [Float] {
        if system.isEmpty {
            print("No system audio — using mic only")
        } else {
            print("Mixed \(String(format: "%.1f", Double(mic.count) / 16000))s mic + \(String(format: "%.1f", Double(system.count) / 16000))s system")
        }
        return AudioUtilities.mixAudio(mic: mic, system: system)
    }
}
