import Foundation
import LocalAuthentication

/// System device-owner authentication (`deviceOwnerAuthentication`): Touch ID /
/// Face ID when available, with the OS passcode / account-password fallback.
/// The OS owns all UI; nothing custom is stored. If the device cannot
/// authenticate its owner at all (e.g. no passcode set) the result is `.failed`
/// and pairing stays untrusted.
final class LocalOwnerAuthenticator: OwnerAuthenticating, @unchecked Sendable {
    private let lock = NSLock()
    private var context: LAContext?

    func authenticate(reason: String) async -> OwnerAuthResult {
        let context = LAContext()
        lock.lock(); self.context = context; lock.unlock()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            Log.info("ownerAuth: unavailable code=\(error?.code ?? 0)")
            return .failed
        }
        do {
            let ok = try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
            return ok ? .success : .failed
        } catch let laError as LAError {
            switch laError.code {
            case .userCancel, .appCancel, .systemCancel: return .cancelled
            default:
                Log.info("ownerAuth: failed code=\(laError.code.rawValue)")
                return .failed
            }
        } catch {
            return .failed
        }
    }

    func invalidate() {
        lock.lock(); let current = context; context = nil; lock.unlock()
        current?.invalidate()
    }
}
