import AppKit
import AVFoundation

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let audioService = AudioCaptureService()
    private let shortcutManager = GlobalShortcutManager()
    private let overlay = OverlayWindow()
    private var recordingMenuItem: NSMenuItem!

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        requestPermissionsUpfront()
        setupGlobalShortcut()
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
        shortcutManager.start()
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

    @objc private func toggleRecording() {
        if audioService.isRecording {
            overlay.hide()
            let samples = audioService.stopRecording()
            recordingMenuItem.title = "Start Recording"

            guard ModelManager.shared.isReady else {
                print("Model not ready — skipping transcription")
                return
            }
            Task {
                print("Transcribing \(String(format: "%.1f", Double(samples.count) / 16000))s of audio...")
                if let transcript = await ModelManager.shared.transcribe(samples) {
                    print("Transcript: \(transcript)")
                    // TODO: surface in overlay / post-processing UI
                }
            }
        } else {
            do {
                try audioService.startRecording()
                overlay.show(audioService: audioService)
                recordingMenuItem.title = "Stop Recording"
            } catch {
                print("Failed to start recording: \(error)")
            }
        }
    }
}
