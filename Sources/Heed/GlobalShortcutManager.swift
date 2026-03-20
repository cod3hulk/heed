import AppKit
import Carbon.HIToolbox

@MainActor
final class GlobalShortcutManager {
    private var eventMonitors: [Any] = []
    var onToggleRecording: (() -> Void)?

    func start() {
        // Monitor when app is NOT focused
        let globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKeyEvent(event)
        }
        if let globalMonitor {
            eventMonitors.append(globalMonitor)
        }

        // Monitor when app IS focused (e.g., menu is open)
        let localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if self?.isToggleShortcut(event) == true {
                self?.handleKeyEvent(event)
                return nil // consume the event
            }
            return event
        }
        if let localMonitor {
            eventMonitors.append(localMonitor)
        }
    }

    func stop() {
        for monitor in eventMonitors {
            NSEvent.removeMonitor(monitor)
        }
        eventMonitors.removeAll()
    }

    private func handleKeyEvent(_ event: NSEvent) {
        guard isToggleShortcut(event) else { return }
        Task { @MainActor [weak self] in
            self?.onToggleRecording?()
        }
    }

    private func isToggleShortcut(_ event: NSEvent) -> Bool {
        let requiredFlags: NSEvent.ModifierFlags = [.command, .shift]
        let pressedFlags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return pressedFlags == requiredFlags && event.keyCode == UInt16(kVK_ANSI_R)
    }
}
