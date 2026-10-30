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
    /// `held`: a covered device disconnected and no one at the Mac has unlocked since; the cover
    /// stays (a reconnect or mode switch never uncovers the Mac, even for a moment).
    static func shouldCover(remoteOn: Bool, localOn: Bool, sessions: [Bool], revealed: Bool,
                            physicalIdle: TimeInterval, relockAfter: TimeInterval, held: Bool = false) -> Bool {
        guard held || sessions.contains(where: { $0 ? remoteOn : localOn }) else { return false }
        return !(revealed && physicalIdle < relockAfter)
    }

    /// A device whose connection had the shield on ended while the cover showed: keep covering
    /// until someone at the Mac unlocks it (fail closed).
    static func holdsAfterDisconnect(showing: Bool, endedProtected: Bool) -> Bool { showing && endedProtected }

    /// Hardware input carries no posting process; anything posted by a process (MeowDisplay's
    /// remote input, other apps' synthetic events) has its pid. Only hardware counts as someone
    /// at the Mac.
    static func isPhysical(sourcePID: Int64) -> Bool { sourcePID == 0 }

    /// Every display a person can look at: MeowDisplay's own virtual displays (Extend) are left out.
    static func coveredDisplays(_ all: [CGDirectDisplayID], virtual: Set<CGDirectDisplayID>) -> [CGDirectDisplayID] {
        all.filter { !virtual.contains($0) }
    }

    // MARK: OLED care
    // The cover is black, which an OLED panel shows with its pixels off. Only the message and the
    // Unlock button light pixels, so they move to a new spot every minute, dim after a minute
    // without use at the Mac and go dark after five; touching the Mac's own mouse, trackpad or
    // keyboard brings them back at once. macOS doesn't tell apps which panels are OLED, so every
    // display gets this (it costs nothing on others).

    enum CoverLook: Equatable { case bright, dim, dark }
    static let coverMoveEvery: TimeInterval = 60
    static let coverDimAfter: TimeInterval = 60
    static let coverDarkAfter: TimeInterval = 5 * 60
    /// The message (icon and two lines) with the Unlock button under it, as one block.
    static let coverBlock = CGSize(width: 640, height: 200)
    /// The message's own box (icon and two lines), inside the block.
    static let coverMessageSize = CGSize(width: 640, height: 110)
    /// From the block's centre: up to the message's centre, down to the Unlock button's centre.
    static let coverMessageLift: CGFloat = 50
    static let coverButtonDrop: CGFloat = 48

    /// `idle`: since the cover appeared or someone last used this Mac's own input, whichever is later.
    static func coverLook(idle: TimeInterval) -> CoverLook {
        idle >= coverDarkAfter ? .dark : idle >= coverDimAfter ? .dim : .bright
    }

    /// Where the block's centre goes at `step` on a screen of `size` (origin top left). The screen
    /// is split into nine areas, visited in an order that always jumps to a different area, with
    /// the spot inside each area varied so the same pixels aren't lit again round after round.
    static func coverCenter(step: Int, screen size: CGSize, block: CGSize = coverBlock, margin: CGFloat = 24) -> CGPoint {
        let order = [4, 0, 8, 2, 6, 1, 7, 3, 5]
        let area = order[((step % order.count) + order.count) % order.count]
        func axis(_ length: CGFloat, _ blockLength: CGFloat, cell: Int, salt: UInt64) -> CGFloat {
            let room = length - blockLength - margin * 2
            guard room > 0 else { return length / 2 }
            // Within the middle half of its third, so neighbouring areas' spots never touch.
            let jitter = CGFloat(mix(UInt64(bitPattern: Int64(step)) &* 2 &+ salt) % 10_000) / 10_000
            let fraction = (CGFloat(cell) + 0.25 + jitter * 0.5) / 3
            return margin + blockLength / 2 + room * fraction
        }
        return CGPoint(x: axis(size.width, block.width, cell: area % 3, salt: 0),
                       y: axis(size.height, block.height, cell: area / 3, salt: 1))
    }

    /// SplitMix64's finaliser: a fixed, well-spread number for each step.
    private static func mix(_ v: UInt64) -> UInt64 {
        var z = v &+ 0x9E37_79B9_7F4A_7C15
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
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

    nonisolated(unsafe) private static var unlocking = false
    /// macOS is asking for the login password to remove the cover: no remote input reaches the Mac
    /// (the password can only come from this Mac's own keyboard) and the prompt is left out of
    /// what devices see.
    static var isUnlocking: Bool {
        get { lock.withLock { unlocking } }
        set { lock.withLock { unlocking = newValue } }
    }
}

