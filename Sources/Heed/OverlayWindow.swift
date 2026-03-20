import AppKit
import SwiftUI

@MainActor
final class OverlayWindow {
    private var panel: NSPanel?
    private let waveformModel = WaveformModel()
    private var levelTimer: Timer?

    func show(audioService: AudioCaptureService) {
        guard panel == nil else { return }

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

        // Position at bottom center of main screen
        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let x = screenFrame.midX - 240
            let y = screenFrame.minY + 60
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }

        panel.orderFrontRegardless()
        self.panel = panel

        // Poll audio level at 30fps for waveform animation
        levelTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let level = audioService.currentLevel
                self.waveformModel.addLevel(level)
            }
        }
    }

    func hide() {
        levelTimer?.invalidate()
        levelTimer = nil
        panel?.close()
        panel = nil
        waveformModel.reset()
    }

    var isVisible: Bool {
        panel != nil
    }
}

// MARK: - Waveform Data Model

@MainActor
final class WaveformModel: ObservableObject {
    @Published var levels: [Float] = []
    private let maxBars = 60

    func addLevel(_ level: Float) {
        levels.append(level)
        if levels.count > maxBars {
            levels.removeFirst(levels.count - maxBars)
        }
    }

    func reset() {
        levels = []
    }
}

// MARK: - SwiftUI Views

struct OverlayContentView: View {
    @ObservedObject var model: WaveformModel

    var body: some View {
        VStack(spacing: 0) {
            // Waveform area
            WaveformView(levels: model.levels)
                .frame(maxWidth: .infinity)
                .frame(height: 100)
                .padding(.horizontal, 16)
                .padding(.top, 12)

            // Bottom bar
            HStack {
                // Recording indicator
                HStack(spacing: 6) {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 8, height: 8)
                    Text("Recording")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white)
                }

                Spacer()

                // Stop shortcut hint
                HStack(spacing: 4) {
                    Text("Stop")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.7))
                    Text("⇧⌘R")
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
                .fill(Color.black.opacity(0.85))
        )
    }
}

struct WaveformView: View {
    let levels: [Float]
    private let barWidth: CGFloat = 3
    private let barSpacing: CGFloat = 2

    var body: some View {
        GeometryReader { geo in
            let maxBars = Int(geo.size.width / (barWidth + barSpacing))
            let displayLevels = paddedLevels(count: maxBars)
            let midY = geo.size.height / 2

            Canvas { context, size in
                for (i, level) in displayLevels.enumerated() {
                    let barHeight = max(2, CGFloat(level) * midY * 2)
                    let x = CGFloat(i) * (barWidth + barSpacing)
                    let y = midY - barHeight / 2

                    let rect = CGRect(x: x, y: y, width: barWidth, height: barHeight)
                    let path = RoundedRectangle(cornerRadius: 1.5).path(in: rect)

                    let opacity = Double(max(0.3, min(1.0, level * 3 + 0.3)))
                    context.fill(path, with: .color(.white.opacity(opacity)))
                }
            }
        }
    }

    private func paddedLevels(count: Int) -> [Float] {
        if levels.count >= count {
            return Array(levels.suffix(count))
        }
        let padding = [Float](repeating: 0, count: count - levels.count)
        return padding + levels
    }
}
