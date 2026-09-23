// MacSender — captures a display, H.264-encodes it, streams it to the phone.
//
// Milestone 1 (mirror):  capture the main display.
// Milestone 2 (extend):  create a CGVirtualDisplay sized to the phone panel
//                        (announced by the phone in a "hello" message) and
//                        capture that — macOS gains a true second monitor.
//
// Pipeline:  ScreenCaptureKit -> VideoToolbox (H.264) -> framed TCP
// Roles: the PHONE listens, the MAC connects (required for usbmux/USB).
//
// Wire protocol, Mac -> phone:   [4-byte big-endian length][Annex B payload]
//   (keyframes prefixed with SPS+PPS, NALUs delimited by 00 00 00 01)
// Wire protocol, phone -> Mac:   [4-byte big-endian length][JSON message]
//   e.g. {"type":"hello","pixelsWide":2556,"pixelsHigh":1179,"scale":3}

@preconcurrency import ScreenCaptureKit
import VideoToolbox
import Network
import CryptoKit
import Security
import CoreMedia
import AppKit

/// Capture-resolution / bitrate trade-off. The virtual display always runs at
/// native size — only the captured/encoded stream is scaled, so lower presets
/// cut encode, transmit, and decode time at the cost of sharpness.
enum StreamQuality: String, CaseIterable {
    case best, balanced, fast

    var scale: Double {
        switch self {
        case .best: return 1.0
        case .balanced: return 0.75
        case .fast: return 0.5
        }
    }

    var bitrate: Int {
        switch self {
        case .best: return 18_000_000
        case .balanced: return 10_000_000
        case .fast: return 6_000_000
        }
    }

    var label: String {
        switch self {
        case .best: return "Best (native)"
        case .balanced: return "Balanced (75%)"
        case .fast: return "Fast (50%)"
        }
    }

    var explanation: String {
        switch self {
        case .best: return "Pixel-perfect at the device's native resolution. Highest bandwidth and latency."
        case .balanced: return "75% capture resolution — noticeably lower latency, slight softness."
        case .fast: return "Half resolution — lowest latency and bandwidth, visibly softer. Good for WiFi."
        }
    }

    /// Automatic/Custom streaming settings milestone: `StreamQuality` is
    /// Mac-app-only (see `StreamingModePolicy`'s doc comment for why its
    /// Shared siblings' equivalent lives there instead), so its own
    /// Automatic default — matching today's pre-milestone default — lives
    /// here rather than in `StreamingModePolicy`.
    static let automatic = StreamQuality.best

    static func effective(mode: StreamingMode, stored: StreamQuality) -> StreamQuality {
        mode == .custom ? stored : automatic
    }
}

struct PhoneInfo: Decodable {
    let pixelsWide: Int   // landscape-oriented (long edge)
    let pixelsHigh: Int
    let scale: Double
    let device: String?   // "iPad" / "iPhone" (older receivers omit it)
    let id: String?       // per-install identity (older receivers omit it) —
                          // lets the controller match the same physical device
                          // across USB and WiFi
    let pv: Int?          // receiver protocol version (issue #132); absent on
                          // every pre-handshake install → treat as protocol 1
    let pp: Int?          // pairing-protocol-version hint (unauthenticated,
                          // separate from `pv`/media version — see
                          // `WireProtocol.pairingVersion`'s doc comment).
                          // Early UX only; the in-band v13 ceremony is the
                          // real pairing-compatibility decision and fails
                          // closed regardless of this field.
    let addrs: [String]?  // every address the receiver is reachable on
                          // (PROTOCOL.md 6.4); probed for a cable upgrade
    let maxEncodeWide: Int?  // receiver's LEGACY decode ceiling in pixels
    let maxEncodeHigh: Int?  // (PROTOCOL.md 6.5): cap the stream, keep the
                             // desktop size. Historically H.264-specific
                             // (see `iOSDecodeCeiling`/`MacReceiver.start()`'s
                             // doc comments) but applied today as a shared
                             // conservative bound for whichever codec is
                             // chosen — see `CodecDecodeCeiling`'s doc
                             // comment for why this is deliberate, not a bug.
    // Receiver's real maximum display refresh rate in Hz (high-refresh
    // milestone): the screen's actual capability, not a request. Absent on
    // any receiver that predates this field — StreamingFPSPolicy treats nil
    // as `defaultReceiverMaxFPS` (60), never as "unlimited".
    let maxFPS: Int?
    // Receiver's hardware-decode-capable codec list (HEVC milestone,
    // PROTOCOL.md section 6.9): e.g. ["h264"] or ["h264","hevc"]. Absent on
    // any receiver that predates codec advertisement entirely — always
    // treated as H.264-only, never as "unknown means everything", exactly
    // like `maxFPS` treats absence as the safe default rather than
    // "unlimited". This field's presence (not the receiver's overall `pv`)
    // is what gates codec negotiation — see `WireProtocol.
    // hevcCodecWireVersion`'s doc comment for why: a receiver can cap its
    // advertised `pv` below the wire's latest for reasons unrelated to
    // codec support (MacReceiver does, for the unrelated Mirror-unavailable
    // UI), while still fully implementing this milestone's codec messages.
    let codecs: [String]?
    let trayEnabled: Bool?   // receiver-local control UI state (protocol 6)
    let keyboardButtonEnabled: Bool?
    // Per-device receiver settings the connected receiver reports on every
    // hello — see `StreamReceiver.announceReceiverPreferences`/`sendHello`.
    // Read-only visibility for Mac's device detail; Mac may push most of
    // these back via `MacSender.setReceiverUIPreferences` (see
    // `ReceiverUIPreferenceUpdate`), except `avSyncOffsetMs`, which only the
    // receiver ever sets.
    let functionTrayEnabled: Bool?
    let inputMode: String?
    let trackpadSensitivity: Double?
    let hapticsEnabled: Bool?
    let avoidNotch: Bool?
    let pinchTarget: String?
    let rotateTarget: String?
    let snapRotation: Bool?
    let avSyncOffsetMs: Int?
    // App-mode command chords (see `AppGestureCommands`) — reported/pushed
    // alongside pinch/rotateTarget, never a separate storage.
    let appGestureCommands: AppGestureCommands?

    var kind: String { device ?? "device" }
    var protocolVersion: Int { pv ?? WireProtocol.assumedWhenAbsent }
    /// True only when the receiver explicitly listed `"hevc"` in `codecs`.
    /// Deliberately NOT gated on `protocolVersion` — see `codecs`' and
    /// `WireProtocol.hevcCodecWireVersion`'s doc comments: a receiver can
    /// advertise a lower overall `pv` for reasons unrelated to codec
    /// support (MacReceiver does), so overall `pv` is never a valid proxy
    /// for "does this peer understand codec negotiation". A peer that omits
    /// `codecs` entirely, or sends it without `"hevc"`, is always H.264-only.
    /// Delegates to `CodecCapabilityProbe.receiverSupportsHEVC` (`Shared/`)
    /// so this exact decision is directly unit-testable without `PhoneInfo`.
    var receiverSupportsHEVC: Bool {
        CodecCapabilityProbe.receiverSupportsHEVC(codecs: codecs)
    }
}

// `TLSSessionConfig`/`SenderTransport` now live in SenderTransport.swift
// (Phase 1 of the MT-C1 transport-isolation design) so the transport
// controller and its unit tests can see them without depending on the rest
// of this file.

/// Lock-protected box holding a weak `MacSender` reference — the sender-side
/// analogue of `StreamReceiverSelfBox` (see Shared/StreamReceiver.swift). A
/// `queue.asyncAfter` telemetry-flush closure needs to reach back into a
/// queue-confined `MacSender` instance method at fire time without capturing
/// the non-Sendable `MacSender` itself. `install(_:)` runs once `self` is
/// fully initialized (see `init`).
///
/// The lock protects only the weak-reference slot itself — it does NOT make
/// `MacSender` thread-safe. `currentOnQueue()` must only be called from code
/// already executing on the sender's `queue` (`sender.video`); every call
/// site resolves it from inside a `queue`-confined closure before touching
/// any `queue`-confined state, exactly like the `weak self` capture it
/// replaces. Avoid this bridge in encode/capture per-frame hot paths where
/// avoidable — the encode completion path is an accepted exception: its
/// `@Sendable` VT callback cannot capture `self` at all, and `currentOnQueue()`
/// is only ever resolved after re-entering `queue` via the existing
/// `queue.async` hops, so the added cost is one `NSLock` lock/unlock per
/// frame alongside the locks `MacSenderPipelineState` already takes there.
final class MacSenderSelfBox: @unchecked Sendable {
    private let lock = NSLock()
    private weak var value: MacSender?

    func install(_ sender: MacSender) {
        lock.lock(); defer { lock.unlock() }
        value = sender
    }

    /// Must only be called from code already running on `sender.video` —
    /// see this type's doc comment.
    func currentOnQueue() -> MacSender? {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    /// Safe to call from any thread — resolves the weak reference under
    /// `lock`, same as `currentOnQueue()`. Kept as a separate name so call
    /// sites stay honest about whether they're already queue-confined;
    /// used by `MacSender.beginStart()`'s startup `Task`, which runs on
    /// the global executor rather than `sender.video`.
    func resolve() -> MacSender? {
        lock.lock(); defer { lock.unlock() }
        return value
    }
}


/// Sendable handle for the async remainder of startup, returned by
/// `MacSender.beginStart()`. Never holds a raw `MacSender` — the
/// underlying `Task` resolves `self` from a `MacSenderSelfBox` only
/// after it has already hopped onto the global executor, so no
/// non-Sendable value ever crosses a suspension point on its way here.
struct MacSenderStartupHandle: Sendable {
    fileprivate let task: Task<Void, Error>

    func wait() async throws {
        try await task.value
    }
}

/// Strong analog of `MacSenderSelfBox`, for the one place (currently only
/// `transitionToMirrorAndDisableVideo`) where dropping `self` mid-async-chain
/// would silently drop the caller's completion. `MacSenderSelfBox` resolves
/// weakly and is fine when the operation is best-effort; here the transition
/// must run to completion even if every other owner releases the sender
/// first, so this holds `self` strongly for exactly the lifetime of one
/// transition. Like `selfBox`, it's only ever read to produce a fresh local
/// `self` inside the domain that's about to use it — never sent across a
/// suspension point itself.
struct MacSenderTransitionOwner: @unchecked Sendable {
    let sender: MacSender
}

/// Runs `disconnect(completion:)`'s completion at most once, regardless of
/// which of its two possible triggers — the transport send acknowledgment,
/// or the 1s "the link may be dying" fallback — fires first, and always on
/// the main actor (callers, like `SenderController.end`, are themselves
/// `@MainActor` and call synchronously into `completion`). Both triggers now
/// hop through this gate's `fire()` instead of each separately capturing a
/// shared `var completed` (that shared mutable local, captured into two
/// independently-crossing closures, is exactly what Swift 6 region isolation
/// cannot prove race-free). `fire()` must be callable synchronously from any
/// queue — including `queue` itself — so the at-most-once check is a plain
/// `NSLock`, the same pattern `MacSenderSelfBox` already uses; only the
/// actual `completion()` call hops to the main actor, via `Task`.
private final class MacSenderDisconnectCompletionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false
    private let completion: @MainActor @Sendable () -> Void

    init(completion: @escaping @MainActor @Sendable () -> Void) {
        self.completion = completion
    }

    func fire() {
        lock.lock()
        let shouldRun = !completed
        completed = true
        lock.unlock()
        guard shouldRun else { return }
        let completion = completion
        Task { @MainActor in completion() }
    }
}

@available(macOS 14.0, *)
final class MacSender: NSObject, SCStreamOutput, SCStreamDelegate {

    // Status/lifecycle callbacks live on `statusSink` (see
    // MacSenderStatusSink.swift) — a small @MainActor Sendable type that
    // owns them so publishing a status hop doesn't need to capture
    // non-Sendable `MacSender` into a `@Sendable` closure. These computed
    // properties preserve the previous `sender.onStatus = { ... }`-shaped
    // API for callers.
    let statusSink = MacSenderStatusSink()

    @MainActor var onStatus: ((String) -> Void)? {
        get { statusSink.onStatus }
        set { statusSink.onStatus = newValue }
    }
    @MainActor var onStats: ((Int, Double) -> Void)? {   // framesSent, mbps
        get { statusSink.onStats }
        set { statusSink.onStats = newValue }
    }
    // Refreshed on the same ~1s cadence as onStats: this session's current
    // video/audio activity and capture geometry, for the canonical runtime
    // projection (Overview / Active Display / menu bar all read from the
    // one place this feeds — DeviceSession — rather than re-deriving it).
    @MainActor var onMediaState: ((_ videoActive: Bool, _ audioActive: Bool,
                                   _ width: Int, _ height: Int, _ fps: Int) -> Void)? {
        get { statusSink.onMediaState }
        set { statusSink.onMediaState = newValue }
    }
    @MainActor var onCaptureLifecycleChanged: ((CaptureLifecyclePhase) -> Void)? {
        get { statusSink.onCaptureLifecycleChanged }
        set { statusSink.onCaptureLifecycleChanged = newValue }
    }
    // Fired when a previously connected device stays gone past the grace
    // period — the controller ends the session (capture, virtual display,
    // recording indicator all torn down) instead of dialing forever or
    // silently coming back over a different transport.
    @MainActor var onDisconnected: (() -> Void)? {
        get { statusSink.onDisconnected }
        set { statusSink.onDisconnected = newValue }
    }
    // Fired when the receiver announces its device locked. The controller
    // ends this session — an invisible display strands the cursor — and
    // starts a fresh one that waits for the wake.
    @MainActor var onPeerSleeping: (() -> Void)? {
        get { statusSink.onPeerSleeping }
        set { statusSink.onPeerSleeping = newValue }
    }
    // Fired when the receiver announces the app is quitting: deliberate,
    // so the controller ends the session without arming a reconnect.
    @MainActor var onPeerClosed: (() -> Void)? {
        get { statusSink.onPeerClosed }
        set { statusSink.onPeerClosed = newValue }
    }
    // Fired when an established connection's actual Network.framework path
    // changes. Nil while disconnected; the UI never infers a route from the
    // requested target.
    @MainActor var onTransportPath: ((ConnectionRoute?) -> Void)? {
        get { statusSink.onTransportPath }
        set { statusSink.onTransportPath = newValue }
    }
    // Fired on every hello — carries the receiver's install id so the
    // controller can deduplicate USB/WiFi sessions to the same device.
    @MainActor var onHello: ((PhoneInfo) -> Void)?
    @MainActor var onStreamingProfileRequest: ((StreamingProfile, CustomFrameRateSelection) -> Void)?
    /// A receiver asked to change Streaming Priority. Handed to
    /// `SenderController`, which owns the canonical `streamingPriority`
    /// setting (same one its own Settings picker writes) and rebuilds the
    /// session the same way a Streaming Profile change does.
    @MainActor var onStreamingPriorityRequest: ((StreamingPriority) -> Void)?
    // Fired when the user stopped the capture from the system UI (menu-bar
    // recording indicator / "Stop Extending"). The controller disconnects
    // the session — teardown plus auto-connect opt-out — so the app honors
    // the stop instead of fighting it.
    @MainActor var onCaptureStoppedByUser: (() -> Void)? {
        get { statusSink.onCaptureStoppedByUser }
        set { statusSink.onCaptureStoppedByUser = newValue }
    }
    // Fired when the device's display identity had to be abandoned (macOS
    // saved hostile state for it — see setupExtend) and a bumped identity
    // came online instead: carries the validated TOTAL offset from the
    // device's base identity, for the controller to store as-is. Absolute,
    // not a delta — repeated bumps in one session must not accumulate into
    // an offset nothing ever validated.
    @MainActor var onDisplayIdentityBumped: ((UInt32) -> Void)? {
        get { statusSink.onDisplayIdentityBumped }
        set { statusSink.onDisplayIdentityBumped = newValue }
    }
    /// Receiver requests are handed to SenderController, which owns the
    /// existing authoritative session-rebuild mode-switch path.
    @MainActor var onDisplayModeRequest: ((ReceiverDisplayMode) -> Void)?
    /// A receiver requested (`true`) or released (`false`) control of THIS
    /// session. Handed to `SenderController.handleInputControlRequested`,
    /// which owns the per-peer policy lookup, the Mac owner prompt, and the
    /// session-grant decision — this instance never grants itself. `false`
    /// (release) is applied immediately, with no callback needed, by
    /// `denySessionInput` at the call site in `handleControl` — this
    /// closure only ever fires for `true` (a request that needs a policy
    /// decision).
    @MainActor var onAllowInputRequest: ((Bool) -> Void)?
    /// Fires whenever this session's own ephemeral input grant changes —
    /// purely so `DeviceSession` can mirror it for display
    /// (`ReceiverDeviceDetailView`'s "Current session" row). The
    /// authoritative bit lives in `sessionInputGrant`, not here.
    @MainActor var onSessionInputGrantChanged: ((Bool) -> Void)? {
        get { statusSink.onSessionInputGrantChanged }
        set { statusSink.onSessionInputGrantChanged = newValue }
    }
    /// Receiver video requests are handed to the controller, which persists
    /// the Mac-authoritative setting and broadcasts it to every session.
    @MainActor var onVideoEnabledRequest: ((Bool) -> Void)?
    /// A receiver asked to change the Mirror capture source. Handed to
    /// `SenderController`, which owns the canonical `mirrorDisplayUUID`
    /// setting (the same one its own Settings picker writes) and the
    /// existing session-rebuild path that applies it. `nil` requests Auto.
    @MainActor var onMirrorDisplayRequest: ((String?) -> Void)?
    /// Fires whenever this peer's Extend shape preference changes — from a
    /// receiver's `extendShapeRequest` or from `requestExtendShape` (the
    /// Mac's own per-device Settings control). Unlike Mirror/mode/streaming
    /// profile, Extend shape is genuinely per-peer, so this instance applies
    /// and persists it directly rather than bubbling up to
    /// `SenderController`; the callback only lets the UI mirror the current
    /// value onto `DeviceSession` for display.
    @MainActor var onExtendShapeChanged: ((ExtendDisplayShapePreference) -> Void)? {
        get { statusSink.onExtendShapeChanged }
        set { statusSink.onExtendShapeChanged = newValue }
    }
    @MainActor var onMaxFPSChanged: ((ReceiverMaxFPSPreference) -> Void)? {
        get { statusSink.onMaxFPSChanged }
        set { statusSink.onMaxFPSChanged = newValue }
    }
    /// Pinned TLS failures are terminal trust failures, never packet-loss retries.
    @MainActor var onTrustFailure: ((String) -> Void)?

    private var stream: SCStream?
    /// Sole owner of the `VTCompressionSession` — creation, configuration,
    /// submission, invalidation and session identity. See
    /// MacSenderVideoEncoder.swift for the confinement invariant that makes
    /// it safe to reach from `queue`, from this class's nonisolated `async`
    /// methods, from `stop()` on the main thread, and from VideoToolbox's own
    /// output thread. `needsKeyframe` deliberately stays here (streaming/
    /// recovery policy, not encoder mechanism) and is passed in per
    /// submission as an immutable force-keyframe decision.
    private let videoEncoder = MacSenderVideoEncoder()
    /// Gates actual encode admission to the authoritative effective FPS —
    /// `minimumFrameInterval`/`ExpectedFrameRate` alone are requests/hints,
    /// not proof VideoToolbox receives no more than that rate (see
    /// `FrameRateLimiter`). Reconfigured from `setupEncoder`, the one choke
    /// point every FPS change already goes through. Mutated only from
    /// `queue` (both `setupEncoder` and the capture callback run there), so
    /// this needs no lock of its own.
    private var frameRateLimiter = FrameRateLimiter(fps: StreamingFPSPolicy.defaultReceiverMaxFPS)
    private var virtualDisplay: VirtualDisplay?
    /// The MEOW virtual display's CoreGraphics ID, if Extend currently has
    /// one — exposed only so `SenderController` can exclude it when
    /// deciding whether a genuinely usable PHYSICAL display exists
    /// (Mirror's authoritative availability gate in `requestMode`).
    var virtualDisplayID: CGDirectDisplayID? { virtualDisplay?.displayID }
    private let queue = DispatchQueue(label: "sender.video")
    /// See `MacSenderSelfBox`'s doc comment. Installed once `self` is fully
    /// constructed (end of `init`).
    private let selfBox = MacSenderSelfBox()
    /// Owns the live `NWConnection` and its Network.framework callback
    /// plumbing on `queue` — see MacSenderTransportController.swift for the
    /// `@unchecked Sendable` invariant this relies on. Created before
    /// `super.init()` (it only needs `queue`/`endpointName`/`statusSink`,
    /// all of which have their own default initializers); `delegate` is
    /// wired to `self` right after `super.init()`.
    private let transportController: MacSenderTransportController
    private static let startCode: [UInt8] = [0, 0, 0, 1]

    // The dial target. Written on `queue` only (after init): the controller
    // can migrate a live session between transports via switchTransport.
    private var transport: SenderTransport
    private let endpointName: String
    private var mode: CaptureMode
    private let quality: StreamQuality
    // Streaming Profile (high-refresh milestone): Efficiency/Performance/
    // Custom, plus Custom's manual FPS pick (nil = Auto). Like `quality`,
    // these apply per-pipeline at construction — a change rebuilds the
    // session (see SenderController.restartAll).
    private let streamingProfile: StreamingProfile
    private let customFPS: Int?
    /// Streaming Priority (bounded encoder-pipelining depth, see
    /// `StreamingPriorityPolicy`): like `streamingProfile`, applies per-
    /// pipeline at construction — a change rebuilds the session (see
    /// SenderController.restartAll).
    private let streamingPriority: StreamingPriority
    /// HEVC milestone: user codec preference (Auto/H.264/HEVC), like
    /// `streamingProfile`/`streamingPriority` applies per-pipeline at
    /// construction — a change rebuilds the session (see
    /// `SenderController.restartAll`).
    private let codecPreference: CodecPreference
    /// The codec `setupEncoder` last actually configured the compression
    /// session for — `queue`-confined REPORTING state, read by
    /// `sendStreamCodecState` to report the confirmed codec and by the
    /// "encoder ready" log line.
    ///
    /// Parameter-set extraction deliberately does NOT read this: `annexB`
    /// runs on VideoToolbox's output thread and is handed the codec of the
    /// session that actually produced its sample (still never re-derived
    /// from NAL bytes, per the milestone's "no ambiguous heuristics" rule).
    /// Reading `activeCodec` there was both an unsynchronized cross-thread
    /// read and wrong for output from a session that has since been replaced.
    private var activeCodec: StreamCodec = .h264
    private var activeCodecReason: String = CodecSelectionPolicy.Reason.explicitPreference.rawValue
    /// Cached once per process: whether this Mac has a real, usable
    /// hardware HEVC encoder (VideoToolbox's actual encoder list, never an
    /// OS-version guess). `VTCopyVideoEncoderList` enumerates every
    /// encoder VideoToolbox can create right now, so this reflects actual
    /// hardware, not a static capability table.
    private static let senderSupportsHEVC: Bool = {
        var list: CFArray?
        guard VTCopyVideoEncoderList(nil, &list) == noErr,
              let encoders = list as? [[CFString: Any]] else { return false }
        return encoders.contains { entry in
            guard let codec = entry[kVTVideoEncoderList_CodecType] as? UInt32,
                  codec == kCMVideoCodecType_HEVC else { return false }
            // Not every entry carries the hardware-acceleration key on
            // every macOS version; a missing key on an entry that DID
            // enumerate as a real HEVC encoder is treated as capable
            // rather than excluded, since VideoToolbox only lists
            // encoders it can actually instantiate. When present, it must
            // not be explicitly `false`.
            let isHardware = entry[kVTVideoEncoderList_IsHardwareAccelerated] as? Bool
            return isHardware != false
        }
    }()
    /// Capability-aware effective encode/capture FPS for this session right
    /// now (`StreamingFPSPolicy`), at a given final encode size. Recomputed
    /// on demand from `lastHello?.maxFPS` and `receiverMaxFPSPreference` —
    /// the receiver capability is authoritative and can only ever be known
    /// once hello has arrived, which every capture-start call site already
    /// waits for (see `start()`'s `waitForHello()`). `width`/`height` MUST
    /// be the actual final encode pixel dimensions (post `DecodeCeiling`),
    /// never the desktop/virtual-display size — see `EncoderCapability`.
    ///
    /// HEVC milestone: this is now CODEC-AWARE, via `selectCodec` +
    /// `StreamingFPSPolicy.codecEffectiveFPS`, rather than unconditionally
    /// folding H.264's `encoderSafeFPS` into the result the way the old
    /// single-call `StreamingFPSPolicy.effectiveFPS` did. That old shape
    /// silently pre-clamped the FPS value every caller of THIS function
    /// (capture-frame-interval configuration, `setupEncoder`'s own internal
    /// `selectCodec` re-derivation) ever saw to H.264's throughput ceiling —
    /// so by the time Auto's `CodecSelectionPolicy` ran, its `requestedFPS`
    /// input was already H.264-safe by construction, and the entire
    /// "HEVC rescues a throughput-constrained request" path could never
    /// fire in the live pipeline, even though `CodecSelectionPolicyTests`
    /// verified the pure policy function correctly in isolation (fed raw,
    /// un-pre-clamped numbers directly). Computing the COMMON target first,
    /// deciding the codec against IT, then applying only the CHOSEN codec's
    /// own ceiling closes that gap.
    private func effectiveFPS(width: Int, height: Int) -> StreamingFPSPolicy.Result {
        let commonTarget = StreamingFPSPolicy.commonTargetFPS(
            profile: streamingProfile, requestedFPS: customFPS,
            receiverMaxFPS: lastHello?.maxFPS, userMaxFPS: receiverMaxFPSPreference.userCeilingFPS)
        let codec = selectCodec(width: width, height: height, fps: commonTarget.fps).codec
        let encoderSafeFPS = EncoderCapability.codecSafeFPS(width: width, height: height)
        return StreamingFPSPolicy.codecEffectiveFPS(commonTarget: commonTarget, codec: codec, encoderSafeFPS: encoderSafeFPS)
    }
    /// The FPS actually applied to the live capture/encoder pipeline, latched
    /// at the last `startCapture`/`setupEncoder` call — for status/telemetry
    /// (`onMediaState`) so the UI reports what's really running, not a
    /// recomputation that could have since drifted from a later hello.
    private var captureTargetFPS = StreamingFPSPolicy.defaultReceiverMaxFPS
    // The user's persisted Mirror-mode display choice (a stable UUID, never
    // a raw CGDirectDisplayID — see MirrorDisplaySelection.swift). Resolved
    // against the live display list at capture start; unresolvable or nil
    // falls back to Automatic (today: SCShareableContent's first display).
    private let mirrorDisplayUUID: String?
    // Stable per-device serial for the virtual display, so macOS can tell
    // multiple MeowDisplay monitors apart and persist their arrangement.
    private let displaySerial: UInt32
    // How far this device's identity has already moved off its base serial
    // and productID (identities macOS saved hostile state for are abandoned
    // permanently — see setupExtend). Advanced in-session when a fallback
    // identity is validated, so a rotation rebuild doesn't re-probe the
    // poisoned one.
    private var baseIdentityOffset: UInt32

    // ── Encoder parallelism limiter (maxPendingEncodes = 2) ─────────────────
    //
    // VTCompressionSessionEncodeFrame returns immediately; the hardware H.264
    // encoder runs asynchronously, and one encode round trip (submit →
    // callback) routinely takes longer than a single frame interval at
    // 60fps+. A cap of 1 turns that per-frame latency into a hard admission
    // ceiling — a *second* frame can never even be submitted until the first
    // one's callback fires, so real throughput is capped at 1/(encode
    // latency), not by the requested FPS or by hardware capacity. That
    // ceiling was the confirmed cause of VideoToolbox topping out at
    // ~25-45fps on BOTH USB and LAN regardless of target (LAN diagnostics
    // pass, dev/opendisplay-next): purely a same-machine, same-transport
    // pipelining limit, not a network problem.
    //
    // Raising the cap to 2 lets one frame encode while the previous one is
    // still finishing — real pipelining instead of the FrameRateLimiter's
    // cadence being gated by encode latency — while still bounding
    // in-flight work to a small, fixed number (never unbounded), and still
    // dropping (never queuing) once even that small pipeline is full. Two
    // was chosen over three-plus because `kVTCompressionPropertyKey_
    // MaxFrameDelayCount = 0` already asks the session to minimize its own
    // internal buffering/lookahead, and `AllowFrameReordering = false`
    // means VideoToolbox emits completions in submission order — so a
    // deeper app-level queue would only add latency the encoder itself
    // isn't using, not more real parallelism. Re-measure with the
    // senderPipeline DEBUG log (`vtSub`/`vtOK`/`peakPending`) before going
    // higher.
    //
    // "Latest frame wins" no longer applies at the encoder stage the way it
    // did at cap 1 (both in-flight frames now genuinely get encoded and
    // sent, not just the most recent); it still applies at the admission
    // gate one level up — `FrameRateLimiter` — which decides which SCK
    // samples are even eligible to reach here.
    //
    // ── Outstanding send backpressure (maxPendingSends = 3) ──────────────────
    //
    // pendingSends counts video frames whose NWConnection.send completion has
    // not fired yet — i.e. bytes still in flight / waiting on TCP ACKs. Allow a
    // small pipeline (3) so the link is not idle between ACKs; unlike the encoder,
    // a few outstanding sends helps throughput without piling up seconds of lag.
    //
    // When pendingSends hits the cap we skip the capture before encode (net
    // drops). Same drop point as enc drops, but means “TCP send queue full”, not
    // “encoder busy” — split counters (enc↓ vs net↓) so the HUD shows which
    // bottleneck fired. Never encode-then-discard: dropping here avoids wasting
    // VT work on frames that would only add latency.
    //
    // `pendingEncodes`/`maxPendingEncodes`, `pendingSends`/`maxPendingSends`,
    // the enc/net drop counters (this-window, total, and ping-window), and the
    // DEBUG VT submitted/completed counters below are all written from the
    // ScreenCaptureKit sample-buffer callback and/or the VideoToolbox encode
    // -completion callback — never `queue` — and read back on `queue`. That
    // shared cross-thread invariant is exactly `MacSenderPipelineState`'s
    // single responsibility; see its header comment.
    private let pipelineState: MacSenderPipelineState
    // HUD-only per-ping-interval drop counters (~2s, reset in `schedulePing`)
    // — separate from the this-window counters, which are reset on the
    // phone's own independent "stats" cadence for the PHONE-STATS debug log.
    // The `enc↓`/`net↓` HUD metric (`PerfOverlay`) previously showed the
    // lifetime totals, which only ever grow for the life of the session —
    // misleading on a long-running stream. This makes the HUD counter answer
    // "how many drops in roughly the last couple seconds", the same
    // per-window shape `capFps` already uses.
    private var needsKeyframe = true
    #if DEBUG
    // Rolling ~1s sender-pipeline instrumentation (LAN FPS-collapse
    // diagnosis). All `queue`-confined except the VT submitted/completed
    // counters, which live on `pipelineState` (see above).
    private var debugSCKWindow = 0
    private var debugAdmittedWindow = 0
    private var debugSendsStartedWindow = 0
    private var debugSendsCompletedWindow = 0
    private var debugPeakPendingSends = 0
    private var debugSendTimingsMs: [Double] = []
    #endif
    /// The persisted preference and the state actually applied to this peer
    /// differ until its hello proves support for protocol v9. Older peers are
    /// always kept video-on so they never get a frozen, unexplained surface.
    private var desiredVideoEnabled: Bool
    private var videoEnabled = true
    // Mac system audio (M-audio). Per-receiver, not Mac-wide like
    // `videoEnabled`: only this session's receiver can turn its own audio
    // on, via `audioRequest` (PROTOCOL.md `pv` 12). Default off — capturing
    // system audio is opt-in, never ambient. `audioEnabled` tracks what
    // ScreenCaptureKit is actually configured to capture right now;
    // `desiredAudioEnabled` is what the receiver last asked for, reapplied
    // whenever capture (re)starts.
    private var desiredAudioEnabled = false
    private var audioEnabled = false
    private let audioCaptureEncoder = AudioCaptureEncoder()
    private var audioPacketSeq: UInt32 = 0
    private var audioConfigSent = false
    // Bumped at every point that resets `audioConfigSent`/`audioPacketSeq`
    // (i.e. every fresh audio generation: capture start, Audio Off→On,
    // pause, reconnect). Lives on `pipelineState` like `captureGeneration`
    // because it's read from the SCStream audio callback (not `queue`) and
    // compared again once that callback's async encode work completes back
    // on `queue` — the same stale-completion guard `captureGenerationNow`
    // already provides for video, extended to cover an audio-only generation
    // change too (Audio Off→On doesn't necessarily bump `captureGeneration`).
    private var audioGenerationNow: UInt64 { pipelineState.audioGenerationNow }
    #if DEBUG
    // DEBUG-only telemetry, piggybacked on the existing throttled `ping`
    // (PROTOCOL.md 6.2 — free-form, no version bump). Never raw audio.
    private var audioPacketsThisWindow = 0
    private var audioBytesThisWindow = 0
    // Transport head-of-line-blocking audit (see `sendFramed`): the most
    // recent video frame's on-wire byte count, for correlating with a slow
    // audio write completing right after it.
    private var lastVideoFrameByteCount = 0
    // DEBUG-only PCM bypass A/B mode (GOAL: isolate remaining intermittent
    // audio garble to AAC vs. everything upstream of it). Switch with:
    //   defaults write <bundle id from the `audioTrace: generation=` self-report line> audioDebugMode -string pcm
    //   defaults write <bundle id> audioDebugMode -string aac   (or delete the key)
    // FORENSIC NOTE: an earlier version of this read `audioDebugMode` fresh
    // on every ScreenCaptureKit audio callback, so a live defaults change
    // mid-session could interleave an in-flight AAC encode Task with a
    // freshly-started PCM one on the SAME generation — the receiver then
    // saw AAC config, PCM config, and both codecs' packets arrive
    // out of their own sequence spaces, which is exactly what produced the
    // "expected=4856 got=1" discontinuity / -12735 renderer error / non-
    // monotonic-playout-target evidence from that test. `activeAudioIsPCM`
    // is now latched ONCE per audio generation, at every site that already
    // resets `audioConfigSent`/`audioPacketSeq` (`beginAudioGeneration`) —
    // a live defaults change only takes effect the next time one of those
    // sites runs (Audio Off→On rebuild, pause/resume, or reconnect), never
    // mid-generation. Diagnostic only — never affects a Release build, and
    // production AAC behavior is byte-for-byte unchanged when this is false.
    private var activeAudioIsPCM = false
    private var pcmConfigSent = false
    private var pcmPacketSeq: UInt32 = 0
    #endif

    /// Call at every point that starts a fresh audio generation (capture
    /// start, Audio Off→On, pause, stop, reconnect) — resets
    /// `audioConfigSent`/`audioPacketSeq` (and the PCM counterparts) as one
    /// atomic unit with bumping `audioGeneration`, and, in DEBUG, latches
    /// this generation's codec choice from `audioDebugMode` (see
    /// `activeAudioIsPCM`'s doc comment — never read live per-packet).
    /// Must run on `queue` (all its call sites already do).
    private func beginAudioGeneration() {
        audioConfigSent = false
        audioPacketSeq = 0
        let generation = pipelineState.beginAudioGeneration()
        #if DEBUG
        pcmConfigSent = false
        pcmPacketSeq = 0
        activeAudioIsPCM = UserDefaults.standard.string(forKey: "audioDebugMode") == "pcm"
        // FORENSIC NOTE: a previous pass's instructions told the user to
        // `defaults write com.peetzweg.opensidecar.mac.debug ...` — the
        // upstream/tracked bundle ID (`project.yml`). This checkout's local
        // signing override (`project.local.yml`, see repo CLAUDE.md) rebuilds
        // the Debug target as `com.raisecaterror.meowdisplay.mac.debug`, so
        // every one of those `defaults write` calls silently missed the
        // running process's actual domain — `UserDefaults.standard` itself
        // was never the bug, only the hardcoded domain in prior instructions
        // was. Self-report the REAL running identifier every generation so
        // this can never go stale again, independent of which project file
        // built the running binary.
        Log.info("audioTrace: generation=\(generation) codec=\(activeAudioIsPCM ? "PCM" : "AAC") starting bundleID=\(Bundle.main.bundleIdentifier ?? "?")")
        let encoder = audioCaptureEncoder
        Task {
            let status = await encoder.debugDiagnosticStatus()
            Log.info("audioTrace: diagnostics audioPCMCompareDump=\(status.pcmCompareDumpEnabled) audioLocalRoundTrip=\(status.localRoundTripEnabled) audioDebugDump=\(status.debugDumpEnabled) dumpDirectory=\(status.dumpDirectory)")
        }
        #endif
    }

    private var capturePixelsWide = 0
    private var capturePixelsHigh = 0
    private let authenticatedSession = AuthenticatedSessionState()
    private var activeConnectionGeneration: UInt64 = 0
    private var stopped = false
    // The liveness monitors are self-rescheduling chains guarded only by
    // `stopped`; arm them at most once per instance so a double start() can't
    // stack parallel loops (the failure mode behind #75). Mirrors the
    // `monitorsStarted` guard the iOS PhoneReceiver already uses.
    private var monitorsStarted = false

    // Disconnect detection: before the first connection we dial patiently
    // (the user may start the Mac side first); once connected, a device that
    // stays gone past the grace ends the session via onDisconnected.
    private var everConnected = false
    private var disconnectedSince: Date?
    private let disconnectGraceSeconds: TimeInterval = 10
    /// Auto-Reconnect preference (Mac Sender's own local Settings toggle).
    /// `queue`-confined like the rest of this class's connection state; set
    /// by `SenderController` at session creation and live-updated by
    /// `applyAutoReconnectPreferenceChange` when the user flips the toggle.
    /// Gates only `scheduleReconnect`'s automatic in-place retry — see
    /// `ReconnectPolicy`.
    var autoReconnectEnabled = true

    private var lastHello: PhoneInfo?
    private struct ApplicationReadySession {
        let info: PhoneInfo
        let generation: UInt64
    }
    private var helloContinuation: CheckedContinuation<ApplicationReadySession, Error>?
    private var inputInjector: InputInjector?
    // This logical session's ephemeral input grant (per-device/per-session
    // consent milestone). Lives here — not on `DeviceSession` — because
    // every input-gate choke point already runs on `queue`/under
    // `InputInjector`'s own lock, never on the main actor; `DeviceSession`
    // only ever mirrors this for display via `onSessionInputGrantChanged`.
    // Never persisted: this instance is recreated for every fresh logical
    // session (see `SenderController.startSession`), so a brand-new session
    // always starts at `false`, and transport migration (`switchTransport`)
    // never replaces this `MacSender` instance, so the grant survives it for
    // free.
    private let sessionInputGrant = SessionInputGrantBox()
    private var nativeAppGestureState = NativeAppGestureSessionState()
    private var loggedNativeGestureLimitation = false

    // Liveness: both sides ping every 2s; if nothing arrives for 5s the link
    // is half-open (e.g. usbmuxd accepted but the device is gone) — reconnect.
    private var lastReceived = Date()

    // Session created after the receiver went to sleep: it refuses
    // connections until its screen is back, so dial failures mean "asleep",
    // not "app closed" — surface that instead of the usual hints. Cleared by
    // the first successful connection.
    private var awaitingWake: Bool

    // A capture that keeps dying is not coming back on its own (capture
    // authorization revoked, or saved display state blocks the identity) —
    // retrying forever spams WindowServer with create/destroy cycles and,
    // after a user-initiated stop, amounts to defying the user. Counted per
    // failed recovery round, reset by a capture that comes back up. On
    // `queue`.
    private var captureRecoveryBudget = CaptureRecoveryBudget()
    private var captureRecoveryScheduled = false

    // Consecutive actively-refused dials on a previously connected session.
    // Refusal is unambiguous: the device is reachable but nothing listens,
    // so the app was quit (a suspended app's kernel still accepts, and a
    // network blip times out instead of refusing). Three in a row (~3s)
    // ends the session early; the full 10s grace stays reserved for the
    // ambiguous failure kinds.
    private var consecutiveRefusals = 0
    private let refusalsBeforeGivingUp = 3
    private var dropsTotal: Int { pipelineState.dropsEncTotal + pipelineState.dropsNetTotal }

    // Local cursor echo: a cursor baked into the video carries the full
    // capture→encode→stream→display latency (~30ms perceived). Instead we
    // hide it from capture and stream its position on the control channel —
    // the phone draws it locally on the ~2ms path the touches use.
    // Escape hatch: `defaults write com.peetzweg.opensidecar.mac localCursor -bool false`.
    private let localCursor = UserDefaults.standard.object(forKey: "localCursor") == nil
        || UserDefaults.standard.bool(forKey: "localCursor")
    private var cursorTimer: DispatchSourceTimer?
    private var cursorImageTimer: DispatchSourceTimer?
    // Cable upgrade (PROTOCOL.md 6.4): while a WiFi session runs, probe the
    // receiver's advertised addresses over non-WiFi paths and migrate the
    // session the moment one answers — the Mac-to-Mac analogue of the
    // iPhone's WiFi→USB transport switch. Mechanism (timer/monitor/probe
    // connections/generation) lives on `transportController`; only the
    // dialing INPUTS (peer addresses, current transport) stay here.
    private var peerAddrs: [String] = []
    // route/direct-link classification, upgrade-probe timer/monitor state,
    // and dial generation all live on `transportController` now — see
    // MacSenderTransportController.swift.
    private var lastCursorSent: (x: Double, y: Double, visible: Bool) = (-1, -1, false)
    private var lastCursorPNGHash = 0
    private var cursorSeq: UInt64 = 0
    private var captureDisplayID: CGDirectDisplayID = 0
    private let captureLifecycleLock = NSLock()
    private var captureLifecycle = CaptureLifecycleState()
    // ScreenCaptureKit and VideoToolbox finish work asynchronously. During a
    // rotation, an old capture callback or a late encoder completion must not
    // put a frame from the retired display onto this device's new socket.
    // Bumped on `queue` but read from the SCK sample queue and the VideoToolbox
    // callback queue, so it lives on `pipelineState` like the other counters
    // those callbacks touch — read it via `captureGenerationNow`.
    // Bounded encoder-failure safety net (PART 8): the theoretical
    // `EncoderCapability` ceiling should prevent a size x fps combination
    // the hardware can't sustain, but real hardware may still be stricter.
    // If a freshly (re)started encoder generation produces ZERO successful
    // frames within `encodeFailureStreakLimit` attempts, that is treated as
    // proof of the same class of failure, not a transient glitch — recover
    // once by dropping to the next lower supported FPS tier rather than
    // leaving the receiver black forever. Guarded on `pipelineState` like
    // the other per-generation counters the encode callback touches;
    // `encoderRecoveryDowngradedGeneration` ensures at most one downgrade
    // per generation, so a persistently broken encoder degrades once and
    // then surfaces as an ordinary capture-recovery/failed-session instead
    // of bouncing between FPS levels forever.
    private var encodeFailureStreakLimit: Int { pipelineState.encodeFailureStreakLimit }
    private var captureGenerationNow: UInt64 { pipelineState.captureGenerationNow }
    #if DEBUG
    // BLACK-VIDEO forensics (SCK stage) — `didOutputSampleBuffer`'s `queue`-
    // confined per-generation frame counter; see its call site.
    private var debugSCKFrameLogGeneration: UInt64?
    private var debugSCKFrameLogCount = 0
    #endif

    // Mirror display inventory (P1): a connected/external display appearing
    // or disappearing must refresh what a receiver's Manual picker can
    // choose from — main-thread only, `sendMirrorDisplayState` itself hops
    // onto `queue`.
    private var mirrorDisplayTopologyObserver: NSObjectProtocol?

    // Post-wake SCK reconstruction (Mirror mode only) — see
    // `runWakeCaptureRecovery`. `wakeCaptureObserver`/scheduling flags are
    // `queue`-confined like the rest of the capture-recovery state; the two
    // "awaiting" generations are read from the SCK sample-buffer callback
    // and the VideoToolbox encode-completion callback (different queues),
    // so — like `captureGeneration`/`audioGeneration` — they live on
    // `pipelineState`.
    private var wakeCaptureObserver: NSObjectProtocol?
    // Not itself part of the wake-capture-recovery machinery above — this is
    // the fixed 60s post-authentication display/system-sleep stabilization
    // hold (see WakeStabilizationAssertion), armed for every route.
    private var wakeStabilizationAssertion: WakeStabilizationAssertion?
    // The connection generation `wakeStabilizationAssertion` was last armed
    // for (see `SessionStabilizationPolicy`) — distinct from the explicit
    // `promoteInteractiveWake` wire handler, which still begins the same
    // assertion on its own. `queue`-confined, like `reportRoute`.
    private var sessionStabilizationArmedGeneration: UInt64?
    // Set only while `offerExtendOrFailMirror` is actively waiting on a
    // headless-Mirror "Use Extend?" offer, scoped to the connection
    // generation it was sent for — exactly one pending offer per
    // generation. Cleared on timeout, on `stop()`, or found stale (a
    // different generation) by the poll itself.
    private var mirrorUnavailableOfferGeneration: UInt64?
    private var wakeCaptureRecoveryScheduled = false
    private var wakeCaptureRecoveryRunning = false
    // Display-topology generation (distinct from `captureGeneration`/session
    // generation): bumped on every topology-changing notification so an
    // async post-event health re-check that finishes after a NEWER topology
    // event started can recognize itself as stale and no-op instead of
    // acting on outdated readings. `queue`-confined.
    private var topologyGenerationNow: UInt64 = 0
    private var wakeCaptureAwaitingFirstFrameGeneration: UInt64? {
        get { pipelineState.wakeCaptureAwaitingFirstFrameGeneration }
        set { pipelineState.wakeCaptureAwaitingFirstFrameGeneration = newValue }
    }
    private var wakeCaptureAwaitingEncodedFrameGeneration: UInt64? {
        get { pipelineState.wakeCaptureAwaitingEncodedFrameGeneration }
        set { pipelineState.wakeCaptureAwaitingEncodedFrameGeneration = newValue }
    }

    // Input latency: touches arrive stamped in our clock (the phone applies
    // its sync offset); delta to now = network + deframe + dispatch.
    private var inputLatencies: [Double] = []
    // These policies bound noisy paths while retaining an explicit record when
    // details were suppressed. Unknown types and unparseable messages live on
    // `queue` with the rest of the control-connection state; encoder failures
    // (submit and output-callback, kept as separate policies so "submit
    // failed" and "output rejected" stay distinguishable) live on
    // `pipelineState` with the other pipeline counters.
    private var unknownTypeLogPolicy = UnknownControlTypeLogPolicy()
    // A framing desync feeds this garbage at the peer's message rate until the
    // watchdog redials, so it needs the same treatment. Detail is the byte
    // count of the last message that would not parse.
    private var unparseableControlLogPolicy = ThrottledLogPolicy<Int>()
    // Capture cadence: SCK only emits on content change, so the phone can't
    // tell "Mac rendered 45fps" from "frames got lost" — count deliveries here.
    private var capFrames = 0
    private var capWindowStart = Date()

    private var framesSent = 0
    private var bytesSent = 0
    private var statsWindowStart = Date()

    // Outbound-writer liveness (MEDIA DEATH forensics — see `sendFramed`'s
    // completion handler and `scheduleWatchdog`). The connection's own
    // read-direction health says nothing about the write direction: a stuck
    // socket-send buffer (e.g. the peer's own read loop wedged) leaves
    // `connectionReady` true and inbound control traffic flowing fine —
    // exactly "connected, input works, but media silently stopped" — with
    // no NWConnection state transition to notice it by. This tracks the
    // last time ANY queued write actually completed so the watchdog can
    // tell "no video right now because the screen is static" apart from
    // "nothing is draining the socket at all".
    private var lastSendCompletionAt = Date()
    private var sendStallReported = false

    // ScreenCaptureKit emits frames only when content changes. After a
    // reconnect on a static screen there is nothing to hang the forced
    // keyframe on — so keep the last frame around and re-encode it.
    private var lastPixelBuffer: CVPixelBuffer?
    private var lastCaptureAt = Date.distantPast
    /// Debounced replay after encoder/send backpressure drops a frame.
    /// At most one timer is active; each new drop resets the 30ms deadline.
    private var dropReplayTimer: DispatchSourceTimer?

    /// Extend virtual-display shape (PROTOCOL.md 6.7). Seeded from the Mac's
    /// global default at construction; once a peer's own stored preference
    /// (or a live `extendShapeRequest`) is known, it takes over for this
    /// peer specifically — see `applyExtendShape`.
    private var extendShapePreference: ExtendDisplayShapePreference
    /// Receiver-enforced max-FPS preference (PART 2/3). Same seeding
    /// convention as `extendShapePreference`: the Mac-wide/constructor
    /// default until a peer's own stored preference (or a live
    /// `maxFPSRequest`) is known, at which point it takes over for this
    /// peer specifically — see `applyMaxFPS`.
    private var receiverMaxFPSPreference: ReceiverMaxFPSPreference

    init(transport: SenderTransport, name: String, mode: CaptureMode,
         quality: StreamQuality = .best, displaySerial: UInt32 = 0x0001,
         identityOffset: UInt32 = 0, awaitingWake: Bool = false,
         videoEnabled: Bool = true, mirrorDisplayUUID: String? = nil,
         streamingProfile: StreamingProfile = .performance, customFPS: Int? = nil,
         extendShapePreference: ExtendDisplayShapePreference = .standard,
         receiverMaxFPSPreference: ReceiverMaxFPSPreference = .standard,
         streamingPriority: StreamingPriority = .auto,
         codecPreference: CodecPreference = .auto) {
        self.transport = transport
        self.endpointName = name
        self.mode = mode
        self.quality = quality
        self.mirrorDisplayUUID = mirrorDisplayUUID
        self.displaySerial = displaySerial
        self.baseIdentityOffset = identityOffset
        self.awaitingWake = awaitingWake
        self.desiredVideoEnabled = videoEnabled
        self.streamingProfile = streamingProfile
        self.customFPS = customFPS
        self.extendShapePreference = extendShapePreference
        self.receiverMaxFPSPreference = receiverMaxFPSPreference
        self.streamingPriority = streamingPriority
        self.pipelineState = MacSenderPipelineState(
            maxPendingEncodes: StreamingPriorityPolicy.maxPendingEncodes(for: streamingPriority))
        self.codecPreference = codecPreference
        self.transportController = MacSenderTransportController(
            queue: queue, endpointName: name, statusSink: statusSink)
        super.init()
        transportController.delegate = self
        selfBox.install(self)
    }

    // MARK: - Lifecycle

    private func captureStateSnapshot() -> CaptureLifecycleState {
        captureLifecycleLock.lock()
        defer { captureLifecycleLock.unlock() }
        return captureLifecycle
    }

    @discardableResult
    private func updateCaptureState(
        _ update: (inout CaptureLifecycleState) -> Bool
    ) -> Bool {
        captureLifecycleLock.lock()
        let previous = captureLifecycle.phase
        let accepted = update(&captureLifecycle)
        let current = captureLifecycle.phase
        captureLifecycleLock.unlock()
        guard previous != current else { return accepted }
        let sink = statusSink
        Task { @MainActor in sink.publishCaptureLifecycleChanged(current) }
        return accepted
    }

    /// Called on the sender queue while framing control messages.
    private func sendDisplayState(_ state: DisplayState) {
        sendJSONFrame("{\"type\":\"displayState\",\"state\":\"\(state.rawValue)\"}")
    }

    private func sendDisplayModeState() {
        sendJSONObject(["type": WireMessage.displayModeState,
                        "mode": mode.receiverMode.rawValue])
    }

    func pushDisplayModeState() {
        let selfBox = self.selfBox
        queue.async { selfBox.currentOnQueue()?.sendDisplayModeState() }
    }

    /// Broadcasts `mirrorUnavailable` outside the headless-Mirror-STARTUP
    /// offer flow (`offerExtendOrFailMirror`) — used when an already-
    /// connected receiver requests Mirror via `displayModeRequest` while
    /// this Mac has no usable physical display (see
    /// `SenderController.requestMode`'s authoritative rejection). Reuses
    /// the exact same wire message; the receiver tells the two contexts
    /// apart by its own already-confirmed mode (see
    /// `StreamReceiver`'s handling) — no new field, no new message type.
    func pushMirrorUnavailable() {
        let selfBox = self.selfBox
        queue.async {
            selfBox.currentOnQueue()?.sendJSONObject(["type": WireMessage.mirrorUnavailable, "reason": "noUsablePhysicalDisplay"])
        }
    }

    /// PROTOCOL.md 6.7. Meaningful only in Extend, but harmless to send
    /// regardless of mode (same pattern as `sendVideoState`/`sendAudioState`
    /// — an old/mirror-mode receiver simply ignores it), so every
    /// capture-start call site can send it unconditionally.
    private func sendExtendShapeState() {
        guard let info = lastHello,
              info.protocolVersion >= WireProtocol.extendShapeWireVersion else { return }
        var dict = extendShapePreference.wireFields
        dict["type"] = WireMessage.extendShapeState
        sendJSONObject(dict)
    }

    /// The Mac's own per-device Extend Display control (`ReceiverDeviceDetailView`)
    /// drives this directly — the exact same authoritative path a receiver's
    /// own `extendShapeRequest` takes, so both directions of PROTOCOL.md 6.7
    /// stay one source of truth.
    func requestExtendShape(_ preference: ExtendDisplayShapePreference) {
        let selfBox = self.selfBox
        queue.async {
            guard let self = selfBox.currentOnQueue(), let info = self.lastHello else { return }
            self.applyExtendShape(preference, info: info)
        }
    }

    /// Applies an Extend shape change (from either direction), persists it
    /// per-peer, reports it back, and — while Extend is actually active —
    /// safely reconfigures the virtual display through the same
    /// generation-guarded `reconfigure` path a rotation already uses.
    /// Called on `queue`.
    private func applyExtendShape(_ preference: ExtendDisplayShapePreference, info: PhoneInfo) {
        guard preference != extendShapePreference else {
            sendExtendShapeState()
            return
        }
        extendShapePreference = preference
        if let peerID = info.id { ExtendDisplayShapeStore.save(preference, peerID: peerID) }
        let sink = self.statusSink
        Task { @MainActor in sink.publishExtendShapeChanged(preference) }
        guard mode == .extend, virtualDisplay != nil else {
            sendExtendShapeState()
            return
        }
        let selfBox = self.selfBox
        Task {
            guard let self = selfBox.resolve() else { return }
            await self.reconfigure(info)
            self.queue.async {
                guard let self = selfBox.currentOnQueue() else { return }
                self.sendExtendShapeState()
            }
        }
    }

    /// PART 4/9: unlike `sendExtendShapeState`, max-FPS state is meaningful
    /// in both Mirror and Extend, so every hello/capture-start call site can
    /// send it unconditionally — an old receiver simply ignores it.
    /// `capturePixelsWide/High` being 0 (no capture has started yet) still
    /// reports a real `encoderSafeFPS`/`effectiveFPS`/`availableTiers` off
    /// the receiver's advertised capability alone, so a receiver sees a
    /// sane picker before the first frame.
    private func sendMaxFPSState() {
        guard let info = lastHello,
              info.protocolVersion >= WireProtocol.maxFPSWireVersion else { return }
        let width = capturePixelsWide
        let height = capturePixelsHigh
        let encoderSafeFPS = (width > 0 && height > 0)
            ? EncoderCapability.codecSafeFPS(width: width, height: height)
            : (EncoderCapability.supportedFPSTiers.last ?? StreamingFPSPolicy.hardCapFPS)
        let result = StreamingFPSPolicy.effectiveFPS(
            profile: streamingProfile, requestedFPS: customFPS, receiverMaxFPS: info.maxFPS,
            userMaxFPS: receiverMaxFPSPreference.userCeilingFPS, encoderSafeFPS: encoderSafeFPS)
        let requestedFPS = StreamingFPSPolicy.profileRequestedFPS(profile: streamingProfile, requestedFPS: customFPS)
        let availableTiers = StreamingFPSPolicy.availableUserCeilingTiers(
            receiverMaxFPS: info.maxFPS, encoderSafeFPS: encoderSafeFPS)
        var dict = MaxFPSStateUpdate(preference: receiverMaxFPSPreference, availableTiers: availableTiers,
                                      encoderSafeFPS: encoderSafeFPS, requestedFPS: requestedFPS,
                                      effectiveFPS: result.fps, reason: result.reason.rawValue).wireFields
        dict["type"] = WireMessage.maxFPSState
        sendJSONObject(dict)
    }

    /// The Mac's own per-device max-FPS control (`ReceiverDeviceDetailView`)
    /// drives this directly — same authoritative path a receiver's own
    /// `maxFPSRequest` takes, so both directions stay one source of truth.
    func requestMaxFPS(_ preference: ReceiverMaxFPSPreference) {
        let selfBox = self.selfBox
        queue.async {
            guard let self = selfBox.currentOnQueue(), let info = self.lastHello else { return }
            self.applyMaxFPS(preference, info: info)
        }
    }

    /// Applies a max-FPS change (from either direction), persists it
    /// per-peer, reports it back, and — while capture is actually live —
    /// reconfigures the running pipeline in place rather than tearing
    /// anything down (same pattern as `applyAudioEnabled`'s live
    /// `stream.updateConfiguration`). Called on `queue`.
    private func applyMaxFPS(_ preference: ReceiverMaxFPSPreference, info: PhoneInfo) {
        guard preference != receiverMaxFPSPreference else {
            sendMaxFPSState()
            return
        }
        receiverMaxFPSPreference = preference
        if let peerID = info.id { ReceiverMaxFPSStore.save(preference, peerID: peerID) }
        let sink = self.statusSink
        Task { @MainActor in sink.publishMaxFPSChanged(preference) }
        applyEffectiveFPSChange()
        sendMaxFPSState()
    }

    /// Re-derives the effective FPS for the live pipeline's current encode
    /// size (a profile/user-ceiling/receiver-capability change, never a
    /// resolution change — resolution changes already go through
    /// `reconfigure`/`startCapture`) and applies it without a capture
    /// restart: `SCStreamConfiguration.minimumFrameInterval` via
    /// `updateConfiguration`, then a fresh `setupEncoder` at the new rate.
    /// No-op while there is no live stream — the next `startCapture` picks
    /// up the new preference on its own.
    private func applyEffectiveFPSChange() {
        guard let stream, capturePixelsWide > 0, capturePixelsHigh > 0 else { return }
        let fpsResult = effectiveFPS(width: capturePixelsWide, height: capturePixelsHigh)
        guard fpsResult.fps != captureTargetFPS else { return }
        logEncodeCapability(width: capturePixelsWide, height: capturePixelsHigh, result: fpsResult)
        needsKeyframe = true
        let config = SCStreamConfiguration()
        config.minimumFrameInterval = CMTime(value: 1, timescale: Int32(fpsResult.fps * 2))
        let selfBox = self.selfBox
        Task {
            do {
                try await stream.updateConfiguration(config)
            } catch {
                Log.info("FPS reconfigure failed: \(error)")
            }
            selfBox.resolve()?.queue.async {
                guard let self = selfBox.currentOnQueue(), self.stream === stream else { return }
                self.captureTargetFPS = fpsResult.fps
                if self.videoEnabled {
                    do {
                        try self.setupEncoder(width: self.capturePixelsWide, height: self.capturePixelsHigh,
                                              fps: fpsResult.fps)
                    } catch {
                        Log.info("FPS-change encoder setup failed: \(error) — entering capture recovery")
                        guard self.updateCaptureState({ $0.unexpectedStop() }) else { return }
                        self.scheduleCaptureRecovery()
                    }
                }
            }
        }
    }

    /// PART 9 diagnostic line. DEBUG-only: this fires on every capture
    /// (re)start, and the throttled encode-failure logs already cover the
    /// production-worthy signal.
    private func logEncodeCapability(width: Int, height: Int, result: StreamingFPSPolicy.Result) {
        #if DEBUG
        let requestedFPS = StreamingFPSPolicy.profileRequestedFPS(profile: streamingProfile, requestedFPS: customFPS)
        Log.info("encodeCapability: size=\(width)x\(height) requestedFPS=\(requestedFPS) "
            + "receiverMaxFPS=\(lastHello?.maxFPS.map(String.init) ?? "none") "
            + "userMaxFPS=\(receiverMaxFPSPreference.userCeilingFPS.map(String.init) ?? "none") "
            + "encoderSafeFPS=\(EncoderCapability.codecSafeFPS(width: width, height: height)) "
            + "effectiveFPS=\(result.fps) reason=\(result.reason.rawValue)")
        #endif
    }

    /// Called on the sender queue. `InputPolicy.allowsInput()` reads
    /// straight from UserDefaults (the same static check every input-
    /// injection call site already gates on) and `sessionInputGrant` is this
    /// session's own live grant, so this always reports the exact
    /// `receiverInputIsAllowed()` result — never a stale cached copy, and
    /// never another session's state. `state` is additive (pv 18+, see
    /// `WireProtocol.sessionScopedInputConsentWireVersion`); `allowed`
    /// alone remains a correct summary for every older peer.
    private func sendAllowInputState(state: SessionInputWireState? = nil) {
        let allowed = EffectiveInputAuthorization.allowed(masterEnabled: InputPolicy.allowsInput(),
                                                            sessionGranted: sessionInputGrant.get())
        let resolvedState = state ?? (allowed ? .allowed : .off)
        sendJSONObject(["type": WireMessage.allowInputState,
                        "allowed": allowed,
                        "state": resolvedState.rawValue])
    }

    /// A control-request prompt is now up on the Mac for this session — lets
    /// a pv 18+ receiver show "Requesting…" instead of a silent wait.
    func notifyInputRequestPending() {
        let selfBox = self.selfBox
        queue.async { selfBox.currentOnQueue()?.sendAllowInputState(state: .requesting) }
    }

    /// A Mac-owner (or auto-policy) decision granted this session control.
    /// Only ever called from the main-actor consent flow
    /// (`SenderController.handleInputControlRequested`/
    /// `resolveInputControlRequest`), never directly from a wire handler.
    func grantSessionInput() {
        let selfBox = self.selfBox
        queue.async {
            guard let self = selfBox.currentOnQueue() else { return }
            self.sessionInputGrant.set(true)
            self.sendAllowInputState(state: .allowed)
            let sink = self.statusSink
            Task { @MainActor in sink.publishSessionInputGrantChanged(true) }
        }
    }

    /// A request was denied (Not Now / timeout / Never-Allow policy / Mac
    /// master off) or this session's own grant was released/revoked. Always
    /// safe to call even if the grant was already off — narrowing input is
    /// never blocked, unlike granting it.
    func denySessionInput(state: SessionInputWireState) {
        let selfBox = self.selfBox
        queue.async {
            guard let self = selfBox.currentOnQueue() else { return }
            let wasGranted = self.sessionInputGrant.get()
            self.sessionInputGrant.set(false)
            if wasGranted {
                // Held-input cleanup: an ON -> OFF transition must never
                // leave a stuck key/button/touch behind.
                self.inputInjector?.cancelActiveInput()
                self.sendJSONObject(["type": WireMessage.inputReset])
            }
            self.sendAllowInputState(state: state)
            if wasGranted {
                let sink = self.statusSink
                Task { @MainActor in sink.publishSessionInputGrantChanged(false) }
            }
        }
    }

    private func sendVideoState() {
        guard let info = lastHello,
              info.protocolVersion >= WireProtocol.videoControlWireVersion else { return }
        sendJSONObject(["type": WireMessage.videoState,
                        "enabled": videoEnabled,
                        "width": capturePixelsWide,
                        "height": capturePixelsHigh])
    }

    private func sendAudioState() {
        guard let info = lastHello,
              info.protocolVersion >= WireProtocol.audioWireVersion else { return }
        sendJSONObject(["type": WireMessage.audioState, "enabled": audioEnabled])
    }

    /// Toggles Mac system-audio capture for this receiver. Per-receiver,
    /// unlike `applyVideoEnabled` (Mac-wide) — only ever driven by this
    /// session's own `audioRequest`. Prefers reconfiguring the live
    /// `SCStream` at runtime (PROTOCOL.md 5A / milestone note) over tearing
    /// down anything video-related.
    private func applyAudioEnabled(_ enabled: Bool) {
        desiredAudioEnabled = enabled
        guard enabled != audioEnabled else {
            sendAudioState()
            return
        }
        guard let stream else {
            // No live capture (e.g. video and audio both off, or between
            // sessions) — the next startCapture() picks up
            // `desiredAudioEnabled`. Nothing to reconfigure yet.
            audioEnabled = enabled
            sendAudioState()
            return
        }
        let config = SCStreamConfiguration()
        config.capturesAudio = enabled
        config.sampleRate = 48_000
        config.channelCount = 2
        config.excludesCurrentProcessAudio = true
        let selfBox = self.selfBox
        let queue = self.queue
        let audioCaptureEncoder = self.audioCaptureEncoder
        Task {
            do {
                try await stream.updateConfiguration(config)
            } catch {
                Log.info("audio reconfigure failed: \(error)")
            }
            queue.async {
                guard let sender = selfBox.currentOnQueue(), sender.stream === stream else { return }
                sender.audioEnabled = enabled
                if !enabled {
                    Task { await audioCaptureEncoder.reset() }
                }
                sender.beginAudioGeneration()
                sender.sendAudioState()
                if !enabled, sender.videoEnabled == false, sender.desiredAudioEnabled == false {
                    // Nothing wants this stream anymore — release it the
                    // same way Video Off does on its own.
                    sender.stream = nil
                    stream.stopCapture { _ in }
                    _ = sender.updateCaptureState { $0.stop(); return true }
                }
            }
        }
    }

    private func sendAudioConfigIfNeeded() {
        let selfBox = self.selfBox
        Task {
            guard let self = selfBox.resolve(),
                  let config = await self.audioCaptureEncoder.formatConfig else { return }
            self.queue.async {
                guard let self = selfBox.currentOnQueue(), !self.audioConfigSent else { return }
                self.audioConfigSent = true
                self.sendFramed(AudioMediaFrame.config(AudioConfigFrame(
                    sampleRate: config.sampleRate,
                    channelCount: config.channelCount,
                    cookie: config.cookie)).encode(), kind: "audio")
            }
        }
    }

    private func sendAudioPacket(_ packet: EncodedAudioPacket) {
        audioPacketSeq &+= 1
        #if DEBUG
        audioPacketsThisWindow += 1
        audioBytesThisWindow += packet.payload.count
        // GOAL (receiver-side AAC investigation): a periodic checksum over
        // the EXACT bytes handed to `sendFramed` — not a re-derivation —
        // tagged with generation/sequence, so it can be matched against
        // `StreamReceiver`'s identical periodic log for the same
        // generation/sequence. A mismatch means transport/framing
        // corrupted the bytes; a match rules that out entirely, narrowing
        // any remaining glitch to reconstruction/decode/render on-device.
        if audioPacketSeq % 100 == 1 {
            Log.info("audioTrace: AAC integrity side=sender generation=\(audioGenerationNow) seq=\(audioPacketSeq) capturedAtMs=\(packet.capturedAtMs) durationMs=\(packet.durationMs) payloadBytes=\(packet.payload.count) checksum=\(PCMChecksum.fnv1a(packet.payload))")
        }
        #endif
        sendFramed(AudioMediaFrame.packet(AudioPacketFrame(
            sequence: audioPacketSeq,
            capturedAtMs: packet.capturedAtMs,
            durationMs: packet.durationMs,
            payload: packet.payload)).encode(), kind: "audio")
    }

    #if DEBUG
    /// DEBUG-only PCM bypass A/B mode counterparts of
    /// `sendAudioConfigIfNeeded`/`sendAudioPacket` — see `audioDebugPCMMode`.
    private func sendPCMConfigIfNeeded() {
        let selfBox = self.selfBox
        Task {
            guard let self = selfBox.resolve(),
                  let config = await self.audioCaptureEncoder.pcmFormatConfig else { return }
            self.queue.async {
                guard let self = selfBox.currentOnQueue(), !self.pcmConfigSent else { return }
                self.pcmConfigSent = true
                self.sendFramed(AudioMediaFrame.pcmConfig(PCMConfigFrame(
                    sampleRate: config.sampleRate,
                    channelCount: config.channelCount)).encode(), kind: "audio")
            }
        }
    }

    private func sendPCMPacket(_ packet: EncodedPCMPacket) {
        pcmPacketSeq &+= 1
        sendFramed(AudioMediaFrame.pcmPacket(PCMPacketFrame(
            sequence: pcmPacketSeq,
            capturedAtMs: packet.capturedAtMs,
            frameCount: UInt32(packet.frameCount),
            payload: packet.payload)).encode(), kind: "audio")
    }
    #endif

    /// Public entry point for `AppController.allowInput`'s `didSet` to
    /// broadcast the Mac's new state to this receiver.
    func pushAllowInputState() {
        let selfBox = self.selfBox
        queue.async { selfBox.currentOnQueue()?.sendAllowInputState() }
    }

    /// Thread-safe read of this session's own live grant — used by
    /// `SenderController.anySessionHasEffectiveInput` and UI display. Safe
    /// to call from the main actor: `SessionInputGrantBox` is lock-guarded.
    var hasSessionInputGrant: Bool { sessionInputGrant.get() }

    /// Mac owner manually revoked this session's control from Settings/
    /// device detail. Same held-input cleanup and wire notification as any
    /// other ON -> OFF transition.
    func revokeSessionInput() {
        denySessionInput(state: .off)
    }

    func setVideoEnabled(_ enabled: Bool) {
        let selfBox = self.selfBox
        queue.async {
            guard let sender = selfBox.currentOnQueue() else { return }
            sender.desiredVideoEnabled = enabled
            guard let info = sender.lastHello,
                  info.protocolVersion >= WireProtocol.videoControlWireVersion else { return }
            sender.applyVideoEnabled(enabled)
        }
    }

    /// Performs the Extend -> Mirror -> Video Off sequence without replacing
    /// the transport/session. Input is retargeted to the physical display,
    /// the virtual display is released only after Extend capture has stopped,
    /// and video production is disabled only after Mirror setup completes.
    func transitionToMirrorAndDisableVideo(completion: @escaping @MainActor () -> Void) {
        let selfBox = self.selfBox
        queue.async {
            guard let self = selfBox.currentOnQueue() else { return }
            self.desiredVideoEnabled = false
            self.inputInjector?.cancelActiveInput()
            let oldStream = self.stream
            self.stream = nil
            self.invalidateCapturePipeline(discardingLastFrame: true)
            self.videoEncoder.invalidate()
            let owner = MacSenderTransitionOwner(sender: self)
            let continueTransition: @Sendable () -> Void = {
                let sender = owner.sender
                sender.queue.async {
                    let sender = owner.sender
                    sender.mode = .mirror
                    sender.virtualDisplay = nil
                    Task {
                        let sender = owner.sender
                        do {
                            try await sender.startMirrorCaptureUsingPreference()
                        } catch {
                            Log.info("Extend to Mirror transition failed before Video Off: \(error)")
                        }
                        sender.queue.async {
                            let sender = owner.sender
                            sender.applyVideoEnabled(false)
                            Task { @MainActor in completion() }
                        }
                    }
                }
            }
            if let oldStream {
                oldStream.stopCapture { _ in continueTransition() }
            } else {
                continueTransition()
            }
        }
    }

    /// Headless counterpart to `transitionToMirrorAndDisableVideo`: this Mac
    /// has no usable physical display, so becoming Mirror to reclaim the
    /// virtual display's resources is exactly as impossible as requesting
    /// Mirror directly (see `SenderController.requestMode`'s guard).
    /// Stays in Extend and stops capture the same way `applyVideoEnabled(false)`
    /// already does for the "stream survives for audio" case — the virtual
    /// display and its identity are left alone, so re-enabling video later
    /// (`restartVideoCapture`'s `.extend` branch) resumes Extend on the
    /// SAME display normally, headless or not.
    func disableVideoKeepingExtend(completion: @escaping @MainActor () -> Void) {
        let selfBox = self.selfBox
        queue.async {
            guard let self = selfBox.currentOnQueue() else { return }
            self.desiredVideoEnabled = false
            self.applyVideoEnabled(false)
            Task { @MainActor in completion() }
        }
    }

    /// Synchronous initiation half of startup. Safe to call directly from
    /// `@MainActor` (e.g. `SenderController`): `DeviceSession` already owns
    /// this `MacSender` before startup begins, and a plain synchronous call
    /// never suspends, so no isolation boundary is actually crossed here —
    /// nothing needs to be `Sendable` yet.
    ///
    /// Does only the queue-owned/fire-and-forget setup (dial kickoff,
    /// monitor startup) and returns a `Sendable` handle whose `wait()`
    /// performs the rest of startup (permission gates, hello wait, mirror/
    /// extend setup) off-actor. That Task captures only `selfBox`
    /// (`@unchecked Sendable`) and resolves `self` locally once it's
    /// already running there — `self` is never sent across the suspension,
    /// it's produced fresh inside the domain that uses it.
    nonisolated func beginStart() -> MacSenderStartupHandle {
        stopped = false
        queue.async { self.connect() }   // dial state lives on `queue`
        if !monitorsStarted {
            monitorsStarted = true
            schedulePing()
            scheduleWatchdog()
            startWakeCaptureObserver()
            startMirrorDisplayTopologyObserver()
        }

        let selfBox = self.selfBox
        let task = Task {
            guard let sender = selfBox.resolve() else { throw CancellationError() }
            try await sender.awaitStartup()
        }
        return MacSenderStartupHandle(task: task)
    }

    /// Async wait half of startup — see `beginStart()`. Only ever invoked
    /// from the Task `beginStart()` creates, on a `self` resolved fresh in
    /// that Task's own isolation domain.
    private func awaitStartup() async throws {
        // Screen Recording permission: poll until granted. No auto-prompt at
        // launch — the permission panel's Grant button triggers the system
        // dialog, so the request always has visible context.
        if !CGPreflightScreenCaptureAccess() {
            await status("Screen Recording permission needed — see Permissions below")
            Log.info("Screen Recording permission missing — waiting for grant via the permission panel")
            while !CGPreflightScreenCaptureAccess() {
                try await Task.sleep(for: .seconds(2))
                if stopped { return }
            }
            Log.info("Screen Recording permission granted")
        }

        let ready = try await waitForHello()
        guard authenticatedSession.isLive(generation: ready.generation) else {
            Log.info("sessionDebug: ignored stale capture start generation=\(ready.generation)")
            throw CancellationError()
        }

        switch mode {
        case .mirror:
            if DisplayHealth.hasUsablePhysicalDisplay(excluding: nil) {
                try await startMirrorCaptureUsingPreference(sessionGeneration: ready.generation)
            } else {
                try await offerExtendOrFailMirror(info: ready.info, sessionGeneration: ready.generation)
            }

        case .extend:
            // awaitingWake is queue-confined — read it there before surfacing.
            let selfBox = self.selfBox
            queue.async {
                guard let self = selfBox.currentOnQueue() else { return }
                let text = self.awaitingWake
                    ? "\(self.endpointName) is asleep — reconnects when it wakes…"
                    : "Waiting for the device to connect…"
                let sink = self.statusSink
                Task { @MainActor in sink.publishStatus(text) }
            }
            try await setupExtend(ready.info, sessionGeneration: ready.generation)

            // Touch back-channel (Milestone 3). Needs Accessibility trust;
            // streaming works without it, so don't interrupt with a prompt —
            // the permission panel's Grant button asks when the user is ready.
            if !AXIsProcessTrusted() {
                await status("Extending — grant Accessibility for touch input")
                // Event posting is trust-checked per-post, so it starts working
                // the moment the user grants — poll just to log/report it.
                while !AXIsProcessTrusted() {
                    try await Task.sleep(for: .seconds(2))
                    if stopped { return }
                }
                Log.info("Accessibility permission granted — touch input live")
            }
        }
    }

    private func startMirrorCapture(preferredDisplayID: CGDirectDisplayID?,
                                    sessionGeneration: UInt64? = nil) async throws {
        let content = try await SCShareableContent.current
        let display = preferredDisplayID.flatMap { id in
            content.displays.first(where: { $0.displayID == id })
        } ?? content.displays.first
        guard let display else {
            throw NSError(domain: "MacSender", code: 1,
                          userInfo: [NSLocalizedDescriptionKey:
                              "No display available to mirror — connect a display, or use Extend instead."])
        }
        try await startMirrorCapture(display: display, sessionGeneration: sessionGeneration)
    }

    /// Entry point for the user's persisted Mirror-display choice (as
    /// opposed to `preferredDisplayID`, used by the recovery path to
    /// reattach to whatever was already active). Resolves the stable UUID
    /// against the current display list — an unresolvable or absent
    /// preference logs the decision and falls back to Automatic.
    private func startMirrorCaptureUsingPreference(sessionGeneration: UInt64? = nil) async throws {
        let content = try await SCShareableContent.current
        var display = content.displays.first
        if let uuid = mirrorDisplayUUID {
            if let resolved = MirrorDisplayIdentity.resolve(persistentID: uuid, in: content.displays) {
                display = resolved
            } else {
                Log.info("displayDebug: mirrorSelection unavailable persistentID=\(uuid) — falling back to Automatic")
            }
        }
        guard let display else {
            throw NSError(domain: "MacSender", code: 1,
                          userInfo: [NSLocalizedDescriptionKey:
                              "No display available to mirror — connect a display, or use Extend instead."])
        }
        try await startMirrorCapture(display: display, sessionGeneration: sessionGeneration)
    }

    /// Mirror has no usable physical source (headless): instead of failing
    /// immediately, give the receiver a bounded chance to switch to Extend
    /// over the EXISTING `displayModeRequest` path — never a parallel
    /// mode-switch mechanism, and the Mac's `mode` remains the sole
    /// authoritative source of truth throughout (see
    /// `SenderController.requestMode`). Only offered when the receiver's
    /// protocol version advertises understanding it; an older receiver gets
    /// today's clean, immediate Mirror failure instead of sitting on a
    /// prompt it cannot show. `sessionGeneration` scopes the offer to
    /// exactly this authenticated connection — a route migration,
    /// Disconnect, Forget, or a newer session all invalidate
    /// `authenticatedSession`'s generation, which this function's own poll
    /// notices and aborts on, so a stale offer can never resurface or force
    /// anything. If a physical display returns while this is waiting, that
    /// alone changes nothing here — the receiver's own "Use Extend" tap (if
    /// it still arrives) remains a perfectly valid request regardless of
    /// what the physical topology looks like by then.
    private func offerExtendOrFailMirror(info: PhoneInfo, sessionGeneration: UInt64) async throws {
        guard MirrorUnavailableOfferPolicy.shouldOffer(
            hasUsablePhysicalDisplay: false, receiverProtocolVersion: info.protocolVersion
        ) else {
            throw NSError(domain: "MacSender", code: 1, userInfo: [
                NSLocalizedDescriptionKey:
                    "No display available to mirror — connect a display, or use Extend instead."])
        }
        guard authenticatedSession.isLive(generation: sessionGeneration) else { throw CancellationError() }
        mirrorUnavailableOfferGeneration = sessionGeneration
        Log.info("displayDebug: mirrorUnavailable offered generation=\(sessionGeneration)")
        sendJSONObject(["type": WireMessage.mirrorUnavailable, "reason": "noUsablePhysicalDisplay"])
        let deadline = Date().addingTimeInterval(Self.mirrorUnavailableOfferTimeout)
        // Wake/lid/topology churn can report a display usable for a single
        // transient sample before it actually settles — require it stably
        // usable (consecutive samples covering ~1s) before ever cancelling
        // the offer and resuming Mirror. This is scoped to exactly this
        // wait; ordinary Mirror startup with a display already present
        // never goes through this function at all, so no delay is added there.
        var stability = DisplayStabilityTracker()
        while Date() < deadline {
            try await Task.sleep(for: .milliseconds(500))
            guard MirrorUnavailableOfferPolicy.isOfferStillPending(
                offerGeneration: mirrorUnavailableOfferGeneration, sessionGeneration: sessionGeneration,
                sessionIsLive: authenticatedSession.isLive(generation: sessionGeneration)
            ) else {
                // Superseded already — an Extend request won (handled
                // entirely by the existing `onDisplayModeRequest` ->
                // `requestMode` -> mode-restart path), or the session ended/
                // migrated/was superseded. Nothing left for this attempt to do.
                throw CancellationError()
            }
            guard !stability.recordSample(usable: DisplayHealth.hasUsablePhysicalDisplay(excluding: nil)) else {
                // Mirror became STABLY viable again while the offer was
                // pending — the MAC decides this, never a stale "Use
                // Extend" tap that might still be in flight: dismiss the
                // offer and go straight back to Mirror. `startCapture`'s
                // existing unconditional post-success `sendDisplayModeState()`
                // is what tells the receiver to dismiss the now-moot alert
                // (see `applyConfirmedDisplayMode`) — no new wire message.
                mirrorUnavailableOfferGeneration = nil
                Log.info("displayDebug: mirrorUnavailable offer cleared generation=\(sessionGeneration) "
                    + "— a physical display returned and stayed stable, resuming Mirror")
                try await startMirrorCaptureUsingPreference(sessionGeneration: sessionGeneration)
                return
            }
        }
        mirrorUnavailableOfferGeneration = nil
        Log.info("displayDebug: mirrorUnavailable offer timed out generation=\(sessionGeneration)")
        // Distinct error code (vs. the plain "no display" throw above) so
        // `SenderController`'s start-failure handler can tell "the receiver
        // never answered" apart from "declined immediately" and suppress
        // auto-connect for this peer accordingly — see
        // `mirrorUnavailableTimeoutErrorCode`.
        throw NSError(domain: "MacSender", code: Self.mirrorUnavailableTimeoutErrorCode, userInfo: [
            NSLocalizedDescriptionKey:
                "No display available to mirror — connect a display, or use Extend instead."])
    }

    /// `NSError.code` used only for the `offerExtendOrFailMirror` timeout
    /// throw — lets `SenderController` distinguish "the receiver never
    /// responded to the headless-Mirror offer" from every other Mirror
    /// failure, so ONLY that specific case suppresses auto-connect for this
    /// peer (see `SenderController`'s `sender.start()` catch block). Not
    /// `private` because that controller check needs it.
    static let mirrorUnavailableTimeoutErrorCode = 13

    /// How long the Mac waits for the receiver to answer a headless-Mirror
    /// "Use Extend?" offer before failing Mirror cleanly — bounded so a
    /// silent/unresponsive receiver can never hold the Mac's stabilization
    /// assertions (or the session) open indefinitely.
    private static let mirrorUnavailableOfferTimeout: TimeInterval = 30

    /// Whether an in-flight `setupExtend` probe/attempt should abort rather
    /// than create, adopt, or keep waiting on a virtual display: `stopped`,
    /// or the authenticated session this setup belongs to is no longer the
    /// live one (disconnect, reconnect, or a newer session mid-setup).
    /// Reuses `AuthenticatedSessionState` — the existing session-generation
    /// gate every other stale-callback check in this file already relies on
    /// — rather than a new generation counter.
    private func isExtendSetupStale(ownerGeneration: UInt64?) -> Bool {
        guard !stopped, let ownerGeneration else { return true }
        return !authenticatedSession.isLive(generation: ownerGeneration)
    }

    /// Bounded topology diagnostics — called only at headless creation/
    /// recovery boundaries, never per-frame. Answers, from real hardware
    /// logs alone, which displays exist, which is CoreGraphics' main
    /// display, whether MEOW's own virtual display is main, and what a
    /// FRESH ScreenCaptureKit enumeration currently sees — so a "shows only
    /// wallpaper" hardware report can be diagnosed without attaching a
    /// debugger to the sender.
    private func logDisplayTopologyDiagnostics(reason: String, vdID: CGDirectDisplayID?) async {
        let mainID = CGMainDisplayID()
        Log.info("displayDebug: topologyDiag reason=\(reason) mainDisplayID=\(mainID) "
            + "vdID=\(vdID.map(String.init) ?? "none") vdIsMain=\(vdID == mainID)")
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        if count > 0 { CGGetActiveDisplayList(count, &ids, &count) }
        for id in ids {
            let reading = DisplayHealth.reading(for: id)
            let bounds = CGDisplayBounds(id)
            let builtin = CGDisplayIsBuiltin(id) != 0
            Log.info("displayDebug: topologyDiag display id=\(id) builtin=\(builtin) "
                + "online=\(reading.isOnline) active=\(reading.isActive) "
                + "bounds=(\(Int(bounds.origin.x)),\(Int(bounds.origin.y)),\(Int(bounds.width)),\(Int(bounds.height))) "
                + "mirror=\(reading.mirrorState) isMain=\(id == mainID)")
        }
        if let content = try? await SCShareableContent.current {
            Log.info("displayDebug: topologyDiag scShareableDisplayIDs=\(content.displays.map(\.displayID))")
        }
    }

    /// `VirtualDisplay.init` is `@MainActor`; this wraps it as a single
    /// cross-actor call rather than `setupExtend` capturing `self`/an outer
    /// result var into a `MainActor.run` closure — that closure form is what
    /// sends the non-Sendable `MacSender`/`VirtualDisplay` across the
    /// boundary. The freshly created `VirtualDisplay` itself never leaves
    /// the main actor: on success it's stored directly into
    /// `self.virtualDisplay` here, and only its Sendable `displayID` is
    /// returned to the nonisolated caller. Re-checks staleness once more
    /// right after creation, immediately before that assignment — the
    /// hop/construction can itself take a while, and a disconnect or a newer
    /// session racing it must not resurrect a display for a session that no
    /// longer exists.
    @MainActor
    private func makeVirtualDisplayIfNotStale(
        ownerGeneration: UInt64?, name: String, pointsWide: Int, pointsHigh: Int,
        sizeInMillimeters: CGSize, serialNum: UInt32, productID: UInt32, refreshRate: Int,
        arrangementKey: String, sizeInPoints: CGSize
    ) throws -> CGDirectDisplayID? {
        guard !isExtendSetupStale(ownerGeneration: ownerGeneration) else { throw CancellationError() }
        // Headless (no usable physical display exists): place the VD at
        // (0,0) — CoreGraphics defines "main display" as whichever display
        // sits at that origin — instead of the per-device saved arrangement,
        // so the login/lock UI has an actual main display to render onto.
        // This never touches the saved arrangement itself (no `save` call
        // fires unless something later actually moves it), so a physical
        // display returning still restores normally.
        let restoreOrigin: CGPoint? = DisplayHealth.hasUsablePhysicalDisplay(excluding: nil)
            ? DisplayArrangement.origin(for: sizeInPoints, device: arrangementKey)
            : CGPoint.zero
        guard let vd = VirtualDisplay(name: name,
                              pointsWide: pointsWide, pointsHigh: pointsHigh,
                              sizeInMillimeters: sizeInMillimeters,
                              serialNum: serialNum,
                              productID: productID,
                              refreshRate: refreshRate,
                              restoreOrigin: restoreOrigin,
                              onOriginChange: { origin, currentSize in
                                  DisplayArrangement.save(origin: origin, size: currentSize,
                                                           device: arrangementKey)
                              }) else { return nil }
        guard !isExtendSetupStale(ownerGeneration: ownerGeneration) else { throw CancellationError() }
        virtualDisplay = vd
        return vd.displayID
    }

    /// Build (or rebuild) the virtual display + capture for the announced
    /// phone dimensions. Called at startup and again whenever the phone
    /// rotates (it re-sends hello with swapped dimensions).
    private func setupExtend(_ info: PhoneInfo, sessionGeneration: UInt64? = nil) async throws {
        Log.info("phone hello: \(info.pixelsWide)x\(info.pixelsHigh) @\(info.scale)x")

        // Extend display shape (PROTOCOL.md 6.7): a peer's own remembered
        // choice — set by an earlier `extendShapeRequest`, or by the Mac's
        // own per-device Extend Display picker — wins over the Mac-wide
        // default this instance was constructed with, so each physical
        // device keeps its own shape.
        if let peerID = info.id, let stored = ExtendDisplayShapeStore.load(peerID: peerID) {
            extendShapePreference = stored
        }
        let sink = self.statusSink
        let extendShapePreference = self.extendShapePreference
        Task { @MainActor in sink.publishExtendShapeChanged(extendShapePreference) }
        let physicalAspect = Double(info.pixelsWide) / Double(info.pixelsHigh)
        let resolvedAspect = extendShapePreference.resolvedAspect(receiverPhysicalAspect: physicalAspect)
        // Phone panel is @3x; the virtual display runs @2x HiDPI, so points
        // = native pixels / 2 (rounded down to even for the encoder) when
        // the shape matches the phone's own aspect; otherwise the shape's
        // own ratio governs — see `ExtendDisplaySizing`.
        let (pointsWide, pointsHigh) = ExtendDisplaySizing.pointSize(
            receiverPixelsWide: info.pixelsWide, receiverPixelsHigh: info.pixelsHigh, aspect: resolvedAspect)
        #if DEBUG
        Log.info("extendDebug: setupExtend shape=\(extendShapePreference.shape.rawValue) "
            + "useFullDisplay=\(extendShapePreference.useFullDisplay) physicalAspect=\(physicalAspect) "
            + "resolvedAspect=\(resolvedAspect) virtualDisplayPoints=\(pointsWide)x\(pointsHigh)")
        #endif
        // Rough physical size so macOS picks a sane default UI scale.
        let mm = pointsWide >= pointsHigh
            ? CGSize(width: 147, height: 68)
            : CGSize(width: 68, height: 147)
        // Encoder-safe FPS (PART 1/7) depends on the actual encode pixel
        // size, not the shape/points alone — compute it from the same
        // `clampedCaptureSize` the capture start path below uses, so the
        // virtual display's own refresh rate never claims a rate the
        // encoder can't actually sustain at this size.
        let (virtualDisplayCaptureW, virtualDisplayCaptureH) = clampedCaptureSize(
            pointsWide: pointsWide, pointsHigh: pointsHigh, info: info)
        let virtualDisplayFPS = effectiveFPS(width: virtualDisplayCaptureW, height: virtualDisplayCaptureH).fps

        // USB sessions can start before lockdown resolves the device name —
        // fall back to the kind from the hello rather than the generic label.
        let displayName = endpointName.hasPrefix("iPhone / iPad")
            ? "MeowDisplay — \(info.kind)"
            : "MeowDisplay — \(endpointName)"
        // Keep one stable identity across rotations. Reconfiguration below
        // applies a new mode to the existing virtual monitor, so macOS keeps
        // its windows and arrangement attached to this physical device.
        let serial = displaySerial
        // Arrangement memory (#116): keyed on the device's install id so the
        // display returns to its spot across transports and orientations —
        // the serial-keyed memory macOS keeps starts from scratch whenever
        // the serial changes. Old receivers without an id fall back to the
        // session serial, which is at least orientation-stable.
        let arrangementKey = info.id ?? String(format: "serial-%08x", displaySerial)
        let sizeInPoints = CGSize(width: pointsWide, height: pointsHigh)
        // Creating a display whose serial is still registered fails — e.g. a
        // just-quit instance's display lingers in WindowServer for a moment
        // after the process dies. Retry through that window instead of
        // parking the session on "Failed" until a manual reconnect.
        //
        // macOS also keys SAVED display state on this identity, and that
        // state can be hostile: the system UI's "Stop Extending" records a
        // config under which the identity never comes online again —
        // creation "succeeds" but the display joins neither the active
        // display list nor shareable content (#206, #221). Unlike the saved
        // mirror-set (#100) and 1x-mode variants, no post-creation
        // enforcement can undo that, so an identity that never surfaces is
        // abandoned for a fresh serial. The controller persists the working
        // offset, so the device skips its poisoned identities from then on.
        // Only `displayID` (Sendable) is tracked here — the `VirtualDisplay`
        // itself is never held by this nonisolated function; it is created
        // and stored into `self.virtualDisplay` entirely on the main actor
        // by `makeVirtualDisplayIfNotStale`, so the non-Sendable object
        // never has to cross back out to this scope.
        var vdID: CGDirectDisplayID?
        var display: SCDisplay?
        var identityError = NSError(domain: "MacSender", code: 2,
                                    userInfo: [NSLocalizedDescriptionKey: "CGVirtualDisplay creation failed"])
        // Every checkpoint below re-validates against this SAME captured
        // generation (see `isExtendSetupStale`) — a disconnect or a newer
        // authenticated session mid-probe must abort the whole setup rather
        // than resurrect a display for a session that no longer exists.
        let ownerGeneration = sessionGeneration ?? authenticatedSession.liveGeneration
        // Only a created-but-never-surfaced display proves the identity is
        // poisoned. Creation refusing outright usually means a twin still
        // holds the serial (just-quit instance, parallel debug build) —
        // moving to a fallback identity is fine for THIS session, but the
        // move must not be persisted over a merely-transient condition.
        var sawPoisonedIdentity = false
        // Resolved fresh inside the `MainActor.run` hop below instead of
        // calling `self.makeVirtualDisplayIfNotStale` directly — a direct
        // cross-actor call sends `self` to the main actor, and `self` here
        // is not a disconnected region (this function keeps using it after
        // the call returns), so the compiler rejects the send outright.
        let selfBox = self.selfBox
        identities: for probe in 0..<UInt32(3) {
            let totalOffset = baseIdentityOffset &+ probe
            // A lingering serial belongs to a just-quit twin of the CURRENT
            // identity; fresh fallback identities get a shorter window.
            var createdID: CGDirectDisplayID?
            for attempt in 0..<(probe == 0 ? 8 : 3) {
                if attempt > 0 { try await Task.sleep(for: .seconds(2)) }
                // A Disconnect (or a newer session) during the retry window
                // tore this setup down. Bail before creating/assigning the
                // display: the serial the old display held is likely free
                // now, so a late attempt would *succeed* and resurrect the
                // very zombie this retry exists to avoid. Checked again
                // INSIDE the MainActor hop below — the race can land during
                // the hop itself, not just before it, and once more right
                // after creation succeeds, before it is ever adopted as the
                // live display.
                guard !isExtendSetupStale(ownerGeneration: ownerGeneration) else { throw CancellationError() }
                // A dedicated @MainActor method, not `MainActor.run` with a
                // closure mutating an outer `var`: that closure form
                // captures `self` (and the var) into a `@Sendable` closure,
                // which is what actually sends the non-Sendable
                // `MacSender`/`VirtualDisplay` across the boundary, and a
                // non-Sendable return value can't cross back either. Instead
                // the callee stores the freshly created `VirtualDisplay`
                // into `self.virtualDisplay` itself, entirely on the main
                // actor, and only a Sendable `displayID` comes back here.
                createdID = try await MainActor.run {
                    guard let live = selfBox.resolve() else { return nil }
                    return try live.makeVirtualDisplayIfNotStale(
                        ownerGeneration: ownerGeneration,
                        name: displayName,
                        pointsWide: pointsWide, pointsHigh: pointsHigh,
                        sizeInMillimeters: mm,
                        serialNum: serial &+ totalOffset,
                        productID: 0x4F53 &+ totalOffset,
                        refreshRate: virtualDisplayFPS,
                        arrangementKey: arrangementKey,
                        sizeInPoints: sizeInPoints)
                }
                if createdID != nil { break }
                Log.info("virtual display creation failed (identity +\(totalOffset), attempt \(attempt + 1)) — retrying")
                await status("Preparing virtual display…")
            }
            guard let candidateID = createdID else { continue }
            do {
                display = try await findSCDisplay(id: candidateID, isCancelled: { [weak self] in
                    self?.isExtendSetupStale(ownerGeneration: ownerGeneration) ?? true
                })
                // Transactional creation (#288's lesson: a successful
                // CGVirtualDisplay apply does not mean WindowServer/SCK
                // actually expose it) — `findSCDisplay` proves SCK sees it;
                // this also proves CoreGraphics agrees it's actually usable.
                guard DisplayUsability.evaluate(DisplayHealth.reading(for: candidateID)) == .usable else {
                    throw NSError(domain: "MacSender", code: 12, userInfo: [
                        NSLocalizedDescriptionKey: "virtual display appeared but is not usable"])
                }
                guard !isExtendSetupStale(ownerGeneration: ownerGeneration) else { throw CancellationError() }
                vdID = candidateID
                if probe > 0, sawPoisonedIdentity {
                    Log.info("display identity +\(totalOffset) came online — the previous one is "
                        + "poisoned by saved system state; persisting the offset")
                    baseIdentityOffset = totalOffset   // rebuilds skip the dead probe
                    let sink = self.statusSink
                    Task { @MainActor in sink.publishDisplayIdentityBumped(totalOffset) }
                }
                break identities
            } catch is CancellationError {
                // Stale, not a display failure — no fallback identity was
                // burned proving anything, so this must surface as
                // cancellation, not a misleading "display failed".
                virtualDisplay = nil
                throw CancellationError()
            } catch {
                virtualDisplay = nil   // release the dead display and its serial
                // No shareable displays at all is a permission-side failure —
                // a different identity cannot help there.
                if (error as NSError).domain == "MacSender", (error as NSError).code == 4 { throw error }
                identityError = error as NSError
                sawPoisonedIdentity = true
                guard !isExtendSetupStale(ownerGeneration: ownerGeneration) else { throw CancellationError() }
                Log.info("virtual display (identity +\(totalOffset)) never came online — trying a fresh identity")
                await status("Display blocked by saved macOS state — trying a fresh identity…")
            }
        }
        guard let vdID, let display else {
            if sawPoisonedIdentity {
                throw NSError(domain: "MacSender", code: 5, userInfo: [
                    NSLocalizedDescriptionKey: "saved display state in macOS is blocking "
                        + "MeowDisplay's displays — log out and back in (or restart the Mac), then reconnect"])
            }
            throw identityError
        }
        if let targetID = InputTargetResolver.displayID(
            mode: .extend, mirrorDisplayID: 0, virtualDisplayID: vdID) {
            inputInjector = InputInjector(displayID: targetID, sessionInputGrant: sessionInputGrant)
        }
        // Quality scaling: capture/encode below native when requested — the
        // display itself stays native so window layout is unaffected.
        let (captureW, captureH) = clampedCaptureSize(
            pointsWide: pointsWide, pointsHigh: pointsHigh, info: info)
        #if DEBUG
        Log.info("extendDebug: selectedSCDisplay id=\(display.displayID) "
            + "reportedSize=\(display.width)x\(display.height) "
            + "encodeOutput=\(captureW)x\(captureH) captureGeneration=\(captureGenerationNow)")
        #endif
        try await startCapture(display: display, pixelsWide: captureW, pixelsHigh: captureH,
                               sessionGeneration: sessionGeneration)
        await logDisplayTopologyDiagnostics(reason: "setupExtend", vdID: vdID)

        // Debug aid (`defaults write com.peetzweg.opensidecar.mac testPattern -bool true`):
        // an animated window on the virtual display generates a constant frame
        // stream so steady-state latency can be measured without user activity.
        if UserDefaults.standard.bool(forKey: "testPattern") {
            let id = vdID
            Task { @MainActor in TestPattern.show(on: id) }
        }
    }

    /// Tear down and rebuild when the phone announces new dimensions. Loops
    /// until the built display matches the latest hello, so rotations that
    /// arrive mid-rebuild aren't lost (and rapid flip-flops settle once).
    private var reconfiguring = false
    private func reconfigure(_ info: PhoneInfo) async {
        guard !reconfiguring, !stopped else { return }
        reconfiguring = true
        defer { reconfiguring = false }
        var target = info
        while !stopped {
            Log.info("reconfiguring for \(target.pixelsWide)x\(target.pixelsHigh)")
            // A cached frame is valid for a network reconnect to the same
            // display, but never for a rotation: it belongs to the retired
            // desktop and can otherwise be replayed onto the new one.
            invalidateCapturePipeline(discardingLastFrame: true)
            if let stream { try? await stream.stopCapture() }
            stream = nil
            videoEncoder.invalidate()
            needsKeyframe = true
            do {
                var resized = false
                do {
                    resized = try await resizeExistingDisplay(for: target)
                } catch is CancellationError {
                    // Stale (stop()/new session/a newer VD replaced this one
                    // mid-resize) — propagate as cancellation, never as
                    // "resize failed, fall back to a full rebuild": building
                    // a fresh VD for a session/identity that no longer owns
                    // this reconfigure would resurrect exactly the kind of
                    // stale-async work #288 flagged.
                    throw CancellationError()
                } catch {
                    // The in-place resize path (mode-switch, or the SCK
                    // re-enumeration that follows it) failed partway
                    // through — e.g. the resized display never reappeared
                    // in SCShareableContent in time. Letting this propagate
                    // as a terminal failure left the session with `stream`
                    // and `encoder` already torn down (see above) and
                    // nothing to rebuild them: capture never restarts, so
                    // the receiver goes black/frozen while the cursor (a
                    // separate channel, unaffected) keeps moving. Treat it
                    // exactly like "no reusable display" below and fall
                    // back to a full rebuild instead.
                    Log.info("resize path failed (\(error)) — falling back to a full rebuild")
                }
                if resized {
                    // The display identity survived, so WindowServer has no
                    // reason to migrate this device's windows to a sibling.
                } else {
                    // Safety fallback for a system that refuses an in-place
                    // mode switch. This keeps the old recovery behaviour.
                    virtualDisplay = nil
                    try await setupExtend(target)
                }
            } catch is CancellationError {
                return
            } catch {
                Log.info("reconfigure failed: \(error)")
                await status("Rotation failed: \(error.localizedDescription)")
                return
            }
            if let latest = lastHello,
               latest.pixelsWide != target.pixelsWide || latest.pixelsHigh != target.pixelsHigh {
                target = latest   // rotated again while we were rebuilding
                continue
            }
            return
        }
    }

    /// Apply the rotated mode to the existing virtual monitor and restart
    /// only the capture/encoder pieces that depend on pixel dimensions.
    /// Returns false when there is no reusable display or macOS rejected the
    /// mode switch, letting the caller use the legacy rebuild fallback.
    ///
    /// Transactional (#288's lesson: `vd.resize` returning true never
    /// guarantees WindowServer/SCK actually expose the new mode): if the new
    /// mode never becomes shareable/healthy, this rolls the SAME identity
    /// back to the last known-good mode rather than letting the caller fall
    /// straight to a full rebuild that would destroy an otherwise-working
    /// display. A successful rollback still returns `true` — the receiver
    /// keeps streaming at the old size rather than going black, and the next
    /// genuine topology/rotation event gets a fresh attempt at the new one.
    private func resizeExistingDisplay(for info: PhoneInfo) async throws -> Bool {
        guard let vd = virtualDisplay else { return false }
        // Scoped to THIS VirtualDisplay instance — if stop() or a fresh
        // setupExtend() replaces `virtualDisplay` while this function is
        // suspended, nothing below may resize/reattach/start capture again
        // on the old identity. Compares by `displayID` (a Sendable value)
        // via `selfBox` (safe to resolve from any thread) rather than
        // capturing `self`/`vd` directly, so this closure never sends the
        // non-Sendable `MacSender`/`VirtualDisplay` across the isolation
        // boundaries it gets passed through below (e.g. into
        // `findSCDisplay`, or the main-actor resize hops further down).
        let vdID = vd.displayID
        let selfBox = self.selfBox
        func isStale() -> Bool {
            guard let live = selfBox.resolve() else { return true }
            return live.stopped || live.virtualDisplay?.displayID != vdID
        }
        guard !isStale() else { throw CancellationError() }

        if let peerID = info.id, let stored = ExtendDisplayShapeStore.load(peerID: peerID) {
            extendShapePreference = stored
        }
        let physicalAspect = Double(info.pixelsWide) / Double(info.pixelsHigh)
        let resolvedAspect = extendShapePreference.resolvedAspect(receiverPhysicalAspect: physicalAspect)
        let (pointsWide, pointsHigh) = ExtendDisplaySizing.pointSize(
            receiverPixelsWide: info.pixelsWide, receiverPixelsHigh: info.pixelsHigh, aspect: resolvedAspect)
        let arrangementKey = info.id ?? String(format: "serial-%08x", displaySerial)
        let size = CGSize(width: pointsWide, height: pointsHigh)
        let (resizeCaptureW, resizeCaptureH) = clampedCaptureSize(
            pointsWide: pointsWide, pointsHigh: pointsHigh, info: info)
        let targetFPS = effectiveFPS(width: resizeCaptureW, height: resizeCaptureH).fps
        #if DEBUG
        Log.info("extendDebug: resizeExistingDisplay id=\(vd.displayID) "
            + "shape=\(extendShapePreference.shape.rawValue) resolvedAspect=\(resolvedAspect) "
            + "targetPoints=\(pointsWide)x\(pointsHigh)")
        #endif

        // Brings the CURRENT vd mode online end-to-end: fresh SCK match +
        // DisplayHealth (does WindowServer/SCK actually agree it's usable,
        // not just "the apply call returned true") + capture start. Shared
        // by the initial resize attempt and the same-identity rollback below.
        func attachCurrentMode(pointsWide: Int, pointsHigh: Int, size: CGSize) async throws {
            let display = try await findSCDisplay(id: vd.displayID, expectedSize: size, isCancelled: isStale)
            guard !isStale() else { throw CancellationError() }
            guard DisplayUsability.evaluate(DisplayHealth.reading(for: vd.displayID)) == .usable else {
                throw NSError(domain: "MacSender", code: 11, userInfo: [
                    NSLocalizedDescriptionKey: "resized virtual display did not become usable"])
            }
            let (captureW, captureH) = clampedCaptureSize(pointsWide: pointsWide, pointsHigh: pointsHigh, info: info)
            #if DEBUG
            Log.info("extendDebug: resizeExistingDisplay selectedSCDisplay id=\(display.displayID) "
                + "reportedSize=\(display.width)x\(display.height) encodeOutput=\(captureW)x\(captureH)")
            #endif
            try await startCapture(display: display, pixelsWide: captureW, pixelsHigh: captureH)
            if let targetID = InputTargetResolver.displayID(
                mode: .extend, mirrorDisplayID: 0, virtualDisplayID: vd.displayID) {
                inputInjector = InputInjector(displayID: targetID, sessionInputGrant: sessionInputGrant)
            }
            if UserDefaults.standard.bool(forKey: "testPattern") {
                let id = vd.displayID
                Task { @MainActor in TestPattern.show(on: id) }
            }
        }

        // Remember mode A before attempting B, so a B that never becomes
        // shareable can be reverted on the same identity.
        let previousPointsWide = vd.pointsWide
        let previousPointsHigh = vd.pointsHigh
        let previousRefreshRate = vd.currentRefreshRate
        let previousSize = CGSize(width: previousPointsWide, height: previousPointsHigh)

        // Re-resolves the live `VirtualDisplay` from `selfBox` on the main
        // actor rather than capturing `vd` into this `@Sendable` closure —
        // `vd` is not Sendable, and re-checking identity here (instead of
        // trusting the pre-hop `vd`) also means a replacement racing this
        // exact hop is caught before mutating the wrong display.
        let didResize = try await MainActor.run { () -> Bool in
            guard !isStale(), let live = selfBox.resolve(), live.virtualDisplay?.displayID == vdID else {
                throw CancellationError()
            }
            return live.virtualDisplay!.resize(pointsWide: pointsWide, pointsHigh: pointsHigh, refreshRate: targetFPS,
                              movingTo: DisplayArrangement.origin(for: size, device: arrangementKey))
        }
        guard didResize else { return false }
        guard !isStale() else { throw CancellationError() }

        do {
            try await attachCurrentMode(pointsWide: pointsWide, pointsHigh: pointsHigh, size: size)
            return true
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            Log.info("resize to \(pointsWide)x\(pointsHigh) did not become shareable (\(error)) — "
                + "rolling back \(vd.displayID) to \(previousPointsWide)x\(previousPointsHigh)")
            guard !isStale() else { throw CancellationError() }
            let rolledBack = try await MainActor.run { () -> Bool in
                guard !isStale(), let live = selfBox.resolve(), live.virtualDisplay?.displayID == vdID else {
                    throw CancellationError()
                }
                return live.virtualDisplay!.resize(pointsWide: previousPointsWide, pointsHigh: previousPointsHigh,
                                  refreshRate: previousRefreshRate,
                                  movingTo: DisplayArrangement.origin(for: previousSize, device: arrangementKey))
            }
            guard rolledBack else {
                Log.info("rollback mode-apply on \(vd.displayID) itself failed — falling back to a full rebuild")
                return false
            }
            guard !isStale() else { throw CancellationError() }
            do {
                try await attachCurrentMode(pointsWide: previousPointsWide, pointsHigh: previousPointsHigh,
                                            size: previousSize)
                Log.info("rollback to \(previousPointsWide)x\(previousPointsHigh) succeeded — "
                    + "identity \(vd.displayID) preserved")
                return true
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                Log.info("rollback to \(previousPointsWide)x\(previousPointsHigh) also failed (\(error)) — "
                    + "falling back to a full rebuild")
                return false
            }
        }
    }

    /// hello.maxEncodeWide/High (PROTOCOL.md 6.5): a big panel does not imply
    /// a big decoder. Caps the stream at the receiver's advertised decode
    /// ceiling — SCK scales the capture — while the desktop keeps its full
    /// resolved size. Aspect-preserving, never upscales (a stream already
    /// inside the ceiling passes through unchanged). Shared by every capture
    /// (re)start path so the ceiling is never bypassed by taking the resize
    /// fast-path instead of a full rebuild.
    ///
    /// Capture is provisioned once, before a codec is chosen (`setupEncoder`
    /// — and the codec decision inside it — runs strictly AFTER this), so
    /// there is no live codec to consult yet. `.h264` is passed to
    /// `CodecDecodeCeiling.applicable` explicitly rather than the clamp
    /// silently reusing the legacy fields on its own: it documents that this
    /// capture-time bound is (and, per that function's doc comment, for now
    /// always resolves to) H.264's historically-measured ceiling, applied as
    /// today's deliberate conservative choice for whichever codec
    /// `setupEncoder` goes on to pick — never a larger, unverified HEVC
    /// number invented ahead of hardware testing.
    private func clampedCaptureSize(pointsWide: Int, pointsHigh: Int, info: PhoneInfo) -> (Int, Int) {
        let nativeW = (Int(Double(pointsWide * 2) * quality.scale)) & ~1
        let nativeH = (Int(Double(pointsHigh * 2) * quality.scale)) & ~1
        let (maxWide, maxHigh) = CodecDecodeCeiling.applicable(
            codec: .h264, legacyMaxEncodeWide: info.maxEncodeWide, legacyMaxEncodeHigh: info.maxEncodeHigh)
        let (captureW, captureH) = DecodeCeiling.clamp(
            width: nativeW, height: nativeH, maxWide: maxWide, maxHigh: maxHigh)
        if captureW != nativeW || captureH != nativeH {
            Log.info("stream capped at \(captureW)x\(captureH) by the receiver's decode ceiling "
                + "\(maxWide ?? 0)x\(maxHigh ?? 0)")
        }
        return (captureW, captureH)
    }

    /// The virtual display takes a moment to show up in shareable content.
    /// `isCancelled` lets a caller supersede this poll with its own
    /// ownership/generation check (a specific VD identity, an authenticated
    /// session generation, …) — without one, only `stopped` bounds it, which
    /// on its own already stops the ~5s poll from outliving a plain
    /// disconnect (#288: a stale operation should not keep polling for dead
    /// work).
    private func findSCDisplay(id: CGDirectDisplayID, expectedSize: CGSize? = nil,
                               isCancelled: () -> Bool = { false }) async throws -> SCDisplay {
        var lastDisplayCount = 0
        for _ in 0..<20 {
            guard !stopped, !isCancelled() else { throw CancellationError() }
            let content = try await SCShareableContent.current
            lastDisplayCount = content.displays.count
            if let display = content.displays.first(where: {
                $0.displayID == id
                    && (expectedSize == nil
                        || ($0.width == Int(expectedSize!.width)
                            && $0.height == Int(expectedSize!.height)))
            }) {
                return display
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        // An empty display list is a different disease from "ours is
        // missing": capture authorization is broken app-wide, and callers
        // must not burn fallback identities on it.
        if lastDisplayCount == 0 {
            throw NSError(domain: "MacSender", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "macOS returned no capturable displays — "
                              + "the screen may be locked; if this persists unlocked, re-grant "
                              + "Screen Recording in System Settings and relaunch"])
        }
        let state = DisplayHealth.reading(for: id).diagnosticSummary
        Log.info("virtual display never appeared in SCShareableContent — CG state: \(state)")
        throw NSError(domain: "MacSender", code: 3,
                      userInfo: [NSLocalizedDescriptionKey: "virtual display never appeared in SCShareableContent (\(state))"])
    }

    private func startCapture(display: SCDisplay, pixelsWide: Int, pixelsHigh: Int,
                              sessionGeneration requestedGeneration: UInt64? = nil) async throws {
        guard let sessionGeneration = requestedGeneration ?? authenticatedSession.liveGeneration,
              authenticatedSession.isLive(generation: sessionGeneration) else {
            Log.info("sessionDebug: ignored stale capture start generation=\(requestedGeneration.map(String.init) ?? "none")")
            throw CancellationError()
        }
        let initialPhase = captureStateSnapshot().phase
        guard initialPhase != .pausing, initialPhase != .paused, initialPhase != .stopped else {
            throw CancellationError()
        }
        guard stream == nil else {
            throw NSError(domain: "MacSender", code: 6,
                          userInfo: [NSLocalizedDescriptionKey: "capture stream is already active"])
        }
        captureDisplayID = display.displayID
        capturePixelsWide = pixelsWide
        capturePixelsHigh = pixelsHigh
        guard videoEnabled || desiredAudioEnabled else {
            // Nothing wants ScreenCaptureKit right now — stay a no-op
            // logical session exactly as before audio existed, rather than
            // paying for a capture stream nobody will read from.
            invalidateCapturePipeline(discardingLastFrame: true)
            _ = updateCaptureState { $0.captureStarted() }
            lastCursorPNGHash = 0
            lastCursorSent = (-1, -1, false)
            startCursorEcho()
            queue.async {
                self.sendDisplayState(self.captureStateSnapshot().receiverDisplayState)
                self.sendDisplayModeState()
                self.sendAllowInputState()
                self.sendVideoState()
                self.sendAudioState()
                self.sendExtendShapeState()
            }
            await status("Video off — controls remain connected")
            return
        }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        #if DEBUG
        Log.info("extendDebug: startCapture mode=\(mode.rawValue) targetDisplay=\(display.displayID) "
            + "SCDisplaySize=\(display.width)x\(display.height) requestedEncode=\(pixelsWide)x\(pixelsHigh) "
            + "captureGeneration=\(captureGenerationNow)")
        #endif

        // Capability-aware effective FPS (high-refresh milestone):
        // Efficiency/Performance/Custom clamped to the receiver's advertised
        // max refresh rate, an optional receiver-enforced ceiling, and the
        // 120 FPS product ceiling — and now also to the encoder-safe ceiling
        // for THESE final encode dimensions (PART 1/7), so a resolution that
        // can't sustain the requested rate never reaches VideoToolbox at it.
        // Mirror mode's physical source still governs how many *unique*
        // frames actually exist — this only ever asks SCK for up to this
        // rate, it never fabricates duplicates, so a 60Hz physical display
        // streaming under Performance simply keeps delivering real frames at
        // its own cadence.
        let fpsResult = effectiveFPS(width: pixelsWide, height: pixelsHigh)
        let targetFPS = fpsResult.fps
        captureTargetFPS = targetFPS
        logEncodeCapability(width: pixelsWide, height: pixelsHigh, result: fpsResult)

        let config = SCStreamConfiguration()
        config.width = pixelsWide
        config.height = pixelsHigh
        // Ask for double the target even though the source may run slower:
        // requesting exactly 1/fps makes SCK's rate limiter skip frames that
        // arrive a hair early (beat frequency) — measured ~51fps instead of
        // 60 at parity. Same headroom, generalized to the target rate.
        config.minimumFrameInterval = CMTime(value: 1, timescale: Int32(targetFPS * 2))
        // 420v matches the encoder's native input — skips a BGRA→YUV conversion
        // inside VideoToolbox. (`-pixfmt bgra` reverts for A/B testing.)
        config.pixelFormat = UserDefaults.standard.string(forKey: "pixfmt") == "bgra"
            ? kCVPixelFormatType_32BGRA
            : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        // One buffer is held permanently (keyframe replay) and one sits in
        // the encoder for ~13ms — headroom prevents SCK starvation drops.
        config.queueDepth = 8
        config.showsCursor = !localCursor
        // Mac system audio (M-audio): a copy of system audio, never a
        // reroute of the Mac's physical output. `capturesAudio` gates SCK's
        // own audio capture work — off means SCK does none of it, not just
        // "we ignore the samples" (PROTOCOL.md 5A). Both outputs share this
        // one SCStream; audio's actual on/off is toggled later at runtime
        // via `stream.updateConfiguration` rather than tearing this stream
        // down, and it MUST NOT pick up this Mac's own MeowDisplay audio
        // (there is none today, but excluding it is the documented,
        // future-proof way to avoid a feedback loop).
        config.capturesAudio = desiredAudioEnabled
        config.sampleRate = 48_000
        config.channelCount = 2
        config.excludesCurrentProcessAudio = true

        invalidateCapturePipeline(discardingLastFrame: true)
        let generation = captureGenerationNow
        videoEncoder.invalidate()
        if videoEnabled {
            try setupEncoder(width: pixelsWide, height: pixelsHigh, fps: targetFPS)
        }
        await audioCaptureEncoder.reset()
        beginAudioGeneration()

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        self.stream = stream
        do {
            try await stream.startCapture()
        } catch {
            if self.stream === stream { self.stream = nil }
            captureDisplayID = 0   // this attempt never actually started capturing
            throw error
        }
        guard authenticatedSession.isLive(generation: sessionGeneration),
              self.stream === stream, videoEnabled || desiredAudioEnabled,
              updateCaptureState({ state in state.captureStarted() }) else {
            if self.stream === stream { self.stream = nil }
            captureDisplayID = 0   // superseded/discarded — not the active capture
            invalidateCapturePipeline()
            do {
                try await stream.stopCapture()
            } catch {
                let nsError = error as NSError
                Log.info("capture discarded after pause/disconnect failed to stop domain=\(nsError.domain) code=\(nsError.code)")
            }
            Log.info("sessionDebug: ignored stale capture start generation=\(sessionGeneration)")
            throw CancellationError()
        }
        audioEnabled = desiredAudioEnabled
        lastCursorPNGHash = 0      // rotation rebuilds: re-send the sprite
        lastCursorSent = (-1, -1, false)
        startCursorEcho()
        // A capture that came back through any path (recovery, rotation,
        // identity fallback) earns the full recovery budget again — without
        // this, a pending recovery timer that finds the stream alive exits
        // without ever resetting the counter, and the next unrelated death
        // starts with as little as one round left.
        let receiverState = captureStateSnapshot().receiverDisplayState
        queue.async {
            self.captureRecoveryBudget.reset()
            // Every successful capture start is authoritative. This also
            // clears a paused state retained by the receiver when changing
            // modes replaces the old session with a new sender.
            self.sendDisplayState(receiverState)
            self.sendDisplayModeState()
            self.sendAllowInputState()
            self.sendVideoState()
            self.sendAudioState()
            self.sendExtendShapeState()
        }
        guard authenticatedSession.isLive(generation: sessionGeneration) else {
            Log.info("sessionDebug: ignored stale capture status generation=\(sessionGeneration)")
            return
        }
        Log.info("capture started: \(pixelsWide)x\(pixelsHigh) display \(display.displayID) generation \(generation) mode \(mode.rawValue) localCursor=\(localCursor) video=\(videoEnabled) audio=\(audioEnabled)")
        let kind = lastHello?.kind ?? "device"
        await status("\(mode == .extend ? "Extending to" : "Mirroring to") \(kind) (\(pixelsWide)×\(pixelsHigh))")
    }

    // PHASE-1 NOTE: this used to read `connection`/`connectionReady`
    // directly, synchronously, from whatever thread the caller (the
    // MainActor `SenderController.disconnect`) ran on — an unguarded
    // cross-thread read predating this controller. Now that
    // `connectionReady`/`connection` are confined to `transportController`
    // with a DEBUG `dispatchPrecondition(.onQueue(queue))`, that same call
    // would trip the precondition; hop onto `queue` here instead, same as
    // every other connection-touching entry point already does. Completion
    // now always fires asynchronously (previously synchronous only on the
    // "not connected" path).
    func disconnect(completion: @escaping @MainActor @Sendable () -> Void) {
        queue.async { [weak self] in
            guard let self, self.transportController.isReady,
                  self.transportController.currentConnection != nil else {
                Task { @MainActor in completion() }
                return
            }
            let gate = MacSenderDisconnectCompletionGate(completion: completion)
            let json = "{\"type\":\"\(WireMessage.closing)\"}"
            let payload = Data(json.utf8)
            var header = UInt32(payload.count).bigEndian
            var frame = Data(bytes: &header, count: 4)
            frame.append(payload)
            self.transportController.send(content: frame) { _ in
                gate.fire()
            }
            // The send completion may never fire on a dying link.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                gate.fire()
            }
        }
    }

    func stop() {
        stopped = true
        authenticatedSession.invalidate()
        mirrorUnavailableOfferGeneration = nil
        wakeStabilizationAssertion?.release()
        inputInjector?.cancelActiveInput()
        _ = updateCaptureState { state in
            state.stop()
            return true
        }
        invalidateCapturePipeline(discardingLastFrame: true)
        captureDisplayID = 0   // definitive teardown — nothing is being captured anymore
        cursorTimer?.cancel()
        cursorTimer = nil
        cursorImageTimer?.cancel()
        cursorImageTimer = nil
        if let wakeCaptureObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeCaptureObserver)
        }
        wakeCaptureObserver = nil
        if let mirrorDisplayTopologyObserver {
            NotificationCenter.default.removeObserver(mirrorDisplayTopologyObserver)
        }
        mirrorDisplayTopologyObserver = nil
        stream?.stopCapture { _ in }
        stream = nil
        audioEnabled = false
        beginAudioGeneration()
        let audioCaptureEncoder = self.audioCaptureEncoder
        Task { await audioCaptureEncoder.reset() }
        // STOP-B: synchronous relative to `stop()` returning, exactly like
        // the direct `connection?.cancel(); connection = nil` this replaces
        // — see `stopCurrentConnectionSynchronously()`'s doc comment. Also
        // tears down the upgrade-probe timer/monitor/probes (previously
        // done a moment later via `queue.async { stopUpgradeProbing() }`);
        // folding it into the same synchronous call is safe (no delegate/
        // MainActor work in it) and leaves less of a window where a stray
        // probe callback could fire after `stop()` returned.
        transportController.stopCurrentConnectionSynchronously()
        queue.async { [weak self] in
            self?.activeUSBBridge?.cancel()
            self?.activeUSBBridge = nil
            self?.activeUSBBridgeTLS = nil
        }
        videoEncoder.invalidate()
        virtualDisplay = nil   // releasing it removes the display
        cancelDropReplayTimer()
        queue.async { [weak self] in
            // Unblock a start() that is still waiting for the hello.
            self?.helloContinuation?.resume(throwing: CancellationError())
            self?.helloContinuation = nil
        }
    }

    /// Called when the preference changes so a gesture already in progress
    /// cannot leave a synthetic mouse or tablet button held down.
    func cancelActiveInput() {
        inputInjector?.cancelActiveInput()
    }

    func setReceiverUIPreferences(trayEnabled: Bool, keyboardButtonEnabled: Bool) {
        let selfBox = self.selfBox
        queue.async {
            selfBox.currentOnQueue()?.sendJSONObject([
                "type": WireMessage.receiverUI,
                "trayEnabled": trayEnabled,
                "keyboardButtonEnabled": keyboardButtonEnabled,
            ])
        }
    }

    /// Per-device receiver-controls push — the same `WireMessage.receiverUI`
    /// path `setReceiverUIPreferences` uses, extended to the rest of the
    /// fields `ReceiverUIPreferenceUpdate` understands. Every parameter is
    /// optional and omitted-if-nil, so a caller only ever sends the field(s)
    /// actually being edited rather than re-broadcasting every value.
    func setReceiverControlOverrides(
        functionTrayEnabled: Bool? = nil,
        inputMode: String? = nil,
        trackpadSensitivity: Double? = nil,
        hapticsEnabled: Bool? = nil,
        avoidNotch: Bool? = nil,
        pinchTarget: String? = nil,
        rotateTarget: String? = nil,
        snapRotation: Bool? = nil,
        appGestureCommands: AppGestureCommands? = nil
    ) {
        var message: [String: Any] = ["type": WireMessage.receiverUI]
        if let functionTrayEnabled { message["functionTrayEnabled"] = functionTrayEnabled }
        if let inputMode { message["inputMode"] = inputMode }
        if let trackpadSensitivity { message["trackpadSensitivity"] = trackpadSensitivity }
        if let hapticsEnabled { message["hapticsEnabled"] = hapticsEnabled }
        if let avoidNotch { message["avoidNotch"] = avoidNotch }
        if let pinchTarget { message["pinchTarget"] = pinchTarget }
        if let rotateTarget { message["rotateTarget"] = rotateTarget }
        if let snapRotation { message["snapRotation"] = snapRotation }
        // Reuses `AppGestureCommands`'s own `Codable` conformance — see
        // `ReceiverUIPreferenceUpdate`.
        if let appGestureCommands,
           let data = try? JSONEncoder().encode(appGestureCommands),
           let obj = try? JSONSerialization.jsonObject(with: data) {
            message["appGestureCommands"] = obj
        }
        guard message.count > 1 else { return }
        queue.async { [weak self] in self?.sendJSONObject(message) }
    }

    func resetReceiverInputState() {
        let selfBox = self.selfBox
        queue.async {
            guard let self = selfBox.currentOnQueue() else { return }
            self.inputInjector?.cancelActiveInput()
            self.sendJSONObject(["type": WireMessage.inputReset])
        }
    }

    /// The one authoritative control-message-level gate: effectiveInput =
    /// Mac master ON AND this logical session's own grant ON (see
    /// `EffectiveInputAuthorization`) — never the master alone. A receiver
    /// that never requested/was never granted control stays gated out here
    /// even while the Mac master is fully on.
    private func receiverInputIsAllowed() -> Bool {
        guard EffectiveInputAuthorization.allowed(masterEnabled: InputPolicy.allowsInput(),
                                                   sessionGranted: sessionInputGrant.get()),
              captureStateSnapshot().allowsInput else {
            inputInjector?.cancelActiveInput()
            return false
        }
        return true
    }

    /// M4: the keyboard's own, stricter input gate. Touch/Pencil/scroll keep
    /// using `receiverInputIsAllowed()` (tolerates `.recovering`) — this
    /// exists only so keyboard input additionally requires the capture
    /// lifecycle to be fully `.running` (see `CaptureLifecycleState.
    /// allowsKeyboardInput`), without touching that shared policy.
    private func receiverKeyboardInputIsAllowed() -> Bool {
        guard EffectiveInputAuthorization.allowed(masterEnabled: InputPolicy.allowsInput(),
                                                   sessionGranted: sessionInputGrant.get()),
              captureStateSnapshot().allowsKeyboardInput else {
            inputInjector?.cancelActiveInput()
            return false
        }
        return true
    }

    func pauseDisplay() {
        let selfBox = self.selfBox
        queue.async {
            guard let self = selfBox.currentOnQueue(),
                  self.updateCaptureState({ $0.requestPause() }) else { return }
            self.sendDisplayState(.paused)
            self.inputInjector?.cancelActiveInput()
            self.invalidateCapturePipeline()
            self.captureDisplayID = 0   // paused — no active capture until resumeDisplay()
            let activeStream = self.stream
            let queue = self.queue
            let audioCaptureEncoder = self.audioCaptureEncoder
            Task {
                var stopSucceeded = true
                if let activeStream {
                    do {
                        try await activeStream.stopCapture()
                    } catch {
                        stopSucceeded = false
                        let nsError = error as NSError
                        Log.info("intentional pause stop failed domain=\(nsError.domain) code=\(nsError.code): \(error)")
                    }
                }
                let stoppedCapture = stopSucceeded
                queue.async {
                    guard let self = selfBox.currentOnQueue(), self.captureStateSnapshot().phase == .pausing else { return }
                    if stoppedCapture {
                        if self.stream === activeStream { self.stream = nil }
                        self.videoEncoder.invalidate()
                        // Pause stops both media (SESSION BEHAVIOR): the
                        // stream is gone either way, so audio is not
                        // capturing — resumeDisplay's resumeCapture() always
                        // rebuilds the stream and re-applies
                        // `desiredAudioEnabled`, giving resume a clean,
                        // freshly-anchored audio timeline.
                        self.audioEnabled = false
                        self.beginAudioGeneration()
                        Task { await audioCaptureEncoder.reset() }
                    }
                    _ = self.updateCaptureState { $0.pauseCompleted() }
                    let sink = self.statusSink
                    Task { @MainActor in sink.publishStatus("Display paused") }
                }
            }
        }
    }

    func resumeDisplay() {
        let selfBox = self.selfBox
        queue.async {
            guard let self = selfBox.currentOnQueue(),
                  self.updateCaptureState({ $0.requestResume() }) else { return }
            self.captureRecoveryBudget.reset()
            Task { await self.resumeCapture() }
        }
    }

    private func applyVideoEnabled(_ enabled: Bool) {
        guard enabled != videoEnabled else {
            sendVideoState()
            return
        }
        videoEnabled = enabled
        sendVideoState()
        if !enabled {
            let phase = captureStateSnapshot().phase
            if phase != .pausing, phase != .paused, phase != .stopped {
                _ = updateCaptureState { $0.captureStarted() }
            }
            invalidateCapturePipeline(discardingLastFrame: true)
            videoEncoder.invalidate()
            needsKeyframe = true
            // Video Off does not mean Audio Off (SESSION BEHAVIOR): if audio
            // still wants this SCStream, keep it running — the didOutput
            // callback's `videoEnabled` guard is what actually stops
            // encoding/sending, not stream teardown.
            if desiredAudioEnabled, stream != nil {
                let sink = statusSink
                Task { @MainActor in sink.publishStatus("Video off — controls remain connected") }
                return
            }
            let activeStream = stream
            stream = nil
            activeStream?.stopCapture { error in
                if let error {
                    let nsError = error as NSError
                    Log.info("video off capture stop failed domain=\(nsError.domain) code=\(nsError.code)")
                }
            }
            let sink = statusSink
            Task { @MainActor in sink.publishStatus("Video off — controls remain connected") }
            return
        }

        needsKeyframe = true
        guard captureStateSnapshot().phase != .paused,
              captureStateSnapshot().phase != .pausing,
              captureStateSnapshot().phase != .stopped else { return }
        if stream != nil, capturePixelsWide > 0, capturePixelsHigh > 0 {
            // The stream survived Video Off for audio's sake — resume
            // encoding on it directly instead of restarting capture (which
            // would find `stream != nil` and throw "already active").
            do {
                captureTargetFPS = effectiveFPS(width: capturePixelsWide, height: capturePixelsHigh).fps
                try setupEncoder(width: capturePixelsWide, height: capturePixelsHigh, fps: captureTargetFPS)
            } catch {
                Log.info("video resume encoder setup failed: \(error) — entering capture recovery")
                guard updateCaptureState({ $0.unexpectedStop() }) else { return }
                scheduleCaptureRecovery()
            }
            return
        }
        let selfBox = self.selfBox
        Task {
            guard let self = selfBox.resolve() else { return }
            await self.restartVideoCapture()
        }
    }

    private func restartVideoCapture() async {
        do {
            switch mode {
            case .mirror:
                try await startMirrorCapture(preferredDisplayID: captureDisplayID == 0 ? nil : captureDisplayID)
            case .extend:
                guard let vd = virtualDisplay else {
                    throw NSError(domain: "MacSender", code: 10,
                                  userInfo: [NSLocalizedDescriptionKey: "virtual display is unavailable while enabling video"])
                }
                let display = try await findSCDisplay(
                    id: vd.displayID,
                    expectedSize: CGSize(width: vd.pointsWide, height: vd.pointsHigh))
                var width = capturePixelsWide
                var height = capturePixelsHigh
                if width <= 0 || height <= 0 {
                    (width, height) = lastHello.map {
                        clampedCaptureSize(pointsWide: vd.pointsWide, pointsHigh: vd.pointsHigh, info: $0)
                    } ?? ((Int(Double(vd.pointsWide * 2) * quality.scale)) & ~1,
                          (Int(Double(vd.pointsHigh * 2) * quality.scale)) & ~1)
                }
                try await startCapture(display: display, pixelsWide: width, pixelsHigh: height)
            }
        } catch is CancellationError {
            return
        } catch {
            guard videoEnabled,
                  updateCaptureState({ $0.unexpectedStop() }) else { return }
            Log.info("video restart failed: \(error) — entering capture recovery")
            scheduleCaptureRecovery()
        }
    }

    private func resumeCapture() async {
        if let existing = stream {
            do {
                try await existing.stopCapture()
            } catch {
                let nsError = error as NSError
                Log.info("resume could not stop retained stream domain=\(nsError.domain) code=\(nsError.code): \(error)")
                queue.async {
                    _ = self.updateCaptureState { $0.resumeStopFailed() }
                }
                return
            }
            if stream === existing { stream = nil }
        }
        videoEncoder.invalidate()
        needsKeyframe = true
        do {
            switch mode {
            case .mirror:
                try await startMirrorCapture(preferredDisplayID: captureDisplayID == 0 ? nil : captureDisplayID)
            case .extend:
                guard let vd = virtualDisplay else {
                    throw NSError(domain: "MacSender", code: 7,
                                  userInfo: [NSLocalizedDescriptionKey: "virtual display is unavailable while resuming"])
                }
                let size = CGSize(width: vd.pointsWide, height: vd.pointsHigh)
                let display = try await findSCDisplay(id: vd.displayID, expectedSize: size)
                let (width, height) = lastHello.map {
                    clampedCaptureSize(pointsWide: vd.pointsWide, pointsHigh: vd.pointsHigh, info: $0)
                } ?? ((Int(Double(vd.pointsWide * 2) * quality.scale)) & ~1,
                      (Int(Double(vd.pointsHigh * 2) * quality.scale)) & ~1)
                try await startCapture(display: display, pixelsWide: width, pixelsHigh: height)
            }
        } catch is CancellationError {
            return
        } catch {
            guard captureStateSnapshot().phase == .resuming else { return }
            let nsError = error as NSError
            Log.info("capture resume failed domain=\(nsError.domain) code=\(nsError.code): \(error) — retrying")
            queue.async { self.recoveryRoundEnded() }
        }
    }

    /// Migrate the live session to another transport: swap the socket under
    /// the pipeline — virtual display, capture and encoder stay up (no
    /// display destroy/create, so no screen flash and no window reshuffle)
    /// while the connection redials over the new transport. The receiver
    /// treats it like any reconnect: the fresh connection replaces the old
    /// one and the video resyncs with a keyframe. Which transport to be on
    /// is the controller's call (cable-in upgrade, unplug failover).
    func switchTransport(to newTransport: SenderTransport) {
        queue.async { [weak self] in
            guard let self, !self.stopped else { return }
            let label = if case .usb = newTransport { "USB" } else { "WiFi" }
            Log.info("switching \(self.endpointName) to \(label)")
            // A held hardware key (or drag/pen contact) must not survive the
            // old connection into the migrated one.
            self.inputInjector?.cancelActiveInput()
            self.transport = newTransport
            // Fresh grace window: if the new link can't come up either, the
            // session ends like any other disconnect instead of dialing
            // a dead transport forever.
            self.disconnectedSince = Date()
            self.invalidateApplicationSession(reason: "transportSwitch")
            let sink = self.statusSink
            Task { @MainActor in sink.publishTransportPath(nil) }
            self.activeUSBBridge?.cancel()
            self.activeUSBBridge = nil
            self.activeUSBBridgeTLS = nil
            // Clears the direct-link flag (the new transport re-classifies),
            // bumps the dial generation (a dial still in flight must not
            // adopt), cancels/clears the connection, and stops upgrade
            // probing — see MacSenderTransportController.resetForTransportSwitch.
            self.transportController.resetForTransportSwitch()
            self.pipelineState.setPendingSends(0)
            self.pipelineState.resetPendingEncodes()
            self.connect()
        }
    }

    // The controller's end() is idempotent, but several detectors (grace,
    // refusals, service withdrawal) can conclude "gone" repeatedly while the
    // stop is in flight — report once so the log tells the story once.
    private var goneReported = false

    /// Declare the device gone and end the session (must be called on `queue`).
    private func reportGone(_ reason: String) {
        guard !goneReported, !stopped else { return }
        goneReported = true
        Log.info(reason)
        let sink = statusSink
        Task { @MainActor in sink.publishDisconnected() }
    }

    /// A live connection just died (must be called on `queue`). On the
    /// direct cable link the death is almost always someone pulling the
    /// plug, and unplugging is how people intentionally end a session —
    /// falling back to WiFi would resurrect what they just killed. Every
    /// other path (WiFi, routed Ethernet, the dev loopback) keeps the
    /// redial loop: a drop there is never intent.
    private func linkDied(_ detail: String) {
        if transportController.isDirectLink, case .tcp = transport {
            reportGone("cable link lost (\(detail)) — unplugging means disconnect, ending session")
        } else {
            scheduleReconnect()
        }
    }

    // refreshDirectLinkClassification/reportRoute now live on
    // `transportController` — see MacSenderTransportController.swift. This
    // class still owns `transport`/`lastHello`, which the controller reads
    // back through `MacSenderTransportDelegate`.

    /// Arms/extends the bounded 60s post-wake stabilization for ANY
    /// authenticated route (USB/LAN/AWDL/Remote alike) — called once the
    /// MEOW application handshake completes (`markApplicationReady`), which
    /// already implies pinned mutual-TLS (checked earlier in the same hello
    /// path). Every route's graphical/video pipeline needs the same runway
    /// to come alive, not just Remote's dark-wake gap. A same-peer transport
    /// migration (`switchTransport`) redials and reaches this again with a
    /// new generation — `SessionStabilizationPolicy`/`WakeStabilizationAssertion.begin()`
    /// both treat that as "extend," not "release+reopen a gap," since
    /// `invalidateApplicationSession` deliberately does not release the
    /// assertion for a `"transportSwitch"` reason.
    private func armSessionStabilizationIfNeeded(generation: UInt64) {
        guard SessionStabilizationPolicy.shouldArm(
            previouslyArmedGeneration: sessionStabilizationArmedGeneration,
            currentGeneration: generation
        ) else { return }
        sessionStabilizationArmedGeneration = generation
        if wakeStabilizationAssertion == nil { wakeStabilizationAssertion = WakeStabilizationAssertion() }
        wakeStabilizationAssertion?.begin(generation: generation, route: transportController.route?.rawValue)
    }

    /// A dial was actively refused (must be called on `queue`). On a session
    /// that has streamed before, enough refusals in a row prove the receiver
    /// app is gone — end now instead of waiting out the grace.
    private func dialRefused() {
        guard everConnected, !stopped else { return }
        consecutiveRefusals += 1
        if consecutiveRefusals >= refusalsBeforeGivingUp {
            reportGone("dial refused \(consecutiveRefusals)x — receiver app is gone, ending session")
        }
    }

    /// The receiver's Bonjour advertisement disappeared (the system
    /// deregisters a dead app's service within ~1s, while a suspended app
    /// keeps it). Only meaningful once the connection is already down —
    /// a live connection outranks a flapping mDNS cache. Together they
    /// prove a WiFi receiver quit, where dials just stall instead of
    /// being refused.
    func peerServiceWithdrawn() {
        queue.async { [weak self] in
            guard let self, !self.stopped, self.everConnected,
                  !self.transportController.isReady else { return }
            self.reportGone("service withdrawn and connection down — receiver app is gone, ending session")
        }
    }

    /// Drop the current connection and dial again — fresh TCP through the
    /// tunnel, fresh accept on the phone. Bound to the UI Reconnect button.
    func forceReconnect() {
        queue.async { [weak self] in
            guard let self, !self.stopped else { return }
            Log.info("manual reconnect requested")
            Log.info("reconnectPolicy: manualAttempt allowed autoReconnect=\(self.autoReconnectEnabled)")
            self.disconnectedSince = Date()   // fresh grace window
            self.scheduleReconnect(automatic: false)
        }
    }

    /// The user flipped the Auto-Reconnect toggle. A currently connected
    /// session is left running untouched either way. A session in this
    /// sender's own in-place retry window (already connected once, now
    /// mid-grace after a loss) is ended immediately when the preference goes
    /// off, so an already-scheduled automatic redial cannot reconnect behind
    /// the user's back — `SenderController` leaves it out of `sessions`
    /// afterward, so the device stays reachable for a manual Connect.
    func applyAutoReconnectPreferenceChange(enabled: Bool) {
        queue.async { [weak self] in
            guard let self, !self.stopped else { return }
            self.autoReconnectEnabled = enabled
            guard !enabled, self.everConnected, !self.transportController.isReady,
                  self.disconnectedSince != nil else { return }
            // `reportGone` only flips `stopped` asynchronously (it hops
            // through SenderController on the main actor), so a redial timer
            // already queued by `scheduleReconnect` could otherwise still
            // fire and connect in that window. Bumping the generation here,
            // synchronously on this same queue, invalidates it immediately.
            self.transportController.bumpDialGeneration()
            self.activeUSBBridge?.cancel()
            self.activeUSBBridge = nil
            self.activeUSBBridgeTLS = nil
            Log.info("reconnectPolicy: automaticRetry cancelled reason=disabled peer=\(self.endpointName)")
            self.reportGone("auto-reconnect disabled — ending session")
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        let selfBox = self.selfBox
        queue.async {
            selfBox.currentOnQueue()?.handleCaptureStopped(stream, error: error)
        }
    }

    private func handleCaptureStopped(_ stoppedStream: SCStream, error: Error) {
        let lifecycle = captureStateSnapshot()
        let nsError = error as NSError
        // FORENSIC FIX: `!videoEnabled` alone used to mean "this stop is
        // intentional, ignore it" — true before Video Off could keep the
        // stream alive for audio (see `startCapture`'s
        // `videoEnabled || desiredAudioEnabled` guard). Since that changed,
        // an unexpected stop of a Video-Off-but-Audio-On stream hit this
        // guard, returned early, and left `stream` pointing at a dead
        // SCStream forever — audio (and video, whenever it was turned back
        // on) stayed silent/black with no recovery ever scheduled. Only
        // treat the stop as intentional when NOTHING currently wants this
        // stream.
        let intentional = lifecycle.ownsCaptureStop || (!videoEnabled && !desiredAudioEnabled)
        let isCurrentStream = stoppedStream === stream
        // Pause/Resume owns its stream stops. In particular, .userStopped from
        // our Pause button must not be mistaken for the system's Stop Extending.
        guard !intentional else { return }
        // A retired stream commonly reports its stop after its replacement is
        // already live. It must not tear down that replacement (#203).
        guard isCurrentStream else { return }
        // The system UI's Stop Extending is a user disconnect, not a fault.
        if let scError = error as? SCStreamError, scError.code == .userStopped,
           consoleIsInteractive {
            let sink = statusSink
            Task { @MainActor in sink.publishCaptureStoppedByUser() }
            return
        }
        guard !stopped,
              updateCaptureState({ $0.unexpectedStop() }) else { return }
        Log.info("unexpected SCStream stop mode=\(mode.rawValue) domain=\(nsError.domain) "
            + "code=\(nsError.code): \(error.localizedDescription)")
        let stopSink = statusSink
        let stopText = "Capture stopped: \(error.localizedDescription)"
        Task { @MainActor in stopSink.publishStatus(stopText) }
        // An unplanned stop is exactly the kind of drop a held keyboard key
        // (or mouse/Pencil contact) must not survive — the recovery window
        // that follows has no live session for it to belong to.
        inputInjector?.cancelActiveInput()
        invalidateCapturePipeline()
        stream = nil
        scheduleCaptureRecovery()
    }

    /// PART 8 recovery: called at most once per capture generation (guarded
    /// by `encoderRecoveryDowngradedGeneration` at the call site) after
    /// `encodeFailureStreakLimit` consecutive encode-output failures with
    /// zero successful frames. Reconfigures the LIVE stream/encoder at the
    /// next lower supported FPS tier — same in-place mechanism as
    /// `applyEffectiveFPSChange` — rather than tearing down and rebuilding
    /// the whole capture pipeline, so a genuinely-transient stall isn't
    /// compounded by a full restart. Already at the lowest tier (1 FPS)
    /// means the size itself is the problem, not the rate — falls through
    /// to the ordinary capture-recovery/reconnect path instead of an
    /// infinite downgrade loop.
    private func recoverFromEncoderFailureStreak(generation: UInt64) {
        guard generation == captureGenerationNow, let stream,
              capturePixelsWide > 0, capturePixelsHigh > 0 else { return }
        let tiers = EncoderCapability.supportedFPSTiers
        guard let currentIndex = tiers.firstIndex(where: { $0 >= captureTargetFPS }),
              currentIndex > 0 else {
            Log.info("encoder failure safety net: no successful frames after "
                + "\(encodeFailureStreakLimit) attempts at \(capturePixelsWide)x\(capturePixelsHigh)"
                + "@\(captureTargetFPS), already at the lowest FPS tier — entering capture recovery")
            guard updateCaptureState({ $0.unexpectedStop() }) else { return }
            scheduleCaptureRecovery()
            return
        }
        let downgraded = tiers[currentIndex - 1]
        Log.info("encoder failure safety net: no successful frames after \(encodeFailureStreakLimit) "
            + "attempts at \(capturePixelsWide)x\(capturePixelsHigh)@\(captureTargetFPS) — "
            + "recovering once at \(downgraded) FPS")
        needsKeyframe = true
        let config = SCStreamConfiguration()
        config.minimumFrameInterval = CMTime(value: 1, timescale: Int32(downgraded * 2))
        let selfBox = self.selfBox
        let queue = self.queue
        Task {
            do {
                try await stream.updateConfiguration(config)
            } catch {
                Log.info("failure-streak SCK reconfigure failed: \(error)")
            }
            queue.async {
                guard let self = selfBox.currentOnQueue(),
                      self.stream === stream, generation == self.captureGenerationNow else { return }
                self.captureTargetFPS = downgraded
                do {
                    try self.setupEncoder(width: self.capturePixelsWide, height: self.capturePixelsHigh,
                                          fps: downgraded)
                    self.sendMaxFPSState()
                } catch {
                    Log.info("encoder failure-streak recovery setup failed: \(error) — entering capture recovery")
                    guard self.updateCaptureState({ $0.unexpectedStop() }) else { return }
                    self.scheduleCaptureRecovery()
                }
            }
        }
    }

    /// Retry capture without rebuilding a healthy display. Extend recovery
    /// keeps its existing reattach-first path; Mirror recovery reattaches to
    /// the captured physical display and rebuilds capture alone on fallback.
    private func scheduleCaptureRecovery() {
        // Video-Off + Audio-On keeps this stream alive on nothing but the
        // audio side (see `startCapture`) — recovery must stay reachable
        // then too, or a dead stream in that combination never comes back
        // (see the FORENSIC FIX note in `handleCaptureStopped`).
        guard videoEnabled || desiredAudioEnabled, !captureRecoveryScheduled,
              captureStateSnapshot().shouldRetryCapture else { return }
        captureRecoveryScheduled = true
        let attempt = captureRecoveryBudget.failedAttempts + 1
        Log.info("capture recovery starting mode=\(mode.rawValue) "
            + "attempt=\(attempt)/\(captureRecoveryBudget.maximumAttempts) delay=3s")
        let selfBox = self.selfBox
        queue.asyncAfter(deadline: .now() + 3.0) {
            guard let self = selfBox.currentOnQueue() else { return }
            self.captureRecoveryScheduled = false
            guard self.videoEnabled || self.desiredAudioEnabled, !self.stopped, self.stream == nil,
                  self.captureStateSnapshot().shouldRetryCapture else { return }
            Task { await self.runCaptureRecovery(attempt: attempt) }
        }
    }

    private func runCaptureRecovery(attempt: Int) async {
        let targetAvailable: Bool
        switch mode {
        case .mirror:
            targetAvailable = captureDisplayID != 0 && DisplayHealth.isUsable(captureDisplayID)
        case .extend:
            if let virtualDisplay {
                targetAvailable = DisplayHealth.isUsable(virtualDisplay.displayID)
            } else {
                targetAvailable = false
            }
        }
        let path = CaptureRecoveryPath.resolve(mode: mode, targetDisplayAvailable: targetAvailable)
        Log.info("capture recovery attempt \(attempt)/\(captureRecoveryBudget.maximumAttempts) "
            + "mode=\(mode.rawValue) path=\(String(describing: path)) targetAvailable=\(targetAvailable)")

        do {
            switch path {
            case .reattachMirrorCapture:
                try await reattachMirrorCapture()
            case .rebuildMirrorPipeline:
                try await rebuildMirrorCapturePipeline()
            case .reattachExtendCapture:
                try await reattachExtendCapture()
            case .rebuildExtendPipeline:
                if let hello = lastHello { await reconfigure(hello) }
                else { throw CancellationError() }
            }
            guard captureStateSnapshot().phase == .running else { return }
            Log.info("capture recovery attempt \(attempt) succeeded mode=\(mode.rawValue)")
        } catch is CancellationError {
            return
        } catch {
            guard captureStateSnapshot().shouldRetryCapture else { return }
            let nsError = error as NSError
            Log.info("capture reattach/rebuild attempt \(attempt) failed domain=\(nsError.domain) code=\(nsError.code): \(error)")
            do {
                switch mode {
                case .mirror:
                    Log.info("capture recovery attempt \(attempt) falling back to Mirror capture-pipeline rebuild")
                    try await rebuildMirrorCapturePipeline()
                case .extend:
                    Log.info("capture recovery attempt \(attempt) falling back to Extend display-pipeline rebuild")
                    if let hello = lastHello { await reconfigure(hello) }
                }
                if captureStateSnapshot().phase == .running {
                    Log.info("capture recovery fallback succeeded attempt=\(attempt) mode=\(mode.rawValue)")
                }
            } catch is CancellationError {
                return
            } catch {
                let rebuildError = error as NSError
                Log.info("capture rebuild fallback failed domain=\(rebuildError.domain) code=\(rebuildError.code): \(error)")
            }
        }
        let selfBox = self.selfBox
        queue.async { selfBox.currentOnQueue()?.recoveryRoundEnded() }
    }

    private func reattachMirrorCapture() async throws {
        guard captureDisplayID != 0,
              !CGDisplayBounds(captureDisplayID).isEmpty else {
            throw NSError(domain: "MacSender", code: 8,
                          userInfo: [NSLocalizedDescriptionKey: "captured physical display is unavailable"])
        }
        let display = try await findSCDisplay(id: captureDisplayID)
        try await startMirrorCapture(display: display)
    }

    private func startMirrorCapture(display: SCDisplay,
                                    sessionGeneration: UInt64? = nil) async throws {
        if let targetID = InputTargetResolver.displayID(
            mode: .mirror,
            mirrorDisplayID: display.displayID,
            virtualDisplayID: nil
        ) {
            inputInjector = InputInjector(displayID: targetID, sessionInputGrant: sessionInputGrant)
        }

        let displayMode = CGDisplayCopyDisplayMode(display.displayID)
        let pixelsW = displayMode?.pixelWidth ?? display.width
        let pixelsH = displayMode?.pixelHeight ?? display.height
        let nativeCaptureW = (Int(Double(pixelsW) * quality.scale)) & ~1
        let nativeCaptureH = (Int(Double(pixelsH) * quality.scale)) & ~1
        // Clamp to the receiver's advertised decode ceiling (PROTOCOL.md
        // 6.5) exactly like Extend does via `clampedCaptureSize` — Mirror
        // used to skip this because capture started before any hello was
        // available, but `start()` now awaits `waitForHello()` before
        // either mode begins, and every recovery path here runs only after
        // the current session's hello is already in `lastHello`, so the
        // ceiling is always known by this point.
        let (maxWide, maxHigh) = lastHello.map {
            CodecDecodeCeiling.applicable(
                codec: .h264, legacyMaxEncodeWide: $0.maxEncodeWide, legacyMaxEncodeHigh: $0.maxEncodeHigh)
        } ?? (nil, nil)
        let (captureW, captureH) = DecodeCeiling.clamp(
            width: nativeCaptureW, height: nativeCaptureH, maxWide: maxWide, maxHigh: maxHigh)
        if captureW != nativeCaptureW || captureH != nativeCaptureH {
            Log.info("mirror stream capped at \(captureW)x\(captureH) by the receiver's decode ceiling "
                + "\(maxWide ?? 0)x\(maxHigh ?? 0)")
        }

        // Logical (point) size vs. native backing-pixel size are frequently
        // different (HiDPI @2x, or a virtual display like BetterDisplay
        // configured with a large backing framebuffer) — log both plus the
        // actual capture/encode target distinctly so a huge backing store
        // is visible as exactly that, not confused with the encoded size.
        let displayName = NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == display.displayID
        }?.localizedName ?? "Display \(display.displayID)"
        Log.info("displayDebug: mirrorSelection name=\(displayName)")
        Log.info("displayDebug: persistentID=\(MirrorDisplayIdentity.uuidString(for: display.displayID) ?? "unknown")")
        Log.info("displayDebug: resolvedCGDisplayID=\(display.displayID)")
        Log.info("displayDebug: logicalSize=\(display.width)x\(display.height)")
        Log.info("displayDebug: pixelSize=\(pixelsW)x\(pixelsH)")
        Log.info("displayDebug: main=\(display.displayID == CGMainDisplayID())")
        Log.info("displayDebug: captureSize=\(captureW)x\(captureH)")

        try await startCapture(display: display, pixelsWide: captureW, pixelsHigh: captureH,
                               sessionGeneration: sessionGeneration)
    }

    private func rebuildMirrorCapturePipeline() async throws {
        let preferred = captureDisplayID != 0 && !CGDisplayBounds(captureDisplayID).isEmpty
            ? captureDisplayID : nil
        try await startMirrorCapture(preferredDisplayID: preferred)
    }

    private func reattachExtendCapture() async throws {
        guard let vd = virtualDisplay else {
            throw NSError(domain: "MacSender", code: 9,
                          userInfo: [NSLocalizedDescriptionKey: "virtual display is unavailable"])
        }
        // Scoped to THIS identity — if stop() or a fresh setupExtend()
        // replaces `virtualDisplay` while this function is suspended (e.g.
        // during the findSCDisplay poll below), nothing here may reattach or
        // start capture against the old one.
        func isStale() -> Bool { stopped || virtualDisplay !== vd }
        // Cheap CoreGraphics-only check before paying `findSCDisplay`'s SCK
        // poll: a torn-down/offline identity (upstream #219 — non-empty
        // bounds but CGDisplayIsOnline/IsActive false) never appears in
        // shareable content, so failing fast here skips straight to the
        // caller's rebuild fallback instead of waiting out the ~5s poll.
        let usability = DisplayUsability.evaluate(DisplayHealth.reading(for: vd.displayID))
        guard usability == .usable else {
            Log.info("displayDebug: virtual display \(vd.displayID) stale (\(usability)) — rebuilding")
            throw NSError(domain: "MacSender", code: 10,
                          userInfo: [NSLocalizedDescriptionKey: "virtual display is stale/offline"])
        }
        let display = try await findSCDisplay(id: vd.displayID, isCancelled: isStale)
        guard !isStale() else { throw CancellationError() }
        let (captureW, captureH) = lastHello.map {
            clampedCaptureSize(pointsWide: vd.pointsWide, pointsHigh: vd.pointsHigh, info: $0)
        } ?? ((Int(Double(vd.pointsWide * 2) * quality.scale)) & ~1,
              (Int(Double(vd.pointsHigh * 2) * quality.scale)) & ~1)
        try await startCapture(display: display, pixelsWide: captureW, pixelsHigh: captureH)
    }

    /// SCK can report `.userStopped` for stops the user did not initiate
    /// when the console goes non-interactive (screen lock, fast user
    /// switch). Only a stop from an interactive console can be a deliberate
    /// menu-bar "stop sharing"; everything else stays on the recovery path,
    /// which was already how those transitions healed before this check
    /// existed.
    private var consoleIsInteractive: Bool {
        guard let info = CGSessionCopyCurrentDictionary() as? [String: Any] else { return true }
        let onConsole = info[kCGSessionOnConsoleKey as String] as? Bool ?? true
        let locked = info["CGSSessionScreenIsLocked"] as? Bool ?? false
        return onConsole && !locked
    }

    /// On `queue`: after a recovery round, re-arm the loop while capture is
    /// still down — up to the cap, then declare the session gone. A capture
    /// dead this many rounds is not coming back by itself, and ending the
    /// session (display torn down, reconnect is the user's call) beats
    /// hammering WindowServer with create/destroy cycles forever.
    private func recoveryRoundEnded() {
        guard videoEnabled, captureStateSnapshot().shouldRetryCapture else { return }
        guard stream == nil else {
            captureRecoveryBudget.reset()
            return
        }
        let shouldRetry = captureRecoveryBudget.recordFailure()
        guard shouldRetry else {
            let recoverySink = statusSink
            if captureStateSnapshot().phase == .resuming {
                _ = updateCaptureState { $0.resumeFailed() }
                Task { @MainActor in recoverySink.publishStatus("Resume failed — try again") }
                return
            }
            _ = updateCaptureState { $0.recoveryFailed() }
            Task { @MainActor in recoverySink.publishStatus("Capture could not be restarted") }
            reportGone("capture recovery failed \(captureRecoveryBudget.failedAttempts)x — ending session")
            return
        }
        scheduleCaptureRecovery()
    }

    // MARK: - Wake capture recovery (fresh post-wake SCK reconstruction)
    //
    // After sleep → WoL → Promote Interactive Wake → external monitor
    // power-on, the pre-sleep SCStream/SCContentFilter/SCDisplay must not be
    // trusted or reused — this reconstructs capture from scratch so the
    // existing Aqua process can stream the post-wake lock screen (`wakeCapture:`
    // logs trace each step). Mirror mode only;
    // does not touch Extend, WoL, Promote, or the reconnect/dial machinery.

    /// `screensDidWakeNotification` is the earliest point the interactive
    /// display graph is expected to exist — unlike `didWakeNotification`
    /// (fires on DarkWake/network wake, before displays are necessarily
    /// live). Debounced below so a multi-display topology settling into
    /// place cannot launch overlapping reconstructions.
    private func startWakeCaptureObserver() {
        guard wakeCaptureObserver == nil else { return }
        wakeCaptureObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.queue.async { self?.topologyChanged(reason: "screensDidWake") }
        }
    }

    /// Called on `queue` for every topology-changing notification, for both
    /// modes. Bumps `topologyGenerationNow` first so any in-flight async
    /// health check started by an earlier event can recognize itself as
    /// stale, then routes to the mode-appropriate recovery: Mirror keeps its
    /// existing full SCK reconstruction; Extend gets a lighter health-check
    /// pass (see `scheduleExtendTopologyHealthCheck`) since its capture
    /// pipeline normally survives a topology change untouched and only needs
    /// forcing back to life when the virtual display actually went stale.
    private func topologyChanged(reason: String) {
        guard !stopped else { return }
        topologyGenerationNow &+= 1
        Log.info("displayDebug: topologyChanged reason=\(reason) generation=\(topologyGenerationNow)")
        switch mode {
        case .mirror:
            // Unchanged from before this milestone: only `screensDidWake`
            // triggers Mirror's full SCK reconstruction.
            // `didChangeScreenParameters` still only refreshes the picker
            // list (via `sendMirrorDisplayState`, called at the notification
            // site) — a real detach of the mirrored display already surfaces
            // as an SCStream error through `handleCaptureStopped`, so forcing
            // a rebuild here too would churn Mirror on unrelated topology
            // changes (e.g. a second, uninvolved display attaching).
            guard reason == "screensDidWake" else { return }
            scheduleWakeCaptureRecovery(reason: reason)
        case .extend:
            scheduleExtendTopologyHealthCheck(reason: reason)
        }
    }

    /// Extend's analogue of `runWakeCaptureRecovery`: a lid-close/open or
    /// external-display attach/detach cycle can leave the SCStream itself
    /// alive but the virtual display no longer capturable (WindowServer
    /// transiently drops it from the topology without erroring the stream) —
    /// the exact "silent black screen" gap Mirror doesn't have because it
    /// always rebuilds from scratch on `screensDidWake`. This only forces
    /// recovery when the display is actually unhealthy; a healthy display
    /// mid-transition is left alone.
    private func scheduleExtendTopologyHealthCheck(reason: String) {
        guard mode == .extend, !stopped, let vd = virtualDisplay else { return }
        let generation = topologyGenerationNow
        let displayID = vd.displayID
        // Give WindowServer/SCK the same settle window `findSCDisplay` polls
        // at (250ms) before judging the display — an immediate read during
        // the transition itself would false-positive on a display that is
        // about to be fine.
        let selfBox = self.selfBox
        queue.asyncAfter(deadline: .now() + 0.25) {
            guard let self = selfBox.currentOnQueue(), !self.stopped, self.mode == .extend,
                  !GenerationGate.isStale(capturedAt: generation, current: self.topologyGenerationNow),
                  self.virtualDisplay?.displayID == displayID else { return }
            // Going headless mid-session: the VD is still healthy, but if
            // it isn't already the main display (origin (0,0)) macOS's
            // login/lock UI has no usable main display to render onto — a
            // separate concern from the "went stale, rebuild" check below,
            // which only fires for an actually-unhealthy display.
            if !DisplayHealth.hasUsablePhysicalDisplay(excluding: displayID),
               CGDisplayBounds(displayID).origin != .zero {
                Log.info("displayDebug: no usable physical display — repositioning VD "
                    + "\(displayID) to become main (origin 0,0)")
                // Re-derives the VD on the main actor via `selfBox` instead
                // of capturing `vd` itself into the Task — `vd` is not
                // Sendable, and `selfBox.resolve()` (safe from any thread,
                // unlike `currentOnQueue()`) re-checks the same identity so
                // a replacement/teardown that raced this hop is a no-op.
                Task { @MainActor in
                    guard let sender = selfBox.resolve(), !sender.stopped,
                          sender.virtualDisplay?.displayID == displayID else { return }
                    sender.virtualDisplay?.repositionForHeadlessMain()
                }
                // Resolved via `selfBox` rather than capturing the
                // queue-confined `self` — that `self` is still in active use
                // for the rest of this closure, so it is not a disconnected
                // region the compiler will let this escaping `Task` send.
                Task {
                    guard let sender = selfBox.resolve() else { return }
                    await sender.logDisplayTopologyDiagnostics(reason: reason, vdID: displayID)
                }
            }
            let usability = DisplayUsability.evaluate(DisplayHealth.reading(for: displayID))
            guard usability != .usable else { return }
            guard self.captureStateSnapshot().phase == .running else { return }
            Log.info("displayDebug: extend virtual display \(displayID) went stale after "
                + "\(reason) (\(usability)) with no SCK error — forcing capture recovery")
            guard self.updateCaptureState({ $0.unexpectedStop() }) else { return }
            self.inputInjector?.cancelActiveInput()
            self.invalidateCapturePipeline()
            // Unlike `handleCaptureStopped`, SCK itself has not reported this
            // stream dead — it must be stopped explicitly rather than just
            // dropped, or the doomed SCStream instance keeps running in the
            // background.
            let staleStream = self.stream
            self.stream = nil
            if let staleStream {
                Task {
                    do { try await staleStream.stopCapture() }
                    catch { Log.info("displayDebug: stale extend stream stop failed: \(error)") }
                }
            }
            self.scheduleCaptureRecovery()
        }
    }

    private func scheduleWakeCaptureRecovery(reason: String) {
        guard mode == .mirror, !stopped else { return }
        guard !wakeCaptureRecoveryScheduled, !wakeCaptureRecoveryRunning else {
            Log.info("wakeCapture: coalesced duplicate reason=\(reason)")
            return
        }
        wakeCaptureRecoveryScheduled = true
        let selfBox = self.selfBox
        queue.asyncAfter(deadline: .now() + 0.75) {
            guard let self = selfBox.currentOnQueue() else { return }
            self.wakeCaptureRecoveryScheduled = false
            guard self.mode == .mirror, !self.stopped, !self.wakeCaptureRecoveryRunning else { return }
            self.wakeCaptureRecoveryRunning = true
            Task { await self.runWakeCaptureRecovery(reason: reason) }
        }
    }

    /// Stale pre-sleep SCK objects are stopped and discarded; the persisted
    /// stable display UUID is re-resolved against a freshly fetched
    /// `SCShareableContent`; a brand-new `SCStream` is built via the
    /// existing `startMirrorCapture` path. Generation-safe: bumping
    /// `captureGeneration` up front means the old stream's own late async
    /// stop completion, and any of its stale frame/encode callbacks, are
    /// ignored by the checks already in `stream(_:didOutputSampleBuffer:)`
    /// and `encode`, so they cannot affect the new stream once it exists.
    private func runWakeCaptureRecovery(reason: String) async {
        let selfBox = self.selfBox
        defer { queue.async { selfBox.currentOnQueue()?.wakeCaptureRecoveryRunning = false } }
        Log.info("wakeCapture: begin reason=\(reason)")

        invalidateCapturePipeline(discardingLastFrame: true)
        let generation = captureGenerationNow
        Log.info("wakeCapture: generation=\(generation)")

        let oldStream = stream
        Log.info("wakeCapture: oldStreamPresent=\(oldStream != nil)")
        stream = nil   // the new build below must not be torn down by the old stream's late callback
        if let oldStream {
            Log.info("wakeCapture: stoppingOldStream")
            do {
                try await oldStream.stopCapture()
            } catch {
                Log.info("wakeCapture: oldStreamStopFailed error=\(error)")
            }
            Log.info("wakeCapture: oldStreamStopped")
        }

        Log.info("wakeCapture: requestingShareableContent")
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.current
        } catch {
            Log.info("wakeCapture: shareableContentFailed error=\(error)")
            scheduleCaptureRecoveryAfterWakeFailure()
            return
        }
        Log.info("wakeCapture: shareableContentResult displayCount=\(content.displays.count)")
        let mainID = CGMainDisplayID()
        for candidate in content.displays {
            let uuid = MirrorDisplayIdentity.uuidString(for: candidate.displayID) ?? "unknown"
            let screen = NSScreen.screens.first {
                ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID)
                    == candidate.displayID
            }
            let name = screen?.localizedName ?? "Display \(candidate.displayID)"
            let displayMode = CGDisplayCopyDisplayMode(candidate.displayID)
            Log.info("wakeCapture: display uuid=\(uuid) id=\(candidate.displayID) name=\(name) "
                + "logical=\(candidate.width)x\(candidate.height) "
                + "pixel=\(displayMode?.pixelWidth ?? candidate.width)x\(displayMode?.pixelHeight ?? candidate.height) "
                + "main=\(candidate.displayID == mainID)")
        }

        var resolvedDisplay: SCDisplay?
        if let uuid = mirrorDisplayUUID {
            Log.info("wakeCapture: selectedUUID=\(uuid)")
            resolvedDisplay = MirrorDisplayIdentity.resolve(persistentID: uuid, in: content.displays)
            guard resolvedDisplay != nil else {
                // Explicit selection: an unresolved UUID must not silently
                // fall back to a random display just to make a test pass.
                Log.info("wakeCapture: displayNotFound uuid=\(uuid)")
                scheduleCaptureRecoveryAfterWakeFailure()
                return
            }
        } else {
            // Auto mode: preserve existing Automatic behavior.
            Log.info("wakeCapture: selectedUUID=none(Auto)")
            resolvedDisplay = content.displays.first
        }
        guard let display = resolvedDisplay else {
            Log.info("wakeCapture: displayNotFound uuid=none")
            scheduleCaptureRecoveryAfterWakeFailure()
            return
        }
        Log.info("wakeCapture: resolvedDisplay id=\(display.displayID)")

        guard let sessionGeneration = authenticatedSession.liveGeneration,
              authenticatedSession.isLive(generation: sessionGeneration) else {
            Log.info("wakeCapture: noLiveSession")
            return
        }
        Log.info("wakeCapture: contentFilterCreated")
        wakeCaptureAwaitingFirstFrameGeneration = generation
        wakeCaptureAwaitingEncodedFrameGeneration = generation
        Log.info("wakeCapture: streamCreated generation=\(generation)")
        Log.info("wakeCapture: startCaptureRequested")
        do {
            try await startMirrorCapture(display: display, sessionGeneration: sessionGeneration)
            Log.info("wakeCapture: startCaptureSucceeded")
        } catch {
            Log.info("wakeCapture: startCaptureFailed error=\(error)")
            wakeCaptureAwaitingFirstFrameGeneration = nil
            wakeCaptureAwaitingEncodedFrameGeneration = nil
            scheduleCaptureRecoveryAfterWakeFailure()
        }
    }

    /// On failure, fall back to the existing generic recovery loop rather
    /// than leaving the session stuck — the wake path is a best-effort fast
    /// path, not the only route back to a live capture.
    private func scheduleCaptureRecoveryAfterWakeFailure() {
        let selfBox = self.selfBox
        queue.async {
            guard let self = selfBox.currentOnQueue(), !self.stopped else { return }
            _ = self.updateCaptureState { $0.unexpectedStop() }
            self.scheduleCaptureRecovery()
        }
    }

    /// Logged once, from the SCK sample-buffer callback, for the first
    /// frame of a wake-recovery generation — never per-frame. Reads
    /// `SCStreamFrameInfo.status` (idle/blank/suspended vs. complete) so a
    /// stale/frozen capture is distinguishable from a genuinely fresh one
    /// without adding per-frame pixel analysis.
    private func logWakeCaptureFirstFrame(sampleBuffer: CMSampleBuffer, pixelBuffer: CVPixelBuffer) {
        Log.info("wakeCapture: firstFrame")
        var statusDescription = "unknown"
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
            as? [[SCStreamFrameInfo: Any]],
           let raw = attachments.first?[.status] as? Int,
           let status = SCFrameStatus(rawValue: raw) {
            statusDescription = String(describing: status)
        }
        Log.info("wakeCapture: firstFrameStatus=\(statusDescription)")
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        Log.info("wakeCapture: firstFramePTS=\(pts.seconds)")
        Log.info("wakeCapture: frameSize=\(CVPixelBufferGetWidth(pixelBuffer))x\(CVPixelBufferGetHeight(pixelBuffer))")
    }

    // MARK: - Connection (with retry)

    // Guards against a stale async USB dial adopting after a newer one (or a
    // manual reconnect) superseded it. Only touched on `queue`.
    // The USB secure bridge for the in-flight/live USB dial, if any. Owned
    // here so every generation bump/stop/transport-switch can cancel a
    // superseded bridge explicitly instead of relying only on TCP-level
    // teardown propagation. Only touched on `queue`.
    private var activeUSBBridge: USBTLSBridge?
    // Holds the TLS config for the USB bridge dial in flight so the
    // unstructured Task below never captures the non-Sendable
    // `TLSSessionConfig` (it holds a `SecIdentity`) across the isolation
    // boundary; it re-reads this queue-confined property once back on
    // `queue` instead. Only touched on `queue`.
    private var activeUSBBridgeTLS: TLSSessionConfig?

    private func connect() {
        guard !stopped else { return }
        Log.info("connectDebug: senderStartRequested peer=\(endpointName)")
        switch transport {
        case .tcp(let endpoint, let tls):
            Log.info("connectDebug: dialStarted peer=\(endpointName) route=tcp")
            connectTCP(endpoint, tls: tls)
        case .usb(let udid, let tls):
            Log.info("connectDebug: dialStarted peer=\(endpointName) route=usb")
            connectUSB(udid: udid, tls: tls)
        }
    }

    private func connectTCP(_ endpoint: NWEndpoint, tls: TLSSessionConfig) {
        let options = NWProtocolTCP.Options()
        options.noDelay = true   // latency matters more than throughput here
        // No interface steering: macOS already ranks a Thunderbolt Bridge or
        // Ethernet link above WiFi, so a plain dial lands on the cable when
        // there is one (field-tested: en10 chosen over en0). A WiFi-prohibited
        // pre-dial was tried and only ever hung until its timeout, adding 2s
        // to every connect. becomeReady reports which path won.
        guard let tlsOptions = TLSConfigurator.mutualTLSOptions(
            identity: tls.identity,
            pinnedSPKIs: { [tls.pinnedPeerSPKI] },
            isListener: false, queue: queue) else {
            let sink = statusSink
            Task { @MainActor in sink.publishStatus("Secure connection unavailable") }
            return
        }
        let params = NWParameters(tls: tlsOptions, tcp: options)
        params.includePeerToPeer = true
        let conn = NWConnection(to: endpoint, using: params)
        transportController.installConnection(conn)
        // A dial to a withdrawn Bonjour service (receiver asleep or app
        // closed) sits in .preparing forever — it neither fails nor resolves
        // when the service later returns, observed on macOS 26. Give every
        // dial a deadline and redial fresh: a new NWConnection re-runs
        // Bonjour resolution, so the retry loop reaches the receiver the
        // moment it advertises again.
        let generation = transportController.currentDialGeneration
        let selfBox = self.selfBox
        queue.asyncAfter(deadline: .now() + 5.0) {
            guard let self = selfBox.currentOnQueue(), generation == self.transportController.currentDialGeneration, !self.stopped,
                  self.transportController.currentConnection === conn, conn.state != .ready else { return }
            Log.info("dial timed out in \(conn.state) — redialing")
            self.scheduleReconnect()
        }
        conn.stateUpdateHandler = { state in
            guard let self = selfBox.currentOnQueue(), self.transportController.currentConnection === conn else { return }
            switch state {
            case .ready:
                self.transportController.becomeReady(conn, transport: self.transport)
            case .failed(let error):
                Log.info("connection failed: \(error)")
                self.invalidateApplicationSession(reason: Self.isTLSFailure(error)
                    ? "certificateRejected" : "connectionFailed")
                if Self.isTLSFailure(error) {
                    self.reportTrustFailure()
                    return
                }
                if case .posix(let code) = error, code == .ECONNREFUSED {
                    self.dialRefused()
                }
                // Dial-phase state: this connection never carried the
                // session, so its failure says nothing about a cable —
                // plain reconnect, under the grace/refusal rules.
                self.scheduleReconnect()
            case .waiting(let error):
                // On loopback there is no "path change" to wake us up again
                // (e.g. the receiver is not up yet) — treat
                // waiting as failure and poll by reconnecting.
                Log.info("connection waiting: \(error) — will retry")
                self.invalidateApplicationSession(reason: Self.isTLSFailure(error)
                    ? "certificateRejected" : "connectionWaiting")
                if Self.isTLSFailure(error) {
                    self.reportTrustFailure()
                    return
                }
                // Read the queue-confined flag here (handler runs on queue),
                // not inside the detached status Task.
                let text = self.awaitingWake
                    ? "\(self.endpointName) is asleep — reconnects when it wakes…"
                    : "Waiting for receiver at \(self.endpointName)…"
                let sink = self.statusSink
                Task { @MainActor in sink.publishStatus(text) }
                self.scheduleReconnect()
            case .cancelled:
                self.invalidateApplicationSession(reason: "connectionCancelled")
            default:
                break
            }
        }
        conn.start(queue: queue)
    }

    private static func isTLSFailure(_ error: NWError) -> Bool {
        if case .tls = error { return true }
        return false
    }

    private func reportTrustFailure() {
        guard !stopped else { return }
        invalidateApplicationSession(reason: "certificateRejected")
        stopped = true
        transportController.cancelConnectionWithoutClearing()
        helloContinuation?.resume(throwing: PairingError.invalidKey)
        helloContinuation = nil
        let selfBox = self.selfBox
        Task { @MainActor in
            guard let self = selfBox.resolve() else { return }
            self.onTrustFailure?("MeowDisplay could not verify this device. Forget it and pair again if its identity was reset.")
        }
    }

    private func invalidateApplicationSession(reason: String) {
        let generation = activeConnectionGeneration
        authenticatedSession.invalidate(generation: generation == 0 ? nil : generation)
        transportController.markNotReady()
        // A same-peer transport migration is not a session end — the
        // stabilization window must survive the redial/re-handshake gap,
        // not release-then-reopen a window during exactly the moment it
        // exists to cover (the new connection's `markApplicationReady`
        // re-arms/extends it once the migration completes). Every other
        // reason here is a genuine failure/disconnect and must still
        // release it.
        if reason != "transportSwitch" {
            wakeStabilizationAssertion?.release()
        }
        Log.info("sessionDebug: invalidated reason=\(reason) generation=\(generation)")
    }

    /// Dial through macOS's built-in usbmuxd — no external tunnel needed —
    /// but treat USB as only a ROUTE to the receiver's existing trusted TLS
    /// media listener, never a separate trust model. `USBTLSBridge` turns
    /// the raw usbmux tunnel into a local loopback endpoint, which is then
    /// dialed through the EXACT SAME `connectTCP`/`TLSConfigurator` path
    /// LAN and Remote already use — no USB-specific cryptography, no
    /// plaintext fallback. The handshake is async, so adoption is gated on
    /// `dialGeneration`; a superseded bridge is explicitly cancelled rather
    /// than left to time out on its own.
    private func connectUSB(udid: String?, tls: TLSSessionConfig) {
        let generation = transportController.bumpDialGeneration()
        activeUSBBridge?.cancel()
        let bridge = USBTLSBridge(udid: udid, queue: queue, dialTunnel: Usbmux.dial)
        activeUSBBridge = bridge
        activeUSBBridgeTLS = tls
        let selfBox = self.selfBox
        Task {
            do {
                let bridgePort = try await bridge.start()
                selfBox.resolve()?.queue.async {
                    guard let self = selfBox.currentOnQueue(),
                          generation == self.transportController.currentDialGeneration, !self.stopped,
                          let tls = self.activeUSBBridgeTLS else {
                        bridge.cancel()
                        return
                    }
                    self.activeUSBBridgeTLS = nil
                    // Reuse connectTCP unmodified: same TLSConfigurator call,
                    // same pin verification, same authenticated-session
                    // machinery LAN/Remote already exercise. `self.transport`
                    // stays `.usb(...)` throughout, so route classification
                    // (`reportRoute`) still reports USB even though this
                    // dial's literal endpoint is the loopback bridge.
                    self.connectTCP(.hostPort(host: "127.0.0.1", port: bridgePort), tls: tls)
                }
            } catch {
                bridge.cancel()
                selfBox.resolve()?.queue.async {
                    guard let self = selfBox.currentOnQueue(),
                          generation == self.transportController.currentDialGeneration, !self.stopped else { return }
                    // Distinct guidance per failure: cable missing vs app
                    // closed. Composed on `queue`: awaitingWake lives there.
                    // No plaintext downgrade on any USB failure — a failed
                    // secure USB attempt only ever leads to a redial of the
                    // same secure USB path (or the controller's own choice
                    // of a different, independently-secure route).
                    let hint: String
                    switch error as? Usbmux.Failure {
                    case .noDevice:
                        hint = "Waiting for a USB device — plug in the iPhone or iPad…"
                    case .refused:
                        self.dialRefused()
                        hint = self.awaitingWake
                            ? "\(self.endpointName) is asleep — reconnects when it wakes…"
                            : "Device found — open the MeowDisplay app on it…"
                    default:
                        Log.info("usb dial failed: \(error)")
                        hint = "USB connection failed: \(error.localizedDescription)"
                    }
                    let sink = self.statusSink
                    Task { @MainActor in sink.publishStatus(hint) }
                    self.scheduleReconnect()
                }
            }
        }
    }

    private func scheduleReconnect(automatic: Bool = true) {
        guard !stopped else { return }
        // Same reasoning as switchTransport/migrate: the connection this
        // session held input on is gone, so nothing may stay held across
        // the reconnect attempt.
        inputInjector?.cancelActiveInput()
        if automatic, !ReconnectPolicy.automaticRetryAllowed(
            autoReconnectEnabled: autoReconnectEnabled, everConnected: everConnected) {
            Log.info("reconnectPolicy: automaticRetry suppressed reason=disabled peer=\(endpointName)")
            reportGone("auto-reconnect disabled — not retrying")
            return
        }
        if everConnected {
            if let since = disconnectedSince {
                if Date().timeIntervalSince(since) > disconnectGraceSeconds {
                    Log.info("connectDebug: lost peer=\(endpointName) reason=graceExpired")
                    reportGone("device gone for >\(Int(disconnectGraceSeconds))s — ending session")
                    return
                }
            } else {
                disconnectedSince = Date()
                Log.info("connectDebug: lost peer=\(endpointName) reason=transportDropped")
                let sink = statusSink
                let text = "Connection lost — retrying for \(Int(disconnectGraceSeconds))s…"
                Task { @MainActor in sink.publishStatus(text) }
            }
        }
        Log.info("connectDebug: automaticRetry peer=\(endpointName)")
        invalidateApplicationSession(reason: "reconnectScheduled")
        let transportPathSink = statusSink
        Task { @MainActor in transportPathSink.publishTransportPath(nil) }
        activeUSBBridge?.cancel()
        activeUSBBridge = nil
        activeUSBBridgeTLS = nil
        // Whatever this session rode is gone; deciding to redial means it is
        // an ordinary reconnecting session now (a stale direct-link flag
        // would let the first dial hiccup end the session via linkDied),
        // bumps the dial generation (a USB dial still in flight must not
        // adopt) and cancels/clears the connection — see
        // MacSenderTransportController.resetForRedial.
        let generation = transportController.resetForRedial()
        pipelineState.setPendingSends(0)
        pipelineState.resetPendingEncodes()
        queue.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            // Generation-guarded so a switchTransport (or another reconnect)
            // that landed in this 1s window supersedes this dial instead of
            // racing it — otherwise the queued connect() re-dials the new
            // transport, briefly running two live connections. (No bare
            // self-rescheduling asyncAfter — the pattern banned in #76.)
            guard let self, generation == self.transportController.currentDialGeneration,
                  !self.stopped else { return }
            self.connect()
        }
    }

    // MARK: - Liveness (ping + watchdog)

    private func schedulePing() {
        let selfBox = self.selfBox
        queue.asyncAfter(deadline: .now() + 2.0) {
            guard let self = selfBox.currentOnQueue(), !self.stopped else { return }
            if self.transportController.isReady {
                // Liveness + send-side health for the phone's overlay.
                let elapsed = Date().timeIntervalSince(self.capWindowStart)
                let capFps = elapsed > 0 ? Int(Double(self.capFrames) / elapsed) : 0
                self.capFrames = 0
                self.capWindowStart = Date()
                let sorted = self.inputLatencies.sorted()
                let inp50 = sorted.isEmpty ? 0 : sorted[sorted.count / 2].rounded()
                let inp95 = sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))].rounded()
                #if DEBUG
                let audioBitrateKbps = self.audioBytesThisWindow * 8 / 1000 / 2   // ~2s window
                let audioSuffix = ",\"audioPkts\":\(self.audioPacketsThisWindow),\"audioKbps\":\(audioBitrateKbps)"
                self.audioPacketsThisWindow = 0
                self.audioBytesThisWindow = 0
                #else
                let audioSuffix = ""
                #endif
                // `encDrops`/`netDrops` are this ~2s window's drops (reset
                // right after being sent), matching the `capFps` shape above
                // — the HUD's `enc↓`/`net↓` want "recent", not a lifetime
                // total that only ever climbs. `drops` (the sum) stays the
                // session-lifetime total for anything relying on that legacy
                // meaning.
                let pingWindowDrops = self.pipelineState.drainPingWindowDrops()
                self.sendJSONFrame("{\"type\":\"ping\",\"drops\":\(self.dropsTotal),\"encDrops\":\(pingWindowDrops.enc),\"netDrops\":\(pingWindowDrops.net),\"pending\":\(self.pipelineState.pendingSendsNow),\"inp50\":\(inp50),\"inp95\":\(inp95),\"capFps\":\(capFps)\(audioSuffix)}")
            }
            self.schedulePing()
        }
    }

    private func scheduleWatchdog() {
        let selfBox = self.selfBox
        queue.asyncAfter(deadline: .now() + 2.0) {
            guard let self = selfBox.currentOnQueue(), !self.stopped else { return }
            if self.transportController.isReady, Date().timeIntervalSince(self.lastReceived) > 5 {
                // A suspended receiver app (user switched apps) goes silent
                // like this while its kernel still accepts redials — the
                // session and display are kept on purpose so the user's
                // window arrangement survives until they come back. Genuine
                // network loss fails the redials and ends via the grace.
                if self.transportController.isDirectLink, case .tcp = self.transport {
                    // Backstop for the viability handler: silence on the
                    // direct cable is an unplug (or a dead peer) — never
                    // redial onto WiFi.
                    self.linkDied("silent for >5s")
                } else {
                    Log.info("watchdog: nothing from the phone for >5s — reconnecting")
                    // Can't tell a backgrounded receiver from a brief stall here
                    // (both go silent while redials still succeed) — hedge.
                    let sink = self.statusSink
                    let text = "\(self.endpointName) is silent — keeping the display (app in background or brief stall)"
                    Task { @MainActor in sink.publishStatus(text) }
                    self.scheduleReconnect()
                }
            }
            // MEDIA DEATH forensics: the phone-silence check above says
            // nothing about OUR write direction — a receiver whose own read
            // loop has wedged (see `StreamReceiver.receive`'s fix for
            // exactly that) keeps ACKing at the TCP level and keeps sending
            // its own control/input traffic (so `lastReceived` stays fresh
            // and this branch never fires) while never draining what we
            // write, until the kernel send buffer fills and every further
            // `sendFramed` queues forever with its completion never called.
            // `connectionReady` and the NWConnection state handler see
            // nothing wrong either — the socket is technically still open.
            // `pendingSends > 0` with no completion in >5s is the signature:
            // treat it exactly like inbound silence, since silently sitting
            // on a wedged writer forever is the "connected but frozen"
            // failure this exists to catch.
            if self.transportController.isReady, self.pipelineState.pendingSendsNow > 0,
               Date().timeIntervalSince(self.lastSendCompletionAt) > 5 {
                if !self.sendStallReported {
                    self.sendStallReported = true
                    Log.info("watchdog: outbound writer stalled — pendingSends=\(self.pipelineState.pendingSendsNow) "
                        + "idle for >5s — reconnecting")
                }
                if self.transportController.isDirectLink, case .tcp = self.transport {
                    self.linkDied("outbound writer stalled")
                } else {
                    self.scheduleReconnect()
                }
            }
            // The disconnect grace is otherwise only evaluated when a dial
            // changes state — a dial stuck in .preparing (withdrawn Bonjour
            // service) would keep a dead session's display up forever.
            // Enforce it from here too, where the clock always ticks.
            if !self.transportController.isReady, self.everConnected,
               let since = self.disconnectedSince,
               Date().timeIntervalSince(since) > self.disconnectGraceSeconds {
                self.reportGone("device gone for >\(Int(self.disconnectGraceSeconds))s — ending session")
            }
            // A reconnect on a static screen produces no capture frames, so
            // the receiver would stay black — replay the last frame as IDR.
            if self.transportController.isReady, self.needsKeyframe,
               Date().timeIntervalSince(self.lastCaptureAt) > 1,
                let pixelBuffer = self.lastPixelBuffer {
                Log.info("static screen after reconnect to \(self.endpointName) — replaying last frame as keyframe")
                self.encode(pixelBuffer, pts: CMClockGetTime(CMClockGetHostTimeClock()),
                            generation: self.captureGenerationNow, connectionGeneration: self.activeConnectionGeneration)
            }
            self.scheduleWatchdog()
        }
    }

    // MARK: - Local cursor echo (Mac -> phone)

    private func startCursorEcho() {
        guard localCursor else { return }
        cursorTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(8))   // 120Hz
        timer.setEventHandler { [weak self] in self?.pollCursorPosition() }
        timer.resume()
        cursorTimer = timer
        scheduleCursorImagePoll()
    }

    /// Sprite changes (arrow ↔ I-beam ↔ resize…) must land fast or the wrong
    /// cursor shows over hot areas — poll at 30Hz on the main thread (NSCursor
    /// is AppKit), hash the raw bitmap, and only PNG-encode + send on change.
    ///
    /// A dedicated timer (cancelled+replaced here, like cursorTimer above) — not
    /// a self-rescheduling asyncAfter chain. Every rebuild re-enters
    /// startCursorEcho, and sleep/wake rebuilds happen often; a recursive chain
    /// guarded only by `stopped` would stack one extra 30Hz main-thread
    /// TIFF-encode loop per rebuild, creeping CPU to ~50% until a restart (#75).
    private func scheduleCursorImagePoll() {
        cursorImageTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 0.033, repeating: .milliseconds(33))
        timer.setEventHandler { [weak self] in
            guard let self, !self.stopped, self.localCursor else { return }
            self.pollCursorImage()
        }
        timer.resume()
        cursorImageTimer = timer
    }

    private func pollCursorPosition() {
        guard transportController.isReady, captureDisplayID != 0,
              let loc = CGEvent(source: nil)?.location else {
            #if DEBUG
            logCursorTraceIfDue(reason: "gated: connectionReady=\(transportController.isReady) captureDisplayID=\(captureDisplayID)")
            #endif
            return
        }
        let bounds = CGDisplayBounds(captureDisplayID)
        guard bounds.width > 0, bounds.height > 0 else {
            #if DEBUG
            logCursorTraceIfDue(reason: "gated: empty display bounds for \(captureDisplayID)")
            #endif
            return
        }
        if bounds.contains(loc) {
            let x = (loc.x - bounds.minX) / bounds.width
            let y = (loc.y - bounds.minY) / bounds.height
            if !lastCursorSent.visible
                || abs(x - lastCursorSent.x) > 0.0004 || abs(y - lastCursorSent.y) > 0.0004 {
                lastCursorSent = (x, y, true)
                sendCursor(String(format: "\"x\":%.4f,\"y\":%.4f,\"v\":1", x, y))
            }
        } else if lastCursorSent.visible {
            lastCursorSent.visible = false
            sendCursor("\"v\":0")
        }
        #if DEBUG
        logCursorTraceIfDue(reason: "polling: loc=\(loc) bounds=\(bounds) visible=\(lastCursorSent.visible) "
            + "localCursor=\(localCursor) hasSprite=\(lastCursorPNGHash != 0)")
        #endif
    }

    #if DEBUG
    private var lastCursorTraceAt = Date.distantPast
    /// Throttled to once every 2s — `pollCursorPosition` runs at 120Hz, and
    /// unthrottled logging at that rate would itself be a performance
    /// regression and would flood the log past usefulness.
    private func logCursorTraceIfDue(reason: String) {
        let now = Date()
        guard now.timeIntervalSince(lastCursorTraceAt) > 2 else { return }
        lastCursorTraceAt = now
        Log.info("cursorTrace: \(reason)")
    }
    #endif

    /// Cursor position over the authenticated main transport. The sequence
    /// lets the receiver drop reordered frames (e.g. around a path switch).
    private func sendCursor(_ fields: String) {
        cursorSeq &+= 1
        sendJSONFrame("{\"type\":\"cursor\",\(fields),\"s\":\(cursorSeq)}")
    }

    private static let maxCursorPNGBytes = 24_000

    private func pollCursorImage() {
        // Display size read LIVE, not snapshotted at capture start: the
        // HiDPI mode settles (and macOS re-flips it) asynchronously, and a
        // sprite normalized against the 1x size renders at half size on the
        // device. Mixing the size into the dedup hash re-sends the sprite
        // whenever the mode flips, so the proportion always heals.
        // CR2 fix: this timer fires on `.main` (NSCursor is AppKit — see the
        // doc comment above), never on `queue`, so `transportController.
        // isReady` cannot be read here — it would trip the controller's
        // on-queue `dispatchPrecondition` from the wrong thread, exactly
        // like the `setupEncoder`/`sendStreamCodecState` crash this whole
        // fix addresses. Readiness is instead enforced where the frame is
        // actually sent: `sendCursor`/`sendJSONFrame` already hop onto
        // `queue` via `sendFromAnyContext` and silently no-op there if the
        // connection isn't ready, exactly as this early gate used to.
        // Skipping this check only means an occasional wasted sprite
        // encode while disconnected — `transportSessionBecameReady` resets
        // `lastCursorPNGHash` to 0 on every reconnect, so the fresh peer
        // still gets a sprite the moment it's ready.
        guard captureDisplayID != 0,
              let cursor = NSCursor.currentSystem else {
            #if DEBUG
            logCursorTraceIfDue(reason: "cursorImg gated: captureDisplayID=\(captureDisplayID) "
                + "currentSystem=\(NSCursor.currentSystem != nil)")
            #endif
            return
        }
        let displaySize = CGDisplayBounds(captureDisplayID).size   // points, current mode
        guard displaySize.width > 0, displaySize.height > 0 else { return }
        let image = cursor.image
        guard let tiff = image.tiffRepresentation else {
            #if DEBUG
            Log.info("cursorTrace: cursorImg dropped — no tiffRepresentation for system cursor \(image.size)")
            #endif
            return
        }
        let hash = tiff.hashValue ^ Int(displaySize.width) &* 31
        guard hash != lastCursorPNGHash else { return }
        guard var png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
            #if DEBUG
            Log.info("cursorTrace: cursorImg dropped — could not build a PNG representation")
            #endif
            return
        }
        // A larger system cursor (bumped Accessibility pointer size, a
        // custom high-res bitmap) can exceed the size cap — downscale
        // rather than silently dropping the sprite outright. The receiver
        // stretches `contents` to whatever bounds it computes from `nw`/
        // `nh` below, which stay derived from the ORIGINAL `image.size`, so
        // shrinking only the PNG's own pixels here never changes the
        // displayed size or hotspot math.
        if png.count >= Self.maxCursorPNGBytes,
           let downscaled = Self.downscaledCursorPNG(image: image, maxDimension: 96) {
            png = downscaled
        }
        guard png.count < Self.maxCursorPNGBytes else {
            #if DEBUG
            Log.info("cursorTrace: cursorImg dropped — PNG still \(png.count) bytes after downscaling")
            #endif
            return
        }
        lastCursorPNGHash = hash
        let size = image.size            // Mac points
        let hot = cursor.hotSpot
        // Normalized against the display so the phone can size/anchor the
        // sprite without knowing capture scale or HiDPI factor.
        let msg = String(format:
            "{\"type\":\"cursorImg\",\"nw\":%.5f,\"nh\":%.5f,\"ax\":%.3f,\"ay\":%.3f,\"png\":\"%@\"}",
            size.width / displaySize.width,
            size.height / displaySize.height,
            size.width > 0 ? hot.x / size.width : 0,
            size.height > 0 ? hot.y / size.height : 0,
            png.base64EncodedString())
        let selfBox = self.selfBox
        queue.async { selfBox.currentOnQueue()?.sendJSONFrame(msg) }
        #if DEBUG
        logCursorTraceIfDue(reason: "cursorImg sent: \(png.count) bytes size=\(size) hot=\(hot)")
        #endif
    }

    /// Re-renders `image` into a smaller bitmap, preserving aspect ratio, so
    /// an oversized system cursor bitmap still produces a PNG under the wire
    /// size cap instead of never sending a sprite at all. Returns `nil` if
    /// the image is already within `maxDimension` (nothing to do) or the
    /// re-render fails.
    private static func downscaledCursorPNG(image: NSImage, maxDimension: CGFloat) -> Data? {
        guard image.size.width > 0, image.size.height > 0 else { return nil }
        let scale = maxDimension / max(image.size.width, image.size.height)
        guard scale < 1 else { return nil }
        let targetSize = NSSize(width: max(1, image.size.width * scale),
                                height: max(1, image.size.height * scale))
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(targetSize.width), pixelsHigh: Int(targetSize.height),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.current = context
        image.draw(in: NSRect(origin: .zero, size: targetSize),
                  from: .zero, operation: .copy, fraction: 1)
        return rep.representation(using: .png, properties: [:])
    }

    // MARK: - Control messages (phone -> Mac)

    private func receiveControl(on conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] data, _, _, error in
            guard let self, self.transportController.currentConnection === conn,
                  error == nil, let data, data.count == 4 else {
                if let error {
                    Log.info("control receive ended: \(error)")
                    // A receive error on the live connection is fatal to it.
                    // Route through linkDied so a cable session ends instead
                    // of silently waiting for the watchdog to redial. Skip
                    // ECANCELED: that is our own cancel (stop, migrate,
                    // redial), not the link dying.
                    var isOwnCancel = false
                    if case .posix(let code) = error, code == .ECANCELED { isOwnCancel = true }
                    if let self, self.transportController.currentConnection === conn, !isOwnCancel {
                        self.linkDied("receive failed: \(error)")
                    }
                } else if let self, self.transportController.currentConnection === conn {
                    Log.info("control receive ended: EOF")
                    self.invalidateApplicationSession(reason: "controlEOF")
                    self.linkDied("control EOF")
                }
                return
            }
            let len = Int(UInt32(bigEndian: data.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }))
            guard len > 0, len < 1 << 20 else { return }
            conn.receive(minimumIncompleteLength: len, maximumLength: len) { [weak self] payload, _, _, error in
                guard let self, self.transportController.currentConnection === conn,
                      error == nil, let payload, payload.count == len else {
                    if let self, self.transportController.currentConnection === conn {
                        Log.info("control payload receive ended: \(error.map(String.init(describing:)) ?? "EOF")")
                        self.invalidateApplicationSession(reason: error == nil ? "controlEOF" : "controlReceiveFailed")
                        self.linkDied("control receive ended")
                    }
                    return
                }
                self.handleControl(payload, from: conn)
                self.receiveControl(on: conn)
            }
        }
    }

    private func handleControl(_ payload: Data, from conn: NWConnection) {
        guard transportController.currentConnection === conn else { return }
        lastReceived = Date()
        guard let obj = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let type = obj["type"] as? String else {
            handleUnparseableControlLogAction(
                unparseableControlLogPolicy.record(
                    payload.count,
                    at: ProcessInfo.processInfo.systemUptime
                )
            )
            return
        }
        switch type {
        case "ping":
            // Echo with our clock so the phone can estimate the offset
            // (NTP-style) and compute true end-to-end frame latency.
            if let t = obj["t"] as? Double {
                let mt = Date().timeIntervalSince1970 * 1000
                sendJSONFrame("{\"type\":\"pong\",\"t\":\(t),\"mt\":\(mt)}")
            }
        case "stats":
            // Aggregated pipeline health measured on the phone — logged here
            // so one file holds both ends of the story.
            if let json = try? JSONSerialization.data(withJSONObject: obj),
               let line = String(data: json, encoding: .utf8) {
                let thisWindowDrops = pipelineState.drainThisWindowDrops()
                Log.info("PHONE-STATS \(line) | mac enc↓=\(thisWindowDrops.enc) net↓=\(thisWindowDrops.net) pending=\(pipelineState.pendingSendsNow)")
            }
        case "hello":
            if let info = try? JSONDecoder().decode(PhoneInfo.self, from: payload) {
                let authenticatedSPKI: Data? = {
                    guard let conn = transportController.currentConnection,
                          let metadata = conn.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata else { return nil }
                    var result: Data?
                    sec_protocol_metadata_access_peer_certificate_chain(metadata.securityProtocolMetadata) { certificate in
                        guard result == nil else { return }
                        let secCert = sec_certificate_copy_ref(certificate).takeRetainedValue()
                        guard let key = SecCertificateCopyKey(secCert),
                              let x963 = SecKeyCopyExternalRepresentation(key, nil) as Data?,
                              let pub = try? P256.Signing.PublicKey(x963Representation: x963) else { return }
                        result = pub.derRepresentation
                    }
                    return result
                }()
                if case .tcp(_, let tls) = transport,
                   !SenderApplicationAuthorization.isAllowed(
                       intendedPeerID: tls.peerID, authenticatedPeerID: info.id ?? "",
                       authenticatedSPKI: authenticatedSPKI,
                       currentPinnedSPKI: TrustStore.shared.pin(peerID: tls.peerID)) {
                    Log.info("SECURITY: current trust no longer authorizes application session")
                    invalidateApplicationSession(reason: "trustRevokedOrChanged")
                    stopped = true
                    transportController.cancelConnectionWithoutClearing()
                    let selfBox = self.selfBox
                    Task { @MainActor in
                        guard let self = selfBox.resolve() else { return }
                        self.onTrustFailure?("This device is no longer trusted. Pair it again if needed.")
                    }
                    return
                }
                if case .tcp(_, let tls) = transport, info.id != tls.peerID {
                    Log.info("SECURITY: authenticated key claimed unexpected peer id")
                    invalidateApplicationSession(reason: "applicationIdentityMismatch")
                    stopped = true
                    transportController.cancelConnectionWithoutClearing()
                    let selfBox = self.selfBox
                    Task { @MainActor in
                        guard let self = selfBox.resolve() else { return }
                        self.onTrustFailure?("Device identity changed. Forget the device and pair again if you intentionally reset it.")
                    }
                    return
                }
                let generation = activeConnectionGeneration
                guard authenticatedSession.markApplicationReady(generation: generation) else {
                    Log.info("sessionDebug: ignored stale application handshake generation=\(generation)")
                    return
                }
                everConnected = true
                awaitingWake = false
                disconnectedSince = nil
                Log.info("sessionDebug: applicationReady generation=\(generation)")
                // Pinned mutual-TLS (checked above) + this application
                // handshake together are exactly "the expected paired peer
                // is authenticated" for every route — arm the same bounded
                // stabilization window Remote previously got alone.
                armSessionStabilizationIfNeeded(generation: generation)
                let sink = self.statusSink
                Task { @MainActor in sink.publishStatus("Connected") }
                let previous = lastHello
                lastHello = info
                // Receiver-enforced max FPS (PART 3): load this peer's own
                // stored preference the first time it's known, same
                // convention as Extend shape — a live `maxFPSRequest` (or
                // the Mac's own per-device picker) takes over from here.
                if previous == nil, let peerID = info.id,
                   let stored = ReceiverMaxFPSStore.load(peerID: peerID) {
                    receiverMaxFPSPreference = stored
                    let sink = self.statusSink
                    Task { @MainActor in sink.publishMaxFPSChanged(stored) }
                }
                // A fresh dial classifies before the hello names the device —
                // now that it has, decide again (see the comment on the func).
                if let conn = transportController.currentConnection {
                    transportController.refreshDirectLinkClassification(
                        for: conn, transport: transport, peerDevice: lastHello?.device)
                }
                let helloSelfBox = self.selfBox
                Task { @MainActor in
                    guard let self = helloSelfBox.resolve() else { return }
                    self.onHello?(info)
                }
                let addrs = info.addrs ?? []
                if addrs != peerAddrs {
                    let firstHello = peerAddrs.isEmpty
                    peerAddrs = addrs
                    // A re-hello with a changed address set usually means a
                    // cable was just plugged — probe now, not in up to 10s,
                    // and cancel any stale round still in flight.
                    if transportController.isUpgradeProbingActive, !firstHello {
                        Log.info("receiver addrs changed (\(addrs.count)) — probing cable paths now")
                        transportController.probeForCablePath(transport: transport, peerAddrs: addrs, force: true)
                    }
                }
                // Version handshake (issue #132). Reply with our identity, and
                // if the receiver is below the version we support, tell it to
                // update. Both are additive: older receivers ignore unknown
                // message types. Sending on every hello is idempotent — the
                // phone dedupes by content.
                sendWelcome()
                sendStreamingProfileState()
                sendStreamingPriorityState()
                sendWakeInfo()
                sendDisplayModeState()
                sendMaxFPSState()
                // Re-confirm whatever codec is ALREADY active (`activeCodec`,
                // last set by `setupEncoder`) on every hello — same
                // re-sent-on-every-hello pattern as the state messages
                // above, and internally gated on `info.codecs != nil`
                // exactly like `setupEncoder`'s own call. Deliberately NOT a
                // fresh `selectCodec`/Auto recomputation: a reconnect or
                // route migration (new TCP connection, no dimension/FPS
                // change) never re-runs `setupEncoder`, so the encoder
                // simply keeps running whatever codec it already had — but
                // the RECEIVER's own `receivedStreamCodec` only lives in
                // that StreamReceiver instance's memory, defaulting back to
                // `.h264` if the receiver app/process restarted while the
                // Mac's encoder stayed on HEVC. Without this resend, the
                // receiver would misclassify the next HEVC keyframe's
                // VPS/SPS/PPS using H.264's `&0x1F` NAL-type space.
                sendStreamCodecState()
                if info.protocolVersion >= WireProtocol.mirrorDisplayWireVersion {
                    sendMirrorDisplayState()
                }
                if info.protocolVersion >= WireProtocol.videoControlWireVersion {
                    applyVideoEnabled(desiredVideoEnabled)
                } else {
                    applyVideoEnabled(true)
                }
                // Audio has no legacy fallback (like keyboard, unlike
                // pointer/pencil): below `audioWireVersion` it just stays
                // off, and the receiver never sends `audioRequest` to ask.
                sendAudioState()
                if info.protocolVersion < WireProtocol.minSupportedPeer {
                    Log.info("receiver protocol \(info.protocolVersion) below supported \(WireProtocol.minSupportedPeer) — requesting update")
                    sendUpdateRequired(kind: info.kind)
                }
                if let continuation = helloContinuation {
                    helloContinuation = nil
                    continuation.resume(returning: ApplicationReadySession(
                        info: info, generation: generation))
                } else if mode == .extend, virtualDisplay != nil, let previous,
                          previous.pixelsWide != info.pixelsWide
                          || previous.pixelsHigh != info.pixelsHigh {
                    // Phone rotated — rebuild after a short debounce so a
                    // flurry of orientation flips settles into one rebuild.
                    let rotationSelfBox = self.selfBox
                    Task {
                        try? await Task.sleep(for: .milliseconds(300))
                        guard let self = rotationSelfBox.resolve(),
                              let current = self.lastHello,
                              current.pixelsWide == info.pixelsWide,
                              current.pixelsHigh == info.pixelsHigh else { return }
                        await self.reconfigure(info)
                    }
                }
            }
        case "touch":
            guard receiverInputIsAllowed() else { return }
            if let phase = obj["phase"] as? String,
               let x = obj["x"] as? Double,
               let y = obj["y"] as? Double {
                inputInjector?.handleTouch(phase: phase, x: x, y: y)
                if let t = obj["t"] as? Double {
                    let delta = Date().timeIntervalSince1970 * 1000 - t
                    if delta > -50, delta < 1000 {
                        inputLatencies.append(max(delta, 0))
                        if inputLatencies.count > 240 { inputLatencies.removeFirst(120) }
                    }
                }
            }
        case "scroll":
            guard receiverInputIsAllowed() else { return }
            if let dx = obj["dx"] as? Double, let dy = obj["dy"] as? Double {
                inputInjector?.handleScroll(dx: dx, dy: dy)
            }
        case "pointer":
            // M7: absolute/relative cursor movement decoupled from button
            // state, plus explicit left/right down/up with click counts.
            guard receiverInputIsAllowed(), let action = obj["action"] as? String else { return }
            switch action {
            case "move":
                if let x = obj["x"] as? Double, let y = obj["y"] as? Double {
                    inputInjector?.handlePointerMove(x: x, y: y)
                }
            case "moveRelative":
                if let dx = obj["dx"] as? Double, let dy = obj["dy"] as? Double {
                    inputInjector?.handlePointerMoveRelative(dx: dx, dy: dy)
                }
            case "down":
                if let button = PointerButton.parse(obj["button"]) {
                    inputInjector?.handlePointerDown(button: button, clickCount: obj["clickCount"] as? Int ?? 1)
                }
            case "up":
                if let button = PointerButton.parse(obj["button"]) {
                    inputInjector?.handlePointerUp(button: button, clickCount: obj["clickCount"] as? Int ?? 1)
                }
            default:
                break   // unknown pointer action from a newer peer — ignore
            }
        case "pencil":
            guard receiverInputIsAllowed() else { return }
            if let phase = obj["phase"] as? String,
               let x = obj["x"] as? Double,
               let y = obj["y"] as? Double {
                inputInjector?.handlePencil(
                    phase: phase, x: x, y: y,
                    pressure: obj["pressure"] as? Double ?? 0,
                    azimuth: obj["azimuth"] as? Double ?? 0,
                    altitude: obj["altitude"] as? Double ?? (.pi / 2),
                    rotation: obj["rotation"] as? Double ?? 0)
                if let t = obj["t"] as? Double {
                    let delta = Date().timeIntervalSince1970 * 1000 - t
                    if delta > -50, delta < 1000 {
                        inputLatencies.append(max(delta, 0))
                        if inputLatencies.count > 240 { inputLatencies.removeFirst(120) }
                    }
                }
            }
        case "proximity":
            guard receiverInputIsAllowed() else { return }
            if let entering = obj["entering"] as? Bool,
               let x = obj["x"] as? Double,
               let y = obj["y"] as? Double {
                inputInjector?.handleProximity(entering: entering, x: x, y: y)
            }
        case "keyboard":
            // M4: stricter than touch/pencil/proximity — keyboard requires
            // the capture lifecycle to be fully running, not merely
            // "recovering" (see receiverKeyboardInputIsAllowed), on top of
            // the usual Allow Input requirement.
            guard receiverKeyboardInputIsAllowed(), let action = obj["action"] as? String else { return }
            switch action {
            case "text":
                if let text = obj["text"] as? String {
                    inputInjector?.handleKeyboardText(text)
                }
            case "press":
                if let usage = HIDKeyUsage.parse(obj["usage"]) {
                    #if DEBUG
                    if usage == .deleteOrBackspace {
                        Log.info("keyboardDebug: specialPress received usage=42")
                    }
                    #endif
                    inputInjector?.handleKeyboardPress(
                        usage, modifiers: obj["modifiers"] as? [String] ?? [])
                }
            case "down":
                if let usage = HIDKeyUsage.parse(obj["usage"]) {
                    inputInjector?.handleKeyboardDown(usage: usage, modifiers: obj["modifiers"] as? [String] ?? [])
                }
            case "up":
                if let usage = HIDKeyUsage.parse(obj["usage"]) {
                    inputInjector?.handleKeyboardUp(usage: usage, modifiers: obj["modifiers"] as? [String] ?? [])
                }
            case "modifierDown", "modifierUp":
                if let name = obj["modifier"] as? String {
                    inputInjector?.handleModifier(name: name, down: action == "modifierDown")
                }
            case "cancel":
                inputInjector?.cancelActiveInput()
            default:
                break   // unknown keyboard action from a newer peer — ignore
            }
        case WireMessage.displayModeRequest:
            guard let info = lastHello,
                  info.protocolVersion >= WireProtocol.displayModeWireVersion,
                  let rawMode = obj["mode"] as? String,
                  let requestedMode = ReceiverDisplayMode(rawValue: rawMode) else { return }
            guard desiredVideoEnabled || requestedMode == .mirror else {
                sendDisplayModeState()
                return
            }
            inputInjector?.cancelActiveInput()
            sendJSONObject(["type": WireMessage.inputReset])
            if requestedMode == mode.receiverMode {
                sendDisplayModeState()
            } else {
                let displayModeSelfBox = self.selfBox
                Task { @MainActor in
                    guard let self = displayModeSelfBox.resolve() else { return }
                    self.onDisplayModeRequest?(requestedMode)
                }
            }
        case WireMessage.allowInputRequest:
            guard let info = lastHello,
                  info.protocolVersion >= WireProtocol.allowInputWireVersion,
                  let requested = obj["allowed"] as? Bool else { return }
            if requested {
                if sessionInputGrant.get() {
                    // Already granted — just re-confirm, covering a
                    // receiver that missed an earlier push (e.g. it
                    // connected mid-flight).
                    sendAllowInputState()
                } else {
                    // NEVER auto-grants here: only `SenderController.
                    // handleInputControlRequested` decides (policy lookup +
                    // Mac prompt), keeping the Mac authoritative and this
                    // session's grant independent of every other session's.
                    let allowInputSelfBox = self.selfBox
                    Task { @MainActor in
                        guard let self = allowInputSelfBox.resolve() else { return }
                        self.onAllowInputRequest?(true)
                    }
                }
            } else {
                // Releasing this session's own grant is always safe/
                // immediate — narrowing never needs a decision.
                denySessionInput(state: .off)
            }
        case WireMessage.videoRequest:
            guard let info = lastHello,
                  info.protocolVersion >= WireProtocol.videoControlWireVersion,
                  let requested = obj["enabled"] as? Bool else { return }
            if requested == desiredVideoEnabled {
                applyVideoEnabled(requested)
            } else {
                let videoEnabledSelfBox = self.selfBox
                Task { @MainActor in
                    guard let self = videoEnabledSelfBox.resolve() else { return }
                    self.onVideoEnabledRequest?(requested)
                }
            }
        case WireMessage.streamingProfileRequest:
            guard let info = lastHello,
                  info.protocolVersion >= WireProtocol.version,
                  let raw = obj["profile"] as? String,
                  let profile = StreamingProfile(rawValue: raw) else { return }
            let custom = (obj["customFrameRate"] as? String).flatMap(CustomFrameRateSelection.init(rawValue:)) ?? .auto
            let streamingProfileSelfBox = self.selfBox
            Task { @MainActor in
                guard let self = streamingProfileSelfBox.resolve() else { return }
                self.onStreamingProfileRequest?(profile, custom)
            }
        case WireMessage.streamingPriorityRequest:
            guard let info = lastHello,
                  info.protocolVersion >= WireProtocol.streamingPriorityWireVersion,
                  let raw = obj["priority"] as? String,
                  let priority = StreamingPriority(rawValue: raw) else { return }
            let streamingPrioritySelfBox = self.selfBox
            Task { @MainActor in
                guard let self = streamingPrioritySelfBox.resolve() else { return }
                self.onStreamingPriorityRequest?(priority)
            }
        case WireMessage.mirrorDisplayRequest:
            // Same construction as `promoteInteractiveWake` above: this only
            // ever runs on data read off an already pinned-TLS/loopback
            // `connection`, so it is authenticated by construction.
            guard let info = lastHello,
                  info.protocolVersion >= WireProtocol.mirrorDisplayWireVersion else { return }
            let requestedUUID = obj["selectedUUID"] as? String
            let mirrorDisplaySelfBox = self.selfBox
            Task { @MainActor in
                guard let self = mirrorDisplaySelfBox.resolve() else { return }
                self.onMirrorDisplayRequest?(requestedUUID)
            }
        case WireMessage.extendShapeRequest:
            // Same construction as `mirrorDisplayRequest` above: only ever
            // read off an already-authenticated `connection`.
            guard let info = lastHello,
                  info.protocolVersion >= WireProtocol.extendShapeWireVersion,
                  let preference = ExtendDisplayShapePreference(message: obj) else { return }
            applyExtendShape(preference, info: info)
        case WireMessage.maxFPSRequest:
            // Same construction as `extendShapeRequest` above: only ever
            // read off an already-authenticated `connection`.
            guard let info = lastHello,
                  info.protocolVersion >= WireProtocol.maxFPSWireVersion,
                  let preference = ReceiverMaxFPSPreference(message: obj) else { return }
            applyMaxFPS(preference, info: info)
        case WireMessage.promoteInteractiveWake:
            // `handleControl` only ever runs on data read off `connection`,
            // which for wireless media is always the pinned-mutual-TLS
            // secure transport (TLSConfigurator) and for USB is loopback —
            // there is no other path into this switch, so this is already
            // gated to an authenticated session by construction.
            let peerID = lastHello?.id ?? "unknown"
            Log.info("wakeDebug: remote promoteInteractiveWake requested")
            Log.info("wakeDebug: peerID=\(peerID)")
            Log.info("wakeDebug: userActivityType=remote")
            let attempt = InteractiveWakePromotion.promote()
            var result: [String: Any] = ["type": WireMessage.promoteInteractiveWakeResult]
            if attempt.result == kIOReturnSuccess, let assertionID = attempt.assertionID {
                result["success"] = true
                result["assertionID"] = Int(assertionID)
                // Only after a successful Promote — see
                // WakeStabilizationAssertion's doc comment for why this is a
                // separate, longer hold from the one-shot declaration above.
                if wakeStabilizationAssertion == nil { wakeStabilizationAssertion = WakeStabilizationAssertion() }
                wakeStabilizationAssertion?.begin(generation: activeConnectionGeneration, route: transportController.route?.rawValue)
            } else {
                result["success"] = false
                result["code"] = Int(attempt.result)
            }
            sendJSONObject(result)
        case WireMessage.audioRequest:
            // Per-receiver, unlike Video/Allow Input: no Mac-wide policy to
            // check, so this applies directly rather than bouncing through
            // an app-level callback (SESSION BEHAVIOR — Audio On/Off).
            guard let info = lastHello,
                  info.protocolVersion >= WireProtocol.audioWireVersion,
                  let requested = obj["enabled"] as? Bool else { return }
            applyAudioEnabled(requested)
        case WireMessage.nativeAppGesture:
            guard let info = lastHello,
                  info.protocolVersion >= WireProtocol.nativeAppGestureWireVersion,
                  receiverInputIsAllowed(),
                  let update = NativeAppGestureUpdate(message: obj),
                  nativeAppGestureState.accept(update) else { return }
            // CGEvent can post mouse/keyboard/scroll/tablet events, while
            // AppKit exposes magnification/rotation only as read-only fields
            // on received NSEvents. There is no public cross-process event
            // constructor carrying these payloads/phases. Keep the complete
            // wire lifecycle for a future supported backend, but never fall
            // back to keyboard shortcuts or undocumented event fields.
            if !loggedNativeGestureLimitation {
                loggedNativeGestureLimitation = true
                Log.info("native app magnify/rotate unavailable: macOS has no public cross-process injection API")
            }
        case "gesture":
            guard let name = obj["name"] as? String,
                  let gesture = ReceiverGesture(rawValue: name),
                  receiverInputIsAllowed(),
                  ReceiverGesture.shouldRoute(name: name, inputAllowed: true) else { return }
            // The receiver normally sent a touch cancellation immediately
            // before this semantic message. Release again here as a safeguard
            // against an in-flight or missing cancellation.
            inputInjector?.cancelActiveInput()
            let sessionInputGrant = self.sessionInputGrant
            Task { @MainActor in
                guard EffectiveInputAuthorization.allowed(masterEnabled: InputPolicy.allowsInput(),
                                                           sessionGranted: sessionInputGrant.get()) else { return }
                SystemGestureInvoker.invoke(gesture)
            }
        case "kf":
            // The phone's decoder lost sync (e.g. it attached mid-GOP and
            // periodic keyframes are off) — force an IDR on the next frame.
            Log.info("phone requested keyframe")
            needsKeyframe = true
        case WireMessage.sleeping:
            // The device locked and is about to close on us. Hand the
            // session to the controller right away: it tears the virtual
            // display down (returning the cursor to a visible screen) and
            // starts a wake-waiting replacement session.
            Log.info("receiver went to sleep — ending session, reconnect armed for wake")
            let sleepingSink = statusSink
            Task { @MainActor in sleepingSink.publishPeerSleeping() }
        case WireMessage.closing:
            // The app on the device is quitting for real — end the session
            // without the silence grace and without waiting for a wake.
            Log.info("receiver app closed — ending session")
            let closedSink = statusSink
            Task { @MainActor in closedSink.publishPeerClosed() }
        default:
            // Unknown types are a normal consequence of the additive wire
            // protocol: a newer peer can send messages this build predates.
            // Log each type once per session, never per message. A peer can
            // drive this at input rates (a pencil stroke is ~240 messages/sec),
            // so the policy also caps distinct types and reports that cap once.
            switch unknownTypeLogPolicy.record(type) {
            case .logType(let type):
                Log.info("unknown control message type: \(type) — ignoring (logged once)")
            case .logSuppression(let limit):
                Log.info("additional unknown control message types suppressed after \(limit) distinct types")
            case .none:
                break
            }
        }
    }

    private func waitForHello() async throws -> ApplicationReadySession {
        if let lastHello, let generation = authenticatedSession.liveGeneration {
            return ApplicationReadySession(info: lastHello, generation: generation)
        }
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                if let hello = self.lastHello,
                   let generation = self.authenticatedSession.liveGeneration {
                    continuation.resume(returning: ApplicationReadySession(
                        info: hello, generation: generation))
                } else {
                    self.helloContinuation = continuation
                }
            }
        }
    }

    // MARK: - Encoder setup

    /// Create (and fully configure) the compression session inside
    /// `videoEncoder`, optionally requiring an encoder that supports
    /// low-latency rate control, for the given codec. Every attempt replaces
    /// whatever session was installed before, invalidating it deterministically
    /// — including the three reconfiguration paths (live FPS change, Video
    /// On, encoder-failure-streak recovery) that previously overwrote the
    /// session reference without ever invalidating the session it retired.
    private func createCompressionSession(width: Int, height: Int, fps: Int,
                                          lowLatency: Bool, codec: StreamCodec) -> OSStatus {
        videoEncoder.create(MacSenderVideoEncoder.Configuration(
            width: width, height: height, fps: fps,
            bitrate: quality.bitrate, codec: codec, lowLatency: lowLatency))
    }

    /// Decides the codec for the NEXT `setupEncoder` call, per
    /// `CodecSelectionPolicy` (AUTO POLICY in the HEVC milestone spec).
    /// `EncoderCapability.codecSafeFPS` — H.264's macroblock-rate ceiling —
    /// is what "would H.264 need to reduce the request" means here.
    /// `fps` MUST be the COMMON, non-codec-specific target
    /// (`StreamingFPSPolicy.commonTargetFPS` — decode-ceiling raster is
    /// already applied via `width`/`height`, but NEVER H.264's own
    /// throughput ceiling), never an already-H.264-clamped value: clamping
    /// first and asking Auto second is exactly the bug this doc comment used
    /// to describe as correct and isn't — see `effectiveFPS`'s doc comment.
    /// `effectiveFPS` is the one caller-facing entry point that gets this
    /// right; `setupEncoder`'s own internal call is safe only because every
    /// external caller already routes `fps` through `effectiveFPS` first.
    private func selectCodec(width: Int, height: Int, fps: Int) -> CodecSelectionPolicy.Result {
        let receiverSupportsHEVC = lastHello?.receiverSupportsHEVC ?? false
        let input = CodecSelectionPolicy.Input(
            preference: codecPreference,
            senderSupportsHEVC: Self.senderSupportsHEVC,
            receiverSupportsHEVC: receiverSupportsHEVC,
            requestedWidth: width, requestedHeight: height, requestedFPS: fps)
        return CodecSelectionPolicy.select(input)
    }

    private func setupEncoder(width: Int, height: Int, fps: Int) throws {
        // Low-latency rate control: the hardware encoder emits every frame
        // immediately instead of pipelining. (`-lowlatency NO` for A/B.)
        let lowLatency = UserDefaults.standard.object(forKey: "lowlatency") == nil
            || UserDefaults.standard.bool(forKey: "lowlatency")
        // Mutable: the runtime-HEVC-failure fallback below reduces this to
        // H.264's safe ceiling — `fps` may be an UNCLAMPED common target
        // (HEVC has no throughput ceiling of its own), which would silently
        // recreate the exact throughput failure `EncoderCapability` exists
        // to prevent if reused as-is for the H.264 encoder it falls back to.
        var fps = fps
        let decision = selectCodec(width: width, height: height, fps: fps)
        var codec = decision.codec
        var reason = decision.reason
        // The spec filters which encoder VideoToolbox is allowed to pick, so an
        // unsupported key fails creation outright rather than being ignored the
        // way the properties below are: this key *requires* an encoder that
        // offers the mode, and Macs whose only encoder is AMD have none (#133).
        // Retrying without it is close to free — the guarantees the mode makes
        // (infinite GOP, no reordering, High profile) are all set explicitly
        // below, and the default rate controller only pipelines when it is fed
        // faster than real time, which the pendingEncodes backpressure already
        // prevents. Measured on Apple silicon at a paced 60fps: 5.3ms mean
        // submit→emit without the spec vs 6.1ms with it, 1 frame held either
        // way. (Overfeeding it at ~320fps does queue ~8 frames, hence the cap.)
        var status = createCompressionSession(width: width, height: height, fps: fps, lowLatency: lowLatency, codec: codec)
        var usedFallback = false
        if !videoEncoder.isActive, lowLatency {
            Log.info("VTCompressionSessionCreate failed with low-latency rate control (status \(status)) — retrying without an encoder specification")
            status = createCompressionSession(width: width, height: height, fps: fps, lowLatency: false, codec: codec)
            usedFallback = true
        }
        // Runtime HEVC failure despite advertised/probed capability: recover
        // safely to H.264 rather than throwing and killing the session. This
        // is the ONLY codec fallback that happens post-decision — every
        // other case is decided up front by `CodecSelectionPolicy`.
        if !videoEncoder.isActive, codec == .hevc {
            let safeFPS = EncoderCapability.codecSafeFPS(width: width, height: height)
            Log.info("HEVC encoder creation failed at runtime (status \(status)) despite advertised capability — "
                + "falling back to H.264" + (fps > safeFPS ? " at its safe FPS (\(fps) -> \(safeFPS))" : ""))
            codec = .h264
            reason = CodecSelectionPolicy.Reason.runtimeFallback.rawValue
            usedFallback = false
            // The failed HEVC attempt may have been targeting an FPS that
            // was never clamped to H.264's throughput ceiling (HEVC has
            // none) — reduce it now, or the H.264 encoder we're about to
            // create inherits the same size*fps product that just failed
            // for a different codec.
            fps = min(fps, safeFPS)
            status = createCompressionSession(width: width, height: height, fps: fps, lowLatency: lowLatency, codec: codec)
            if !videoEncoder.isActive, lowLatency {
                status = createCompressionSession(width: width, height: height, fps: fps, lowLatency: false, codec: codec)
                usedFallback = true
            }
        }
        guard videoEncoder.isActive else {
            // Returning here used to leave the session "connected, all green"
            // with a dead encoder and a black receiver. Throw so the failure
            // reaches the UI as a red "Failed:" status.
            Log.info("FATAL: VTCompressionSessionCreate failed (status \(status))")
            throw NSError(domain: "MacSender", code: 4, userInfo: [
                NSLocalizedDescriptionKey:
                    "This Mac's video encoder could not be started (VideoToolbox error \(status))"
            ])
        }
        // Reporting state only (`sendStreamCodecState`, the log line below):
        // `queue`-confined, and no longer read from the VideoToolbox output
        // thread — that thread now gets the codec of the session that
        // actually produced each frame, straight from `videoEncoder`.
        activeCodec = codec
        activeCodecReason = reason
        // Every path that sets a new encode rate goes through here (initial
        // start, resize, live FPS change, encoder-failure recovery) — the
        // single choke point to resync frame ADMISSION to match, so
        // VideoToolbox never actually receives more than `fps` submissions/
        // sec regardless of how fast ScreenCaptureKit delivers frames.
        frameRateLimiter.reconfigure(fps: fps)
        Log.info("receiver codecs: \(lastHello?.codecs?.joined(separator: ", ") ?? "h264") "
            + "codec preference: \(codecPreference.rawValue) effective codec: \(codec.wireValue) reason: \(reason)")
        Log.info("encoder ready: \(width)x\(height)@\(fps) \(codec == .hevc ? "HEVC" : "H.264") \(quality.bitrate / 1_000_000)Mbps quality=\(quality.rawValue) profile=\(streamingProfile.rawValue) lowLatencyRC=\(lowLatency && !usedFallback)\(usedFallback ? " (fallback)" : "")")
        sendStreamCodecState()
    }

    /// PROTOCOL.md 6.9 / `WireProtocol.hevcCodecWireVersion`. Meaningful
    /// regardless of mode, same pattern as `sendExtendShapeState`/
    /// `sendMaxFPSState` — an old receiver simply ignores it and correctly
    /// assumes H.264, the only codec it can ever be sent. Gated on `codecs`
    /// having been sent at all (the capability signal — see `PhoneInfo.
    /// codecs`' doc comment), NOT on overall `pv`: a receiver that
    /// advertises a `pv` below `hevcCodecWireVersion` still fully implements
    /// this message when it sends `codecs` at all.
    private func sendStreamCodecState() {
        guard let info = lastHello, CodecCapabilityProbe.shouldConfirmCodecOnHello(codecs: info.codecs) else { return }
        sendJSONObject(StreamCodecStateUpdate(codec: activeCodec, reason: activeCodecReason).wireFields)
    }

    // MARK: - Capture callback

    func stream(_ stream: SCStream,
                didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard stream === self.stream, CMSampleBufferIsValid(sampleBuffer) else { return }

        switch type {
        case .screen:
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                if wakeCaptureAwaitingFirstFrameGeneration != nil {
                    Log.info("wakeCapture: frameMissingSurface")
                }
                return
            }
            let generation = captureGenerationNow
            if wakeCaptureAwaitingFirstFrameGeneration == generation {
                wakeCaptureAwaitingFirstFrameGeneration = nil
                logWakeCaptureFirstFrame(sampleBuffer: sampleBuffer, pixelBuffer: pixelBuffer)
            }

            lastPixelBuffer = pixelBuffer
            lastCaptureAt = Date()
            capFrames += 1
            #if DEBUG
            debugSCKWindow += 1
            #endif

            #if DEBUG
            // BLACK-VIDEO forensics: answers "did ScreenCaptureKit itself
            // hand us real desktop pixels, or an all-black frame?" for the
            // first few frames of every capture generation (covers both
            // Mirror and Extend — same callback — so the two can be
            // compared directly from the log). Cheap: a sparse ~32x32 grid
            // sample, not a full-frame scan, and capped at 5 frames/generation.
            if debugSCKFrameLogGeneration != generation {
                debugSCKFrameLogGeneration = generation
                debugSCKFrameLogCount = 0
            }
            if debugSCKFrameLogCount < 5 {
                debugSCKFrameLogCount += 1
                let n = debugSCKFrameLogCount
                let w = CVPixelBufferGetWidth(pixelBuffer)
                let h = CVPixelBufferGetHeight(pixelBuffer)
                let luma = Self.debugAverageLuma(pixelBuffer)
                Log.info("extendDebug: SCK frame mode=\(mode.rawValue) gen=\(generation) #\(n) "
                    + "\(w)x\(h) avgLuma=\(luma.map { String(format: "%.1f", $0) } ?? "n/a")")
            }
            #endif

            // No receiver, video off, or a pipeline stage is backed up: skip
            // this frame. Video off never tears down an audio-only stream
            // (see startCapture), so this guard — not stream teardown — is
            // what makes "no encoding, no network video packets" true then.
            guard transportController.isReady, videoEnabled else { return }
            // Rate-gate BEFORE backpressure: SCK's capture headroom means
            // frames can arrive up to ~2x the target rate, and neither
            // `minimumFrameInterval` nor `kVTCompressionPropertyKey_
            // ExpectedFrameRate` stops VideoToolbox from being handed more
            // than the authoritative effective FPS — see `FrameRateLimiter`.
            // A frame the limiter would reject anyway was never going to be
            // encoded, so it must not count as an enc↓/net↓ backpressure
            // drop (that mislabels normal rate-limiting as a stalled
            // pipeline) or arm the drop-replay timer for a frame nobody
            // wanted in the first place.
            guard frameRateLimiter.shouldAdmit(now: ProcessInfo.processInfo.systemUptime) else { return }
            #if DEBUG
            debugAdmittedWindow += 1
            #endif
            if shouldDropFrame(reason: "pending_encode") { return }  // encoder busy
            if shouldDropFrame(reason: "pending_sends") { return }   // TCP send queue full

            encode(pixelBuffer, pts: CMSampleBufferGetPresentationTimeStamp(sampleBuffer), generation: generation, connectionGeneration: activeConnectionGeneration)

        case .audio:
            guard transportController.isReady, audioEnabled else { return }
            let generation = captureGenerationNow
            let audioGen = audioGenerationNow
            let encoder = audioCaptureEncoder
            let boxed = MediaSampleBox(sampleBuffer)
            #if DEBUG
            // `activeAudioIsPCM` was latched for `audioGen` by
            // `beginAudioGeneration` — never re-read live here, so a
            // defaults change mid-generation cannot steer this specific
            // callback's encode down the other codec's path.
            if activeAudioIsPCM {
                Task {
                    guard let packet = await encoder.encodePCM(boxed) else { return }
                    self.queue.async {
                        guard generation == self.captureGenerationNow,
                              audioGen == self.audioGenerationNow,
                              self.audioEnabled else { return }
                        self.sendPCMConfigIfNeeded()
                        self.sendPCMPacket(packet)
                    }
                }
                return
            }
            #endif
            Task {
                let packets = await encoder.encode(boxed)
                guard !packets.isEmpty else { return }
                self.queue.async {
                    guard generation == self.captureGenerationNow,
                          audioGen == self.audioGenerationNow,
                          self.audioEnabled else { return }
                    self.sendAudioConfigIfNeeded()
                    for packet in packets { self.sendAudioPacket(packet) }
                }
            }

        default:
            break
        }
    }

    private func isPipelineBackedUp() -> Bool {
        pipelineState.isBackedUp()
    }

    /// Schedule (or reset) a one-shot replay of `lastPixelBuffer` after drops.
    private func scheduleDropReplayTimer() {
        dropReplayTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .milliseconds(30))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.dropReplayTimer = nil
            self.replayLastFrameAfterDrop()
        }
        timer.resume()
        dropReplayTimer = timer
    }

    private func cancelDropReplayTimer() {
        dropReplayTimer?.cancel()
        dropReplayTimer = nil
    }

    /// Re-encode the most recent pixel buffer once backpressure clears.
    private func replayLastFrameAfterDrop() {
        guard !stopped, transportController.isReady, let pixelBuffer = lastPixelBuffer else { return }
        if isPipelineBackedUp() {
            scheduleDropReplayTimer()
            return
        }
        encode(pixelBuffer, pts: CMClockGetTime(CMClockGetHostTimeClock()),
               generation: captureGenerationNow, connectionGeneration: activeConnectionGeneration)
    }

    /// Drop when encode or send pipeline is busy.
    /// Pre-encode drops are invisible to the decoder — the H.264 reference
    /// chain stays intact, so the next frame can be a normal P-frame (n → n+2).
    /// Do NOT force keyframes here; that causes IDR pulsing / blockiness.
    private func shouldDropFrame(reason: String) -> Bool {
        guard pipelineState.admitFrame(reason: reason) else { return false }
        // Only arm the replay for genuine network backpressure. With
        // `maxPendingEncodes` now a real (>1) pipeline and the
        // FrameRateLimiter already gating admission upstream, an
        // encoder-busy drop here means the next rate-eligible SCK sample —
        // due in a few ms, not 30 — will simply flow through normally once
        // a slot frees. Replaying it too would bypass the limiter and
        // inject an extra, arbitrarily-timed frame outside its cadence.
        // A send-queue drop is different: TCP backpressure on a real link
        // can outlast a frame interval, so proactively retrying once it
        // clears (rather than waiting on the limiter's next tick) still
        // earns its keep recovering from genuine LAN stalls.
        if reason == "pending_sends" {
            scheduleDropReplayTimer()
        }
        return true
    }

    private func encode(_ pixelBuffer: CVPixelBuffer, pts: CMTime, generation: UInt64, connectionGeneration: UInt64) {
        guard generation == captureGenerationNow, videoEncoder.isActive else { return }
        pipelineState.incrementPendingEncodes()
        let capturedAtMs = Int64(Date().timeIntervalSince1970 * 1000)
        // Latched here, on `queue`, and handed to the encoder as an immutable
        // per-submission decision: `needsKeyframe` is streaming/recovery
        // POLICY (reconnect, codec/FPS change, capture restart, recovery, an
        // explicit phone "kf" request), not encoder mechanism, so it stays
        // owned by this class.
        let forceKeyframe = needsKeyframe
        if forceKeyframe { needsKeyframe = false }
        // The completion below runs on VideoToolbox's own callback thread,
        // not `queue` ("sender.video"), so it must not capture non-Sendable
        // `self` directly. Everything it needs off-queue is either an
        // immutable value captured here, or `pipelineState` — the existing
        // `@unchecked Sendable` owner of this pipeline's cross-thread
        // counters/generation state. `selfBox` is resolved only from inside
        // the nested `queue.async` blocks below, which already run on
        // `sender.video` — matching `MacSenderSelfBox.currentOnQueue()`'s
        // documented precondition — for the two operations
        // (`recoverFromEncoderFailureStreak`, `sendFramed`) that genuinely
        // need live `MacSender` state.
        let pipelineState = self.pipelineState
        let queue = self.queue
        let selfBox = self.selfBox
        let submitStatus = videoEncoder.submit(
            pixelBuffer, pts: pts, forceKeyframe: forceKeyframe
        ) { status, buffer, sessionCodec in
            defer { pipelineState.decrementPendingEncodes() }
            guard status == noErr, let buffer else {
                // A session rejecting every frame looks healthy in all other
                // counters — the receiver just stays black. Don't be silent.
                let (logAction, shouldAttemptRecovery) = pipelineState.recordEncodeOutputFailure(
                    status, at: ProcessInfo.processInfo.systemUptime, generation: generation
                )
                MacSender.handleEncodeOutputFailureLogAction(logAction, queue: queue, pipelineState: pipelineState)
                if pipelineState.wakeCaptureAwaitingEncodedFrameGeneration == generation {
                    pipelineState.wakeCaptureAwaitingEncodedFrameGeneration = nil
                    Log.info("wakeCapture: encoderRejectedFirstFrame error=\(status)")
                }
                if shouldAttemptRecovery {
                    queue.async { selfBox.currentOnQueue()?.recoverFromEncoderFailureStreak(generation: generation) }
                }
                return
            }
            pipelineState.recordEncodeSuccess(generation: generation)
            #if DEBUG
            pipelineState.incrementDebugVTCompletedWindow()
            #endif
            guard generation == pipelineState.captureGenerationNow else { return }
            if pipelineState.wakeCaptureAwaitingEncodedFrameGeneration == generation {
                pipelineState.wakeCaptureAwaitingEncodedFrameGeneration = nil
                Log.info("wakeCapture: firstEncodedFrame")
                Log.info("wakeCapture: ready")
            }
            #if DEBUG
            // BLACK-VIDEO forensics (encoder stage): proves VideoToolbox is
            // actually emitting non-trivial output — and whether it's the
            // keyframe/parameter-set-bearing packet a dimension change
            // needs — for the first few encoded frames of every generation.
            let encodeLogNumber = pipelineState.nextDebugEncodeLogNumber(generation: generation)
            if let encodeLogNumber {
                let dims = CMSampleBufferGetFormatDescription(buffer).map { CMVideoFormatDescriptionGetDimensions($0) }
                Log.info("extendDebug: encoder output gen=\(generation) #\(encodeLogNumber) "
                    + "dims=\(dims.map { "\($0.width)x\($0.height)" } ?? "?") "
                    + "bytes=\(CMSampleBufferGetTotalSampleSize(buffer)) keyframe=\(MacSender.isKeyframe(buffer))")
            }
            #endif
            // STALE OUTPUT. `sessionCodec` is nil once the compression
            // session that encoded this frame has been retired — which can
            // happen without `captureGeneration` moving at all, because the
            // live-FPS-change, Video-On and encoder-failure-streak recovery
            // paths all recreate the session in place. Such a frame belongs
            // to a dead reference chain, and packaging it would use the NEW
            // session's codec to read the OLD session's parameter sets
            // (`CodecSelectionPolicy` can flip H.264/HEVC on an FPS change
            // alone). It is a genuine encode success — counted above — but
            // it must never be published as if the current session made it.
            guard let sessionCodec else { return }
            guard let data = MacSender.annexB(from: buffer, codec: sessionCodec) else { return }
            let sndMs = Int64(Date().timeIntervalSince1970 * 1000)
            var framed = Data("{\"cap\":\(capturedAtMs),\"snd\":\(sndMs)}".utf8)
            framed.append(data)
            // The encode above ran asynchronously on VideoToolbox's own
            // callback thread. `activeConnectionGeneration` and `connection`
            // are `queue`-confined, so hop back before touching either — and
            // re-check both the capture AND connection generation there: a
            // live-migrate/reconnect (which bumps `activeConnectionGeneration`
            // via `becomeReady` without rebuilding capture) can complete this
            // encode after the old connection is gone, and this frame must
            // not be delivered onto the new one.
            queue.async {
                guard let self = selfBox.currentOnQueue(),
                      generation == self.captureGenerationNow,
                      connectionGeneration == self.activeConnectionGeneration else { return }
                self.sendFramed(framed)
            }
        }
        if submitStatus == noErr {
            // Encode submission commits this frame to the pipeline; stale in-flight
            // encodes started before a drop won't reach here again, so cancel replay.
            cancelDropReplayTimer()
            #if DEBUG
            pipelineState.incrementDebugVTSubmitted()
            #endif
        } else {
            // A dead encoder session keeps failing, and this runs per frame, so
            // an unthrottled line here is ~60/sec for as long as the problem
            // lasts. Report at most once a second and carry the count: the
            // status code is the diagnosis, the rate is just a number.
            let logAction = pipelineState.recordEncodeSubmitFailure(
                submitStatus, at: ProcessInfo.processInfo.systemUptime
            )
            handleEncodeFailureLogAction(logAction)
        }
    }

    private func handleEncodeFailureLogAction(_ action: ThrottledLogPolicy<OSStatus>.Action) {
        switch action {
        case .report(let report):
            Self.reportEncodeFailures(report)
        case .schedule(let delay):
            // `pipelineState` is the existing Sendable owner of this policy
            // (see MacSenderPipelineState) — captured weakly here instead of
            // `self` so the closure needs no MacSenderSelfBox resolution and
            // still no-ops once nothing else keeps the sender alive.
            queue.asyncAfter(deadline: .now() + delay) { [weak pipelineState] in
                guard let report = pipelineState?.flushEncodeSubmitFailureLog(
                    at: ProcessInfo.processInfo.systemUptime
                ) else { return }
                Self.reportEncodeFailures(report)
            }
        case .none:
            break
        }
    }

    private static func reportEncodeFailures(_ report: ThrottledLogPolicy<OSStatus>.Report) {
        Log.info("VTCompressionSessionEncodeFrame failed: \(report.detail) (\(report.count) since last report)")
    }

    private static func handleEncodeOutputFailureLogAction(
        _ action: ThrottledLogPolicy<OSStatus>.Action, queue: DispatchQueue, pipelineState: MacSenderPipelineState
    ) {
        switch action {
        case .report(let report):
            Self.reportEncodeOutputFailures(report)
        case .schedule(let delay):
            queue.asyncAfter(deadline: .now() + delay) { [weak pipelineState] in
                guard let report = pipelineState?.flushEncodeOutputFailureLog(
                    at: ProcessInfo.processInfo.systemUptime
                ) else { return }
                Self.reportEncodeOutputFailures(report)
            }
        case .none:
            break
        }
    }

    private static func reportEncodeOutputFailures(_ report: ThrottledLogPolicy<OSStatus>.Report) {
        // VideoToolbox can reject a frame with noErr + a nil buffer (e.g.
        // above the H.264 level pixel-rate ceiling) — call that case out.
        let cause = report.detail == noErr ? "nil buffer despite noErr" : "status \(report.detail)"
        Log.info("encoder output rejected: \(cause) (\(report.count) since last report)")
    }

    // Runs on `queue`, where the policy and the control connection both live.
    private func handleUnparseableControlLogAction(_ action: ThrottledLogPolicy<Int>.Action) {
        switch action {
        case .report(let report):
            reportUnparseableControl(report)
        case .schedule(let delay):
            let selfBox = self.selfBox
            queue.asyncAfter(deadline: .now() + delay) {
                selfBox.currentOnQueue()?.flushUnparseableControlLog()
            }
        case .none:
            break
        }
    }

    private func flushUnparseableControlLog() {
        if let report = unparseableControlLogPolicy.flush(at: ProcessInfo.processInfo.systemUptime) {
            reportUnparseableControl(report)
        }
    }

    private func reportUnparseableControl(_ report: ThrottledLogPolicy<Int>.Report) {
        Log.info("unparseable control message (\(report.detail) bytes, \(report.count) since last report)")
    }

    // MARK: - H.264 -> Annex B

    #if DEBUG
    /// BLACK-VIDEO forensics: a cheap, sparse-sampled average luma over a
    /// pixel buffer — never a full-frame scan — to answer "is this frame
    /// actually black?" without the cost/privacy weight of dumping frame
    /// data. Handles the two formats this pipeline ever produces (420v
    /// biplanar, the encoder's native input, and BGRA behind the `-pixfmt`
    /// debug switch); returns `nil` for anything else rather than guessing.
    static func debugAverageLuma(_ pixelBuffer: CVPixelBuffer) -> Double? {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
        var sum = 0.0
        var count = 0
        switch format {
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
            guard let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) else { return nil }
            let stride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
            let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
            let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
            guard width > 0, height > 0 else { return nil }
            let buf = base.assumingMemoryBound(to: UInt8.self)
            let stepX = max(width / 32, 1), stepY = max(height / 32, 1)
            var y = 0
            while y < height {
                var x = 0
                while x < width {
                    sum += Double(buf[y * stride + x])
                    count += 1
                    x += stepX
                }
                y += stepY
            }
        case kCVPixelFormatType_32BGRA:
            guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
            let stride = CVPixelBufferGetBytesPerRow(pixelBuffer)
            let width = CVPixelBufferGetWidth(pixelBuffer)
            let height = CVPixelBufferGetHeight(pixelBuffer)
            guard width > 0, height > 0 else { return nil }
            let buf = base.assumingMemoryBound(to: UInt8.self)
            let stepX = max(width / 32, 1), stepY = max(height / 32, 1)
            var y = 0
            while y < height {
                var x = 0
                while x < width {
                    let o = y * stride + x * 4
                    sum += 0.114 * Double(buf[o]) + 0.587 * Double(buf[o + 1]) + 0.299 * Double(buf[o + 2])
                    count += 1
                    x += stepX
                }
                y += stepY
            }
        default:
            return nil
        }
        guard count > 0 else { return nil }
        return sum / Double(count)
    }
    #endif

    /// `codec` is the codec the compression session that produced `sample`
    /// was configured for — passed in rather than read from `activeCodec`,
    /// which is `queue`-confined while this runs on VideoToolbox's output
    /// thread, and which by then may already describe a newer session.
    private static func annexB(from sample: CMSampleBuffer, codec: StreamCodec) -> Data? {
        guard let block = CMSampleBufferGetDataBuffer(sample) else { return nil }
        var len = 0, total = 0
        var ptr: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0,
                lengthAtOffsetOut: &len, totalLengthOut: &total,
                dataPointerOut: &ptr) == noErr, let ptr else { return nil }

        var out = Data(capacity: total + 128)
        // On keyframes, prepend the codec's parameter sets (they live in the
        // format description): SPS/PPS for H.264, VPS/SPS/PPS for HEVC.
        // Deliberately codec-specific APIs, not shared logic — HEVC's
        // parameter sets are a different count and a different NAL-type
        // space (32/33/34) than H.264's (7/8), and the SUBMITTING session's
        // codec is the authoritative, non-heuristic source of which one this
        // sample is.
        if isKeyframe(sample), let fmt = CMSampleBufferGetFormatDescription(sample) {
            // CoreMedia reports the ACTUAL parameter-set count on
            // `parameterSetCountOut` from the very same call used to fetch
            // each set — query it once at index 0 rather than hardcoding
            // VPS+SPS+PPS=3 / SPS+PPS=2, which assumes VideoToolbox never
            // produces more (or fewer) sets than the common case. Falls
            // back to that historical assumption only if the probe itself
            // fails to report a sane count (e.g. index 0 fetch fails),
            // never silently drops below it.
            var probePtr: UnsafePointer<UInt8>?
            var probeLen = 0
            var reportedCount = 0
            let probeStatus: OSStatus = codec == .hevc
                ? CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                    fmt, parameterSetIndex: 0, parameterSetPointerOut: &probePtr,
                    parameterSetSizeOut: &probeLen, parameterSetCountOut: &reportedCount, nalUnitHeaderLengthOut: nil)
                : CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                    fmt, parameterSetIndex: 0, parameterSetPointerOut: &probePtr,
                    parameterSetSizeOut: &probeLen, parameterSetCountOut: &reportedCount, nalUnitHeaderLengthOut: nil)
            let parameterSetCount = (probeStatus == noErr && reportedCount > 0)
                ? reportedCount : (codec == .hevc ? 3 : 2)   // HEVC: VPS,SPS,PPS. H.264: SPS,PPS.
            for i in 0..<parameterSetCount {
                var psPtr: UnsafePointer<UInt8>?
                var psLen = 0
                let status: OSStatus
                if codec == .hevc {
                    status = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                        fmt, parameterSetIndex: i,
                        parameterSetPointerOut: &psPtr,
                        parameterSetSizeOut: &psLen,
                        parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
                } else {
                    status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                        fmt, parameterSetIndex: i,
                        parameterSetPointerOut: &psPtr,
                        parameterSetSizeOut: &psLen,
                        parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
                }
                if status == noErr, let psPtr {
                    out.append(contentsOf: startCode)
                    out.append(Data(bytes: psPtr, count: psLen))
                }
            }
        }
        // Convert AVCC (4-byte length-prefixed NALUs) to Annex B start codes.
        let raw = UnsafeRawPointer(ptr)
        var offset = 0
        while offset + 4 <= total {
            var nalLen: UInt32 = 0
            memcpy(&nalLen, raw + offset, 4)
            nalLen = CFSwapInt32BigToHost(nalLen)
            offset += 4
            guard offset + Int(nalLen) <= total else { break }
            out.append(contentsOf: startCode)
            out.append(Data(bytes: raw + offset, count: Int(nalLen)))
            offset += Int(nalLen)
        }
        return out
    }

    private static func isKeyframe(_ sample: CMSampleBuffer) -> Bool {
        guard let arr = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false),
              let dict = (arr as? [[CFString: Any]])?.first else { return true }
        return !(dict[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
    }

    // MARK: - Wire framing: [4-byte big-endian length][payload]

    /// Control messages on the video channel (pong etc.) — framed JSON without
    /// start codes; the receiver routes payloads starting with '{'.
    // MARK: - Version handshake (issue #132)

    /// Identify ourselves to the receiver: our protocol version and the oldest
    /// receiver version we still support.
    private func sendWelcome() {
        sendJSONFrame("{\"type\":\"\(WireMessage.welcome)\",\"pv\":\(WireProtocol.version),\"min\":\(WireProtocol.minSupportedPeer)}")
    }

    private func sendStreamingProfileState() {
        sendJSONFrame("{\"type\":\"\(WireMessage.streamingProfileState)\",\"profile\":\"\(streamingProfile.rawValue)\"}")
    }

    private func sendStreamingPriorityState() {
        sendJSONFrame("{\"type\":\"\(WireMessage.streamingPriorityState)\",\"priority\":\"\(streamingPriority.rawValue)\"}")
    }

    /// Best-effort LAN wake hint (Remote Wake-on-LAN foundation): this Mac's
    /// own MAC/interface/broadcast, self-labeled with our own install ID so
    /// the receiver can key its local `WakeMetadataStore` cache. Additive
    /// and non-authoritative like `sendWelcome` — an older receiver ignores
    /// unknown message types, and the label is never used for trust.
    private func sendWakeInfo() {
        guard let metadata = WakeInspector.currentInterfaceWakeMetadata(),
              let peerID = TrustStore.shared.installID() else { return }
        var dict: [String: Any] = [
            "type": WireMessage.wakeInfo,
            "peer": peerID,
            "mac": metadata.macAddress,
            "interface": metadata.interfaceName,
        ]
        if let ipv4 = metadata.ipv4 { dict["ipv4"] = ipv4 }
        if let subnet = metadata.subnetMask { dict["subnet"] = subnet }
        if let broadcast = metadata.broadcastAddress { dict["broadcast"] = broadcast }
        sendJSONObject(dict)
    }

    /// Reports the canonical Mirror capture-source selection (this session's
    /// own `mirrorDisplayUUID`, resolved the same nil-means-Auto way
    /// `startMirrorCaptureUsingPreference` does) plus the Mac's current
    /// display inventory. Mirror-only — Extend always uses MEOW's own
    /// virtual display, so there is nothing to report there. Async because
    /// `SCShareableContent` is: hops back onto `queue` before touching any
    /// sender state or sending, exactly like `runWakeCaptureRecovery` does.
    private func sendMirrorDisplayState() {
        guard mode == .mirror else { return }
        let selfBox = self.selfBox
        Task {
            guard selfBox.resolve() != nil else { return }
            let candidates = await MirrorDisplayCandidate.listCandidates()
            selfBox.resolve()?.queue.async {
                guard let self = selfBox.currentOnQueue(), self.mode == .mirror, !self.stopped else { return }
                let displays = candidates.compactMap { candidate -> [String: Any]? in
                    guard let uuid = candidate.persistentID else { return nil }
                    return [
                        "uuid": uuid, "name": candidate.name, "isMain": candidate.isMain,
                        "logicalWidth": Int(candidate.logicalSize.width),
                        "logicalHeight": Int(candidate.logicalSize.height),
                        "pixelWidth": Int(candidate.pixelSize.width),
                        "pixelHeight": Int(candidate.pixelSize.height),
                        "likelyVirtual": candidate.likelyVirtual,
                    ]
                }
                var dict: [String: Any] = [
                    "type": WireMessage.mirrorDisplayState, "displays": displays,
                ]
                if let mirrorDisplayUUID = self.mirrorDisplayUUID { dict["selectedUUID"] = mirrorDisplayUUID }
                self.sendJSONObject(dict)
            }
        }
    }

    /// A display attaching/detaching must refresh what a connected
    /// receiver's Manual picker offers — `didChangeScreenParametersNotification`
    /// is the same signal `PowerLifecycleLogger` already logs (DEBUG-only,
    /// observation only) for display-topology changes; this reacts to it in
    /// every build, but only ever to re-report the inventory, never to touch
    /// capture itself.
    private func startMirrorDisplayTopologyObserver() {
        guard mirrorDisplayTopologyObserver == nil else { return }
        mirrorDisplayTopologyObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.sendMirrorDisplayState()
            self?.queue.async { self?.topologyChanged(reason: "didChangeScreenParameters") }
        }
    }

    /// Ask the receiver to update (built via JSONSerialization because the
    /// message text is user-facing prose). Dormant while minSupportedPeer is
    /// 1, but the copy must fit the platform the day a floor is raised: a
    /// Mac receiver updates via Sparkle (once MeowDisplay hosts its own
    /// appcast) or the GitHub repo, not the App Store.
    private func sendUpdateRequired(kind: String) {
        let isMac = kind == "Mac"
        let dict: [String: Any] = [
            "type": WireMessage.updateRequired,
            "target": isMac ? "mac" : "ios",
            "store": isMac ? "https://github.com/raiseCatError/MeowDisplay" : AppStore.updateURL.absoluteString,
            "message": isMac
                ? "The MeowDisplay Receiver app on that Mac is too old for this Mac. Use Check for Updates… there to reconnect."
                : "This \(kind) app is too old for this Mac. Update MeowDisplay from the App Store to reconnect.",
        ]
        if let data = try? JSONSerialization.data(withJSONObject: dict),
           let json = String(data: data, encoding: .utf8) {
            sendJSONFrame(json)
        }
    }

    private func sendJSONObject(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let json = String(data: data, encoding: .utf8) else { return }
        sendJSONFrame(json)
    }

    /// CR2 fix: unlike `sendFramed` below (verified — every call site already
    /// runs on `queue`), this is reached from callers that do NOT run on
    /// `queue`, notably ScreenCaptureKit's async setup chain (`start()` →
    /// `startCapture` → `setupEncoder` → `sendStreamCodecState`) and the
    /// main-thread cursor-sprite poll. `sendFromAnyContext` hops onto
    /// `queue` itself when needed instead of this method touching
    /// `currentConnection`/`isReady` directly — see its doc comment.
    private func sendJSONFrame(_ json: String) {
        let payload = Data(json.utf8)
        var header = UInt32(payload.count).bigEndian
        var frame = Data(bytes: &header, count: 4)
        frame.append(payload)
        transportController.sendFromAnyContext(content: frame) { _ in }
    }

    /// `kind` is DEBUG-only telemetry (never sent on the wire): identifies
    /// which media this write carried, so a slow completion can be
    /// attributed to "audio queued behind a video write already in
    /// flight" (TCP head-of-line blocking — PROTOCOL.md 5A implementer
    /// note) rather than guessed at. Video/audio share this single framed
    /// TCP/TLS stream by design (no separate UDP/second connection); this
    /// only measures that choice, it doesn't change it.
    /// CR2 audit: unlike `sendJSONFrame`, every call site of `sendFramed`
    /// (video encode completion, audio/PCM config+packet sends) already runs
    /// inside a `queue.async`/on-queue callback, so reading `currentConnection`/
    /// `isReady` directly here is safe — no change needed.
    private func sendFramed(_ payload: Data, kind: String = "video") {
        guard transportController.currentConnection != nil, transportController.isReady else { return }
        var header = UInt32(payload.count).bigEndian
        var frame = Data(bytes: &header, count: 4)
        frame.append(payload)
        let pendingSendsAfterIncrement = pipelineState.incrementPendingSends()
        #if DEBUG
        let queuedAt = Date()
        let queuedByteCount = frame.count
        debugSendsStartedWindow += 1
        debugPeakPendingSends = max(debugPeakPendingSends, pendingSendsAfterIncrement)
        #endif
        transportController.send(content: frame) { [weak self] error in
            guard let self else { return }
            _ = self.pipelineState.decrementPendingSends()
            self.lastSendCompletionAt = Date()
            self.sendStallReported = false
            if let error {
                Log.info("send error: \(error)")
                return
            }
            self.framesSent += 1
            self.bytesSent += frame.count
            #if DEBUG
            self.debugSendsCompletedWindow += 1
            if kind == "audio" {
                let writeMs = Date().timeIntervalSince(queuedAt) * 1000
                // A normal LAN write completes in low single-digit ms; a
                // multi-KB video keyframe already in flight ahead of this
                // small audio packet is the primary suspect for anything
                // much slower — this is evidence-gathering, not a fix.
                if writeMs > 15 {
                    Log.info("audioTrace: TCP write latency \(String(format: "%.1f", writeMs))ms bytes=\(queuedByteCount) pendingSends=\(self.pipelineState.pendingSendsNow) lastVideoBytes=\(self.lastVideoFrameByteCount)")
                }
            } else {
                self.lastVideoFrameByteCount = queuedByteCount
                self.debugSendTimingsMs.append(Date().timeIntervalSince(queuedAt) * 1000)
            }
            #endif
            // Report stats roughly once a second.
            let elapsed = Date().timeIntervalSince(self.statsWindowStart)
            if elapsed >= 1.0 {
                let mbps = Double(self.bytesSent) * 8 / elapsed / 1_000_000
                let frames = self.framesSent
                self.bytesSent = 0
                self.statsWindowStart = Date()
                let videoActive = self.videoEnabled
                let audioActive = self.audioEnabled
                let width = self.capturePixelsWide
                let height = self.capturePixelsHigh
                let fps = self.captureTargetFPS
                let statsSink = self.statusSink
                Task { @MainActor in
                    statsSink.publishStats(frames: frames, mbps: mbps)
                    statsSink.publishMediaState(videoActive: videoActive, audioActive: audioActive,
                                                 width: width, height: height, fps: fps)
                }
                #if DEBUG
                let vtWindow = self.pipelineState.drainDebugVTWindow()
                let sendTimings = self.debugSendTimingsMs.sorted()
                let sendP50 = sendTimings.isEmpty ? 0 : sendTimings[sendTimings.count / 2]
                let sendP95 = sendTimings.isEmpty ? 0 :
                    sendTimings[min(sendTimings.count - 1, Int(Double(sendTimings.count) * 0.95))]
                let sendMax = sendTimings.last ?? 0
                Log.info("senderPipeline: sck=\(self.debugSCKWindow) admit=\(self.debugAdmittedWindow) "
                    + "vtSub=\(vtWindow.submitted) vtOK=\(vtWindow.completed) "
                    + "encDrop=\(self.pipelineState.dropsEncThisWindow) netDrop=\(self.pipelineState.dropsNetThisWindow) "
                    + "pending=\(self.pipelineState.pendingSendsNow) peakPending=\(self.debugPeakPendingSends) "
                    + "sendStart=\(self.debugSendsStartedWindow) sendOK=\(self.debugSendsCompletedWindow) "
                    + "sendMs(p50=\(String(format: "%.1f", sendP50)) p95=\(String(format: "%.1f", sendP95)) max=\(String(format: "%.1f", sendMax))) "
                    + "frames=\(frames) mbps=\(String(format: "%.2f", mbps))")
                self.debugSCKWindow = 0
                self.debugAdmittedWindow = 0
                self.debugSendsStartedWindow = 0
                self.debugSendsCompletedWindow = 0
                self.debugPeakPendingSends = self.pipelineState.pendingSendsNow
                self.debugSendTimingsMs.removeAll(keepingCapacity: true)
                #endif
            }
        }
    }

    // MARK: - Helpers

    private func status(_ text: String) async {
        let sink = statusSink
        await MainActor.run { sink.publishStatus(text) }
    }

    /// Invalidate the retired ScreenCaptureKit/VideoToolbox callbacks before
    /// changing the display or encoder they feed.
    ///
    /// Deliberately does NOT touch `captureDisplayID`: that field has its own
    /// single lifecycle rule (set once in `startCapture`, right after a
    /// target display is confirmed; cleared explicitly wherever capture
    /// genuinely stops with no immediate restart — `stop()`, a failed
    /// `startCapture`, `pauseDisplay()`). This function runs on every
    /// rebuild — including mid-`startCapture`, before the new display is
    /// fully live — so it must never clear state describing the CURRENT
    /// capture attempt's target; doing so previously left `captureDisplayID`
    /// at 0 for the entire lifetime of every capture session, silently
    /// gating cursor position/image polling (`pollCursorPosition`/
    /// `pollCursorImage` both guard on `captureDisplayID != 0`) even while
    /// capture was healthy and streaming.
    private func invalidateCapturePipeline(discardingLastFrame: Bool = false) {
        pipelineState.bumpCaptureGeneration()
        if discardingLastFrame {
            lastPixelBuffer = nil
            lastCaptureAt = .distantPast
        }
    }
}

// MARK: - MacSenderTransportController delegate (Phase 1 of MT-C1)
//
// Every method here runs synchronously on `queue`, called directly from
// `transportController` (never hopped) — see MacSenderTransportController.swift.
// This is the ONLY place `MacSender` is reached from transport-owned code:
// `transportController` never captures `self` (MacSender) in any closure it
// installs, only `weak var delegate: MacSenderTransportDelegate?`.
extension MacSender: MacSenderTransportDelegate {
    /// The non-transport bookkeeping `becomeReady` used to perform inline,
    /// at the exact point the controller flips `isReady` true and before it
    /// installs the viability/path handlers or begins receiving — same
    /// relative ordering the pre-Phase-1 code had.
    func transportSessionBecameReady(on connection: NWConnection) {
        activeConnectionGeneration = authenticatedSession.beginTransport()
        Log.info("sessionDebug: generation=\(activeConnectionGeneration)")
        Log.info("sessionDebug: tlsReady")
        Log.info("connectDebug: tlsReady peer=\(endpointName)")
        Log.info("connectDebug: authenticated peer=\(endpointName) generation=\(activeConnectionGeneration)")
        Log.info("connectDebug: connected peer=\(endpointName)")
        cursorSeq = 0   // per-session; the receiver rewound its floor with the connection
        consecutiveRefusals = 0
        disconnectedSince = nil
        needsKeyframe = true   // new peer needs SPS/PPS + IDR
        // Keep cached pixels: ScreenCaptureKit stays quiet on a static
        // display, and the watchdog needs them to force the reconnect IDR.
        cancelDropReplayTimer()
        // A reconnect can recreate the phone's video view with no cursor
        // sprite; the sprite is otherwise only sent on shape change, so the
        // cursor would stay invisible until the user hovers something that
        // changes it. Reset the dedup state to re-send sprite + position to
        // the fresh peer — the cursor analogue of forcing a keyframe.
        lastCursorPNGHash = 0
        lastCursorSent = (-1, -1, false)
        lastReceived = Date()  // fresh grace period for the watchdog
        lastSendCompletionAt = Date()   // fresh grace period for the outbound-stall watchdog
        sendStallReported = false
        // A reconnect is also a fresh audio generation — see the FORENSIC
        // FIX note this carried before Phase 1.
        if audioEnabled {
            beginAudioGeneration()
        }
    }

    func transportShouldBeginReceiving(on connection: NWConnection) {
        receiveControl(on: connection)
    }

    func transportPathChanged(_ route: ConnectionRoute?) {
        // The controller already classifies/logs/publishes the route change
        // itself; nothing else currently needs the effect.
    }

    func transportSessionInvalidated(reason: String) {
        invalidateApplicationSession(reason: reason)
    }

    func transportLinkDied(_ detail: String) {
        linkDied(detail)
    }

    func transportCancelActiveInput() {
        inputInjector?.cancelActiveInput()
    }

    func transportPeerDeviceKind() -> String? {
        lastHello?.device
    }

    func transportDialingContext() -> (transport: SenderTransport, peerAddrs: [String]) {
        (transport, peerAddrs)
    }
}
