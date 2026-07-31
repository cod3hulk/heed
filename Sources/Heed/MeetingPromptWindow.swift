import AppKit
import SwiftUI

/// A small non-activating floating panel that asks whether to start recording when a meeting
/// is detected. Modeled on `OverlayWindow`'s `FocusablePanel` recipe so it floats above the
/// meeting (including full-screen Zoom) without stealing focus. Deliberately not an
/// `NSAlert.runModal()` — that blocks the run loop and activates the app.
@MainActor
final class MeetingPromptWindow {
    enum Kind {
        case offerStart
        case offerStop
    }

    private var panel: NSPanel?
    private var autoDismissTimer: Timer?

    var isVisible: Bool { panel != nil }

    /// Show the prompt. No-op if already visible. `onConfirm`/`onDismiss` are invoked on tap;
    /// the caller is responsible for calling `hide()` (the wiring in `AppDelegate` does).
    func show(kind: Kind, onConfirm: @escaping () -> Void, onDismiss: @escaping () -> Void) {
        guard panel == nil else { return }

        let view = MeetingPromptView(kind: kind, onConfirm: onConfirm, onDismiss: onDismiss)
        let hosting = NSHostingView(rootView: view)

        let width: CGFloat = 340
        let height: CGFloat = 140
        hosting.frame = NSRect(x: 0, y: 0, width: width, height: height)

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
        panel.hasShadow = false
        panel.contentView = hosting
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        positionPanel(panel, width: width, height: height)
        panel.orderFrontRegardless()
        self.panel = panel

        // Safety net: don't leave a stale prompt on screen indefinitely.
        let timer = Timer(timeInterval: 20.0, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in self?.hide() }
        }
        RunLoop.main.add(timer, forMode: .common)
        autoDismissTimer = timer
    }

    func hide() {
        autoDismissTimer?.invalidate()
        autoDismissTimer = nil
        panel?.close()
        panel = nil
    }

    private func positionPanel(_ panel: NSPanel, width: CGFloat, height: CGFloat) {
        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.visibleFrame
        let x = screenFrame.midX - width / 2
        let y = screenFrame.maxY - screenFrame.height / 4 - height / 2
        panel.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
    }
}

// MARK: - View

private struct MeetingPromptView: View {
    let kind: MeetingPromptWindow.Kind
    let onConfirm: () -> Void
    let onDismiss: () -> Void

    private static let accentColor = Color(red: 0.369, green: 0.361, blue: 0.902) // #5e5ce6

    private var icon: String {
        switch kind {
        case .offerStart: return "ear.fill"
        case .offerStop: return "stop.circle.fill"
        }
    }

    private var title: String {
        switch kind {
        case .offerStart: return "Start Heed recording?"
        case .offerStop: return "Stop Heed recording?"
        }
    }

    private var subtitle: String {
        switch kind {
        case .offerStart: return "Zoom meeting detected"
        case .offerStop: return "Zoom meeting ended"
        }
    }

    private var dismissTitle: String {
        switch kind {
        case .offerStart: return "Dismiss"
        case .offerStop: return "Keep Recording"
        }
    }

    private var confirmTitle: String {
        switch kind {
        case .offerStart: return "Start"
        case .offerStop: return "Stop"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(Self.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white)
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.55))
                }
                Spacer()
            }

            HStack(spacing: 10) {
                Spacer()
                Button(action: onDismiss) {
                    Text(dismissTitle)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white.opacity(0.7))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(Color.white.opacity(0.08))
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)

                Button(action: onConfirm) {
                    Text(confirmTitle)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 7)
                        .background(Self.accentColor)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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
        .padding(8)
    }
}
