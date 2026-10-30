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

/// Keeps the Mac's display awake for as long as a device is watching (admitted, video on, not
/// paused), on every route and in every mode. A sleeping display stops the window server, and
/// every capture then delivers nothing: Mirror and Extend freeze, and Window-mode panes (Full
/// Desktop included) stall and retry until they give up. That happened whenever the Mac sat idle
/// during a session, for example covered by the Privacy Shield, once the 60 s session
/// stabilization hold ran out. Display sleep only (the Mac's lock, lid and system sleep still
/// apply), one public IOKit assertion, released as soon as nobody is watching.
final class StreamingDisplayAwake {
    static let reason = "MEOW Streaming to a device"

    private let create: (String) -> IOPMAssertionID?
    private let release: (IOPMAssertionID) -> Void
    private var assertionID: IOPMAssertionID?

    var isHeld: Bool { assertionID != nil }

    init(create: @escaping (String) -> IOPMAssertionID? = { reason in
             var id = IOPMAssertionID(0)
             let r = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                                 IOPMAssertionLevel(kIOPMAssertionLevelOn), reason as CFString, &id)
             return r == kIOReturnSuccess ? id : nil
         },
         release: @escaping (IOPMAssertionID) -> Void = { IOPMAssertionRelease($0) }) {
        self.create = create
        self.release = release
    }

    /// Idempotent: holds one assertion while `watching`, none otherwise.
    func set(watching: Bool) {
        if watching, assertionID == nil {
            assertionID = create(Self.reason)
            Log.info("wakeDebug: streamingDisplayAwake \(assertionID.map { "held id=\($0)" } ?? "refused")")
        } else if !watching, let id = assertionID {
            release(id)
            assertionID = nil
            Log.info("wakeDebug: streamingDisplayAwake released")
        }
    }

    deinit { if let id = assertionID { release(id) } }
}
