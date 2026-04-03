import AppKit
import SwiftUI

enum OverlayPhase {
    case recording
    case transcribing
    case done(String)      // initial transcript — shows ⌘1/⌘2 action hints
    case summarizing
    case result(String)    // summary/feedback result — shows only ⎋/↵
}

@MainActor
final class OverlayWindow {
    private var panel: NSPanel?
    private let waveformModel = WaveformModel()
    private weak var audioServiceRef: AudioCaptureService?
    private var levelTimer: Timer?
    private var secondsTimer: Timer?
    private var keyMonitor: Any?
    private var pendingTranscript: String = ""

    /// Called when the stop button is tapped during recording.
    var onStopRecording: (() -> Void)? {
        didSet { waveformModel.onStopTapped = onStopRecording }
    }
    /// Called when ESC or Return is pressed in the done state.
    var onDismiss: (() -> Void)?
    /// Called when ⌘1 is pressed in the done state to request summarization.
    var onSummarize: (() -> Void)?
    /// Called when ⌘2 is pressed in the done state to request meeting feedback.
    var onMeetingFeedback: (() -> Void)?

    func show(audioService: AudioCaptureService) {
        guard panel == nil else { return }
        audioServiceRef = audioService
        waveformModel.phase = .recording

        makePanel(width: 500, height: 60, autoFit: true)

        let levelTimer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let service = self.audioServiceRef else { return }
                self.waveformModel.updateLevel(service.currentLevel)
            }
        }
        RunLoop.main.add(levelTimer, forMode: .common)
        self.levelTimer = levelTimer

        let secondsTimer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.waveformModel.elapsedSeconds += 1
            }
        }
        RunLoop.main.add(secondsTimer, forMode: .common)
        self.secondsTimer = secondsTimer
    }

    func transitionTo(_ phase: OverlayPhase) {
        levelTimer?.invalidate()
        levelTimer = nil
        secondsTimer?.invalidate()
        secondsTimer = nil
        audioServiceRef = nil

        switch phase {
        case .done(let text), .result(let text):
            pendingTranscript = text
            resizePanel(width: 480, height: 380)
            // Activate app so the panel can receive key events
            NSApp.activate(ignoringOtherApps: true)
            panel?.makeKeyAndOrderFront(nil)
            installKeyMonitor()
        case .summarizing:
            removeKeyMonitor()
            resizePanel(width: 480, height: 160)
        default:
            resizePanel(width: 480, height: 160)
        }

        waveformModel.phase = phase
    }

    func hide() {
        removeKeyMonitor()
        levelTimer?.invalidate()
        levelTimer = nil
        secondsTimer?.invalidate()
        secondsTimer = nil
        panel?.close()
        panel = nil
        waveformModel.reset()
        audioServiceRef = nil
        pendingTranscript = ""
    }

    // MARK: - Key handling

    private func installKeyMonitor() {
        let cfg = ConfigManager.shared
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            func matches(_ binding: KeyBinding) -> Bool {
                event.keyCode == binding.keyCode && flags.rawValue == binding.modifierFlags
            }
            if matches(cfg.discardBinding) {
                self.hide()
                self.onDismiss?()
                return nil
            }
            if matches(cfg.copyBinding) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(self.pendingTranscript, forType: .string)
                self.hide()
                self.onDismiss?()
                return nil
            }
            if matches(cfg.summarizeBinding) {
                self.onSummarize?()
                return nil
            }
            if matches(cfg.feedbackBinding) {
                self.onMeetingFeedback?()
                return nil
            }
            return event
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

    private func makePanel(width: CGFloat, height: CGFloat, autoFit: Bool = false) {
        let contentView = NSHostingView(rootView: OverlayContentView(model: waveformModel))

        var panelWidth = width
        var panelHeight = height
        if autoFit {
            contentView.frame = NSRect(x: 0, y: 0, width: 800, height: 200)
            let fit = contentView.fittingSize
            if fit.width > 0 { panelWidth = ceil(fit.width) }
            if fit.height > 0 { panelHeight = ceil(fit.height) }
        }

        contentView.frame = NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight)

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight),
            styleMask: [.nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.contentView = contentView
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.alphaValue = 1.0

        positionPanel(panel, width: panelWidth, height: panelHeight)
        panel.orderFrontRegardless()
        self.panel = panel
    }

    private func resizePanel(width: CGFloat, height: CGFloat) {
        guard let panel else { return }
        panel.contentView?.frame = NSRect(x: 0, y: 0, width: width, height: height)
        positionPanel(panel, width: width, height: height)
        panel.setContentSize(NSSize(width: width, height: height))
    }

    private func positionPanel(_ panel: NSPanel, width: CGFloat, height: CGFloat) {
        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let x = screenFrame.midX - width / 2
            let y = screenFrame.maxY - height - 20
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }
    }
}

// MARK: - Waveform Data Model

@MainActor
final class WaveformModel: ObservableObject {
    static let barCount = 20
    @Published var barHeights: [Float] = Array(repeating: 0, count: WaveformModel.barCount)
    @Published var phase: OverlayPhase = .recording
    @Published var elapsedSeconds: Int = 0
    var onStopTapped: (() -> Void)?
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
            let barAttack: Float = target > barHeights[i] ? 0.6 : 0.15
            barHeights[i] = barHeights[i] + barAttack * (target - barHeights[i])
        }
    }

    func reset() {
        barHeights = Array(repeating: 0, count: WaveformModel.barCount)
        smoothedLevel = 0
        animPhase = 0
        elapsedSeconds = 0
        phase = .recording
    }
}

// MARK: - SwiftUI Views

struct OverlayContentView: View {
    @ObservedObject var model: WaveformModel

    var body: some View {
        switch model.phase {
        case .recording:
            RecordingView(model: model)
        case .transcribing:
            TranscribingView().cardStyle()
        case .done(let text):
            TranscriptView(text: text, showActions: true).cardStyle()
        case .summarizing:
            SummarizingView().cardStyle()
        case .result(let text):
            TranscriptView(text: text, showActions: false).cardStyle()
        }
    }
}

private extension View {
    func cardStyle() -> some View {
        self
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(.ultraThinMaterial)
                    .environment(\.colorScheme, .dark)
            )
            .overlay(RoundedRectangle(cornerRadius: 12).fill(Color.black.opacity(0.5)))
            .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

struct RecordingView: View {
    @ObservedObject var model: WaveformModel

    private var elapsedText: String {
        let m = model.elapsedSeconds / 60
        let s = model.elapsedSeconds % 60
        return String(format: "%02d:%02d", m, s)
    }

    var body: some View {
        HStack(spacing: 0) {
            // Recording indicator: pulsing dot + elapsed timer
            HStack(spacing: 8) {
                PulsingDot()
                Text(elapsedText)
                    .font(.system(size: 12, weight: .bold).monospacedDigit())
                    .foregroundColor(.white)
            }
            .padding(.leading, 20)

            pillSeparator.padding(.horizontal, 16)

            // Compact waveform
            CompactWaveformView(barHeights: model.barHeights)
                .frame(width: 112, height: 24)

            pillSeparator.padding(.horizontal, 16)

            // Stop button + shortcut hint
            HStack(spacing: 10) {
                Button { model.onStopTapped?() } label: {
                    ZStack {
                        Circle()
                            .fill(Color.white.opacity(0.1))
                            .frame(width: 28, height: 28)
                        Image(systemName: "stop.fill")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.white)
                    }
                }
                .buttonStyle(.plain)
                Text("⇧⌘R")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.white.opacity(0.4))
                    .lineLimit(1)
            }
            .padding(.trailing, 20)
        }
        .frame(height: 44)
        .background(
            Capsule()
                .fill(.ultraThinMaterial)
                .environment(\.colorScheme, .dark)
        )
        .overlay(
            Capsule()
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        )
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .fixedSize(horizontal: true, vertical: false)
    }

    private var pillSeparator: some View {
        Rectangle()
            .fill(Color.white.opacity(0.1))
            .frame(width: 1, height: 16)
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

struct SummarizingView: View {
    var body: some View {
        VStack(spacing: 14) {
            ProgressView()
                .progressViewStyle(.circular)
                .controlSize(.large)
                .tint(.white)
            Text("Summarizing…")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.white)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct TranscriptView: View {
    let text: String
    let showActions: Bool
    @ObservedObject private var config = ConfigManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView(.vertical) {
                Text(text)
                    .font(.system(size: 13))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 16)
                    .padding(.trailing, 24) // leave room for scrollbar
                    .padding(.vertical, 16)
                    .textSelection(.enabled)
            }
            .scrollIndicators(.visible)
            .frame(maxHeight: .infinity)

            Divider().background(Color.white.opacity(0.15))

            HStack {
                Text(showActions ? "Transcript" : "Result")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(0.6))
                Spacer()
                HStack(spacing: 8) {
                    KeyHint(key: config.discardBinding.displayString,  label: "Discard")
                    KeyHint(key: config.copyBinding.displayString,     label: "Copy")
                    if showActions {
                        KeyHint(key: config.summarizeBinding.displayString, label: "Summarize")
                        KeyHint(key: config.feedbackBinding.displayString,  label: "Feedback")
                    }
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
    private static let dotColor = Color(red: 1, green: 0.271, blue: 0.227) // #FF453A

    var body: some View {
        ZStack {
            Circle()
                .fill(Self.dotColor.opacity(0.35))
                .frame(width: 10, height: 10)
                .scaleEffect(isPulsing ? 2.2 : 1.0)
                .opacity(isPulsing ? 0 : 0.35)
                .animation(.easeOut(duration: 1.2).repeatForever(autoreverses: false), value: isPulsing)
            Circle()
                .fill(Self.dotColor)
                .frame(width: 10, height: 10)
                .shadow(color: Self.dotColor.opacity(0.5), radius: 6)
        }
        .onAppear { isPulsing = true }
    }
}

struct CompactWaveformView: View {
    let barHeights: [Float]
    private let barWidth: CGFloat = 2
    private let barSpacing: CGFloat = 3
    private static let barColor = Color(red: 0.369, green: 0.361, blue: 0.902) // #5e5ce6

    var body: some View {
        GeometryReader { geo in
            let midY = geo.size.height / 2
            let count = barHeights.count
            let totalWidth = CGFloat(count) * (barWidth + barSpacing) - barSpacing
            let offsetX = (geo.size.width - totalWidth) / 2

            Canvas { context, _ in
                for (i, level) in barHeights.enumerated() {
                    let barHeight = max(2, CGFloat(level) * midY * 4.5)
                    let x = offsetX + CGFloat(i) * (barWidth + barSpacing)
                    let y = midY - barHeight / 2
                    let rect = CGRect(x: x, y: y, width: barWidth, height: barHeight)
                    context.fill(Capsule().path(in: rect), with: .color(Self.barColor))
                }
            }
        }
    }
}
