import AppKit
import SwiftUI
import FluidAudio

@MainActor
final class ModelManager {
    static let shared = ModelManager()

    private(set) var asrManager: AsrManager?
    private(set) var isReady: Bool = false

    // Held during download so the @Sendable progress handler can weakly reach it
    private weak var activeProgressModel: DownloadProgressModel?

    /// True if the Core ML model bundles are already on disk.
    var isModelCached: Bool {
        let encoder = AsrModels.defaultCacheDirectory()
            .appendingPathComponent(ModelNames.ASR.encoderFile)
        return FileManager.default.fileExists(atPath: encoder.path)
    }

    // MARK: - Public API

    /// Called at launch (deferred off applicationDidFinishLaunching).
    /// Loads silently if cached, otherwise prompts the user to download.
    func ensureModelAvailable(completion: @escaping (Bool) -> Void) {
        if isModelCached {
            Task {
                do {
                    let models = try await AsrModels.loadFromCache()
                    let mgr = AsrManager()
                    try await mgr.initialize(models: models)
                    self.asrManager = mgr
                    self.isReady = true
                    completion(true)
                } catch {
                    print("Failed to load cached model: \(error)")
                    completion(false)
                }
            }
        } else {
            showDownloadPrompt(completion: completion)
        }
    }

    func transcribe(_ samples: [Float]) async -> String? {
        guard let asrManager, isReady else { return nil }
        do {
            let result = try await asrManager.transcribe(samples, source: .microphone)
            return result.text
        } catch {
            print("Transcription error: \(error)")
            return nil
        }
    }

    // MARK: - Download flow

    private func showDownloadPrompt(completion: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = "Download Transcription Model"
        alert.informativeText = "Heed requires the Parakeet TDT 0.6B V3 model (~600 MB) for local, on-device transcription.\n\nThis is a one-time download from Hugging Face."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Download")
        alert.addButton(withTitle: "Later")

        if alert.runModal() == .alertFirstButtonReturn {
            showDownloadProgress(completion: completion)
        } else {
            completion(false)
        }
    }

    private func showDownloadProgress(completion: @escaping (Bool) -> Void) {
        let progressModel = DownloadProgressModel()
        activeProgressModel = progressModel
        let downloadWindow = DownloadProgressWindow(model: progressModel)
        downloadWindow.show()

        Task {
            do {
                let models = try await AsrModels.loadFromCache(progressHandler: { [weak self] progress in
                    let fraction = progress.fractionCompleted
                    Task { @MainActor [weak self] in
                        self?.activeProgressModel?.overallProgress = fraction
                        self?.activeProgressModel?.fileProgress = fraction
                        self?.activeProgressModel?.status =
                            "Downloading... \(Int(fraction * 100))%"
                    }
                })
                let mgr = AsrManager()
                try await mgr.initialize(models: models)
                self.asrManager = mgr
                self.isReady = true
                progressModel.status = "Download complete!"
                progressModel.overallProgress = 1.0
                try? await Task.sleep(nanoseconds: 500_000_000)
                downloadWindow.close()
                completion(true)
            } catch {
                downloadWindow.close()
                showDownloadError(error: error, completion: completion)
            }
        }
    }

    private func showDownloadError(error: Error, completion: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = "Download Failed"
        alert.informativeText = "Could not download the model: \(error.localizedDescription)\n\nCheck your internet connection and try again."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Try Again")
        alert.addButton(withTitle: "Later")

        if alert.runModal() == .alertFirstButtonReturn {
            showDownloadProgress(completion: completion)
        } else {
            completion(false)
        }
    }
}

// MARK: - Download Progress UI

@MainActor
final class DownloadProgressModel: ObservableObject {
    @Published var status: String = "Preparing download..."
    @Published var fileProgress: Double = 0
    @Published var overallProgress: Double = 0
}

@MainActor
final class DownloadProgressWindow {
    private var window: NSWindow?
    private let model: DownloadProgressModel

    init(model: DownloadProgressModel) {
        self.model = model
    }

    func show() {
        let contentView = NSHostingView(rootView: DownloadProgressView(model: model))
        contentView.frame = NSRect(x: 0, y: 0, width: 420, height: 140)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 140),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Heed — Model Download"
        window.isReleasedWhenClosed = false  // Required under ARC — prevents autorelease double-free
        window.contentView = contentView
        window.isMovableByWindowBackground = true
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
    }

    func close() {
        window?.close()
        window = nil
    }
}

struct DownloadProgressView: View {
    @ObservedObject var model: DownloadProgressModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Downloading Parakeet TDT 0.6B V3")
                .font(.headline)

            Text(model.status)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .lineLimit(1)

            HStack {
                ProgressView(value: model.overallProgress)
                    .progressViewStyle(.linear)
                Text("\(Int(model.overallProgress * 100))%")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
                    .frame(width: 35, alignment: .trailing)
            }
        }
        .padding(20)
        .frame(width: 420, height: 140)
    }
}
