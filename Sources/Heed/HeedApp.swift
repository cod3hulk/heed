import AppKit
import AVFoundation
import ScreenCaptureKit

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let audioService = AudioCaptureService()
    private let systemAudio = SystemAudioCapture()
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

        // Warm up ScreenCaptureKit permission — triggers the system consent dialog
        // if not yet granted, so the user sees it at launch rather than mid-recording.
        Task {
            do {
                _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                print("Screen capture permission granted")
            } catch {
                print("Screen capture permission not available: \(error)")
            }
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
            let micSamples = audioService.stopRecording()
            recordingMenuItem.title = "Start Recording"

            guard ModelManager.shared.isReady else {
                print("Model not ready — skipping transcription")
                Task { await systemAudio.stopCapture() }
                return
            }

            Task {
                let sysSamples16k = await stopAndResampleSystemAudio()
                let mixed = mixAudio(mic: micSamples, system: sysSamples16k)

                let supportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("Heed")
                try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
                let formatter = DateFormatter()
                formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
                let filename = "recording_\(formatter.string(from: Date())).wav"
                let wavURL = supportDir.appendingPathComponent(filename)
                saveWAV(samples: mixed, sampleRate: 16000, to: wavURL)
                print("Saved recording to \(wavURL.path)")

                print("Transcribing \(String(format: "%.1f", Double(mixed.count) / 16000))s of audio (mic + system)...")
                if let transcript = await ModelManager.shared.transcribe(mixed) {
                    print("Transcript: \(transcript)")
                    // TODO: surface in overlay / post-processing UI
                }
            }
        } else {
            do {
                try audioService.startRecording()
                Task {
                    do {
                        try await systemAudio.startCapture()
                    } catch {
                        print("System audio capture unavailable: \(error) — mic only")
                    }
                }
                overlay.show(audioService: audioService)
                recordingMenuItem.title = "Stop Recording"
            } catch {
                print("Failed to start recording: \(error)")
            }
        }
    }

    private func stopAndResampleSystemAudio() async -> [Float] {
        let raw = await systemAudio.stopCapture()
        guard !raw.isEmpty else { return [] }
        return resampleTo16k(raw, fromRate: systemAudio.nativeSampleRate)
    }

    /// Simple linear interpolation resampler — mirrors AudioCaptureService's approach.
    private func resampleTo16k(_ samples: [Float], fromRate: Double) -> [Float] {
        let targetRate = 16000.0
        if abs(fromRate - targetRate) < 1.0 { return samples }
        let ratio = fromRate / targetRate
        let outputCount = Int(Double(samples.count) / ratio)
        guard outputCount > 0 else { return [] }
        var output = [Float](repeating: 0, count: outputCount)
        for i in 0..<outputCount {
            let srcIndex = Double(i) * ratio
            let idx = Int(srcIndex)
            let frac = Float(srcIndex - Double(idx))
            if idx + 1 < samples.count {
                output[i] = samples[idx] * (1.0 - frac) + samples[idx + 1] * frac
            } else if idx < samples.count {
                output[i] = samples[idx]
            }
        }
        return output
    }

    /// Mix mic and system audio by averaging, aligned to the shorter of the two.
    /// Falls back to mic-only if system audio is empty.
    private func mixAudio(mic: [Float], system: [Float]) -> [Float] {
        guard !system.isEmpty else {
            print("No system audio — using mic only")
            return mic
        }
        let count = min(mic.count, system.count)
        var mixed = [Float](repeating: 0, count: count)
        for i in 0..<count {
            let s = mic[i] * 0.6 + system[i] * 0.4
            mixed[i] = max(-1.0, min(1.0, s))
        }
        // Append remainder from the longer source
        if mic.count > count {
            mixed.append(contentsOf: mic[count...])
        } else if system.count > count {
            mixed.append(contentsOf: system[count...])
        }
        print("Mixed \(String(format: "%.1f", Double(mic.count) / 16000))s mic + \(String(format: "%.1f", Double(system.count) / 16000))s system → \(String(format: "%.1f", Double(mixed.count) / 16000))s")
        return mixed
    }
}
