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
    static let version = 19

    /// First version that requires pinned mutual TLS for LAN/AWDL media and
    /// supports the transcript-authenticated local pairing protocol.
    // 12: pairing adds the live commit/ack finalization phase and authenticated
    // abort (a local accept is provisional until the commit exchange). Older
    // pairing peers (11) are refused at the hello with "update required".
    static let securePairingWireVersion = 12

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

    /// Protocol version that introduced Mac-authoritative Mirror capture-source
    /// selection: `mirrorDisplayState` (Mac -> receiver: current Auto/Manual
    /// selection + display inventory) and `mirrorDisplayRequest` (receiver ->
    /// Mac: select Auto or a specific stable display UUID). A receiver MUST
    /// NOT send `mirrorDisplayRequest`, and MUST NOT expect
    /// `mirrorDisplayState`, when the peer is below this version — the Mac's
    /// own Settings picker still works regardless, it just isn't mirrored to
    /// an old receiver.
    static let mirrorDisplayWireVersion = 13

    /// Protocol version that introduced Mac-authoritative Extend display
    /// shape: `extendShapeState` (Mac -> receiver: confirmed active
    /// shape/Full-Display) and `extendShapeRequest` (receiver -> Mac: request
    /// a shape change). A receiver MUST NOT send `extendShapeRequest`, and
    /// MUST NOT expect `extendShapeState`, when the peer is below this
    /// version — the Mac keeps extending at its existing (pre-shape-picker)
    /// size regardless, exactly the same fallback shape as
    /// `mirrorDisplayWireVersion`.
    static let extendShapeWireVersion = 14

    /// Protocol version that introduced receiver-enforced maximum FPS:
    /// `maxFPSState` (Mac -> receiver: confirmed enforcement + limit, plus
    /// the encoder-safe ceiling for the current encode size) and
    /// `maxFPSRequest` (receiver -> Mac: request enforcement on/off + a
    /// limit). A receiver MUST NOT send `maxFPSRequest`, and MUST NOT
    /// expect `maxFPSState`, when the peer is below this version — the Mac
    /// still applies `EncoderCapability`'s encoder-safe ceiling regardless,
    /// exactly the same fallback shape as `extendShapeWireVersion`.
    static let maxFPSWireVersion = 15

    /// Protocol version that introduced Mac-authoritative Streaming Priority:
    /// `streamingPriorityState` (Mac -> receiver: confirmed Auto/Prefer FPS/
    /// Prefer Latency selection) and `streamingPriorityRequest` (receiver ->
    /// Mac: request a different priority). A receiver MUST NOT send
    /// `streamingPriorityRequest`, and MUST NOT expect
    /// `streamingPriorityState`, when the peer is below this version — the
    /// Mac keeps using its own stored/default priority regardless, exactly
    /// the same fallback shape as `maxFPSWireVersion`.
    static let streamingPriorityWireVersion = 16

    /// Protocol version that introduced `mirrorUnavailable` (Mac ->
    /// receiver): sent when Mirror has no usable physical display (a
    /// headless/clamshell Mac) instead of failing the session immediately —
    /// the receiver may offer to switch to Extend via the EXISTING
    /// `displayModeRequest` message; there is no separate "accepted" reply,
    /// the confirmed mode still arrives back the normal way via
    /// `displayModeState`. A receiver MUST NOT expect `mirrorUnavailable`
    /// when the peer is below this version — the Mac falls back to its
    /// pre-existing clean, immediate Mirror failure instead of waiting on a
    /// prompt an older receiver cannot show.
    static let mirrorUnavailableWireVersion = 17

    /// Protocol version that introduced per-DEVICE-SESSION input consent:
    /// `allowInputState` gained an additive `state` field (`off`/
    /// `requesting`/`allowed`/`notAllowed`/`requestsDisabled` — see
    /// `SessionInputWireState`) alongside its pre-existing `allowed` bool,
    /// which keeps meaning exactly the same thing (effective input on/off)
    /// for every peer regardless of version. `allowInputRequest` itself is
    /// unchanged on the wire (`{type, allowed: Bool}`); only the MAC's
    /// behavior on receiving `allowed: true` changed, from an immediate
    /// Mac-wide grant to a per-session request that may show an owner
    /// prompt — this is strictly a NARROWING of what a request achieves, so
    /// it is safe to apply to every peer unconditionally, not gated on this
    /// version at all. A pre-18 receiver simply sees `allowInputState.
    /// allowed` flip to true later (once/if granted) instead of instantly,
    /// exactly like a slow reply; a pv 18+ receiver can additionally render
    /// "Requesting…"/"Not allowed"/"Requests disabled by Mac" from `state`.
    static let sessionScopedInputConsentWireVersion = 18

    /// Protocol version this build shipped HEVC/H.265 (Main, 8-bit) in, as
    /// an OPTIONAL second video codec alongside the universal H.264
    /// baseline. Historical/documentation marker ONLY — unlike most of the
    /// version constants above, codec capability is deliberately NOT gated
    /// by comparing a peer's overall `pv` against this constant. It follows
    /// the additive-FIELD pattern of `maxEncodeWide`/`maxFPS` instead: a
    /// peer's `hello.codecs` field, if present at all, IS the capability
    /// signal (understands codec negotiation and `streamCodecState`);
    /// absence of the field means H.264-only, regardless of `pv`. This
    /// matters because a peer can advertise a LOWER overall `pv` than its
    /// build's latest for reasons unrelated to codec support; gating HEVC on
    /// overall `pv` would make it unreachable for such a peer.
    /// `minPeer` stays at `1`
    /// on both sides; a peer that never sends `hello.codecs` keeps receiving
    /// H.264 exactly as before this feature existed.
    static let hevcCodecWireVersion = 19

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
    // Mac -> receiver: current Mirror capture-source selection (Auto/Manual +
    // stable UUID) plus the Mac's current display inventory. Re-sent on every
    // hello (same pattern as `wakeInfo`/`displayModeState`) and whenever the
    // selection or display topology changes.
    static let mirrorDisplayState = "mirrorDisplayState"
    // receiver -> Mac: select Auto (absent/null `selectedUUID`) or a specific
    // stable display UUID as the Mirror capture source. Only ever honored
    // over the existing authenticated session — see `mirrorDisplayWireVersion`.
    static let mirrorDisplayRequest = "mirrorDisplayRequest"
    static let streamingProfileRequest = "streamingProfileRequest"
    static let streamingProfileState = "streamingProfileState"
    // receiver -> Mac: request an Extend display shape change (`shape`,
    // `useFullDisplay`) — see `ExtendDisplayShapePreference`.
    static let extendShapeRequest = "extendShapeRequest"
    // Mac -> receiver: confirmed active Extend shape. Re-sent on every
    // successful capture start (same pattern as `displayModeState`) so the
    // receiver never infers shape from stream dimensions.
    static let extendShapeState = "extendShapeState"
    // receiver -> Mac: request receiver-enforced max-FPS enforcement on/off
    // + a limit (`enabled`, `maxFPS`) — see `ReceiverMaxFPSPreference`. Only
    // ever honored over the existing authenticated session — see
    // `maxFPSWireVersion`.
    static let maxFPSRequest = "maxFPSRequest"
    // Mac -> receiver: confirmed max-FPS enforcement state, plus diagnostic
    // ceilings (`encoderSafeFPS`, `effectiveFPS`) so a receiver can show
    // PART 5's limitation text without recomputing `EncoderCapability`
    // itself. Re-sent on every successful capture start (same pattern as
    // `extendShapeState`) so the receiver never infers it from stream
    // dimensions alone.
    static let maxFPSState = "maxFPSState"
    // receiver -> Mac: request a Streaming Priority change (`priority`) —
    // see `StreamingPriority`. Only ever honored over the existing
    // authenticated session — see `streamingPriorityWireVersion`.
    static let streamingPriorityRequest = "streamingPriorityRequest"
    // Mac -> receiver: confirmed active Streaming Priority. Re-sent on every
    // hello (same pattern as `streamingProfileState`) so the receiver never
    // infers it from stream behavior alone.
    static let streamingPriorityState = "streamingPriorityState"
    // Mac -> receiver: Mirror has no usable physical display (headless) —
    // offer the receiver a chance to switch to Extend via the EXISTING
    // `displayModeRequest` message rather than failing the session
    // immediately. `reason` is diagnostic only (currently always
    // "noUsablePhysicalDisplay"). See `mirrorUnavailableWireVersion`.
    static let mirrorUnavailable = "mirrorUnavailable"
    // Mac -> receiver: the confirmed codec ("h264" or "hevc") the in-flight
    // (or about-to-start) video stream actually uses — see
    // `WireProtocol.hevcCodecWireVersion`. Re-sent on every successful
    // capture start and on every codec change (same pattern as
    // `extendShapeState`/`maxFPSState`) so a receiver never infers codec
    // from stream bytes. Sent to any receiver whose `hello` included a
    // `codecs` field at all (that field's presence, not overall `pv`, is
    // the capability signal — see `hevcCodecWireVersion`'s doc comment); a
    // receiver that never sent `codecs` never receives this and correctly
    // assumes H.264, the only codec it can ever be sent.
    static let streamCodecState = "streamCodecState"
}

enum WireCrypto {
    static let tlsPort: UInt16 = 9001
    static let pairingPort: UInt16 = 9002
    /// Mac-side pairing listener that exists only while the user has
    /// explicitly opened "Pair over Remote" (see `RemotePairingWindow`).
    /// Same pairing protocol as `pairingPort`; reachability only, never trust.
    static let remotePairingPort: UInt16 = 9004
    /// Mac-side pinned-mutual-TLS listener a paired peer "knocks" on to
    /// request that the Mac dial it back — see `RemoteConnectRequestPolicy`
    /// and `SenderController.handleRemoteConnectRequest`. The knock itself
    /// carries no payload: establishing this connection at all, as an
    /// already-pinned peer, is the entire request.
    static let remoteRequestPort: UInt16 = 9003
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

/// Wire values for `allowInputState`'s additive `state` field (pv 18+) — see
/// `WireProtocol.sessionScopedInputConsentWireVersion`. A pre-18 receiver
/// never reads this field and only ever sees the unchanged `allowed` bool,
/// which stays a correct summary of every one of these: only `.allowed` is
/// ever sent with `allowed: true`, every other case sends `allowed: false`.
enum SessionInputWireState: String, Equatable {
    /// No session grant, no pending request.
    case off
    /// A control-request prompt is up on the Mac, awaiting the owner.
    case requesting
    /// This session currently has effective input.
    case allowed
    /// The Mac owner said Not Now, or the prompt timed out.
    case notAllowed
    /// This peer's persisted policy is Never Allow Requests — the receiver
    /// should stop offering to retry immediately.
    case requestsDisabled

    var receiverDisplayText: String {
        switch self {
        case .off: return "Off"
        case .requesting: return "Requesting…"
        case .allowed: return "Allowed for this session"
        case .notAllowed: return "Not allowed"
        case .requestsDisabled: return "Requests disabled by Mac"
        }
    }
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

/// One entry in the Mac's Mirror display inventory, wire shape only — never
/// a `CGDirectDisplayID` (see `MirrorDisplayIdentity`). `uuid` is the same
/// stable identity the Mac's own Settings picker persists, so a receiver
/// selection and the Mac's canonical `mirrorDisplayUUID` always speak the
/// same identity.
struct MirrorDisplayEntry: Equatable {
    let uuid: String
    let name: String
    let isMain: Bool
    let logicalWidth: Int
    let logicalHeight: Int
    let pixelWidth: Int
    let pixelHeight: Int
    let likelyVirtual: Bool

    init(uuid: String, name: String, isMain: Bool, logicalWidth: Int, logicalHeight: Int,
        pixelWidth: Int, pixelHeight: Int, likelyVirtual: Bool) {
        self.uuid = uuid
        self.name = name
        self.isMain = isMain
        self.logicalWidth = logicalWidth
        self.logicalHeight = logicalHeight
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.likelyVirtual = likelyVirtual
    }

    init?(entry: [String: Any]) {
        guard let uuid = entry["uuid"] as? String, !uuid.isEmpty,
              let name = entry["name"] as? String else { return nil }
        self.uuid = uuid
        self.name = name
        isMain = entry["isMain"] as? Bool ?? false
        logicalWidth = entry["logicalWidth"] as? Int ?? 0
        logicalHeight = entry["logicalHeight"] as? Int ?? 0
        pixelWidth = entry["pixelWidth"] as? Int ?? 0
        pixelHeight = entry["pixelHeight"] as? Int ?? 0
        likelyVirtual = entry["likelyVirtual"] as? Bool ?? false
    }
}

/// Mac -> receiver Mirror capture-source report. `selectedUUID == nil` means
/// Auto — the same nil-means-automatic semantic the Mac's own
/// `mirrorDisplayUUID` already uses, never a separate boolean (see
/// `MirrorDisplaySelection.swift`).
struct MirrorDisplayStateUpdate: Equatable {
    let selectedUUID: String?
    let displays: [MirrorDisplayEntry]

    init(selectedUUID: String?, displays: [MirrorDisplayEntry]) {
        self.selectedUUID = selectedUUID
        self.displays = displays
    }

    init?(message: [String: Any]) {
        guard message["type"] as? String == WireMessage.mirrorDisplayState else { return nil }
        selectedUUID = message["selectedUUID"] as? String
        // Element-wise, not `as? [[String: Any]]` on the whole array: a
        // single malformed entry from a newer/buggy peer must only drop
        // that entry, never silently empty the whole inventory.
        let rawDisplays = message["displays"] as? [Any] ?? []
        displays = rawDisplays.compactMap { ($0 as? [String: Any]).flatMap(MirrorDisplayEntry.init) }
    }
}

/// Mac -> receiver `maxFPSState` (PART 4/5/9): the confirmed enforcement
/// preference plus enough of `StreamingFPSPolicy`'s last calculation for the
/// receiver to render PART 5's limitation text without re-deriving
/// `EncoderCapability` itself (which would need the encode dimensions the
/// receiver never sees). `reason` is `StreamingFPSPolicy.LimitReason.rawValue`.
struct MaxFPSStateUpdate: Equatable {
    let preference: ReceiverMaxFPSPreference
    let availableTiers: [Int]
    let encoderSafeFPS: Int
    let requestedFPS: Int
    let effectiveFPS: Int
    let reason: String

    init(preference: ReceiverMaxFPSPreference, availableTiers: [Int], encoderSafeFPS: Int,
         requestedFPS: Int, effectiveFPS: Int, reason: String) {
        self.preference = preference
        self.availableTiers = availableTiers
        self.encoderSafeFPS = encoderSafeFPS
        self.requestedFPS = requestedFPS
        self.effectiveFPS = effectiveFPS
        self.reason = reason
    }

    init?(message: [String: Any]) {
        guard message["type"] as? String == WireMessage.maxFPSState,
              let enabled = message["enabled"] as? Bool,
              let maxFPS = message["maxFPS"] as? Int, maxFPS > 0,
              let encoderSafeFPS = message["encoderSafeFPS"] as? Int,
              let requestedFPS = message["requestedFPS"] as? Int,
              let effectiveFPS = message["effectiveFPS"] as? Int,
              let reason = message["reason"] as? String else { return nil }
        preference = ReceiverMaxFPSPreference(enabled: enabled, maxFPS: maxFPS)
        availableTiers = (message["availableTiers"] as? [Int]) ?? EncoderCapability.supportedFPSTiers
        self.encoderSafeFPS = encoderSafeFPS
        self.requestedFPS = requestedFPS
        self.effectiveFPS = effectiveFPS
        self.reason = reason
    }

    var wireFields: [String: Any] {
        var fields = preference.wireFields
        fields["availableTiers"] = availableTiers
        fields["encoderSafeFPS"] = encoderSafeFPS
        fields["requestedFPS"] = requestedFPS
        fields["effectiveFPS"] = effectiveFPS
        fields["reason"] = reason
        return fields
    }
}

/// Mac -> receiver `streamCodecState` (HEVC milestone): the confirmed codec
/// of the in-flight/about-to-start video stream, plus a diagnostic `reason`
/// (a `CodecSelectionPolicy.Reason.rawValue`) so a receiver's diagnostics can
/// show WHY without re-deriving the policy itself. See
/// `WireProtocol.hevcCodecWireVersion`.
struct StreamCodecStateUpdate: Equatable {
    let codec: StreamCodec
    let reason: String

    init(codec: StreamCodec, reason: String) {
        self.codec = codec
        self.reason = reason
    }

    init?(message: [String: Any]) {
        guard message["type"] as? String == WireMessage.streamCodecState,
              let rawCodec = message["codec"] as? String,
              let codec = StreamCodec(rawValue: rawCodec) else { return nil }
        self.codec = codec
        reason = message["reason"] as? String ?? ""
    }

    var wireFields: [String: Any] {
        ["type": WireMessage.streamCodecState, "codec": codec.wireValue, "reason": reason]
    }
}
