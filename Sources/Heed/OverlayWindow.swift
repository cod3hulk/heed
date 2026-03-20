import AppKit
import SwiftUI

final class OverlayWindow: NSPanel {
    init(stateMachine: RecorderStateMachine, audioCaptureService: AudioCaptureService) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 56),
            styleMask: [.nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        titlebarAppearsTransparent = true
        titleVisibility = .hidden

        let hostingView = NSHostingView(
            rootView: OverlayContentView(
                stateMachine: stateMachine,
                audioCaptureService: audioCaptureService
            )
        )
        contentView = hostingView

        positionTopRight()
    }

    private func positionTopRight() {
        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.visibleFrame
        let x = screenFrame.maxX - frame.width - 16
        let y = screenFrame.maxY - frame.height - 16
        setFrameOrigin(NSPoint(x: x, y: y))
    }
}

struct OverlayContentView: View {
    @Bindable var stateMachine: RecorderStateMachine
    var audioCaptureService: AudioCaptureService

    var body: some View {
        VStack(spacing: 0) {
            switch stateMachine.state {
            case .recording:
                recordingView
            default:
                defaultView
            }
        }
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private var recordingView: some View {
        VStack(spacing: 6) {
            AudioWaveformView(level: audioCaptureService.currentLevel)
                .frame(height: 24)
            HStack {
                Circle()
                    .fill(.red)
                    .frame(width: 6, height: 6)
                Text("Recording...")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    private var defaultView: some View {
        HStack(spacing: 8) {
            statusIndicator
            Text(stateMachine.state.label)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var statusIndicator: some View {
        switch stateMachine.state {
        case .idle:
            Circle()
                .fill(.secondary)
                .frame(width: 8, height: 8)
        case .recording:
            EmptyView()
        case .transcribing, .processing:
            ProgressView()
                .controlSize(.small)
        case .actionSelection:
            Image(systemName: "keyboard")
                .font(.system(size: 12))
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.system(size: 14))
        case .error:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .font(.system(size: 14))
        }
    }
}

// MARK: - Audio Waveform Visualization

struct AudioWaveformView: View {
    var level: Float
    private let barCount = 40

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            HStack(spacing: 1.5) {
                ForEach(0..<barCount, id: \.self) { index in
                    WaveformBar(
                        level: level,
                        index: index,
                        time: timeline.date.timeIntervalSinceReferenceDate
                    )
                }
            }
        }
    }
}

struct WaveformBar: View {
    let level: Float
    let index: Int
    let time: TimeInterval

    var body: some View {
        let phase = sin(time * 4.0 + Double(index) * 0.3) * 0.3 + 0.5
        let amplitude = max(0.1, Double(level) * phase + Double.random(in: 0...0.05))
        let height = max(2, amplitude * 22)

        RoundedRectangle(cornerRadius: 1)
            .fill(.primary.opacity(0.6))
            .frame(width: 2, height: height)
    }
}
