import AppKit
import Carbon.HIToolbox

private var globalShortcutCallback: (() -> Void)?

@MainActor
final class GlobalShortcutManager {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    var onToggleRecording: (() -> Void)?

    func start() {
        globalShortcutCallback = { [weak self] in
            self?.onToggleRecording?()
        }

        // Register Carbon hot key handler
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let handler: EventHandlerUPP = { _, event, _ -> OSStatus in
            Task { @MainActor in
                globalShortcutCallback?()
            }
            return noErr
        }

        InstallEventHandler(
            GetApplicationEventTarget(),
            handler,
            1,
            &eventType,
            nil,
            &handlerRef
        )

        // Register Cmd+Shift+R as global hotkey
        var hotKeyID = EventHotKeyID(
            signature: OSType(0x48454544), // "HEED"
            id: 1
        )
        let modifiers = UInt32(cmdKey | shiftKey)

        RegisterEventHotKey(
            UInt32(kVK_ANSI_R),
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
    }

    func stop() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let handlerRef {
            RemoveEventHandler(handlerRef)
            self.handlerRef = nil
        }
        globalShortcutCallback = nil
    }
}
