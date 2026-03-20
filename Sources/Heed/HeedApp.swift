import AppKit

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let stateMachine = RecorderStateMachine()
    private var overlayWindow: OverlayWindow!
    private var recordingMenuItem: NSMenuItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        setupOverlay()
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "record.circle", accessibilityDescription: "Heed")
            button.title = " Heed"
        }

        let menu = NSMenu()

        recordingMenuItem = NSMenuItem(title: "Start Recording ⇧⌘R", action: #selector(toggleRecording), keyEquivalent: "")
        recordingMenuItem.target = self
        menu.addItem(recordingMenuItem)

        menu.addItem(NSMenuItem.separator())

        let settingsItem = NSMenuItem(title: "Settings...", action: nil, keyEquivalent: ",")
        menu.addItem(settingsItem)

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        statusItem.menu = menu
    }

    private func setupOverlay() {
        overlayWindow = OverlayWindow(stateMachine: stateMachine)
    }

    @objc private func toggleRecording() {
        stateMachine.toggleRecording()
        updateMenuState()
        updateOverlayVisibility()
    }

    private func updateMenuState() {
        if stateMachine.state.isRecording {
            recordingMenuItem.title = "Stop Recording ⇧⌘R"
            statusItem.button?.image = NSImage(systemSymbolName: "record.circle.fill", accessibilityDescription: "Heed — Recording")
        } else {
            recordingMenuItem.title = "Start Recording ⇧⌘R"
            statusItem.button?.image = NSImage(systemSymbolName: "record.circle", accessibilityDescription: "Heed")
        }
    }

    private func updateOverlayVisibility() {
        switch stateMachine.state {
        case .idle:
            overlayWindow.orderOut(nil)
        default:
            overlayWindow.orderFront(nil)
        }
    }
}
