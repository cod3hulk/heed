import AppKit
import SwiftUI

enum OverlayPhase {
    case recording
    case transcribing
    case done(String)
}

@MainActor
final class OverlayWindow {
    private var panel: NSPanel?
    private let waveformModel = WaveformModel()
    private weak var audioServiceRef: AudioCaptureService?
    private var levelTimer: Timer?
    private var keyMonitor: Any?
    private var pendingTranscript: String = ""

    /// Called when ESC or Return is pressed in the done state.
    var onDismiss: (() -> Void)?

    func show(audioService: AudioCaptureService) {
        guard panel == nil else { return }
        audioServiceRef = audioService
        waveformModel.phase = .recording

        makePanel(height: 160)

        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let service = self.audioServiceRef else { return }
                self.waveformModel.updateLevel(service.currentLevel)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.levelTimer = timer
    }

    func transitionTo(_ phase: OverlayPhase) {
        levelTimer?.invalidate()
        levelTimer = nil
        audioServiceRef = nil

        if case .done(let text) = phase {
            pendingTranscript = text
            resizePanel(height: 260)
            // Activate app so the panel can receive key events
            NSApp.activate(ignoringOtherApps: true)
            panel?.makeKeyAndOrderFront(nil)
            installKeyMonitor()
        } else {
            resizePanel(height: 160)
        }

        waveformModel.phase = phase
    }

    func hide() {
        removeKeyMonitor()
        levelTimer?.invalidate()
        levelTimer = nil
        panel?.close()
        panel = nil
        waveformModel.reset()
        audioServiceRef = nil
        pendingTranscript = ""
    }

    // MARK: - Key handling

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            switch event.keyCode {
            case 53: // Escape — discard
                self.hide()
                self.onDismiss?()
                return nil
            case 36: // Return — copy transcript then discard
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(self.pendingTranscript, forType: .string)
                self.hide()
                self.onDismiss?()
                return nil
            default:
                return event
            }
        }
    }

    private func removeKeyMonitor() {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
    }

    var isVisible: Bool { panel != nil }

    // MARK: - Private

    private func makePanel(height: CGFloat) {
        let width: CGFloat = 480
        let contentView = NSHostingView(rootView: OverlayContentView(model: waveformModel))
        contentView.frame = NSRect(x: 0, y: 0, width: width, height: height)

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.contentView = contentView
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.alphaValue = 0.92

        positionPanel(panel, height: height)
        panel.orderFrontRegardless()
        self.panel = panel
    }

    private func resizePanel(height: CGFloat) {
        guard let panel else { return }
        let width: CGFloat = 480
        panel.contentView?.frame = NSRect(x: 0, y: 0, width: width, height: height)
        positionPanel(panel, height: height)
        panel.setContentSize(NSSize(width: width, height: height))
    }

    private func positionPanel(_ panel: NSPanel, height: CGFloat) {
        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let x = screenFrame.midX - 240
            let y = screenFrame.minY + 60
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }
    }
}

// MARK: - Waveform Data Model

@MainActor
final class WaveformModel: ObservableObject {
    static let barCount = 112
    @Published var barHeights: [Float] = Array(repeating: 0, count: WaveformModel.barCount)
    @Published var phase: OverlayPhase = .recording
    private var animPhase: Double = 0
    private var smoothedLevel: Float = 0

    func updateLevel(_ rawLevel: Float) {
        let attack: Float = rawLevel > smoothedLevel ? 0.5 : 0.1
        smoothedLevel = smoothedLevel + attack * (rawLevel - smoothedLevel)

        animPhase += 0.08

        let count = WaveformModel.barCount
        for i in 0..<count {
            let pos = Float(i) / Float(count - 1)
            let wave1 = sin(Double(pos) * 4.0 * .pi + animPhase)
            let wave2 = sin(Double(pos) * 7.0 * .pi + animPhase * 1.3) * 0.5
            let wave3 = sin(Double(pos) * 11.0 * .pi + animPhase * 0.7) * 0.3
            let combined = Float(wave1 + wave2 + wave3) / 1.8
            let envelope = 0.15 + abs(combined) * 0.85
            let target = smoothedLevel * envelope
            let barAttack: Float = target > barHeights[i] ? 0.3 : 0.08
            barHeights[i] = barHeights[i] + barAttack * (target - barHeights[i])
        }
    }

    func reset() {
        barHeights = Array(repeating: 0, count: WaveformModel.barCount)
        smoothedLevel = 0
        animPhase = 0
        phase = .recording
    }
}

// MARK: - SwiftUI Views

struct OverlayContentView: View {
    @ObservedObject var model: WaveformModel

    var body: some View {
        Group {
            switch model.phase {
            case .recording:
                RecordingView(model: model)
            case .transcribing:
                TranscribingView()
            case .done(let text):
                TranscriptView(text: text)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.ultraThinMaterial)
                .environment(\.colorScheme, .dark)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.black.opacity(0.5))
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

struct RecordingView: View {
    @ObservedObject var model: WaveformModel

    var body: some View {
        VStack(spacing: 0) {
            WaveformView(barHeights: model.barHeights)
                .frame(maxWidth: .infinity)
                .frame(height: 100)
                .padding(.horizontal, 16)
                .padding(.top, 12)

            HStack {
                HStack(spacing: 6) {
                    PulsingDot()
                    Text("Recording")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white)
                }
                Spacer()
                HStack(spacing: 4) {
                    Text("Stop")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.7))
                    Text("\u{21e7}\u{2318}R")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundColor(.white.opacity(0.9))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.white.opacity(0.15))
                        .cornerRadius(4)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }
}

struct TranscribingView: View {
    var body: some View {
        VStack(spacing: 14) {
            ProgressView()
                .progressViewStyle(.circular)
                .controlSize(.large)
                .tint(.white)
            Text("Transcribing…")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.white)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct TranscriptView: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                Text(text)
                    .font(.system(size: 13))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
            .frame(maxHeight: .infinity)

            Divider().background(Color.white.opacity(0.15))

            HStack {
                Text("Transcript")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(0.6))
                Spacer()
                HStack(spacing: 8) {
                    KeyHint(key: "⎋", label: "Discard")
                    KeyHint(key: "↵", label: "Copy")
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }
}

struct KeyHint: View {
    let key: String
    let label: String

    var body: some View {
        HStack(spacing: 4) {
            Text(key)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundColor(.white.opacity(0.9))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.white.opacity(0.15))
                .cornerRadius(4)
            Text(label)
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.7))
        }
    }
}

struct PulsingDot: View {
    @State private var isPulsing = false

    var body: some View {
        Circle()
            .fill(Color.red)
            .frame(width: 8, height: 8)
            .opacity(isPulsing ? 0.4 : 1.0)
            .animation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true), value: isPulsing)
            .onAppear { isPulsing = true }
    }
}

struct WaveformView: View {
    let barHeights: [Float]
    private let barWidth: CGFloat = 2.5
    private let barSpacing: CGFloat = 1.5

    var body: some View {
        GeometryReader { geo in
            let midY = geo.size.height / 2
            let totalBarPitch = barWidth + barSpacing
            let visibleCount = min(barHeights.count, Int(geo.size.width / totalBarPitch))
            let totalWidth = CGFloat(visibleCount) * totalBarPitch - barSpacing
            let offsetX = (geo.size.width - totalWidth) / 2

            Canvas { context, _ in
                for i in 0..<visibleCount {
                    let level = barHeights[i]
                    let barHeight = max(2, CGFloat(level) * midY * 1.8)
                    let x = offsetX + CGFloat(i) * totalBarPitch
                    let y = midY - barHeight / 2
                    let rect = CGRect(x: x, y: y, width: barWidth, height: barHeight)
                    let path = Capsule().path(in: rect)
                    context.fill(path, with: .color(.white.opacity(0.85)))
                }
            }
        }
    }
}
