import AppKit
import SwiftUI

@MainActor
final class OverlayWindow {
    private var panel: NSPanel?
    private let waveformModel = WaveformModel()
    private var displayLink: CVDisplayLink?
    private weak var audioServiceRef: AudioCaptureService?

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

        // Position at bottom center of main screen
        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let x = screenFrame.midX - 240
            let y = screenFrame.minY + 60
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }

        panel.orderFrontRegardless()
        self.panel = panel

        // Use a timer at 60fps for smooth waveform updates
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let service = self.audioServiceRef else { return }
                self.waveformModel.addLevel(service.currentLevel)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.levelTimer = timer
    }

    private var levelTimer: Timer?

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
    @Published var levels: [Float] = []
    private let maxBars = 80
    private var smoothedLevel: Float = 0

    func addLevel(_ rawLevel: Float) {
        // Exponential smoothing for fluid motion
        let smoothing: Float = 0.3
        smoothedLevel = smoothedLevel * (1 - smoothing) + rawLevel * smoothing
        levels.append(smoothedLevel)
        if levels.count > maxBars {
            levels.removeFirst(levels.count - maxBars)
        }
    }

    func reset() {
        levels = []
        smoothedLevel = 0
    }
}

// MARK: - SwiftUI Views

struct OverlayContentView: View {
    @ObservedObject var model: WaveformModel

    var body: some View {
        VStack(spacing: 0) {
            WaveformView(levels: model.levels)
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
    let levels: [Float]
    private let barWidth: CGFloat = 2.5
    private let barSpacing: CGFloat = 1.5

    var body: some View {
        GeometryReader { geo in
            let maxBars = Int(geo.size.width / (barWidth + barSpacing))
            let displayLevels = paddedLevels(count: maxBars)
            let midY = geo.size.height / 2

            Canvas { context, _ in
                for (i, level) in displayLevels.enumerated() {
                    // Mirror waveform: bars grow symmetrically from center
                    let barHeight = max(1.5, CGFloat(level) * midY * 1.8)
                    let x = CGFloat(i) * (barWidth + barSpacing)
                    let y = midY - barHeight / 2

                    let rect = CGRect(x: x, y: y, width: barWidth, height: barHeight)
                    let path = Capsule().path(in: rect)

                    // Gradient opacity: newer bars (right) are brighter
                    let age = Float(i) / Float(max(1, maxBars - 1))
                    let baseOpacity = Double(age * 0.6 + 0.2)
                    let levelOpacity = Double(min(1.0, level * 2 + 0.3))
                    context.fill(path, with: .color(.white.opacity(min(1.0, baseOpacity * levelOpacity + 0.15))))
                }
            }
        }
        .animation(.linear(duration: 1.0 / 60.0), value: levels.count)
    }

    private func paddedLevels(count: Int) -> [Float] {
        if levels.count >= count {
            return Array(levels.suffix(count))
        }
        return [Float](repeating: 0, count: count - levels.count) + levels
    }
}
