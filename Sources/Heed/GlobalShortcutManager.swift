import AppKit
import Carbon.HIToolbox

// Carbon EventHotKey identifies hotkeys by a UInt32 ID we choose. Dispatch to
// callbacks stored under those IDs. This module owns global mutable state
// because Carbon's C API predates Swift concurrency.
private var hotKeyCallbacks: [UInt32: () -> Void] = [:]

@MainActor
final class GlobalShortcutManager {
    private struct Registration {
        var ref: EventHotKeyRef
        var id: UInt32
    }

    private var handlerRef: EventHandlerRef?
    private var registrations: [String: Registration] = [:]
    private var nextID: UInt32 = 1

    static let toggleRecordingKey = "toggleRecording"
    static let askKey = "ask"

    var onToggleRecording: (() -> Void)?
    var onAsk: (() -> Void)?

    func start() {
        installHandlerIfNeeded()

        // ⇧⌘R — always registered while the app runs
        register(
            key: Self.toggleRecordingKey,
            keyCode: UInt32(kVK_ANSI_R),
            modifiers: UInt32(cmdKey | shiftKey)
        ) { [weak self] in
            self?.onToggleRecording?()
        }
    }

    /// Register the ask hotkey. Called when recording starts so ⌥Space
    /// isn't captured globally when the app is idle.
    func registerAskShortcut(binding: KeyBinding) {
        installHandlerIfNeeded()
        unregister(key: Self.askKey)
        register(
            key: Self.askKey,
            keyCode: UInt32(binding.keyCode),
            modifiers: carbonModifiers(from: binding.modifierFlags)
        ) { [weak self] in
            self?.onAsk?()
        }
    }

    func unregisterAskShortcut() {
        unregister(key: Self.askKey)
    }

    func stop() {
        for (_, reg) in registrations {
            UnregisterEventHotKey(reg.ref)
            hotKeyCallbacks.removeValue(forKey: reg.id)
        }
        registrations.removeAll()

        if let handlerRef {
            RemoveEventHandler(handlerRef)
            self.handlerRef = nil
        }
    }

    // MARK: - Private

    private func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let handler: EventHandlerUPP = { _, event, _ -> OSStatus in
            var hkID = EventHotKeyID()
            let status = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hkID
            )
            guard status == noErr else { return noErr }
            let id = hkID.id
            Task { @MainActor in
                hotKeyCallbacks[id]?()
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
    }

    private func register(key: String, keyCode: UInt32, modifiers: UInt32, callback: @escaping () -> Void) {
        let id = nextID
        nextID += 1
        let hotKeyID = EventHotKeyID(signature: OSType(0x48454544), id: id) // "HEED"
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        guard status == noErr, let ref else {
            print("RegisterEventHotKey failed for \(key): status=\(status)")
            return
        }
        registrations[key] = Registration(ref: ref, id: id)
        hotKeyCallbacks[id] = callback
    }

    private func unregister(key: String) {
        guard let reg = registrations.removeValue(forKey: key) else { return }
        UnregisterEventHotKey(reg.ref)
        hotKeyCallbacks.removeValue(forKey: reg.id)
    }

    /// Convert NSEvent modifier flags → Carbon modifier bitmask.
    private func carbonModifiers(from nsFlags: UInt) -> UInt32 {
        let flags = NSEvent.ModifierFlags(rawValue: nsFlags)
        var mods: UInt32 = 0
        if flags.contains(.command) { mods |= UInt32(cmdKey) }
        if flags.contains(.shift)   { mods |= UInt32(shiftKey) }
        if flags.contains(.option)  { mods |= UInt32(optionKey) }
        if flags.contains(.control) { mods |= UInt32(controlKey) }
        return mods
    }
}
