import CoreGraphics
import Foundation

/// The rules of the Privacy Shield, pure so they are tested.
enum PrivacyShieldPolicy {
    /// Remote connections (Tailscale and other routed addresses): ON by default.
    static let remoteKey = "privacyShield.remote"
    /// Local connections (Wi-Fi, peer-to-peer, USB, hotspot): off by default.
    static let localKey = "privacyShield.local"
    static let relockMinutesKey = "privacyShield.relockMinutes"
    static let relockChoices = [1, 5, 15, 30]
    static let defaultRelockMinutes = 5

    /// Cover the Mac's own screens: a connected device's kind of connection (remote or local) has
    /// the shield on, and no one at the Mac revealed it recently (revealing lasts until the Mac has
    /// had no physical keyboard, mouse or trackpad input for `relockAfter`).
    static func shouldCover(remoteOn: Bool, localOn: Bool, sessions: [Bool], revealed: Bool,
                            physicalIdle: TimeInterval, relockAfter: TimeInterval) -> Bool {
        guard sessions.contains(where: { $0 ? remoteOn : localOn }) else { return false }
        return !(revealed && physicalIdle < relockAfter)
    }

    /// Hardware input carries no posting process; anything posted by a process (MeowDisplay's
    /// remote input, other apps' synthetic events) has its pid. Only hardware counts as someone
    /// at the Mac.
    static func isPhysical(sourcePID: Int64) -> Bool { sourcePID == 0 }

    /// Every display a person can look at: MeowDisplay's own virtual displays (Extend) are left out.
    static func coveredDisplays(_ all: [CGDirectDisplayID], virtual: Set<CGDirectDisplayID>) -> [CGDirectDisplayID] {
        all.filter { !virtual.contains($0) }
    }

    /// Read from any thread (the welcome message). Remote defaults to on, local to off.
    static func isOn(remote: Bool) -> Bool {
        remote ? (UserDefaults.standard.object(forKey: remoteKey) as? Bool ?? true) : UserDefaults.standard.bool(forKey: localKey)
    }
}

/// The cover's window ids, for capture filters on any queue.
enum PrivacyShieldWindows {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var ids: [CGWindowID] = []
    static var current: [CGWindowID] { lock.withLock { ids } }
    /// True when they changed.
    static func replace(with new: [CGWindowID]) -> Bool { lock.withLock { defer { ids = new }; return ids != new } }
}

