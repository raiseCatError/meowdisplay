#if DEBUG
import IOKit.pwr_mgt

/// DEBUG-only probe for one question: does declaring remote user activity
/// promote a dark/network wake into a graphical/interactive one? This calls
/// exactly one public IOKit API and nothing else — no synthesized input, no
/// capture/display rebuild, no pmset changes, no private APIs.
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

/// A fixed, bounded `PreventUserIdleDisplaySleep` assertion held only after
/// a successful `InteractiveWakePromotion.promote()` — a separate, longer-
/// lived hold from that one-shot user-activity declaration, meant to keep
/// the just-promoted display from immediately re-sleeping while the
/// receiver's connection/video pipeline (Promote → screensDidWake → fresh
/// SCK recovery) actually gets going. Always exactly 60 seconds from the
/// most recent successful Promote — `begin()` reschedules rather than
/// stacking a second assertion if one is already held. Owned by
/// `MacSender`, which is responsible for calling `release()` on session
/// invalidation/teardown so this can never outlive the session it started
/// with (see `invalidateApplicationSession`/`stop()`).
final class WakeStabilizationAssertion {
    static let duration: TimeInterval = 60
    static let reason = "MEOW Remote Wake Stabilization"

    private var assertionID: IOPMAssertionID?
    private var releaseWorkItem: DispatchWorkItem?

    func begin() {
        releaseWorkItem?.cancel()
        if assertionID == nil {
            var id: IOPMAssertionID = 0
            let result = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                Self.reason as CFString, &id)
            guard result == kIOReturnSuccess else {
                Log.info("wakeDebug: wakeStabilizationAssertionFailed result=\(result)")
                releaseWorkItem = nil
                return
            }
            assertionID = id
            Log.info("wakeDebug: wakeStabilizationAssertionStarted id=\(id)")
        } else {
            Log.info("wakeDebug: wakeStabilizationAssertionExtended id=\(assertionID!)")
        }
        let work = DispatchWorkItem { [weak self] in
            Log.info("wakeDebug: wakeStabilizationAssertionExpired")
            self?.release()
        }
        releaseWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.duration, execute: work)
    }

    /// Idempotent: safe to call from every teardown path regardless of
    /// whether an assertion is actually held right now.
    func release() {
        releaseWorkItem?.cancel()
        releaseWorkItem = nil
        guard let assertionID else { return }
        IOPMAssertionRelease(assertionID)
        self.assertionID = nil
        Log.info("wakeDebug: wakeStabilizationAssertionReleased")
    }
}
#endif
