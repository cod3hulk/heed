import AppKit
import Carbon.HIToolbox

@MainActor
final class GlobalShortcutManager {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var onToggleRecording: (() -> Void)?
    private var onAction: ((PostTranscriptionAction) -> Void)?

    func register(
        onToggleRecording: @escaping () -> Void,
        onAction: @escaping (PostTranscriptionAction) -> Void
    ) {
        self.onToggleRecording = onToggleRecording
        self.onAction = onAction
        setupEventTap()
    }

    func unregister() {
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        eventTap = nil
        runLoopSource = nil
    }

    private func setupEventTap() {
        // Check accessibility without prompting first
        if !AXIsProcessTrusted() {
            // Only prompt if not already trusted
            let options = ["AXTrustedCheckOptionPrompt" as CFString: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
            print("Accessibility permission not yet granted. Global shortcuts will be unavailable until approved.")
            return
        }

        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue)

        // Store self as unmanaged pointer for the C callback
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, _, event, userInfo -> Unmanaged<CGEvent>? in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let manager = Unmanaged<GlobalShortcutManager>.fromOpaque(userInfo).takeUnretainedValue()
                return manager.handleEvent(event)
            },
            userInfo: selfPtr
        ) else {
            print("Failed to create event tap. Ensure Accessibility permissions are granted.")
            return
        }

        self.eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        self.runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private nonisolated func handleEvent(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags

        let hasShift = flags.contains(.maskShift)
        let hasCommand = flags.contains(.maskCommand)
        let noOtherMods = !flags.contains(.maskControl) && !flags.contains(.maskAlternate)

        // ⇧⌘R (keyCode 15 = R)
        if keyCode == kVK_ANSI_R && hasShift && hasCommand && noOtherMods {
            Task { @MainActor [weak self] in
                self?.onToggleRecording?()
            }
            return nil  // Consume the event
        }

        // ⌘1 (keyCode 18 = 1)
        if keyCode == kVK_ANSI_1 && hasCommand && !hasShift && noOtherMods {
            Task { @MainActor [weak self] in
                self?.onAction?(.summarize)
            }
            return nil
        }

        // ⌘2 (keyCode 19 = 2)
        if keyCode == kVK_ANSI_2 && hasCommand && !hasShift && noOtherMods {
            Task { @MainActor [weak self] in
                self?.onAction?(.meetingFeedback)
            }
            return nil
        }

        return Unmanaged.passUnretained(event)
    }
}
