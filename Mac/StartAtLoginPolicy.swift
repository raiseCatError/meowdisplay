import Foundation
import ServiceManagement
import Carbon.HIToolbox
import AppKit

/// Start at Login for Mac Sender, backed by the modern `SMAppService.mainApp`
/// — never a stored boolean pretending to be the real state, and never the
/// deprecated `SMLoginItemSetEnabled`/shared-file-list/plist approach.
///
/// Split into a pure status→message mapping (`statusMessage(for:)`,
/// independently testable without touching `SMAppService`) and the actual
/// side-effecting register/unregister calls, following the same
/// pure-policy-plus-thin-wrapper shape as `ReconnectPolicy`/`AutoConnectPolicy`.
enum StartAtLoginPolicy {
    static func isEnabled() -> Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Concise, non-onboarding-y status text for the cases that aren't a
    /// plain enabled/disabled — `nil` when there's nothing worth surfacing.
    static func statusMessage() -> String? {
        message(for: SMAppService.mainApp.status)
    }

    /// Pure mapping — the seam the tests exercise directly.
    static func message(for status: SMAppService.Status) -> String? {
        switch status {
        case .enabled, .notRegistered:
            return nil
        case .requiresApproval:
            return String(localized: "Approve MeowDisplay in System Settings → General → Login Items to finish enabling Start at Login.")
        case .notFound:
            return String(localized: "Start at Login is unavailable for this build.")
        @unknown default:
            return String(localized: "Start at Login status is unknown.")
        }
    }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            if SMAppService.mainApp.status == .enabled { return }
            try SMAppService.mainApp.register()
        } else {
            guard SMAppService.mainApp.status != .notRegistered else { return }
            try SMAppService.mainApp.unregister()
        }
    }

    /// True when this process was launched by Login Items (SMAppService's
    /// relaunch at login), detected via the classic `keyAELaunchedAsLogInItem`
    /// parameter on the `kAEOpenApplication` Apple Event — SMAppService gives
    /// no launch-time argument of its own, so this is the standard, reliable
    /// signal. Must be read early in `applicationDidFinishLaunching`, while
    /// the launch Apple Event is still current.
    static func wasLaunchedAsLoginItem() -> Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              event.eventClass == kCoreEventClass,
              event.eventID == kAEOpenApplication else { return false }
        return event.paramDescriptor(forKeyword: keyAELaunchedAsLogInItem) != nil
    }
}
