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
#endif
