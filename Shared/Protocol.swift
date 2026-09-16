// Compiled into BOTH the Mac and iOS targets (see project.yml `sources`).
// Keep this Foundation-only so it stays platform-neutral.

import Foundation

/// The wire-protocol contract between the two apps, decoupled from the app's
/// marketing version. See COMPATIBILITY.md.
///
/// Bumped only when the wire changes, not every release, so UI-only releases
/// never trigger a compatibility event. A peer that advertises no version is
/// protocol 1 — that's every install in the field that predates the handshake.
enum WireProtocol {
    /// The protocol version this build speaks.
    static let version = 12

    /// First version that requires pinned mutual TLS for LAN/AWDL media and
    /// supports the transcript-authenticated local pairing protocol.
    static let securePairingWireVersion = 11

    /// Protocol version that introduced Apple Pencil / proximity wire messages.
    /// Peers below this get pencil input as legacy `touch` events.
    static let pencilWireVersion = 3

    /// Protocol version that introduced the `keyboard` message family (M4).
    /// A receiver MUST NOT surface keyboard input UI, and a sender MUST NOT
    /// expect keyboard messages, when the peer is below this version.
    static let keyboardWireVersion = 4

    /// Protocol version that introduced the `pointer` message family (M7):
    /// absolute/relative cursor movement decoupled from button state, click
    /// counts, and the right mouse button. A receiver MUST NOT send
    /// `pointer` messages, and MUST fall back to legacy `touch`
    /// click-drag semantics, when the peer is below this version.
    static let pointerWireVersion = 5

    /// Protocol version that introduced receiver control-tray preferences and
    /// explicit synthetic modifier transitions.
    static let receiverControlsWireVersion = 6

    /// Protocol version that introduced explicit, Mac-authoritative display
    /// mode state and receiver-originated mode-change requests.
    static let displayModeWireVersion = 7

    /// Protocol version that introduced Mac-authoritative, receiver-visible
    /// Allow Input state: the Mac pushes its current allow/deny gate on
    /// connect and whenever it changes, and a receiver can request a
    /// change. A receiver MUST NOT send `allowInputRequest`, and MUST NOT
    /// expect `allowInputState`, when the peer is below this version — the
    /// Mac's pre-existing local-only Allow Input toggle still enforces
    /// itself regardless, it just isn't mirrored to an old receiver.
    static let allowInputWireVersion = 8

    /// Protocol version that introduced a Mac-authoritative video-production
    /// toggle. Video state carries the retained stream geometry so a receiver
    /// can keep mapping input while capture and encoding are stopped.
    static let videoControlWireVersion = 9

    /// Protocol version that introduced continuous app-gesture lifecycle
    /// messages. The current Mac advertises the wire but reports native
    /// injection unavailable because public CGEvent/AppKit constructors do
    /// not expose cross-process magnify/rotate event payloads.
    static let nativeAppGestureWireVersion = 10

    /// Protocol version that introduced Mac system-audio capture: the
    /// `audioRequest`/`audioState` control messages and the binary audio
    /// media frame (section 5A). A receiver MUST NOT send `audioRequest`,
    /// and a sender MUST NOT emit audio media frames, when the peer is
    /// below this version — there is no legacy audio fallback, the feature
    /// simply stays off, exactly like `keyboard` below pv 4.
    static let audioWireVersion = 12

    /// Oldest peer protocol version this build still supports. Stays at 1
    /// (support everything) until a deliberate two-phase breaking change
    /// raises it — raising this is what turns "peer too old" into a hard gate.
    static let minSupportedPeer = 1

    /// A peer that advertises no `pv` is defined as protocol 1.
    static let assumedWhenAbsent = 1
}

/// Control-message `type` strings introduced with the handshake. The pre-
/// existing types (`hello`, `ping`, `pong`, `touch`, …) stay inline for now to
/// keep this change additive and low-risk; unify later if we do a wider pass.
enum WireMessage {
    static let welcome = "welcome"                  // Mac -> phone: Mac's pv + min supported
    static let updateRequired = "updateRequired"    // Mac -> phone: peer is below the Mac's floor
    static let sleeping = "sleeping"                // phone -> Mac: device locked, reconnect on wake
    static let closing = "closing"                  // phone -> Mac: app quit, end the session for good
    static let receiverUI = "receiverUI"             // Mac -> receiver: receiver-local UI preferences
    static let inputReset = "inputReset"             // Mac -> receiver: clear local modifier state
    static let displayModeRequest = "displayModeRequest" // receiver -> Mac: request Mirror/Extend
    static let displayModeState = "displayModeState" // Mac -> receiver: confirmed actual mode
    static let allowInputRequest = "allowInputRequest" // receiver -> Mac: request Allow Input on/off
    static let allowInputState = "allowInputState"   // Mac -> receiver: confirmed Allow Input state
    static let videoRequest = "videoRequest"         // receiver -> Mac: request video production on/off
    static let videoState = "videoState"             // Mac -> receiver: confirmed state + retained geometry
    static let nativeAppGesture = "nativeAppGesture" // receiver -> Mac: continuous magnify/rotate lifecycle
    static let audioRequest = "audioRequest"         // receiver -> Mac: request system-audio capture on/off
    static let audioState = "audioState"             // Mac -> receiver: confirmed audio production state
    static let unpair = "unpair"
    // Mac -> receiver: LAN wake-on-LAN hint (MAC/interface/broadcast) for
    // this Mac, opportunistically re-sent on every hello like `welcome`.
    // Purely informational — a receiver on an older build ignores it, and
    // it never grants or implies trust (see `WakeMetadata`).
    static let wakeInfo = "wakeInfo"
    // receiver -> Mac (DEBUG-only manual diagnostic): ask the Mac to call
    // IOPMAssertionDeclareUserActivity. Only ever handled if it arrives on
    // the existing authenticated/pinned session — there is no separate
    // unauthenticated channel for it.
    static let promoteInteractiveWake = "promoteInteractiveWake"
    // Mac -> receiver: result of the above.
    static let promoteInteractiveWakeResult = "promoteInteractiveWakeResult"
}

enum WireCrypto {
    static let tlsPort: UInt16 = 9001
    static let pairingPort: UInt16 = 9002
    static let maxPairingFrameBytes = 64 * 1024
    static let identityKeychainLabel = "com.opendisplay.identity.v1"
    static let pinKeychainService = "com.opendisplay.trust.v1"
    static let installIDAccount = "installID"
    static let fingerprintHKDFSalt = Data("OpenDisplay-TLS-Pairing-v1".utf8)
    static let fingerprintHKDFInfo = Data("fingerprint".utf8)
}

enum CursorTransportPolicy {
    static func shouldOpenUDP(isSecureNetworkSession: Bool, advertisedPort: Int?) -> Bool {
        !isSecureNetworkSession && advertisedPort.map { $0 > 0 && $0 <= Int(UInt16.max) } == true
    }

    static func shouldSendOnPrimary(udpAvailable: Bool, udpConfirmed: Bool) -> Bool {
        !udpAvailable || !udpConfirmed
    }
}

enum NativeAppGestureKind: String, Codable, CaseIterable, Hashable {
    case magnify
    case rotate
}

enum NativeAppGesturePhase: String, Codable, CaseIterable {
    case began
    case changed
    case ended
    case cancelled
}

struct NativeAppGestureUpdate: Equatable {
    let kind: NativeAppGestureKind
    let phase: NativeAppGesturePhase
    let delta: Double

    init?(message: [String: Any]) {
        guard message["type"] as? String == WireMessage.nativeAppGesture,
              let rawKind = message["kind"] as? String,
              let kind = NativeAppGestureKind(rawValue: rawKind),
              let rawPhase = message["phase"] as? String,
              let phase = NativeAppGesturePhase(rawValue: rawPhase),
              let number = message["delta"] as? NSNumber,
              number.doubleValue.isFinite else { return nil }
        self.kind = kind
        self.phase = phase
        delta = number.doubleValue
    }
}

/// Pure lifecycle validation shared by the Mac handler and hostless tests.
/// Changed/end packets without a matching begin are safely ignored.
struct NativeAppGestureSessionState: Equatable {
    private(set) var active: Set<NativeAppGestureKind> = []

    mutating func accept(_ update: NativeAppGestureUpdate) -> Bool {
        switch update.phase {
        case .began:
            return active.insert(update.kind).inserted
        case .changed:
            return active.contains(update.kind)
        case .ended, .cancelled:
            return active.remove(update.kind) != nil
        }
    }

    mutating func cancelAll() { active.removeAll() }
}

enum ReceiverDisplayMode: String, Codable, CaseIterable, Identifiable {
    case mirror
    case extend

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

/// Receiver-side request bookkeeping. The Mac's state message always wins;
/// the boolean return from `confirm` identifies the single successful reply
/// that should produce user feedback.
struct DisplayModeRequestState: Equatable {
    private(set) var confirmedMode: ReceiverDisplayMode?
    private(set) var pendingMode: ReceiverDisplayMode?
    /// Bumped for every accepted request so a late expiry can only retire the
    /// request it was armed for, never a newer one.
    private(set) var pendingGeneration = 0

    mutating func request(_ mode: ReceiverDisplayMode) -> Bool {
        guard pendingMode == nil, mode != confirmedMode else { return false }
        pendingMode = mode
        pendingGeneration &+= 1
        return true
    }

    mutating func confirm(_ mode: ReceiverDisplayMode) -> Bool {
        let confirmsReceiverRequest = pendingMode == mode
        confirmedMode = mode
        pendingMode = nil
        return confirmsReceiverRequest
    }

    /// Retires a request the Mac never answered (its transition failed, or the
    /// reply was lost). The last confirmed mode — the real one — is kept.
    mutating func expirePending(generation: Int) -> Bool {
        guard pendingMode != nil, pendingGeneration == generation else { return false }
        pendingMode = nil
        return true
    }

    /// Session teardown. Nothing about the Mac's mode is known across a
    /// deliberate session reset, and no stale request may outlive it.
    mutating func reset() {
        confirmedMode = nil
        pendingMode = nil
    }
}

struct VideoStateUpdate: Equatable {
    let enabled: Bool
    let width: Int?
    let height: Int?

    init(enabled: Bool, width: Int?, height: Int?) {
        self.enabled = enabled
        self.width = width
        self.height = height
    }

    init?(message: [String: Any]) {
        guard message["type"] as? String == WireMessage.videoState,
              let enabled = message["enabled"] as? Bool else { return nil }
        self.enabled = enabled
        if let width = message["width"] as? Int,
           let height = message["height"] as? Int,
           width > 0, height > 0 {
            self.width = width
            self.height = height
        } else {
            width = nil
            height = nil
        }
    }
}


struct AudioStateUpdate: Equatable {
    let enabled: Bool

    init(enabled: Bool) {
        self.enabled = enabled
    }

    init?(message: [String: Any]) {
        guard message["type"] as? String == WireMessage.audioState,
              let enabled = message["enabled"] as? Bool else { return nil }
        self.enabled = enabled
    }
}
