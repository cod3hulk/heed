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
    private weak var systemAudioRef: SystemAudioCapture?
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
    var onSummarize: (() -> Void)? { didSet { waveformModel.onSummarizeTapped = onSummarize } }
    /// Called when ⌘2 is pressed in the done state to request meeting feedback.
    var onMeetingFeedback: (() -> Void)? { didSet { waveformModel.onFeedbackTapped = onMeetingFeedback } }

    func show(audioService: AudioCaptureService, systemAudio: SystemAudioCapture? = nil) {
        guard panel == nil else { return }
        audioServiceRef = audioService
        systemAudioRef = systemAudio
        waveformModel.phase = .recording

        makePanel(width: 500, height: 60, autoFit: true)

        let levelTimer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let service = self.audioServiceRef else { return }
                let micLevel = service.currentLevel
                let sysLevel = self.systemAudioRef?.currentLevel ?? 0
                self.waveformModel.updateLevel(max(micLevel, sysLevel))
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
        systemAudioRef = nil

        // Set phase first so SwiftUI layout reflects new content before autoFit measurement
        waveformModel.phase = phase

        switch phase {
        case .done(let text):
            pendingTranscript = text
            waveformModel.onCopyTapped = { [weak self] in
                guard let self else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(self.pendingTranscript, forType: .string)
                self.hide()
                self.onDismiss?()
            }
            waveformModel.onDiscardTapped = { [weak self] in
                self?.hide()
                self?.onDismiss?()
            }
            resizePanel(width: 600, height: 60, autoFit: true)
            NSApp.activate(ignoringOtherApps: true)
            panel?.makeKeyAndOrderFront(nil)
            installKeyMonitor()
        case .result(let text):
            pendingTranscript = text
            resizePanel(width: 480, height: 380)
            NSApp.activate(ignoringOtherApps: true)
            panel?.makeKeyAndOrderFront(nil)
            installKeyMonitor()
        case .transcribing:
            resizePanel(width: 400, height: 60, autoFit: true)
        case .summarizing:
            removeKeyMonitor()
            resizePanel(width: 400, height: 60, autoFit: true)
        default:
            resizePanel(width: 480, height: 160)
        }
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
        systemAudioRef = nil
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

    private func resizePanel(width: CGFloat, height: CGFloat, autoFit: Bool = false) {
        guard let panel else { return }
        var panelWidth = width
        var panelHeight = height
        if autoFit, let contentView = panel.contentView {
            contentView.frame = NSRect(x: 0, y: 0, width: 800, height: 200)
            let fit = contentView.fittingSize
            if fit.width > 0 { panelWidth = ceil(fit.width) }
            if fit.height > 0 { panelHeight = ceil(fit.height) }
        }
        panel.contentView?.frame = NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight)
        positionPanel(panel, width: panelWidth, height: panelHeight)
        panel.setContentSize(NSSize(width: panelWidth, height: panelHeight))
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
    var onSummarizeTapped: (() -> Void)?
    var onFeedbackTapped: (() -> Void)?
    var onCopyTapped: (() -> Void)?
    var onDiscardTapped: (() -> Void)?
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
        onSummarizeTapped = nil
        onFeedbackTapped = nil
        onCopyTapped = nil
        onDiscardTapped = nil
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
            TranscribingView()
        case .done(_):
            TranscriptionReadyView(model: model)
        case .summarizing:
            SummarizingView()
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
    @State private var shimmerOffset: CGFloat = -1.0
    @State private var pulseOpacity: Double = 1.0
    @State private var dotPulsing = false
    private static let accentColor = Color(red: 0.369, green: 0.361, blue: 0.902) // #5e5ce6
    private static let trackWidth: CGFloat = 80

    var body: some View {
        HStack(spacing: 0) {
            // Pulsing indigo dot
            ZStack {
                Circle()
                    .fill(Self.accentColor.opacity(0.35))
                    .frame(width: 10, height: 10)
                    .scaleEffect(dotPulsing ? 2.2 : 1.0)
                    .opacity(dotPulsing ? 0 : 0.35)
                    .animation(.easeOut(duration: 1.2).repeatForever(autoreverses: false), value: dotPulsing)
                Circle()
                    .fill(Self.accentColor)
                    .frame(width: 10, height: 10)
                    .shadow(color: Self.accentColor.opacity(0.5), radius: 6)
            }
            .padding(.leading, 20)

            Text("TRANSCRIBING...")
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(.white)
                .opacity(pulseOpacity)
                .padding(.leading, 10)

            Rectangle()
                .fill(Color.white.opacity(0.1))
                .frame(width: 1, height: 16)
                .padding(.horizontal, 16)

            // Indeterminate shimmer bar
            Capsule()
                .fill(Color.white.opacity(0.08))
                .frame(width: Self.trackWidth, height: 4)
                .overlay(
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [.clear, Self.accentColor, .clear],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: Self.trackWidth * 0.5)
                        .offset(x: shimmerOffset * Self.trackWidth)
                )
                .clipped()
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
        .onAppear {
            dotPulsing = true
            withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true)) {
                pulseOpacity = 0.5
            }
            withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) {
                shimmerOffset = 1.0
            }
        }
    }
}

struct TranscriptionReadyView: View {
    @ObservedObject var model: WaveformModel
    @State private var dotPulsing = false
    private static let accentColor = Color(red: 0.369, green: 0.361, blue: 0.902) // #5e5ce6

    var body: some View {
        HStack(spacing: 0) {
            // Status indicator: pulsing dot + label
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(Self.accentColor.opacity(0.35))
                        .frame(width: 10, height: 10)
                        .scaleEffect(dotPulsing ? 2.2 : 1.0)
                        .opacity(dotPulsing ? 0 : 0.35)
                        .animation(.easeOut(duration: 1.2).repeatForever(autoreverses: false), value: dotPulsing)
                    Circle()
                        .fill(Self.accentColor)
                        .frame(width: 10, height: 10)
                        .shadow(color: Self.accentColor.opacity(0.5), radius: 6)
                }
                Text("TRANSCRIPTION READY")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.white)
                    .tracking(0.5)
            }
            .padding(.leading, 20)

            pillSeparator.padding(.horizontal, 16)

            // Action chips
            HStack(spacing: 6) {
                ActionChip(key: "⌘1", label: "Summarize") { model.onSummarizeTapped?() }
                ActionChip(key: "⌘2", label: "Feedback")  { model.onFeedbackTapped?() }
                ActionChip(key: "↵",  label: "Copy")      { model.onCopyTapped?() }
                ActionChip(key: "⎋",  label: "Discard")   { model.onDiscardTapped?() }
            }
            .padding(.trailing, 8)

            pillSeparator.padding(.horizontal, 12)

            // Close button
            Button { model.onDiscardTapped?() } label: {
                ZStack {
                    Circle()
                        .fill(Color.white.opacity(0.1))
                        .frame(width: 24, height: 24)
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(.white.opacity(0.5))
                }
            }
            .buttonStyle(.plain)
            .padding(.trailing, 16)
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
        .onAppear { dotPulsing = true }
    }

    private var pillSeparator: some View {
        Rectangle()
            .fill(Color.white.opacity(0.1))
            .frame(width: 1, height: 16)
    }
}

struct ActionChip: View {
    let key: String
    let label: String
    let action: () -> Void
    @State private var isHovered = false
    private static let accentColor = Color(red: 0.369, green: 0.361, blue: 0.902) // #5e5ce6

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(key)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(Self.accentColor)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 3)
                    .background(Self.accentColor.opacity(0.15))
                    .cornerRadius(4)
                Text(label)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white.opacity(isHovered ? 1.0 : 0.8))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.white.opacity(isHovered ? 0.1 : 0.07))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

struct SummarizingView: View {
    @State private var shimmerOffset: CGFloat = -1.0
    @State private var pulseOpacity: Double = 1.0
    @State private var dotPulsing = false
    private static let accentColor = Color(red: 0.369, green: 0.361, blue: 0.902) // #5e5ce6
    private static let trackWidth: CGFloat = 80

    var body: some View {
        HStack(spacing: 0) {
            ZStack {
                Circle()
                    .fill(Self.accentColor.opacity(0.35))
                    .frame(width: 10, height: 10)
                    .scaleEffect(dotPulsing ? 2.2 : 1.0)
                    .opacity(dotPulsing ? 0 : 0.35)
                    .animation(.easeOut(duration: 1.2).repeatForever(autoreverses: false), value: dotPulsing)
                Circle()
                    .fill(Self.accentColor)
                    .frame(width: 10, height: 10)
                    .shadow(color: Self.accentColor.opacity(0.5), radius: 6)
            }
            .padding(.leading, 20)

            Text("SUMMARIZING...")
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(.white)
                .opacity(pulseOpacity)
                .padding(.leading, 10)

            Rectangle()
                .fill(Color.white.opacity(0.1))
                .frame(width: 1, height: 16)
                .padding(.horizontal, 16)

            Capsule()
                .fill(Color.white.opacity(0.08))
                .frame(width: Self.trackWidth, height: 4)
                .overlay(
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [.clear, Self.accentColor, .clear],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: Self.trackWidth * 0.5)
                        .offset(x: shimmerOffset * Self.trackWidth)
                )
                .clipped()
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
        .onAppear {
            dotPulsing = true
            withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true)) {
                pulseOpacity = 0.5
            }
            withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) {
                shimmerOffset = 1.0
            }
        }
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
