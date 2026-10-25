import Foundation

/// The unified MeowDisplay app's two roles: Share This Mac (the sender, as
/// it always was) and Use This Mac as a Display (the Mac Receiver, hosted in
/// the same bundle). Exactly one has live sessions at a time: while this Mac
/// is a display, the sender starts no sessions — no auto-connect, Connect,
/// receiver connect request or Remote knock — and it resumes when the
/// display role is turned off. That rules out a Mac streaming to itself, two
/// Macs streaming into each other, and input looping between them, without
/// tearing down the sender's listeners or pairing.
struct MacAppRoleState: Equatable {
    enum Effect: Equatable {
        /// End every sender session without suppressing auto-reconnect, so
        /// the devices come back by themselves when the role switches back.
        case endSenderSessions
        /// Stop advertising this Mac as a Mac to pair with and connect to
        /// (`_opendisplay-mac-pair._tcp`): while it's a display, other
        /// receivers shouldn't list it as a Mac that will share with them.
        case withdrawSenderAdvertisement
        case startReceiver
        /// Stop the receiver, sending `closing` to a connected sender.
        case stopReceiver
        /// Advertise the sender again.
        case advertiseSender
        /// Let the sender reconnect its devices.
        case resumeSender
    }

    static let defaultsKey = "receiverModeEnabled"

    private(set) var receiverEnabled: Bool

    init(receiverEnabled: Bool) {
        self.receiverEnabled = receiverEnabled
    }

    init(defaults: UserDefaults) {
        receiverEnabled = defaults.bool(forKey: Self.defaultsKey)
    }

    /// Whether the sender may start (or keep) a session.
    var senderMayConnect: Bool { !receiverEnabled }

    /// What launching does: the display role comes back only if the user
    /// left it on. Off by default — a sender install never advertises a
    /// receiver it didn't ask for.
    var launchEffects: [Effect] { receiverEnabled ? [.withdrawSenderAdvertisement, .startReceiver] : [] }

    mutating func setReceiverEnabled(_ enabled: Bool, defaults: UserDefaults) -> [Effect] {
        guard enabled != receiverEnabled else { return [] }
        receiverEnabled = enabled
        defaults.set(enabled, forKey: Self.defaultsKey)
        return enabled
            ? [.endSenderSessions, .withdrawSenderAdvertisement, .startReceiver]
            : [.stopReceiver, .advertiseSender, .resumeSender]
    }
}

/// The standalone MeowDisplay Receiver (still shipped for macOS 12–13, and
/// installed by existing users) listens on the same ports and advertises the
/// same services. Current versions take `ReceiverOwnershipLock` like the
/// display role does; already-released builds don't, so while any version
/// runs the display role waits (`ReceiverController.otherReceiverRunning`)
/// rather than fail to bind next to it.
enum StandaloneReceiverConflict {
    static let bundleIdentifiers: Set<String> = [
        "com.raisecaterror.meowdisplay.mac.receiver",
        "com.raisecaterror.meowdisplay.mac.receiver.debug",
    ]

    static func isRunning(among runningBundleIdentifiers: [String?]) -> Bool {
        runningBundleIdentifiers.contains { $0.map(bundleIdentifiers.contains) ?? false }
    }
}

/// The unified app is a menu-bar (accessory) app unless the user chose a
/// Dock icon. While the display role's video window is up it is a regular
/// app, so it has a Dock icon and Command-Tab can leave the full-screen
/// display; changing the presentation setting meanwhile must not undo that.
enum MacAppActivationPolicy {
    static func isRegular(showsDockIcon: Bool, displayWindowVisible: Bool) -> Bool {
        showsDockIcon || displayWindowVisible
    }
}
