import AppKit
import Foundation

/// Who may answer a prompt that grants something (control of this Mac, a session, pairing,
/// Files or Clipboard access): only the person at this Mac. The prompts never take focus,
/// grant buttons have no Return-key default, and they wake up a moment after appearing, so a
/// keystroke or click meant for another window can't answer them. A grant counts only when
/// the event that pressed the button came from the Mac's own hardware (source PID 0), or when
/// there is no event (VoiceOver and other accessibility presses). Input a device injects is
/// posted by MeowDisplay itself (a non-zero source PID) and is refused, so a device with
/// control can't approve anything for itself or for another device.
enum ConsentInputPolicy {
    /// How long grant buttons stay disabled after a prompt appears.
    static let armDelay: TimeInterval = 1.0

    /// `sourcePID`: the source process of the event that pressed the button
    /// (`CGEvent.eventSourceUnixProcessID`), nil when no event is being handled.
    static func acceptsGrant(sourcePID: Int64?) -> Bool {
        guard let sourcePID else { return true }
        return PrivacyShieldPolicy.isPhysical(sourcePID: sourcePID)
    }
}


/// Grant buttons answer only to the person at this Mac (ConsentInputPolicy): a press made by
/// input a device injected is ignored and logged.
@MainActor
enum ConsentGrant {
    static func allowed() -> Bool {
        let pid = NSApp.currentEvent?.cgEvent?.getIntegerValueField(.eventSourceUnixProcessID)
        guard ConsentInputPolicy.acceptsGrant(sourcePID: pid) else {
            Log.info("SECURITY: a grant button was pressed by injected input; ignored")
            NSSound.beep()
            return false
        }
        return true
    }
}
