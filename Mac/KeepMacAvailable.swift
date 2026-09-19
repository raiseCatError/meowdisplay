import Foundation
import IOKit.pwr_mgt

/// Seam over the IOKit call so tests never touch real system sleep state.
protocol PowerAssertionProviding {
    /// Returns an assertion ID, or nil when macOS refused the assertion.
    func create(reason: String) -> IOPMAssertionID?
    func release(_ id: IOPMAssertionID)
}

/// `kIOPMAssertionTypePreventUserIdleSystemSleep`: stops automatic idle
/// system sleep only. The display may still sleep normally, and it does not
/// (and cannot) override lid-close sleep on battery.
struct IOKitPowerAssertionProvider: PowerAssertionProviding {
    func create(reason: String) -> IOPMAssertionID? {
        var id = IOPMAssertionID(0)
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn), reason as CFString, &id)
        return result == kIOReturnSuccess ? id : nil
    }

    func release(_ id: IOPMAssertionID) { IOPMAssertionRelease(id) }
}

/// Holds at most one assertion. `isActive` reflects what macOS actually
/// granted, never merely the requested preference.
final class KeepMacAvailableAssertion {
    static let reason = "MEOW Keep Mac Available"

    private let provider: PowerAssertionProviding
    private var assertionID: IOPMAssertionID?

    var isActive: Bool { assertionID != nil }

    init(provider: PowerAssertionProviding = IOKitPowerAssertionProvider()) {
        self.provider = provider
    }

    /// Idempotent; a failed acquire leaves `isActive` false. Returns `isActive`.
    @discardableResult
    func enable() -> Bool {
        if assertionID == nil { assertionID = provider.create(reason: Self.reason) }
        return isActive
    }

    /// Idempotent: safe to call when nothing is held.
    func disable() {
        guard let id = assertionID else { return }
        provider.release(id)
        assertionID = nil
    }

    deinit { disable() }
}
