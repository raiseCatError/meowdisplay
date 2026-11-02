import Foundation

/// Grants owner authentication immediately. Ceremony tests that are not about
/// owner auth use it so the (fail-closed) prompt can proceed.
final class GrantingOwnerAuthenticator: OwnerAuthenticating, Sendable {
    func authenticate(reason: String) async -> OwnerAuthResult { .success }
    func invalidate() {}
}

extension PairingPromptModel {
    @MainActor
    static func granting(timeoutNanoseconds: UInt64 = 60_000_000_000) -> PairingPromptModel {
        let prompt = PairingPromptModel(timeoutNanoseconds: timeoutNanoseconds)
        prompt.ownerAuthenticator = GrantingOwnerAuthenticator()
        return prompt
    }
}
