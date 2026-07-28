import AppKit
import HeedCore

/// Detects when the user joins or starts a Zoom meeting and fires `onMeetingDetected`.
///
/// **Signal: meeting-helper process presence.** Zoom spawns `CptHost` (`us.zoom.CptHost`) and
/// `aomhost` (`us.zoom.aomhost`) when a meeting starts, and terminates both within about a
/// second of leaving. Measured on a real call: with Zoom merely open, neither exists; on join
/// both appear; on leave both disappear. `caphost` (`us.zoom.caphost`) runs the whole time Zoom
/// is open and is deliberately NOT part of the signal.
///
/// Window enumeration is not usable here: in a meeting every on-screen window still belongs to
/// the main `us.zoom.xos` process (no helper-owned window), and window titles — which would
/// name the meeting — are gated behind Screen Recording permission and come back empty.
///
/// Requires no permissions: `NSWorkspace.runningApplications` and bundle identifiers are
/// unprivileged. Polls on a ~2s timer and also reacts to app launch/terminate for a fast path.
/// Edge logic (rising/falling, debounce, once-per-session) lives in `MeetingDetectionState`.
@MainActor
final class MeetingDetector {
    /// Fired on a rising edge (a meeting became active), subject to `shouldPrompt`.
    var onMeetingDetected: (() -> Void)?
    /// Fired when a meeting ends (committed after debounce).
    var onMeetingEnded: (() -> Void)?
    /// Supplied by the app: return false to suppress a prompt (e.g. already recording).
    var shouldPrompt: (() -> Bool)?

    private var state = MeetingDetectionState(debounceInterval: 3.0)
    private var timer: Timer?
    private var launchObserver: NSObjectProtocol?
    private var terminateObserver: NSObjectProtocol?
    private var isRunning = false

    // MARK: - Discriminator (kept as data so a helper rename or a new app is easy to add)

    /// Bundle IDs that exist only while a meeting is active. Any one present ⇒ in a meeting.
    private let meetingHelperBundleIDs: Set<String> = ["us.zoom.CptHost", "us.zoom.aomhost"]
    /// Executable names, used as a fallback when a helper reports no bundle identifier.
    private let meetingHelperExecutableNames: Set<String> = ["CptHost", "aomhost", "aomhost64"]

    private let pollInterval: TimeInterval = 2.0

    // MARK: - Lifecycle

    func start() {
        guard !isRunning else { return }
        isRunning = true

        let timer = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.scanAndUpdate() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        let nc = NSWorkspace.shared.notificationCenter
        launchObserver = nc.addObserver(forName: NSWorkspace.didLaunchApplicationNotification,
                                        object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.scanAndUpdate() }
        }
        terminateObserver = nc.addObserver(forName: NSWorkspace.didTerminateApplicationNotification,
                                           object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.scanAndUpdate() }
        }

        // Immediate scan so enabling mid-meeting can prompt right away.
        scanAndUpdate()
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false

        timer?.invalidate()
        timer = nil

        let nc = NSWorkspace.shared.notificationCenter
        if let launchObserver { nc.removeObserver(launchObserver) }
        if let terminateObserver { nc.removeObserver(terminateObserver) }
        launchObserver = nil
        terminateObserver = nil

        state = MeetingDetectionState(debounceInterval: 3.0)
    }

    // MARK: - Scan → state machine

    private func scanAndUpdate() {
        let raw = isMeetingHelperRunning()
        let now = ProcessInfo.processInfo.systemUptime
        switch state.observe(rawActive: raw, now: now) {
        case .meetingStarted:
            if shouldPrompt?() ?? true { onMeetingDetected?() }
        case .meetingEnded:
            onMeetingEnded?()
        case .none:
            break
        }
    }

    /// True if at least one Zoom meeting-helper process is currently running.
    private func isMeetingHelperRunning() -> Bool {
        for app in NSWorkspace.shared.runningApplications {
            if let bundleID = app.bundleIdentifier, meetingHelperBundleIDs.contains(bundleID) {
                return true
            }
            // Some helper builds report no bundle id — fall back to the executable name.
            if let name = app.executableURL?.lastPathComponent,
               meetingHelperExecutableNames.contains(name) {
                return true
            }
        }
        return false
    }
}
