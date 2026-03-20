import AppKit
import SwiftUI

@MainActor
final class OverlayWindow {
    private var panel: NSPanel?
    private let waveformModel = WaveformModel()
    private weak var audioServiceRef: AudioCaptureService?
    private var levelTimer: Timer?

    func show(audioService: AudioCaptureService) {
        guard panel == nil else { return }
        audioServiceRef = audioService

        let contentView = NSHostingView(rootView: OverlayContentView(model: waveformModel))
        contentView.frame = NSRect(x: 0, y: 0, width: 480, height: 160)

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 160),
            styleMask: [.nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isReleasedWhenClosed = false  // Required under ARC — prevents autorelease double-free
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

        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let x = screenFrame.midX - 240
            let y = screenFrame.minY + 60
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }

        panel.orderFrontRegardless()
        self.panel = panel

        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let service = self.audioServiceRef else { return }
                self.waveformModel.updateLevel(service.currentLevel)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.levelTimer = timer
    }

    func hide() {
        levelTimer?.invalidate()
        levelTimer = nil
        panel?.close()
        panel = nil
        waveformModel.reset()
        audioServiceRef = nil
    }

    var isVisible: Bool {
        panel != nil
    }
}

// MARK: - Waveform Data Model

@MainActor
final class WaveformModel: ObservableObject {
    static let barCount = 112
    @Published var barHeights: [Float] = Array(repeating: 0, count: WaveformModel.barCount)
    private var phase: Double = 0
    private var smoothedLevel: Float = 0

    func updateLevel(_ rawLevel: Float) {
        // Smooth the input level
        let attack: Float = rawLevel > smoothedLevel ? 0.5 : 0.1
        smoothedLevel = smoothedLevel + attack * (rawLevel - smoothedLevel)

        phase += 0.08

        let count = WaveformModel.barCount
        for i in 0..<count {
            let pos = Float(i) / Float(count - 1)

            // Multiple sine waves at different frequencies create organic variation
            let wave1 = sin(Double(pos) * 4.0 * .pi + phase)
            let wave2 = sin(Double(pos) * 7.0 * .pi + phase * 1.3) * 0.5
            let wave3 = sin(Double(pos) * 11.0 * .pi + phase * 0.7) * 0.3
            let combined = Float(wave1 + wave2 + wave3) / 1.8 // normalize to ~[-1, 1]

            // Map combined wave to a bar height, scaled by audio level
            let envelope = 0.15 + abs(combined) * 0.85
            let target = smoothedLevel * envelope

            // Smooth each bar individually for fluid motion
            let barAttack: Float = target > barHeights[i] ? 0.3 : 0.08
            barHeights[i] = barHeights[i] + barAttack * (target - barHeights[i])
        }
    }

    func reset() {
        barHeights = Array(repeating: 0, count: WaveformModel.barCount)
        smoothedLevel = 0
        phase = 0
    }
}

// MARK: - SwiftUI Views

struct OverlayContentView: View {
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
