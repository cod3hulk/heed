import AppKit
import SwiftUI

final class OverlayWindow: NSPanel {
    init(stateMachine: RecorderStateMachine) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 280, height: 44),
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

        let hostingView = NSHostingView(rootView: OverlayContentView(stateMachine: stateMachine))
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
    let stateMachine: RecorderStateMachine

    var body: some View {
        HStack(spacing: 8) {
            statusIndicator
            Text(stateMachine.state.label)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule())
    }

    @ViewBuilder
    private var statusIndicator: some View {
        switch stateMachine.state {
        case .idle:
            Circle()
                .fill(.secondary)
                .frame(width: 8, height: 8)
        case .recording:
            Circle()
                .fill(.red)
                .frame(width: 8, height: 8)
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
