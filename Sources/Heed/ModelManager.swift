import AppKit
import SwiftUI

@MainActor
final class ModelManager {
    static let shared = ModelManager()

    private let modelDirName = "parakeet-tdt-0.6b-v3"
    private let repoID = "nvidia/parakeet-tdt-0.6b-v3"

    // Files needed for inference
    private let requiredFiles = [
        "model.onnx",
        "tokenizer.json",
        "config.json",
        "preprocessor_config.json"
    ]

    var modelDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("Heed/Models/\(modelDirName)")
    }

    var isModelDownloaded: Bool {
        let fm = FileManager.default
        // Check that the model directory exists and has at least the main model file
        let modelFile = modelDirectory.appendingPathComponent("model.onnx")
        return fm.fileExists(atPath: modelFile.path)
    }

    /// Shows download prompt if model is missing. Calls completion with true if model is available.
    func ensureModelAvailable(completion: @escaping (Bool) -> Void) {
        if isModelDownloaded {
            completion(true)
            return
        }
        showDownloadPrompt(completion: completion)
    }

    private func showDownloadPrompt(completion: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = "Download Transcription Model"
        alert.informativeText = "Heed requires the Parakeet TDT 0.6B V3 model for local transcription. This is a one-time download (~478 MB).\n\nThe model will be downloaded from Hugging Face."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Download")
        alert.addButton(withTitle: "Later")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            showDownloadProgress(completion: completion)
        } else {
            completion(false)
        }
    }

    private func showDownloadProgress(completion: @escaping (Bool) -> Void) {
        let progressModel = DownloadProgressModel()
        let downloadWindow = DownloadProgressWindow(model: progressModel)
        downloadWindow.show()

        Task {
            let success = await downloadModel(progress: progressModel)
            if success {
                downloadWindow.close()
                completion(true)
            } else {
                downloadWindow.close()
                showDownloadError(completion: completion)
            }
        }
    }

    private func showDownloadError(completion: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = "Download Failed"
        alert.informativeText = "Could not download the Parakeet model. Check your internet connection and try again."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Try Again")
        alert.addButton(withTitle: "Later")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            showDownloadProgress(completion: completion)
        } else {
            completion(false)
        }
    }

    private func downloadModel(progress: DownloadProgressModel) async -> Bool {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: modelDirectory, withIntermediateDirectories: true)
        } catch {
            print("Failed to create model directory: \(error)")
            return false
        }

        // First, discover available files from the HuggingFace API
        let filesToDownload = await discoverModelFiles() ?? requiredFiles

        let totalFiles = filesToDownload.count
        for (index, filename) in filesToDownload.enumerated() {
            let fileURL = modelDirectory.appendingPathComponent(filename)
            if fm.fileExists(atPath: fileURL.path) {
                await MainActor.run {
                    progress.currentFile = filename
                    progress.fileProgress = 1.0
                    progress.overallProgress = Double(index + 1) / Double(totalFiles)
                    progress.status = "Skipping \(filename) (already exists)"
                }
                continue
            }

            let downloadURL = URL(string: "https://huggingface.co/\(repoID)/resolve/main/\(filename)")!

            await MainActor.run {
                progress.currentFile = filename
                progress.fileProgress = 0
                progress.overallProgress = Double(index) / Double(totalFiles)
                progress.status = "Downloading \(filename)..."
            }

            let success = await downloadFile(from: downloadURL, to: fileURL, progress: progress)
            if !success {
                await MainActor.run {
                    progress.status = "Failed to download \(filename)"
                }
                return false
            }

            await MainActor.run {
                progress.overallProgress = Double(index + 1) / Double(totalFiles)
            }
        }

        await MainActor.run {
            progress.status = "Download complete!"
            progress.overallProgress = 1.0
        }
        return true
    }

    private func discoverModelFiles() async -> [String]? {
        let apiURL = URL(string: "https://huggingface.co/api/models/\(repoID)")!
        do {
            let (data, _) = try await URLSession.shared.data(from: apiURL)
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let siblings = json["siblings"] as? [[String: Any]] {
                let filenames = siblings.compactMap { $0["rfilename"] as? String }
                // Filter to essential files — skip large unnecessary files
                let essentialExtensions = ["onnx", "json", "txt", "yaml", "yml"]
                let filtered = filenames.filter { name in
                    let ext = (name as NSString).pathExtension.lowercased()
                    return essentialExtensions.contains(ext) || name == "LICENSE"
                }
                return filtered.isEmpty ? nil : filtered
            }
        } catch {
            print("Failed to query HuggingFace API: \(error)")
        }
        return nil
    }

    private func downloadFile(from url: URL, to destination: URL, progress: DownloadProgressModel) async -> Bool {
        let parentDir = destination.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)

        return await withCheckedContinuation { continuation in
            let delegate = DownloadDelegate(progress: progress, destination: destination) { success in
                continuation.resume(returning: success)
            }
            let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
            let task = session.downloadTask(with: url)
            task.resume()
        }
    }
}

// MARK: - Download Progress Tracking

@MainActor
final class DownloadProgressModel: ObservableObject {
    @Published var status: String = "Preparing download..."
    @Published var currentFile: String = ""
    @Published var fileProgress: Double = 0
    @Published var overallProgress: Double = 0
}

final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let progress: DownloadProgressModel
    private let destination: URL
    private let completion: (Bool) -> Void
    private var finished = false

    init(progress: DownloadProgressModel, destination: URL, completion: @escaping (Bool) -> Void) {
        self.progress = progress
        self.destination = destination
        self.completion = completion
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        let writtenMB = Double(totalBytesWritten) / 1_000_000
        let totalMB = Double(totalBytesExpectedToWrite) / 1_000_000
        Task { @MainActor [progress] in
            progress.fileProgress = fraction
            progress.status = String(format: "Downloading... %.0f / %.0f MB", writtenMB, totalMB)
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            try FileManager.default.moveItem(at: location, to: destination)
            finished = true
            completion(true)
        } catch {
            print("Failed to move downloaded file: \(error)")
            finished = true
            completion(false)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard !finished else { return }
        if let error { print("Download error: \(error)") }
        completion(false)
    }
}

// MARK: - Download Progress Window

@MainActor
final class DownloadProgressWindow {
    private var window: NSWindow?
    private let model: DownloadProgressModel

    init(model: DownloadProgressModel) {
        self.model = model
    }

    func show() {
        let contentView = NSHostingView(rootView: DownloadProgressView(model: model))
        contentView.frame = NSRect(x: 0, y: 0, width: 420, height: 160)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 160),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Heed — Model Download"
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
            Text("Downloading Parakeet Model")
                .font(.headline)

            VStack(alignment: .leading, spacing: 4) {
                Text(model.status)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .lineLimit(1)

                ProgressView(value: model.fileProgress)
                    .progressViewStyle(.linear)
            }

            HStack {
                Text("Overall")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                ProgressView(value: model.overallProgress)
                    .progressViewStyle(.linear)
                Text("\(Int(model.overallProgress * 100))%")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
                    .frame(width: 35, alignment: .trailing)
            }
        }
        .padding(20)
        .frame(width: 420, height: 160)
    }
}
