import Foundation

/// Pure, deterministic edge-detection for meeting activity.
///
/// The impure side (scanning on-screen windows) feeds a single boolean —
/// "is a qualifying meeting window on screen right now" — into `observe(rawActive:now:)`
/// along with a monotonic timestamp. This struct decides when to prompt the user and
/// when a meeting has genuinely ended, applying debounce so a brief window flicker or a
/// quick leave/rejoin doesn't produce a spurious end + re-prompt.
///
/// No AppKit / CoreGraphics dependencies and no internal clock reads, so it can be unit
/// tested by driving `observe` with hand-picked timestamps.
public struct MeetingDetectionState: Equatable {
    public enum Event: Equatable {
        case none
        case meetingStarted   // rising edge — caller should prompt
        case meetingEnded     // falling edge, committed after debounce
    }

    /// How long the meeting window must stay gone before we treat the meeting as ended.
    /// Absorbs brief flickers and quick leave/rejoin cycles.
    public let debounceInterval: TimeInterval

    private var active = false                    // last committed (debounced) meeting state
    private var promptedForCurrentSession = false // ensures we prompt at most once per meeting
    private var pendingFallingSince: TimeInterval? // set when the window drops while active

    public init(debounceInterval: TimeInterval = 3.0) {
        self.debounceInterval = debounceInterval
    }

    /// Feed one observation.
    /// - Parameters:
    ///   - rawActive: whether a qualifying meeting window is on screen right now.
    ///   - now: a monotonic timestamp in seconds (e.g. `ProcessInfo.systemUptime`).
    /// - Returns: the event the caller should act on.
    public mutating func observe(rawActive: Bool, now: TimeInterval) -> Event {
        if rawActive {
            // Any live observation cancels a pending end — still the same session.
            pendingFallingSince = nil

            if !active {
                active = true
                if !promptedForCurrentSession {
                    promptedForCurrentSession = true
                    return .meetingStarted
                }
            }
            return .none
        }

        // rawActive == false
        guard active else { return .none }

        // Start (or continue) the debounce window before committing an end.
        if pendingFallingSince == nil {
            pendingFallingSince = now
            return .none
        }
        if let since = pendingFallingSince, now - since >= debounceInterval {
            active = false
            promptedForCurrentSession = false
            pendingFallingSince = nil
            return .meetingEnded
        }
        return .none
    }
}
