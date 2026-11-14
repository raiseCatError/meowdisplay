// CI experiment: an iOS app change with no UI test of its own (never merged).
import Foundation

// The iPhone/iPad Remote Access setup and status wording, as pure values (Foundation only, so the
// Mac test bundle compiles it). Nothing here dials, checks a network or changes trust: it only
// turns facts the app already has into words a person can act on.

/// Why a Connect over Remote didn't finish, from the last knock this device made at the Mac's
/// saved address (`RemoteKnockResult`), or the Mac not connecting back after a delivered one.
/// The same meanings as Android's `OfflineReason` and `MacStatus` (RemoteStatus.kt).
enum RemoteAccessProblem: Equatable, CaseIterable {
    case addressNotFound
    case timedOut
    case refused
    case noRoute
    case notMeowDisplay
    case differentMac
    case notAccepted
    case didNotConnectBack

    /// Nil for a knock that says nothing about the Mac (cancelled).
    init?(lastKnock: RemoteKnockResult) {
        switch lastKnock {
        case .dnsFailed: self = .addressNotFound
        case .timedOut: self = .timedOut
        case .refused: self = .refused
        case .unreachable: self = .noRoute
        case .failed: self = .notMeowDisplay
        case .identityMismatch: self = .differentMac
        case .notAccepted: self = .notAccepted
        case .delivered: self = .didNotConnectBack
        case .cancelled: return nil
        }
    }

    /// An identity problem: the address answered with another key, or the Mac refused this
    /// device's. Neither is fixed by trying again.
    var isIdentityProblem: Bool { self == .differentMac || self == .notAccepted }

    /// One short line for the Mac's row on Home.
    func summary(deviceKind: String) -> String {
        switch self {
        case .addressNotFound: String(localized: "Offline · address not found")
        case .timedOut: String(localized: "Offline · timed out")
        case .refused: String(localized: "Offline · connection refused")
        case .noRoute: String(localized: "Offline · no route")
        case .notMeowDisplay: String(localized: "Offline · couldn't connect")
        case .differentMac: String(localized: "Connection failed: different Mac at this address")
        case .notAccepted: String(localized: "This Mac doesn't accept this \(deviceKind)")
        case .didNotConnectBack: String(localized: "The Mac didn't connect back")
        }
    }

    /// What to check next. `otherMacName`: the paired Mac that answered instead, when known.
    func hint(deviceKind: String, otherMacName: String? = nil) -> String {
        switch self {
        case .addressNotFound:
            String(localized: "Check the address, and that Tailscale is on for both devices.")
        case .timedOut:
            String(localized: "Check that your Mac is awake and online, and that Tailscale is on for both devices.")
        case .refused:
            String(localized: "The address answered, but MeowDisplay isn't open there. Open MeowDisplay on your Mac, then try again.")
        case .noRoute:
            String(localized: "This \(deviceKind) has no route to that address. Turn on Tailscale on both devices, then try again.")
        case .notMeowDisplay:
            String(localized: "Something answered at that address, but it isn't MeowDisplay. Check the address.")
        case .differentMac:
            if let otherMacName {
                String(localized: "The Mac at this address is \(otherMacName), not the Mac you chose. Check the address. Nothing was connected.")
            } else {
                String(localized: "Whatever answered isn't the Mac you paired. Check the address. Nothing was connected.")
            }
        case .notAccepted:
            String(localized: "Your Mac no longer trusts this \(deviceKind). Forget the Mac here and pair again.")
        case .didNotConnectBack:
            String(localized: "Your Mac got the request but didn't connect back. Allow it on the Mac if it asks, and check that Tailscale lets the Mac reach this \(deviceKind).")
        }
    }
}

/// What a paired Mac's row on Home says about a Connect over Remote. It refines the Wake &
/// Connect status (`WakeConnectAttempt`) only for a Mac with a saved address; every other row
/// keeps its usual words.
enum RemoteConnectRowStatus {
    enum Progress: Equatable {
        /// The request to the Mac is on its way.
        case contacting
        /// The Mac took the request; it should connect to this device now.
        case waitingForMac

        var text: String {
            switch self {
            case .contacting: String(localized: "Contacting your Mac…")
            case .waitingForMac: String(localized: "Waiting for your Mac to connect…")
            }
        }
    }

    /// While a Connect runs, before the Mac connects. Nil keeps the usual status: no saved
    /// address, a Wake-on-LAN attempt ("Waking…" is true there) or a later stage.
    static func progress(stage: WakeConnectStage, wakePacketsSent: Int, hasSavedAddress: Bool,
                         lastKnock: RemoteKnockResult?) -> Progress? {
        guard hasSavedAddress, wakePacketsSent == 0 else { return nil }
        switch stage {
        case .preparing, .waking, .waitingForConnection:
            return lastKnock == .delivered ? .waitingForMac : .contacting
        default:
            return nil
        }
    }

    /// Why a finished Connect failed, when the last knock tells. Only a timed-out attempt whose
    /// Mac never connected is explained this way; a cancel, a Forget or an incompatible Mac keep
    /// their own words.
    static func problem(failureReason: String?, macConnected: Bool, hasSavedAddress: Bool,
                        lastKnock: RemoteKnockResult?) -> RemoteAccessProblem? {
        guard failureReason == "timedOut", !macConnected, hasSavedAddress, let lastKnock else { return nil }
        return RemoteAccessProblem(lastKnock: lastKnock)
    }
}

/// How far Remote Access setup is on this device, for the Remote Access page.
enum RemoteAccessSetup: Equatable {
    /// No Mac is paired yet: pair first (locally, or with Pair over Remote).
    case needsPairing
    /// A Mac is paired, but none has an address saved.
    case needsAddress
    /// At least one paired Mac has an address saved.
    case ready

    init(pairedPeerIDs: [String], savedAddressPeerIDs: Set<String>) {
        if pairedPeerIDs.isEmpty {
            self = .needsPairing
        } else if pairedPeerIDs.contains(where: savedAddressPeerIDs.contains) {
            self = .ready
        } else {
            self = .needsAddress
        }
    }

    /// Before You Start opens by itself until an address is saved; afterwards it stays one tap away.
    var showsPrerequisitesExpanded: Bool { self != .ready }
}

/// The address a paired Mac shared about itself (`AutomaticRemoteEndpointStore`), offered as a
/// suggestion on the Remote Access page. It is never saved or used without the person choosing
/// it: automatic use on iPhone and iPad stays off until it is verified on devices
/// (`TailnetFamilies.appleReceiverKnocking`).
enum RemoteAddressSuggestion {
    /// IPv4 first (the family verified for automatic use on Android), then a MagicDNS name, then
    /// IPv6. Nil when nothing was shared or the saved address is already that one.
    static func host(sharedNames: [String], sharedIPs: [String], saved: String?) -> String? {
        let candidate = sharedIPs.first(where: { !$0.contains(":") })
            ?? sharedNames.first
            ?? sharedIPs.first(where: { $0.contains(":") })
        guard let candidate else { return nil }
        if let saved, saved.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(candidate) == .orderedSame {
            return nil
        }
        return candidate
    }

    /// Whether this device connects to a Mac's shared address by itself. False until the Apple
    /// receiver path is verified on devices; the Remote Access page says so while it is.
    static var connectsAutomatically: Bool { TailnetFamilies.appleReceiverKnocking != .none }
}

/// Official Tailscale pages the Remote Access page links to. Opening one is the person's choice;
/// MeowDisplay never installs, signs in to or changes Tailscale.
enum TailscaleLinks {
    /// Tailscale for iPhone and iPad on the App Store (seller: Tailscale Inc.).
    static let appStore = URL(string: "https://apps.apple.com/app/tailscale/id1470499037")!
    /// Tailscale's own guide to VPN On Demand on iPhone and iPad.
    static let vpnOnDemand = URL(string: "https://tailscale.com/docs/features/client/ios-vpn-on-demand")!
}

/// What Pair over Remote's failure screen adds under its title on iPhone and iPad.
enum RemotePairingGuidance {
    static func detail(for kind: RemotePairingFailureKind) -> String? {
        switch kind {
        case .unreachable:
            String(localized: "Check the address, that Tailscale is on for both devices, and that Pair over Remote is open on the Mac.")
        default:
            kind.detail
        }
    }
}
