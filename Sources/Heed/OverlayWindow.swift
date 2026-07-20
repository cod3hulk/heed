import AppKit
import Carbon.HIToolbox
import SwiftUI

// Custom NSPanel subclass that accepts keyboard focus
private class FocusablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

enum OverlayPhase {
    case recording
    case transcribing
    case done(String)      // initial transcript — shows ⌘1/⌘2 action hints
    case processing(label: String)
    case result(String, title: String, hasSummary: Bool, hasFeedback: Bool)
}

struct QAExchange: Identifiable {
    let id = UUID()
    let question: String
    var answer: String?   // nil while awaiting the LLM
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
    private var cachedSummary: String? = nil
    private var cachedFeedback: String? = nil
    private var originalTranscript: String = ""

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
    /// Called when the user submits a live-recording question. Receives the question text
    /// and the exchange ID that the answer should be attached to.
    var onAsk: ((String, UUID) -> Void)? {
        didSet {
            waveformModel.onAskSubmit = { [weak self] question in
                self?.appendPendingExchange(question: question)
            }
        }
    }

    func show(audioService: AudioCaptureService, systemAudio: SystemAudioCapture? = nil) {
        guard panel == nil else { return }
        audioServiceRef = audioService
        systemAudioRef = systemAudio
        waveformModel.phase = .recording
        waveformModel.qaExchanges = []
        waveformModel.qaVisible = false

        makePanel(width: 800, height: 60)

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

        // Q&A only lives during recording; discard any ephemeral state.
        waveformModel.qaVisible = false
        waveformModel.qaExchanges = []
        waveformModel.qaInput = ""

        // Set phase first so SwiftUI layout reflects new content before autoFit measurement
        waveformModel.phase = phase

        switch phase {
        case .done(let text):
            pendingTranscript = text
            originalTranscript = text
            waveformModel.onCopyTapped = { [weak self] in
                guard let self else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(self.pendingTranscript, forType: .string)
            }
            waveformModel.onDiscardTapped = { [weak self] in
                self?.hide()
                self?.onDismiss?()
            }
            resizePanel(width: 480, height: 440)
            panel?.makeKeyAndOrderFront(nil)
            installKeyMonitor()
        case .result(let text, let title, _, _):
            pendingTranscript = text
            // Cache the result based on title
            if title == "Summary" {
                cachedSummary = text
            } else if title == "Meeting Feedback" {
                cachedFeedback = text
            }
            waveformModel.onCopyTapped = { [weak self] in
                guard let self else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(self.pendingTranscript, forType: .string)
            }
            waveformModel.onDiscardTapped = { [weak self] in
                self?.hide()
                self?.onDismiss?()
            }
            resizePanel(width: 480, height: 440)
            panel?.makeKeyAndOrderFront(nil)
            installKeyMonitor()
        case .transcribing:
            resizePanel(width: 800, height: 60)
        case .processing:
            removeKeyMonitor()
            resizePanel(width: 800, height: 60)
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
        cachedSummary = nil
        cachedFeedback = nil
        originalTranscript = ""
    }

    func getCachedSummary() -> String? { cachedSummary }
    func getCachedFeedback() -> String? { cachedFeedback }
    func getOriginalTranscript() -> String { originalTranscript }

    // MARK: - Q&A (during recording)

    /// Toggle the Q&A panel. Called from the ⌥Space hotkey.
    func toggleQA() {
        guard case .recording = waveformModel.phase else { return }
        setQAVisible(!waveformModel.qaVisible)
    }

    private func setQAVisible(_ visible: Bool) {
        waveformModel.qaVisible = visible
        if visible {
            resizePanel(width: 560, height: 320)
            panel?.makeKeyAndOrderFront(nil)
            installQAKeyMonitor()
        } else {
            waveformModel.qaInput = ""
            resizePanel(width: 800, height: 60)
            removeKeyMonitor()
        }
    }

    /// Called by the WaveformModel when the user submits a question. Appends a
    /// placeholder exchange (nil answer) and forwards to the app-level handler.
    private func appendPendingExchange(question: String) {
        let exchange = QAExchange(question: question, answer: nil)
        waveformModel.qaExchanges.append(exchange)
        waveformModel.qaInput = ""
        onAsk?(question, exchange.id)
    }

    /// Called by HeedApp when the LLM answer arrives (or fails).
    func completeExchange(id: UUID, answer: String) {
        if let idx = waveformModel.qaExchanges.firstIndex(where: { $0.id == id }) {
            waveformModel.qaExchanges[idx].answer = answer
        }
    }

    private func installQAKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            // ESC closes the Q&A panel (only when the text field isn't first responder;
            // the field's ESC is handled by SwiftUI). This catches ESC when the field
            // is empty or not focused.
            if event.keyCode == 53 && event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty {
                self.setQAVisible(false)
                return nil
            }
            return event
        }
    }

    // MARK: - Key handling

    private func installKeyMonitor() {
        // Local monitor: fires only when overlay has keyboard focus
        let cfg = ConfigManager.shared
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            func matches(_ binding: KeyBinding) -> Bool {
                event.keyCode == binding.keyCode && flags.rawValue == binding.modifierFlags
            }

            // Handle each binding and dispatch the action
            if matches(cfg.discardBinding) {
                self.hide()
                self.onDismiss?()
                return nil
            }
            if matches(cfg.copyBinding) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(self.pendingTranscript, forType: .string)
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

        let panel = FocusablePanel(
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
    }

    private func positionPanel(_ panel: NSPanel, width: CGFloat, height: CGFloat) {
        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.visibleFrame
        let x = screenFrame.midX - width / 2
        let y = screenFrame.maxY - screenFrame.height / 4 - height / 2
        panel.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
    }
}

// MARK: - Waveform Data Model

@MainActor
final class WaveformModel: ObservableObject {
    static let barCount = 20
    @Published var barHeights: [Float] = Array(repeating: 0, count: WaveformModel.barCount)
    @Published var phase: OverlayPhase = .recording
    @Published var elapsedSeconds: Int = 0

    // Q&A state (only meaningful while phase == .recording)
    @Published var qaVisible: Bool = false
    @Published var qaExchanges: [QAExchange] = []
    @Published var qaInput: String = ""

    var onStopTapped: (() -> Void)?
    var onSummarizeTapped: (() -> Void)?
    var onFeedbackTapped: (() -> Void)?
    var onCopyTapped: (() -> Void)?
    var onDiscardTapped: (() -> Void)?
    var onAskSubmit: ((String) -> Void)?
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
        qaVisible = false
        qaExchanges = []
        qaInput = ""
        // Keep action callbacks alive for action switching
        // onSummarizeTapped = nil
        // onFeedbackTapped = nil
        onCopyTapped = nil
        onDiscardTapped = nil
    }
}

// MARK: - SwiftUI Views

struct OverlayContentView: View {
    @ObservedObject var model: WaveformModel

    var body: some View {
        ZStack {
            switch model.phase {
            case .recording:
                if model.qaVisible {
                    RecordingWithQAView(model: model)
                } else {
                    RecordingView(model: model)
                }
            case .transcribing:
                TranscribingView()
            case .done(let text):
                TranscriptionReadyView(model: model, transcript: text)
            case .processing(let label):
                ProcessingView(label: label)
            case .result(let text, let title, let hasSummary, let hasFeedback):
                ResultView(text: text, title: title, hasSummary: hasSummary, hasFeedback: hasFeedback, model: model)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
    let transcript: String
    @State private var dotPulsing = false
    private static let accentColor = Color(red: 0.369, green: 0.361, blue: 0.902) // #5e5ce6

    var body: some View {
        VStack(spacing: 0) {
            // Header
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
                Spacer()
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
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(Color.white.opacity(0.05))

            Rectangle()
                .fill(Color.white.opacity(0.1))
                .frame(height: 1)

            // Scrollable transcript
            ScrollView(.vertical) {
                Text(transcript)
                    .font(.system(size: 13))
                    .foregroundColor(.white.opacity(0.85))
                    .lineSpacing(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.trailing, 8)
                    .padding(.vertical, 14)
                    .textSelection(.enabled)
            }
            .scrollIndicators(.visible)
            .frame(maxHeight: .infinity)

            Rectangle()
                .fill(Color.white.opacity(0.1))
                .frame(height: 1)

            // Footer actions
            HStack {
                Button { model.onDiscardTapped?() } label: {
                    HStack(spacing: 6) {
                        Text("⎋")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.white.opacity(0.7))
                            .frame(width: 20, height: 20)
                            .background(Color.white.opacity(0.08))
                            .cornerRadius(4)
                        Text("Discard")
                            .font(.system(size: 13))
                            .foregroundColor(.white.opacity(0.6))
                    }
                }
                .buttonStyle(.plain)

                Spacer()

                HStack(spacing: 8) {
                    ActionChip(key: "↵",  label: "Copy")      { model.onCopyTapped?() }
                    ActionChip(key: "⌘2", label: "Feedback")  { model.onFeedbackTapped?() }
                    ActionChip(key: "⌘1", label: "Summarize") { model.onSummarizeTapped?() }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color.black.opacity(0.2))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.ultraThinMaterial)
                .environment(\.colorScheme, .dark)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .onAppear { dotPulsing = true }
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

struct ProcessingView: View {
    let label: String
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

            Text("\(label)...")
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

struct ResultView: View {
    let text: String
    let title: String
    let hasSummary: Bool
    let hasFeedback: Bool
    @ObservedObject var model: WaveformModel
    private static let accentColor = Color(red: 0.369, green: 0.361, blue: 0.902) // #5e5ce6

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text(title)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.white)
                    .tracking(-0.2)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(Color.white.opacity(0.05))

            Rectangle()
                .fill(Color.white.opacity(0.1))
                .frame(height: 1)

            // Scrollable content
            ScrollView(.vertical) {
                Text(text)
                    .font(.system(size: 14))
                    .foregroundColor(.white.opacity(0.9))
                    .lineSpacing(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.trailing, 8) // scrollbar clearance
                    .padding(.vertical, 16)
                    .textSelection(.enabled)
            }
            .scrollIndicators(.visible)
            .frame(maxHeight: .infinity)

            Rectangle()
                .fill(Color.white.opacity(0.1))
                .frame(height: 1)

            // Footer
            HStack {
                Button { model.onDiscardTapped?() } label: {
                    HStack(spacing: 6) {
                        Text("⎋")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.white.opacity(0.7))
                            .frame(width: 20, height: 20)
                            .background(Color.white.opacity(0.08))
                            .cornerRadius(4)
                        Text("Discard")
                            .font(.system(size: 13))
                            .foregroundColor(.white.opacity(0.6))
                    }
                }
                .buttonStyle(.plain)

                Spacer()

                HStack(spacing: 8) {
                    Button { model.onCopyTapped?() } label: {
                        HStack(spacing: 8) {
                            Text("Copy Results")
                                .font(.system(size: 13, weight: .semibold))
                            Text("↵")
                                .font(.system(size: 10, weight: .bold))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 3)
                                .background(Color.white.opacity(0.2))
                                .cornerRadius(4)
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(Self.accentColor)
                        .cornerRadius(8)
                    }
                    .buttonStyle(.plain)

                    // Show feedback chip if we're viewing summary
                    if title == "Summary" {
                        if hasFeedback {
                            ActionChip(key: "⌘2", label: "View Feedback") {
                                model.onFeedbackTapped?()
                            }
                        } else {
                            ActionChip(key: "⌘2", label: "Generate Feedback") {
                                model.onFeedbackTapped?()
                            }
                        }
                    }

                    // Show summary chip if we're viewing feedback
                    if title == "Meeting Feedback" {
                        if hasSummary {
                            ActionChip(key: "⌘1", label: "View Summary") {
                                model.onSummarizeTapped?()
                            }
                        } else {
                            ActionChip(key: "⌘1", label: "Generate Summary") {
                                model.onSummarizeTapped?()
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color.black.opacity(0.2))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.ultraThinMaterial)
                .environment(\.colorScheme, .dark)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
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

struct RecordingWithQAView: View {
    @ObservedObject var model: WaveformModel
    @FocusState private var inputFocused: Bool
    private static let accentColor = Color(red: 0.369, green: 0.361, blue: 0.902) // #5e5ce6

    var body: some View {
        VStack(spacing: 8) {
            RecordingView(model: model)

            // Q&A card
            VStack(spacing: 0) {
                // Exchanges — most recent at the bottom
                ScrollViewReader { proxy in
                    ScrollView(.vertical) {
                        VStack(alignment: .leading, spacing: 10) {
                            if model.qaExchanges.isEmpty {
                                Text("Ask a question about what's been said so far. The recording keeps going.")
                                    .font(.system(size: 12))
                                    .foregroundColor(.white.opacity(0.5))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.top, 4)
                            } else {
                                ForEach(model.qaExchanges) { exchange in
                                    ExchangeRow(exchange: exchange)
                                        .id(exchange.id)
                                }
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .scrollIndicators(.visible)
                    .frame(maxHeight: .infinity)
                    .onChange(of: model.qaExchanges.count) { _, _ in
                        if let last = model.qaExchanges.last {
                            withAnimation(.easeOut(duration: 0.2)) {
                                proxy.scrollTo(last.id, anchor: .bottom)
                            }
                        }
                    }
                }

                Rectangle()
                    .fill(Color.white.opacity(0.1))
                    .frame(height: 1)

                // Input row
                HStack(spacing: 10) {
                    Image(systemName: "questionmark.bubble.fill")
                        .font(.system(size: 12))
                        .foregroundColor(Self.accentColor)
                    QATextField(text: $model.qaInput, onSubmit: submit)
                        .focused($inputFocused)
                    Button(action: submit) {
                        Text("Ask")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(
                                Capsule().fill(canSubmit ? Self.accentColor : Color.white.opacity(0.15))
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSubmit)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Color.black.opacity(0.2))
            }
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(.ultraThinMaterial)
                    .environment(\.colorScheme, .dark)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
        }
        .onAppear { inputFocused = true }
    }

    private var canSubmit: Bool {
        !model.qaInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func submit() {
        let trimmed = model.qaInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        model.onAskSubmit?(trimmed)
    }
}

/// NSTextField wrapper so we can auto-focus and get a clean single-line editor
/// with proper keyboard handling inside a floating NSPanel.
struct QATextField: NSViewRepresentable {
    @Binding var text: String
    let onSubmit: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onSubmit: onSubmit)
    }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 13)
        field.textColor = .white
        field.placeholderAttributedString = NSAttributedString(
            string: "Ask something…",
            attributes: [
                .foregroundColor: NSColor.white.withAlphaComponent(0.4),
                .font: NSFont.systemFont(ofSize: 13)
            ]
        )
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.submitAction(_:))
        field.stringValue = text
        return field
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
        context.coordinator.text = $text
        context.coordinator.onSubmit = onSubmit
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>
        var onSubmit: () -> Void

        init(text: Binding<String>, onSubmit: @escaping () -> Void) {
            self.text = text
            self.onSubmit = onSubmit
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            text.wrappedValue = field.stringValue
        }

        @objc func submitAction(_ sender: NSTextField) {
            onSubmit()
        }
    }
}

struct ExchangeRow: View {
    let exchange: QAExchange
    private static let accentColor = Color(red: 0.369, green: 0.361, blue: 0.902) // #5e5ce6

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                Text("Q")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 16, height: 16)
                    .background(Self.accentColor.opacity(0.6))
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                Text(exchange.question)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white.opacity(0.95))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(alignment: .top, spacing: 8) {
                Text("A")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 16, height: 16)
                    .background(Color.white.opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                if let answer = exchange.answer {
                    Text(answer)
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.85))
                        .lineSpacing(2)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ThinkingIndicator()
                }
            }
        }
    }
}

struct ThinkingIndicator: View {
    @State private var phase: Double = 0
    private static let accentColor = Color(red: 0.369, green: 0.361, blue: 0.902) // #5e5ce6

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3) { i in
                Circle()
                    .fill(Self.accentColor)
                    .frame(width: 5, height: 5)
                    .opacity(dotOpacity(index: i))
            }
        }
        .onAppear {
            withAnimation(.linear(duration: 1.0).repeatForever(autoreverses: false)) {
                phase = 1.0
            }
        }
    }

    private func dotOpacity(index: Int) -> Double {
        let offset = Double(index) * 0.33
        let t = (phase + offset).truncatingRemainder(dividingBy: 1.0)
        return 0.3 + 0.7 * abs(sin(t * .pi))
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
