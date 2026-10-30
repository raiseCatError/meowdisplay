import Foundation
import IOKit.pwr_mgt

/// Answers one question: does declaring remote user activity promote a
/// dark/network wake into a graphical/interactive one? This calls exactly
/// one public IOKit API and nothing else — no synthesized input, no
/// capture/display rebuild, no pmset changes, no private APIs. Called from
/// `MacSender`'s `promoteInteractiveWake` wire handler in response to the
/// iOS Wake & Connect coordinator's Promote request.
enum InteractiveWakePromotion {
    struct Attempt {
        let result: IOReturn
        let assertionID: IOPMAssertionID?
    }

    static func promote(reason: String = "MEOW Remote Session") -> Attempt {
        var assertionID: IOPMAssertionID = 0
        let result = IOPMAssertionDeclareUserActivity(
            reason as CFString, kIOPMUserActiveRemote, &assertionID)
        Log.info("wakeDebug: promoteInteractiveWake requested")
        Log.info("wakeDebug: userActivityType=remote")
        Log.info("wakeDebug: result=\(result)")
        if result == kIOReturnSuccess {
            Log.info("wakeDebug: assertionID=\(assertionID)")
            return Attempt(result: result, assertionID: assertionID)
        }
        return Attempt(result: result, assertionID: nil)
    }
}

/// A fixed, bounded hold on two PUBLIC IOKit power assertions — held
/// together after either a successful `InteractiveWakePromotion.promote()`
/// (the dark/network-wake path) or, since the headless hardening pass, any
/// authenticated MEOW session becoming application-ready on ANY route (see
/// `SessionStabilizationPolicy` and `MacSender.armSessionStabilizationIfNeeded`)
/// — meant to keep the Mac from re-sleeping while the receiver's
/// connection/video pipeline actually gets going. Real hardware showed
/// `PreventUserIdleDisplaySleep` alone is not enough: the Mac can still
/// `screensDidSleep`/suspend well before the 60s window elapses, so this
/// also holds `PreventSystemSleep` for the identical bounded window — never
/// indefinitely, and never via pmset/NVRAM/a privileged helper.
/// Always exactly 60 seconds from the most recent arm — `begin()`
/// reschedules rather than stacking a second pair of assertions if one is
/// already held, which is exactly how a same-peer route migration extends
/// (rather than re-opens a gap in) the window. Owned by `MacSender`, which
/// is responsible for calling `release()` on session invalidation/teardown
/// so this can never outlive the session it started with (see
/// `invalidateApplicationSession`/`stop()`) — except a same-peer transport
/// migration, which deliberately does NOT release it (see `switchTransport`).
final class WakeStabilizationAssertion {
    static let duration: TimeInterval = 60
    static let reason = "MEOW Session Stabilization"

    private var displaySleepAssertionID: IOPMAssertionID?
    private var systemSleepAssertionID: IOPMAssertionID?
    private var releaseWorkItem: DispatchWorkItem?

    /// `generation`/`route` are logging context only (which session/route
    /// triggered this arm) — they never gate whether the assertions are held.
    func begin(generation: UInt64? = nil, route: String? = nil) {
        releaseWorkItem?.cancel()
        let context = [generation.map { "generation=\($0)" }, route.map { "route=\($0)" }]
            .compactMap { $0 }.joined(separator: " ")
        Log.info("wakeDebug: sessionStabilizationArmed \(context)")
        beginOne(&displaySleepAssertionID,
                type: kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                name: "displaySleepAssertion")
        beginOne(&systemSleepAssertionID,
                type: kIOPMAssertionTypePreventSystemSleep as CFString,
                name: "systemSleepAssertion")
        let work = DispatchWorkItem { [weak self] in
            Log.info("wakeDebug: sessionStabilizationExpired")
            self?.release()
        }
        releaseWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.duration, execute: work)
    }

    private func beginOne(_ id: inout IOPMAssertionID?, type: CFString, name: String) {
        guard id == nil else {
            Log.info("wakeDebug: \(name)Extended id=\(id!)")
            return
        }
        var newID: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(
            type, IOPMAssertionLevel(kIOPMAssertionLevelOn), Self.reason as CFString, &newID)
        guard result == kIOReturnSuccess else {
            Log.info("wakeDebug: \(name)Failed result=\(result)")
            return
        }
        id = newID
        Log.info("wakeDebug: \(name)Started id=\(newID)")
    }

    /// Idempotent: safe to call from every teardown path regardless of
    /// whether an assertion is actually held right now.
    func release() {
        releaseWorkItem?.cancel()
        releaseWorkItem = nil
        if let id = displaySleepAssertionID {
            IOPMAssertionRelease(id)
            displaySleepAssertionID = nil
            Log.info("wakeDebug: displaySleepAssertionReleased")
        }
        if let id = systemSleepAssertionID {
            IOPMAssertionRelease(id)
            systemSleepAssertionID = nil
            Log.info("wakeDebug: systemSleepAssertionReleased")
        }
    }
}

/// Keeps the Mac's display awake while at least one device is watching (admitted, video on, not
/// paused, Screen Recording allowed), on every route and in every mode.
///
/// Why the display and not just the system: when the displays sleep, ScreenCaptureKit stops every
/// stream with -3815 "Failed to find any displays or windows to capture" (logged 2026-10-30
/// 18:41:58, 60 ms after screensDidSleep), and with "require password immediately" the Mac locks
/// too. Keeping the system awake alone leaves the stream dead. `PreventUserIdleDisplaySleep` is
/// the narrowest public assertion that keeps capture alive: it only stops *idle* display sleep.
/// Closing the lid, the Mac's own sleep command, and the user's lock still apply, and it is never
/// user activity (unlike `IOPMAssertionDeclareUserActivity`), so it doesn't wake a sleeping
/// display or postpone the screen saver's lock beyond the display.
///
/// One assertion for the whole app, counted across viewers: it is created when the first device
/// starts watching and released when the last one stops. It is also released while this login
/// session is switched out (another user has the console). powerd releases it if the app exits.
final class DisplayAwakeLedger: @unchecked Sendable {
    static let shared = DisplayAwakeLedger(onConsole: LoginSessionConsole.shared.isOnConsole)
    static let reason = "MEOW Streaming to a device"

    private let lock = NSLock()
    private let create: (String) -> IOPMAssertionID?
    private let release: (IOPMAssertionID) -> Void
    private var watchers = Set<UUID>()
    private var onConsole: Bool
    private var assertionID: IOPMAssertionID?

    init(onConsole: Bool = true,
         create: @escaping (String) -> IOPMAssertionID? = { reason in
             var id = IOPMAssertionID(0)
             let r = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                                 IOPMAssertionLevel(kIOPMAssertionLevelOn), reason as CFString, &id)
             return r == kIOReturnSuccess ? id : nil
         },
         release: @escaping (IOPMAssertionID) -> Void = { IOPMAssertionRelease($0) }) {
        self.onConsole = onConsole
        self.create = create
        self.release = release
    }

    var isHeld: Bool { lock.lock(); defer { lock.unlock() }; return assertionID != nil }
    var watcherCount: Int { lock.lock(); defer { lock.unlock() }; return watchers.count }
    func isWatching(_ watcher: UUID) -> Bool { lock.lock(); defer { lock.unlock() }; return watchers.contains(watcher) }

    /// Idempotent per watcher.
    func set(_ watcher: UUID, watching: Bool) {
        lock.lock(); defer { lock.unlock() }
        let changed = watching ? watchers.insert(watcher).inserted : watchers.remove(watcher) != nil
        guard changed else { return }
        reconcile()
    }

    /// Fast User Switching: nobody here can see this session's displays while it is switched out.
    func setOnConsole(_ value: Bool) {
        lock.lock(); defer { lock.unlock() }
        guard onConsole != value else { return }
        onConsole = value
        reconcile()
    }

    /// `lock` held.
    private func reconcile() {
        let wanted = onConsole && !watchers.isEmpty
        if wanted, assertionID == nil {
            assertionID = create(Self.reason)
            Log.info("wakeDebug: streamingDisplayAwake \(assertionID.map { "held id=\($0)" } ?? "refused") watchers=\(watchers.count)")
        } else if !wanted, let id = assertionID {
            release(id)
            assertionID = nil
            Log.info("wakeDebug: streamingDisplayAwake released watchers=\(watchers.count) onConsole=\(onConsole)")
        }
    }
}

/// One sender's share of `DisplayAwakeLedger`. Going away stops its watch.
final class StreamingDisplayAwake {
    private let ledger: DisplayAwakeLedger
    private let id = UUID()

    init(ledger: DisplayAwakeLedger = .shared) { self.ledger = ledger }

    var isWatching: Bool { ledger.isWatching(id) }

    func set(watching: Bool) { ledger.set(id, watching: watching) }

    deinit { ledger.set(id, watching: false) }
}
