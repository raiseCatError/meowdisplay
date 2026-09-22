// StreamReceiver — the listening half of MeowDisplay: receive H.264 over
// TCP and display it. Compiled into BOTH targets (see project.yml): it is
// the iOS app's core, and the Mac app's receiver mode (issue #82) reuses it
// unchanged to turn a spare Mac into a display.
//
// Pipeline:  TCP socket -> deframe -> Annex B parse -> CMSampleBuffer
//            -> AVSampleBufferDisplayLayer (decodes + renders)
//
// The receiver LISTENS; the sending Mac connects (required for usbmux/USB).
// Wire protocol: [4-byte big-endian length][Annex B payload].
//
// Keep this file UIKit/AppKit-free — platform specifics (device kind,
// default names, cursor drawing, orientation) are injected by the app layer.

import Foundation
import Network
import AVFoundation
import CoreMedia
import VideoToolbox
import QuartzCore
import ImageIO
import Combine
import Security
import CryptoKit

/// One-second window of pipeline health, plus per-frame timing samples for
/// the performance overlay graph.
struct PerfStats: Equatable {
    var fps = 0
    var mbps = 0.0
    var avgFrameMs = 0.0
    var maxFrameMs = 0.0
    var stalls = 0               // frames that arrived >50ms late (this window)
    var decodeFlushes = 0        // display layer failures since connect
    var samples: [Double] = []   // last ~120 inter-frame intervals, ms
    // True end-to-end latency (Mac capture → phone display handoff), using
    // the clock offset estimated from timestamped ping/pong.
    var e2eP50 = 0.0
    var e2eP95 = 0.0
    var encodeP50 = 0.0          // Mac-side capture→socket (encode + queue)
    var rttMs = 0.0              // control-channel round trip
    var e2eSamples: [Double] = []  // last ~120 per-frame e2e latencies, ms
    var transport = "—"          // USB, AWDL, or LAN from the live NWPath
    var cursorPerSec = 0         // cursor position updates applied (this window)
    var cursorLost = 0           // cursor updates dropped as stale/reordered (this window)
    var macDrops = 0             // enc + net drops, this ~2s ping window
    var macEncDrops = 0          // Mac skipped capture: encoder busy (this ~2s ping window)
    var macNetDrops = 0          // Mac skipped capture: TCP queue full (this ~2s ping window)
    var macPending = 0           // Mac send queue depth right now
    var inputP50 = 0.0           // touch sent → CGEvent injected on the Mac, ms
    var inputP95 = 0.0
    var capFps = 0               // frames ScreenCaptureKit delivered on the Mac
    // Metal renderer path only:
    var decodeP50 = 0.0          // VTDecompressionSession decode, ms
    var photonP50 = 0.0          // Mac capture → frame actually on glass, ms
    var photonP95 = 0.0
}

// MARK: - Peer-driven update signals (issue #132)

/// What the connected (sending) Mac tells us about compatibility. The iOS app
/// feeds this into its VersionGate; the Mac receiver panel shows it inline.
enum PeerUpdateSignal: Equatable {
    case updateReceiver(message: String, storeURL: URL)  // Mac sent `updateRequired`
    case updateMac(message: String)                      // sender's pv is below our floor
}

/// Lock-protected home for `transport`, the display-only route label
/// ("USB"/"AWDL"/"LAN"/"—") shown in the status text and mirrored into
/// `PerfStats`. Every writer (`updateTransport`'s path classification,
/// `clearTransport`'s reset to "—") only ever replaces the whole value —
/// there is no compound invariant across writes, so a plain last-write-wins
/// lock is sufficient and no ordering between writers is required. Same
/// idiom as `FramePipelineSyncState` (`ReceiverFramePipeline.swift`): an
/// `NSLock`-protected value, never an unsynchronized `@Sendable` getter
/// closure reading another isolation domain's state directly.
final class ReceiverTransportState: @unchecked Sendable {
    private let lock = NSLock()
    private var value = "—"

    func set(_ newValue: String) {
        lock.lock(); defer { lock.unlock() }
        value = newValue
    }

    func clear() {
        set("—")
    }

    func get() -> String {
        lock.lock(); defer { lock.unlock() }
        return value
    }
}

/// Lock-protected home for the Hello-owned, queue-confined mirror state:
/// the 11 `announced*` UI/receiver-control preference fields non-Mac hello
/// payloads report (`sendHello`), plus `lastAdvertisedAddrs`, the dedup
/// memory `checkAddressChangeAndSendHello` compares against. Receiver
/// Swift6-Hello-1: introduces this owner only — `StreamReceiver`'s own
/// `announced*`/`lastAdvertisedAddrs` stored properties remain untouched
/// and authoritative, and `sendHello`/`checkAddressChangeAndSendHello` are
/// not modified; nothing here is wired into production yet (Hello-2+).
/// Deliberately excludes `avSyncOffsetMs` (audio-timing domain) and the
/// device-geometry fields (`devicePixelsWide`/`devicePixelsHigh`/
/// `deviceScale`, mutated outside `queue` from `setPanel`/`setNativePanel`/
/// `setOrientation`) — neither is Hello-owned mirror state in the sense
/// this type covers. Same `NSLock`-protected, `@unchecked Sendable` idiom
/// as `ReceiverTransportState` above and `FramePipelineSyncState`
/// (`ReceiverFramePipeline.swift`): a plain last-write-wins lock, no
/// mutable reference ever escapes it, no callback is ever invoked while
/// held. `internal` (not `private`), matching `KeyframeThrottle`'s
/// precedent below, solely so `ReceiverHelloStateTests` can exercise it
/// directly.
final class ReceiverHelloState: @unchecked Sendable {
    /// Immutable, cheap-to-copy snapshot of just the announced preference
    /// fields — no geometry, no audio, no address state. Field types/
    /// defaults mirror `StreamReceiver`'s `announced*` stored properties
    /// exactly (`Shared/StreamReceiver.swift`, near line 239).
    struct Snapshot: Equatable, Sendable {
        var trayEnabled = true
        var keyboardButtonEnabled = true
        var functionTrayEnabled = true
        var inputMode = PointerInputMode.direct
        var trackpadSensitivity = PointerGestureConfig.defaultTrackpadSensitivity
        var hapticsEnabled = true
        var avoidNotch = true
        var pinchTarget = ReceiverGestureTarget.viewport
        var rotateTarget = ReceiverGestureTarget.viewport
        var snapRotation = true
        var appGestureCommands = AppGestureCommands.defaults
    }

    private let lock = NSLock()
    private var current = Snapshot()
    private var lastAdvertisedAddrs: [String] = []

    func snapshot() -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    /// Matches `setReceiverUIPreferencesForHello`'s pair — tray/keyboard
    /// are updated together, never separately.
    func updateTrayAndKeyboard(trayEnabled: Bool, keyboardButtonEnabled: Bool) {
        lock.lock(); defer { lock.unlock() }
        current.trayEnabled = trayEnabled
        current.keyboardButtonEnabled = keyboardButtonEnabled
    }

    /// Matches `announceReceiverPreferences`'s pair — every field it
    /// reports together, minus `avSyncOffsetMs` (excluded, see type doc).
    func updatePreferences(
        functionTrayEnabled: Bool, inputMode: PointerInputMode, trackpadSensitivity: Double,
        hapticsEnabled: Bool, avoidNotch: Bool, pinchTarget: ReceiverGestureTarget,
        rotateTarget: ReceiverGestureTarget, snapRotation: Bool, appGestureCommands: AppGestureCommands
    ) {
        lock.lock(); defer { lock.unlock() }
        current.functionTrayEnabled = functionTrayEnabled
        current.inputMode = inputMode
        current.trackpadSensitivity = trackpadSensitivity
        current.hapticsEnabled = hapticsEnabled
        current.avoidNotch = avoidNotch
        current.pinchTarget = pinchTarget
        current.rotateTarget = rotateTarget
        current.snapRotation = snapRotation
        current.appGestureCommands = appGestureCommands
    }

    /// Matches `checkAddressChangeAndSendHello`'s exact comparison: a plain
    /// order-sensitive `[String]` `!=`, no sorting/normalization.
    func addressesChanged(_ addrs: [String]) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return addrs != lastAdvertisedAddrs
    }

    /// Matches `sendHello`'s exact write: unconditional overwrite at the
    /// end regardless of send success (the pre-existing no-rollback-on-
    /// failure gap is preserved, not fixed), including the empty-list case.
    func recordAdvertisedAddresses(_ addrs: [String]) {
        lock.lock(); defer { lock.unlock() }
        lastAdvertisedAddrs = addrs
    }
}

/// Lock-protected sole authoritative store for the receiver-panel geometry
/// `StreamReceiver` announces in every "hello" (`sendHello`):
/// `devicePixelsWide`/`devicePixelsHigh`/`deviceScale`. These three fields
/// used to be plain unsynchronized `StreamReceiver` stored properties,
/// written on the MainActor from `setNativePanel`/`setPanel`/
/// `setOrientation` (which routes through `setPanel`) while `sendHello` can
/// also fire from the receiver pipeline/address-watch path — so a reader
/// could in principle observe a torn width/height/scale triple mid-write.
/// This owner makes each write and each read atomic under one `NSLock`, the
/// same idiom as `ReceiverHelloState` above and `FramePipelineSyncState`
/// (`ReceiverFramePipeline.swift`): a plain last-write-wins lock, no mutable
/// reference ever escapes it, no callback/send/serialization is ever
/// invoked while held, and no nested lock acquisition. `@unchecked Sendable`
/// is justified solely because the lock fully protects all mutable state.
/// `internal` (not `private`), matching `ReceiverHelloState`'s precedent,
/// solely so tests can exercise it directly.
final class ReceiverDisplayGeometryState: @unchecked Sendable {
    /// Immutable, cheap-to-copy snapshot of the three geometry fields.
    /// Defaults mirror the old `StreamReceiver` stored-property defaults
    /// exactly (0 / 0 / 2).
    struct Snapshot: Sendable, Hashable {
        var pixelsWide = 0
        var pixelsHigh = 0
        var scale: Double = 2
    }

    private let lock = NSLock()
    private var current = Snapshot()

    func snapshot() -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    /// Matches `setNativePanel`'s exact contract: scale updates on every
    /// call, but width/height only seed once — the first call after
    /// dimensions are still at their unset default (0) — and are never
    /// overwritten by a later native-panel report.
    @discardableResult
    func seedNativePanelIfUnset(pixelsWide w: Int, pixelsHigh h: Int, scale: Double) -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        current.scale = scale
        if current.pixelsWide == 0 {
            current.pixelsWide = w
            current.pixelsHigh = h
        }
        return current
    }

    /// Matches `setPanel`'s exact contract: scale always updates; width/
    /// height only update when both are positive and at least one actually
    /// differs from the current value. Returns the resulting snapshot along
    /// with whether the dimensions changed, so the caller can preserve
    /// `setPanel`'s change-gated log/sendHello behavior without a separate
    /// read of the fields it just wrote.
    func update(pixelsWide w: Int, pixelsHigh h: Int, scale: Double) -> (snapshot: Snapshot, dimensionsChanged: Bool) {
        lock.lock(); defer { lock.unlock() }
        current.scale = scale
        guard w > 0, h > 0, w != current.pixelsWide || h != current.pixelsHigh else {
            return (current, false)
        }
        current.pixelsWide = w
        current.pixelsHigh = h
        return (current, true)
    }
}

/// Lock-protected sole authoritative store for the receiver-local manual A/V
/// sync offset (`avSyncOffsetMs`), the user's MANUAL adjustment term only —
/// see `StreamReceiver`'s (now-removed) `avSyncOffsetMs` doc comment for why
/// this is a separate domain from `establishAudioAnchor`'s automatic
/// baseline correction, and from `ClockSyncState`'s network clock estimator
/// (`offsetSamples`/`clockOffsetMs`/`lastRttMs`), which this type does not
/// touch. Written from `announceReceiverPreferences`; read from `sendHello`,
/// `scheduleAudioPacket`, `scheduleDecodedAudio`, `logAudioTimingDiagnostic`,
/// and `presentDecodedSample`'s video-delay calculation — every one of those
/// call sites runs on `StreamReceiver.queue`, so in practice this is
/// write-once-read-many from a single serial queue with no real contention.
/// `@unchecked Sendable` via a plain `NSLock`, same idiom as
/// `ReceiverHelloState`/`ReceiverDisplayGeometryState` above: a queue-
/// confinement-only (lock-free) design was considered, but this type has no
/// practical way to assert/enforce that invariant at its call sites (unlike
/// an actor or a `dispatchPrecondition`-backed check), so per STOP-condition
/// guidance this uses the same proven lock instead of an undocumented bare
/// `Sendable` claim. The lock is uncontended in practice (single writer
/// queue, no callback ever invoked while held) so its cost on the per-frame
/// `presentDecodedSample` read is a single uncontended `NSLock` acquisition
/// — no `Task`, no actor hop, no queue hop, no allocation.
final class AVSyncPreference: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func get() -> Int {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    /// Matches `announceReceiverPreferences`'s exact write: clamp then
    /// overwrite unconditionally.
    func set(_ milliseconds: Int) {
        lock.lock(); defer { lock.unlock() }
        value = AVSyncOffset.clamped(milliseconds)
    }
}

/// Lock-protected sole storage authority for `StreamReceiver.onDecodedFrame`
/// — the app-facing "hand me decoded BGRA buffers" sink, live-reassigned
/// (and nil'd) by `iOS/OpenSidecarPhoneApp.swift` for the lifetime of the
/// receiver. This exists only so `makePresenter()`'s `decodedFrameReady`
/// effect can read the CURRENT callback per frame without capturing `self`
/// — capturing the callback's value at presenter-construction time would be
/// wrong, since the app reassigns it after the presenter already exists (see
/// requirement B/C in the header this type was introduced for). Same
/// `NSLock`-protected, `@unchecked Sendable` idiom as `AVSyncPreference`
/// above: `get()` copies the callback under the lock and returns it, so the
/// caller invokes it AFTER releasing the lock — no callback is ever invoked
/// while `lock` is held.
final class ReceiverDecodedFrameSink: @unchecked Sendable {
    private let lock = NSLock()
    private var callback: ((_ pixelBuffer: CVPixelBuffer, _ captureMs: Double?) -> Void)?

    func get() -> ((_ pixelBuffer: CVPixelBuffer, _ captureMs: Double?) -> Void)? {
        lock.lock(); defer { lock.unlock() }
        return callback
    }

    func set(_ callback: ((_ pixelBuffer: CVPixelBuffer, _ captureMs: Double?) -> Void)?) {
        lock.lock(); defer { lock.unlock() }
        self.callback = callback
    }
}

/// Lock-protected sole authoritative owner of the currently installed TLS
/// media listener's identity — nothing more. It holds no listener policy, no
/// TrustStore/TLSConfigurator material, and constructs no `NWListener.Service`;
/// those stay with `startTLSListener`/`ReceiverAdvertisementState`. Same
/// `NSLock`-protected, `@unchecked Sendable` idiom as `ReceiverTransportState`
/// above: a plain reference swap under the lock, no callback (`cancel()`
/// included) ever invoked while held — `cancelCurrent()` takes the reference
/// out from under the lock first, then cancels after releasing it, matching
/// this file's existing "take under lock, release, then call the framework"
/// convention.
final class TLSListenerState: @unchecked Sendable {
    private let lock = NSLock()
    private var current: NWListener?

    func hasCurrent() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return current != nil
    }

    func currentListener() -> NWListener? {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    func install(_ listener: NWListener) {
        lock.lock(); defer { lock.unlock() }
        current = listener
    }

    /// Exact `===` identity check — no generation token, matching the
    /// original `self.tlsListener === listener` guards verbatim.
    func isCurrent(_ listener: NWListener) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return current === listener
    }

    /// Clears the stored reference only if it is still exactly `listener` —
    /// a stale `.failed` callback for an already-superseded listener must
    /// never clear the newer one. Returns whether it matched/cleared.
    @discardableResult
    func clearIfCurrent(_ listener: NWListener) -> Bool {
        lock.lock()
        let matched = current === listener
        if matched { current = nil }
        lock.unlock()
        return matched
    }

    func cancelCurrent() {
        lock.lock()
        let listener = current
        current = nil
        lock.unlock()
        listener?.cancel()
    }
}

/// Lock-protected sole authoritative owner of the currently installed
/// pairing listener's identity — nothing more. Same shape as
/// `TLSListenerState` above (a plain reference swap under the lock, `===`
/// identity checks, no callback ever invoked while held, external framework
/// cancellation happens after releasing the lock); it holds no pairing
/// protocol state, no `PairingPromptModel`, and no `TrustStore` material —
/// those stay with `startPairingListener`/`pairingPrompt`.
final class PairingListenerState: @unchecked Sendable {
    private let lock = NSLock()
    private var current: NWListener?

    func hasCurrent() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return current != nil
    }

    func install(_ listener: NWListener) {
        lock.lock(); defer { lock.unlock() }
        current = listener
    }

    /// Exact `===` identity check — matches the original
    /// `self.pairingListener === listener` guard verbatim.
    func isCurrent(_ listener: NWListener) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return current === listener
    }

    func currentListener() -> NWListener? {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    func cancelCurrent() {
        lock.lock()
        let listener = current
        current = nil
        lock.unlock()
        listener?.cancel()
    }
}

/// Lock-protected sole authoritative store for `mediaSuppressedForPairing` —
/// whether the TLS media listener must refuse new connections because
/// explicit pairing is in progress. Reads happen on connection admission
/// (once per incoming TLS accept, not per frame) and writes only when
/// pairing starts/finishes, so contention is negligible; same `NSLock`-
/// protected, `@unchecked Sendable` idiom as `ReceiverTransportState` above.
final class PairingSuppressionState: @unchecked Sendable {
    private let lock = NSLock()
    private var suppressed = false

    func isSuppressed() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return suppressed
    }

    func setSuppressed(_ value: Bool) {
        lock.lock(); defer { lock.unlock() }
        suppressed = value
    }
}

/// Lock-protected sole authoritative store for the receiver's Bonjour
/// advertisement domain: `serviceName` and the one-shot receiver-originated
/// Connect token (`connectRequestToken`). Also builds the two advertised
/// `NWListener.Service` values (media `_opensidecar._tcp` and pairing
/// `_opendisplay-pair._tcp`) from that state plus the caller-supplied wire
/// identity, so neither service's exact TXT-record shape has to be
/// reconstructed anywhere else. Same `NSLock`-protected, `@unchecked
/// Sendable` idiom as `ReceiverTransportState` above — no callback is ever
/// invoked while the lock is held.
final class ReceiverAdvertisementState: @unchecked Sendable {
    private let lock = NSLock()
    private var serviceName: String
    private var connectRequestToken: String?

    init(serviceName: String) {
        self.serviceName = serviceName
    }

    func currentServiceName() -> String {
        lock.lock(); defer { lock.unlock() }
        return serviceName
    }

    /// Matches `setServiceName`'s exact write: overwrite only when the
    /// resolved name actually differs. Returns whether it changed.
    @discardableResult
    func setServiceName(_ name: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard name != serviceName else { return false }
        serviceName = name
        return true
    }

    /// Publishes a fresh token, replacing/invalidating any previous one.
    @discardableResult
    func beginConnectRequest() -> String {
        lock.lock(); defer { lock.unlock() }
        let token = UUID().uuidString
        connectRequestToken = token
        return token
    }

    /// Clears the token only if it is still exactly `token` — a stale expiry
    /// for a superseded token must never clear a newer one. Returns whether
    /// it matched/cleared.
    @discardableResult
    func clearConnectRequestIfCurrent(_ token: String) -> Bool {
        lock.lock()
        let matched = connectRequestToken == token
        if matched { connectRequestToken = nil }
        lock.unlock()
        return matched
    }

    func mediaService(installID: String, protocolVersion: Int) -> NWListener.Service {
        lock.lock()
        let name = serviceName
        let token = connectRequestToken
        lock.unlock()
        var txt = NWTXTRecord()
        txt["id"] = installID
        txt["pv"] = String(protocolVersion)   // issue #132
        if let token { txt["cr"] = token }
        return NWListener.Service(name: name, type: "_opensidecar._tcp",
                                  domain: nil, txtRecord: txt)
    }

    func pairingService(installID: String, protocolVersion: Int, pairingProtocolVersion: Int) -> NWListener.Service {
        lock.lock()
        let name = serviceName
        lock.unlock()
        var txt = NWTXTRecord()
        txt["id"] = installID
        txt["pv"] = String(protocolVersion)
        // Unauthenticated pairing-protocol-version hint, additive and
        // separate from `pv` (the media wire version) — early UX only, see
        // `WireProtocol.pairingVersion`'s doc comment.
        txt["pp"] = String(pairingProtocolVersion)
        return NWListener.Service(name: name, type: "_opendisplay-pair._tcp",
                                  domain: nil, txtRecord: txt)
    }
}

/// Lock-protected sole owner of the user's last-requested audio preference
/// (`requestAudioEnabled`/`primeAudioPreference`). Previously a plain
/// `private var` on `StreamReceiver` mutated via `queue.async { [weak self]
/// in self?.audioPreferred = enabled }` from `@MainActor` call sites — under
/// strict concurrency that capture of non-Sendable `StreamReceiver` in the
/// `@Sendable` `DispatchQueue.async` closure is what's diagnosed. The value
/// itself has no ordering dependency on anything else `queue`-confined (it
/// is only ever read back verbatim into an outgoing `audioRequest`), so a
/// lock-protected box is a faithful, minimal replacement: same last-write-
/// wins semantics, no `self` capture required to update it.
final class AudioPreferenceBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func set(_ newValue: Bool) {
        lock.lock(); value = newValue; lock.unlock()
    }

    func get() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return value
    }
}

/// Lock-protected box holding the lazily-constructed `pipeline` actor
/// reference, installed once `pipeline`'s own `lazy var` initializer runs.
/// Exists solely so `makePipelineHostEffects()`'s `ensureTLSListening`
/// closure can reach the actor at call time without capturing `self` — a
/// direct `self.pipeline` read there would both reintroduce a
/// `StreamReceiver` capture and re-enter `pipeline`'s own lazy
/// initialization (which itself calls `makePipelineHostEffects()`). Same
/// `NSLock`-protected, `@unchecked Sendable` idiom as `SendTargetBox` below.
final class ReceiverPipelineActorBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: ReceiverPipelineActor?

    func install(_ actor: ReceiverPipelineActor) {
        lock.lock(); defer { lock.unlock() }
        value = actor
    }

    func current() -> ReceiverPipelineActor? {
        lock.lock(); defer { lock.unlock() }
        return value
    }
}

/// Lock-protected box holding a weak `StreamReceiver` reference — the same
/// seam `ReceiverPipelineActorBox` gives `pipeline` above, but for `self`
/// itself. `makeFramePipelineOutputEffects()`'s `@Sendable` output closures
/// (`beginAdoption`, `controlMessage`, `audioPayload`, `presentationFrame`)
/// need to reach back into queue-confined `StreamReceiver` instance methods
/// at call time without capturing the non-Sendable `StreamReceiver` itself —
/// capturing `self` (even `weak`) in one of those closures is a hard Swift 6
/// error. `install(_:)` runs once `self` is fully initialized (see `init`),
/// mirroring `pipelineBox.install`'s "install once constructed" pattern.
///
/// The lock protects only the weak-reference slot itself — it does NOT make
/// `StreamReceiver` thread-safe. `currentOnQueue()` must only be called from
/// code already executing on the receiver's `queue` (`receiver.video`); every
/// call site resolves it from inside a `queue.async { ... }` block before
/// touching any `queue`-confined state, exactly like the `weak self` capture
/// it replaces.
final class StreamReceiverSelfBox: @unchecked Sendable {
    private let lock = NSLock()
    private weak var value: StreamReceiver?

    func install(_ receiver: StreamReceiver) {
        lock.lock(); defer { lock.unlock() }
        value = receiver
    }

    /// Must only be called from code already running on `receiver.video` —
    /// see this type's doc comment.
    func currentOnQueue() -> StreamReceiver? {
        lock.lock(); defer { lock.unlock() }
        return value
    }
}

final class StreamReceiver: ObservableObject {

    @MainActor @Published var status = "Starting…"
    @MainActor @Published var fps = 0
    @MainActor @Published private(set) var streamingProfile: StreamingProfile = .performance
    @Published private(set) var customFrameRate: CustomFrameRateSelection = .auto
    /// Mac-authoritative Streaming Priority mirror. Default `.auto` matches
    /// the Mac's own default so an old-peer/pre-hello receiver never assumes
    /// a different bounded encode depth than the Mac is actually running.
    @MainActor @Published private(set) var streamingPriority: StreamingPriority = .auto
    /// Mac-authoritative confirmed codec (HEVC milestone) — the receiver's
    /// own diagnostics mirror of `streamCodecState`. Default `.h264`: the
    /// only codec a pre-`hevcCodecWireVersion` Mac can ever send, and the
    /// safe assumption until the first `streamCodecState` (or first video
    /// frame) arrives.
    @MainActor @Published private(set) var activeStreamCodec: StreamCodec = .h264
    @MainActor @Published var connected = false
    @MainActor @Published var videoSize = CGSize.zero   // for touch coordinate mapping
    @MainActor @Published private(set) var displayState = DisplayState.running
    @MainActor @Published private(set) var videoEnabled = true
    /// Queue-confined copy used to distinguish an idempotent state push from
    /// an actual off/on transition that must retire decoder state.
    private var receivedVideoEnabled = true
    /// Queue-confined copy of `activeStreamCodec`, same convention as
    /// `receivedVideoEnabled` — this is compared/written on the control-
    /// message queue, never the main-thread `@Published` mirror.
    private var receivedStreamCodec: StreamCodec = .h264
    @MainActor @Published var perf = PerfStats()
    // Compatibility signal from the connected Mac (issue #132). Nil = no signal.
    // Merged into the update gate by ReceiverScreen.
    @MainActor @Published var peerSignal: PeerUpdateSignal?
    /// Mac protocol version from the most recent `welcome` message.
    @MainActor @Published private(set) var macProtocolVersion = WireProtocol.assumedWhenAbsent
    @MainActor @Published private(set) var inputResetGeneration = 0
    @MainActor @Published private(set) var controlResetGeneration = 0
    @MainActor @Published private(set) var confirmedDisplayMode: ReceiverDisplayMode?
    @MainActor @Published private(set) var pendingDisplayMode: ReceiverDisplayMode?
    @MainActor @Published private(set) var displayModeConfirmationGeneration = 0
    @MainActor private var displayModeRequestState = DisplayModeRequestState()
    /// Set when the Mac reports Mirror has no usable physical display (a
    /// headless/clamshell Mac) — see `WireMessage.mirrorUnavailable`. The UI
    /// offers switching to Extend via `acceptMirrorUnavailableOffer()`,
    /// which sends the EXISTING `displayModeRequest` — never a parallel
    /// mode-switch path. Cleared on any disconnect (`setConnected`) or once
    /// the user acts on it.
    @MainActor @Published private(set) var mirrorUnavailable = false
    /// Set when the Mac authoritatively rejects a Mirror request made
    /// WHILE already confirmed extending (see `SenderController.requestMode`)
    /// — a simple informational state, never the "Use Extend?" offer, since
    /// the user is already using Extend. Dismissed with `dismissMirrorRejection()`,
    /// on any disconnect, or once any mode confirmation resolves it.
    @MainActor @Published private(set) var mirrorRejectedWhileExtending = false
    /// The connected Mac's canonical Mirror capture-source report — see
    /// `MirrorDisplayStateUpdate`. `nil` until a Mac speaking
    /// `mirrorDisplayWireVersion` has actually reported one (distinct from
    /// `selectedUUID == nil`, which means Auto).
    @MainActor @Published private(set) var mirrorDisplayState: MirrorDisplayStateUpdate?
    /// The Mac's confirmed active Extend display shape (`extendShapeState`,
    /// `pv` 14) — same request/confirm bookkeeping as `confirmedDisplayMode`.
    @MainActor @Published private(set) var confirmedExtendShape: ExtendDisplayShapePreference?
    @MainActor @Published private(set) var pendingExtendShape: ExtendDisplayShapePreference?
    @MainActor private var extendShapeRequestState = ExtendShapeRequestState()
    // Receiver-enforced max FPS (PART 2/3/4) — same request/confirm shape as
    // Extend shape above. `maxFPSState` (`lastMaxFPSState`) additionally
    // carries the diagnostic ceilings (encoder-safe FPS, available tiers,
    // limitation reason) PART 5's UI text needs; it is NOT itself the
    // confirmed preference — that stays in `confirmedMaxFPS`/`pendingMaxFPS`
    // via the same `MaxFPSRequestState` bookkeeping.
    @MainActor @Published private(set) var confirmedMaxFPS: ReceiverMaxFPSPreference?
    @MainActor @Published private(set) var pendingMaxFPS: ReceiverMaxFPSPreference?
    @MainActor @Published private(set) var lastMaxFPSState: MaxFPSStateUpdate?
    @MainActor private var maxFPSRequestState = MaxFPSRequestState()

    /// The single authoritative session state the UI derives from. Mutated
    /// only inside `pipeline` (`ReceiverPipelineActor`, C1) via its own
    /// `mutateSession`; this is its main-thread mirror, published through
    /// `UIEffects.publishSessionSnapshot`.
    @MainActor @Published private(set) var session = ReceiverSessionState()

    /// The pinned peerID that actually completed mutual TLS for the CURRENT
    /// `session` — derived from the connection's own certificate (SPKI →
    /// `TrustStore.peerID(forSPKI:)`), exactly like `MacSender`'s
    /// `SenderApplicationAuthorization` binding on the dialer side. `nil`
    /// while disconnected, or for a connection with no TLS layer (the
    /// loopback-only USB path). `WakeConnectCoordinator` requires this to
    /// equal its attempt's target peerID before treating a session as having
    /// satisfied that specific wake attempt — a Bonjour peerID, a requested
    /// peerID, a hostname, or wake metadata are never sufficient on their
    /// own (see `resolveAuthenticatedPeerID`).
    @Published private(set) var authenticatedPeerID: String?

    /// Set by `forgetPeer(_:)` so `WakeConnectCoordinator` can end an attempt
    /// targeting a peer whose trust was just revoked instead of letting a
    /// late/stale authentication complete it (P13).
    @MainActor @Published private(set) var lastForgottenPeerID: String?

    /// Coarse, interruption-aware connection headline — "Connected", an
    /// interruption title ("Reconnecting…", "Display Paused", …), or
    /// "Waiting for a Mac…". Every receiver surface (iOS and Mac Receiver)
    /// that needs a phase-level label reads this instead of independently
    /// re-deriving it from `connected` alone, which used to miss states
    /// like reconnecting/paused.
    @MainActor var canonicalPhaseTitle: String {
        session.interruption?.title ?? (session.phase == .connected ? "Connected" : "Waiting for a Mac…")
    }
    /// Auto-Reconnect preference (Settings/Home toggle) — this receiver's own
    /// local setting, independent of the paired Mac's and not synced with
    /// it. Default true preserves existing behavior for installs with no
    /// stored value. Gates only the automatic recovery loop entered from
    /// `connectionLost`'s transport-loss case (see `ReceiverSessionState`);
    /// `requestConnect()`/`reconnectNow()` — manual Connect/Reconnect, and
    /// Wake & Connect on top of them — always bypass it. iOS's Home screen
    /// and Settings both bind this same published property, so the two stay
    /// in sync with no separate storage.
    @Published var autoReconnectEnabled = UserDefaults.standard.object(forKey: "autoReconnectEnabled") == nil
        || UserDefaults.standard.bool(forKey: "autoReconnectEnabled") {
        didSet {
            guard autoReconnectEnabled != oldValue else { return }
            reconnectContext.update { $0.autoReconnectPreferenceEnabled = autoReconnectEnabled }
            UserDefaults.standard.set(autoReconnectEnabled, forKey: "autoReconnectEnabled")
            Log.info("reconnectPolicy: autoReconnect enabled=\(autoReconnectEnabled)")
            if autoReconnectEnabled {
                Log.info("reconnectPolicy: reenabled reevaluatingAvailability")
            } else {
                // Reads `pipeline` through `pipelineBox` rather than
                // `self.pipeline` directly — a `Task { [weak self] in ... }`
                // here would capture the non-Sendable `StreamReceiver` in a
                // `@Sendable` closure, and if `pipeline` were never started
                // there is no automatic recovery to cancel anyway, so a nil
                // box read is a correct no-op.
                let pipelineBox = pipelineBox
                Task { await pipelineBox.current()?.cancelAutomaticRecoveryIfNeeded() }
            }
        }
    }
    // C1 review fix: `peerIsIncompatible`/`manualConnectPeerID` moved into
    // `reconnectContext` (`ReceiverPipelineActor.ReconnectContext`) — the
    // synchronized box `pipeline`'s reconnect logic reads. Both are written
    // only here on the host (the flag's meaning: set when the peer told us
    // the two apps are version-incompatible, so the flag only reclassifies
    // the eventual loss and never touches the live session).

    /// Receiver Swift6-B1: the MainActor publication proxy `pipeline`'s
    /// `@Sendable` `UIEffects` closures publish `status`/`session` through,
    /// instead of capturing `self` — see `ReceiverUISink`'s file header.
    /// `target` is wired weakly in `init` below.
    private let uiSink = ReceiverUISink()

    /// UI-layer seam keeps this shared receiver free of UIKit/SwiftUI.
    var onReceiverUIPreferences: ((ReceiverUIPreferenceUpdate) -> Void)?
    // Receiver Swift6-Hello-2: the 11 announced Hello preference mirrors
    // formerly stored here (tray/keyboard/functionTray/inputMode/
    // trackpadSensitivity/haptics/avoidNotch/pinchTarget/rotateTarget/
    // snapRotation/appGestureCommands) now live solely in `helloState`
    // (`ReceiverHelloState`, added in the prior commit) — see its type doc.
    // `helloState` is the sole authoritative store; `sendHello` reads its
    // snapshot instead of `self`. `internal` (not `private`), matching
    // `ReceiverHelloState` itself and `KeyframeThrottle`'s precedent, solely
    // so tests can verify the writer/reader migration end to end through
    // `StreamReceiver`'s own public API without reaching into `sendHello`'s
    // network send path.
    let helloState = ReceiverHelloState()

    /// Sole authoritative store for the announced panel geometry — see
    /// `ReceiverDisplayGeometryState`'s type doc above. Stable identity,
    /// never replaced; `internal` for the same test-access reason as
    /// `helloState`.
    let displayGeometryState = ReceiverDisplayGeometryState()

    /// This session's confirmed input-consent state — pushed on connect and
    /// whenever it changes on the Mac (master toggle, a Mac-owner prompt
    /// decision, an auto-policy grant/denial, or a manual revoke). The Mac
    /// remains the single authority and never optimistically predicted; see
    /// `requestAllowInput`.
    var onAllowInputStateChange: ((SessionInputWireState) -> Void)?

    /// True when the connected Mac understands pencil/proximity wire messages.
    @MainActor var macSupportsPencilWire: Bool { macProtocolVersion >= WireProtocol.pencilWireVersion }

    @MainActor var macSupportsVideoControl: Bool {
        macProtocolVersion >= WireProtocol.videoControlWireVersion
    }

    /// True when the connected Mac understands the `keyboard` message family (M4).
    @MainActor var macSupportsKeyboardWire: Bool { macProtocolVersion >= WireProtocol.keyboardWireVersion }

    /// True when the connected Mac understands the `pointer` message family (M7).
    @MainActor var macSupportsPointerWire: Bool { macProtocolVersion >= WireProtocol.pointerWireVersion }

    /// True when the connected Mac understands Mac system audio (`pv` 12).
    /// No legacy fallback, same as keyboard: below this, Audio simply stays
    /// unavailable rather than degrading to something else.
    @MainActor var macSupportsAudio: Bool { macProtocolVersion >= WireProtocol.audioWireVersion }

    // MARK: - Mac system audio playback
    //
    // See `AudioMediaFrame` (Shared/AudioMediaFrame.swift) for the wire
    // shape and `AVSyncOffset` for the sync-offset math. Playback uses
    // `AVSampleBufferAudioRenderer` on its own `AVSampleBufferRenderSynchronizer`
    // (never attached to `displayLayer` — the video path's "display
    // immediately" low-latency behavior would conflict with a shared
    // timebase, see PROTOCOL.md Appendix B / the milestone note above
    // `enqueueFrame`). Each audio sample buffer is stamped with an absolute
    // host-time PTS computed from one stable per-generation `audioAnchor`
    // (see its doc comment for why this is deliberately NOT recomputed
    // from every video frame), so the synchronizer plays it out at the
    // right real moment with only a small bounded preroll.

    /// Mac-confirmed actual audio production state (`audioState`).
    @MainActor @Published var audioEnabled = false
    /// What this receiver last asked for — resent on every `welcome` so it
    /// survives reconnection and transport migration without the user
    /// re-enabling it (SESSION BEHAVIOR).
    private let audioPreferredBox = AudioPreferenceBox()
    /// RC-3 Stage E2: the renderer/synchronizer/anchor scheduling domain
    /// moved to `ReceiverAudioPresenter` — see its file header. Owned here,
    /// constructed with `queue` for its DEBUG KVO callback's re-hop.
    private lazy var audioPresenter = ReceiverAudioPresenter(queue: queue)
    private var audioFormatDescription: CMAudioFormatDescription?
    private var audioSampleRate: Double = 48_000
    #if os(iOS)
    private var audioSessionActive = false
    private var audioSessionObserversRegistered = false
    #endif
    /// Receiver-local A/V sync offset (ms), clamped to `AVSyncOffset.range`.
    /// Positive delays audio; negative delays video presentation — set via
    /// `announceReceiverPreferences`, which also reports the current value
    /// to a connected Mac (read-only there; only this receiver ever sets
    /// it). This is the user's MANUAL term only —
    /// `establishAudioAnchor` folds in a separate, automatic one-shot
    /// baseline correction (see `lastVideoLatencySeconds`); the two are
    /// never conflated so "Reset" (manual only) and "Resync" (automatic
    /// only) each touch exactly what they claim to. Sole authority is
    /// `avSyncPreference` (`AVSyncPreference`, see its type doc above) — no
    /// mirrored copy lives here.
    let avSyncPreference = AVSyncPreference()

    /// RC-3 Stage E2: the capture-timeline -> host-time anchor mapping now
    /// lives on `audioPresenter` (`ReceiverAudioPresenter`'s `MediaAnchor`)
    /// — see its file header. This receiver holds no shadow of it; it hands
    /// `audioPresenter` an `AudioTimingSnapshot` per scheduling call instead.
    ///
    /// A slow, one-shot measurement — "how much later than its own capture
    /// moment does video actually appear right now" — updated cheaply on
    /// every displayed video frame but consulted ONLY when establishing a
    /// fresh `audioAnchor`, never used to nudge an anchor already in play.
    /// This is `automaticBaseCorrection` in the Resync design: folded into
    /// the anchor's lead so audio settles near video's real baseline
    /// latency instead of an arbitrary fixed preroll, without ever
    /// continuously chasing an instantaneous, noisy measurement.
    private var lastVideoLatencySeconds: Double?
    private var lastVideoLatencyUpdatedAtWallMs: Double = 0
    /// RC-3 Stage D: the AUTHORITATIVE presentation generation now lives on
    /// `presenter` (`ReceiverVideoPresenter.videoGeneration`) — this is a
    /// `queue`-confined SHADOW, incremented in lockstep at the exact same
    /// call sites (`resetStreamState`, `resync()`), immediately before the
    /// matching `presenter.enqueueAdvanceGeneration()`. It exists only so
    /// `presentDecodedSample`'s hot path can snapshot "the generation this
    /// frame belongs to" with a synchronous, zero-hop read — see
    /// `ReceiverVideoPresenter`'s file header, "Stale-generation safety".
    /// Never read back to make a presentation decision; the actual gate is
    /// `presenter`'s own copy, checked inside its ordered command pump.
    private var presentationGeneration: UInt64 = 0
    /// Which codec the currently-active `audioFormatDescription`/renderer
    /// chain was built for. A config frame for the OTHER codec means the
    /// sender started a new audio generation (Audio Off→On rebuild or
    /// reconnect while `audioDebugMode` changed) — never a live mid-session
    /// codec hot-swap, since `MacSender` only latches its debug codec choice
    /// at those same generation boundaries. Forces a full teardown/rebuild
    /// (`resetAudioForCodecChange`) instead of mutating a live renderer,
    /// which is what produced the -12735 renderer error this fixes.
    private enum AudioCodecKind: Equatable { case aac, pcm }
    private var audioCodecKind: AudioCodecKind?
    #if DEBUG
    /// GOAL #4/#6: set by `applyPCMConfig`, used to verify the
    /// payloadBytes==frameCount*channelCount*4 invariant and to compute
    /// per-channel PCM sanity metrics on the receiver side — see
    /// `logReceiverPCMSanity`.
    private var pcmChannelCount: UInt8 = 2
    private var pcmPacketsSinceSanityLog = 0
    private var audioGenerationCount = 0
    private var lastAudioDiagnosticCaptureMs: Double?
    private var audioDiagnosticLogCounter = 0
    /// Anomaly-only diagnostics (GOAL section 7/PCM bypass A/B mode):
    /// throttled/periodic logs stay in `logAudioTimingDiagnostic`; these
    /// fire only when something is actually unexpected.
    private var audioFrameDecodeFailureCount = 0
    private var lastAudioSequence: UInt32?
    /// Last applied config (AAC sample rate/channels, or PCM sample
    /// rate/channels) — logged only when a fresh config frame changes it
    /// mid-session, which should never happen within one generation.
    private var lastAppliedAudioConfigDescription: String?
    #endif

    /// RC-3 Stage E1: the AAC→PCM `AVAudioConverter` ownership, and the
    /// DEBUG-only anomaly/dump diagnostics that examine only its output,
    /// now live on `ReceiverAudioDecoder` — see its file header. Used both
    /// by `PCMPlaybackEngine` production playback (`scheduleAudioPacket`,
    /// when `activePlaybackPath == .pcmEngine`) and by the DEBUG-only
    /// local-decode diagnostics; deliberately not itself `#if DEBUG` for
    /// the same reason.
    private let audioDecoder = ReceiverAudioDecoder()

    #if DEBUG
    // MARK: Receiver-side AAC investigation (GOAL: local playback still
    // glitches intermittently even with clean Mac-side source PCM/locally-
    // decoded AAC and no video/TCP contention correlation — the suspect is
    // now this device's own AAC reconstruction/decode/render path, not the
    // sender). Every flag here reads `UserDefaults.standard` FRESH on each
    // use (never `lazy`/latched-once) so the in-app "Developer / Audio
    // Diagnostics" toggles in `SettingsView` (iOS) take effect immediately
    // — a physical device's sandboxed defaults can't receive a Mac
    // terminal's `defaults write` the way a Simulator or a Mac-native app
    // can, so an in-app toggle is the only practical way to flip these on
    // a real iPhone.
    private var receiverAACLocalDecodeEnabled: Bool {
        UserDefaults.standard.bool(forKey: "audioReceiverLocalDecode")
    }
    /// Gates the periodic `AAC integrity side=receiver ...` checksum log
    /// (GOAL: was unconditional before this toggle existed — now default
    /// OFF, so it must be explicitly enabled for the sender/receiver
    /// checksum comparison to appear in the next retest's logs).
    private var aacIntegrityLoggingEnabled: Bool {
        UserDefaults.standard.bool(forKey: "audioAACIntegrityLogging")
    }
    #endif

    private let tlsListenerState = TLSListenerState()
    private let pairingListenerState = PairingListenerState()
    // Receiver-originated Connect (see connectDebug): a short-lived token
    // published in the `_opensidecar._tcp` TXT record. The Mac already
    // browses that service continuously (it's how "Paired · Nearby" is
    // known), so this rides the existing discovery channel instead of
    // opening a new one. It carries no authority of its own — the Mac only
    // acts on it for an already-trusted/pinned peer, and the resulting
    // connection still runs the full pinned-TLS + hello handshake.
    private var connectRequestClearWorkItem: DispatchWorkItem?
    /// Narrow, lock-backed owner for `disconnect()`'s in-flight `finish`
    /// closure — same `NSLock`-protected `@unchecked Sendable` idiom as
    /// `TLSListenerState`/`SendTargetBox` above. Exists so `finish` can be a
    /// genuinely `@Sendable () -> Void` (it is stored here, invoked from
    /// `requestConnect()`/`reconnectNow()`, and passed to both
    /// `NWConnection.send`'s completion and `queue.asyncAfter`) without
    /// capturing non-Sendable `StreamReceiver` merely to reach the property
    /// that used to hold it.
    final class PendingDisconnectFinishBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: (@Sendable () -> Void)?

        func set(_ finish: (@Sendable () -> Void)?) {
            lock.lock(); defer { lock.unlock() }
            value = finish
        }

        func clear() { set(nil) }

        func callIfPresent() {
            lock.lock()
            let finish = value
            lock.unlock()
            finish?()
        }
    }
    private let pendingDisconnectFinishBox = PendingDisconnectFinishBox()

    /// Fire-once guard for `disconnect()`/`closeSession(...)`'s `finish`
    /// closure — replaces a plain captured `var finished = false`, which
    /// compiles under `finish`'s previous implicit (non-`@Sendable`) type
    /// but is rejected once `finish` is declared `@Sendable`: `finish` is
    /// invoked from the network completion queue, the `queue.asyncAfter`
    /// timer, and (for the no-live-connection path) `queue` itself, so the
    /// compiler cannot prove those calls are mutually exclusive even though
    /// `queue`'s own serialization makes them so in practice. Same
    /// `NSLock`-protected `@unchecked Sendable` idiom as the boxes above.
    final class OnceGuard: @unchecked Sendable {
        private let lock = NSLock()
        private var fired = false

        /// Returns `true` exactly once — for the call that should run the
        /// guarded effect — and `false` for every call after.
        func fireOnce() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if fired { return false }
            fired = true
            return true
        }
    }
    let pairingPrompt = PairingPromptModel()
    private var pairingObservation: AnyCancellable?
    private let pairingSuppressionState = PairingSuppressionState()
    @MainActor @Published private(set) var discoveredMacs: [NWBrowser.Result] = []
    private var macPairingBrowser: NWBrowser?
    /// Bumped only after a pairing (any transport) truly finalized: both
    /// confirmations, commit exchange and the TrustStore pin. Drives the
    /// success haptic/toast so it is transport-independent.
    @Published private(set) var pairingSuccessCount = 0
    @Published private(set) var remotePairingState: RemotePairingUIState = .idle
    @MainActor private(set) var remotePairingRetry = RemotePairingRetryContext()
    @MainActor private var remotePairingToken: UUID?
    @MainActor private var remotePairingDeadline: Task<Void, Never>?
    @MainActor private var remotePairingAttempt = PairingAttemptTracker()
    @MainActor private var remotePairingConnection: NWConnection?
    @MainActor private var remotePairingValidity: PairingAttemptValidity?
    // Cursor side channel: UDP on port+1. Cursor positions ride TCP behind
    // multi-hundred-KB video frames, so over WiFi one late frame stalls the
    // cursor with it (head-of-line blocking). UDP datagrams skip that queue.
    // Optional end to end: advertised in hello only once the listener is
    // ready, and the sender keeps using TCP when it is absent.
    // C1: `connection`/`pendingConnections` moved into `pipeline`
    // (`ReceiverPipelineActor`) — see that file for the newcomer-race
    // handling that used to live here.
    // What the last hello advertised, to notice a cable appearing
    // mid-session: plugging one creates new interfaces, and a sender can
    // only probe addresses it has been told about. Sole authority is
    // `helloState` (`ReceiverHelloState.addressesChanged`/
    // `recordAdvertisedAddresses`) — no mirrored copy lives here.
    // The cable upgrade (PROTOCOL.md 6.4) is Mac-to-Mac: only Mac
    // receivers put addrs in their hello — see sendHello for why phones
    // must not.
    private var advertisesAddresses: Bool { deviceKind == "Mac" }
    private var lastCursorSeq: UInt64 = 0
    #if DEBUG
    private var lastCursorPositionTraceAt = Date.distantPast
    /// Throttled to once every 2s — cursor position updates can arrive at
    /// up to 120Hz, and unthrottled logging at that rate would itself be a
    /// performance regression and flood the log past usefulness.
    private func logCursorPositionTraceIfDue(x: Double, y: Double, visible: Bool) {
        let now = Date()
        guard now.timeIntervalSince(lastCursorPositionTraceAt) > 2 else { return }
        lastCursorPositionTraceAt = now
        Log.info("cursorTrace: position x=\(x) y=\(y) visible=\(visible)")
    }
    #endif
    // Cursor channel health for the HUD/stats: how many positions landed and
    // how many datagrams never did (sequence gaps + reordered drops). A
    // stuttering pointer with a healthy count means the drawing side; a low
    // count or high loss means the network.
    private var cursorUpdatesThisWindow = 0
    private var cursorLostThisWindow = 0
    private let queue = DispatchQueue(label: "receiver.video")

    // Liveness: the Mac streams video and pings every 2s; if nothing arrives
    // for 5s the connection is half-open (Mac killed, tunnel died) — drop it
    // so the listener can accept a fresh one.
    // C1: the ping/watchdog/addrWatch liveness timers moved into `pipeline`
    // (`ReceiverPipelineActor`) — their correctness is inseparable from the
    // authoritative `connection`/`sessionState` they now read directly.
    // C3: `buffer`/`formatDesc`/`sps`/`pps`/`vps`, the active receive
    // generation (previously `activeReceiveGeneration`), and the liveness
    // timestamp itself (previously `lastDataReceived`, a plain stored
    // property here) all moved into `framePipeline` (`ReceiverFramePipeline`)
    // — the timestamp because per-packet updates now happen entirely
    // inside its own `ingest`, with no host round trip needed just to bump
    // a `Date`. Nothing here holds a writable shadow of any of this; the
    // one synchronous cross-actor read the watchdog still needs
    // (`makePipelineHostEffects`'s `getReceiveLiveness`) goes through
    // `framePipelineSyncState.snapshot()` — the same instance `framePipeline`
    // holds as its own `syncState` — never a local copy.

    private var framesThisWindow = 0
    private var fpsWindowStart = Date()
    private var bytesThisWindow = 0
    private var stallsThisWindow = 0
    private var decodeFlushes = 0
    private var lastFrameAt: Date?
    private var frameIntervals: [Double] = []   // ring buffer, ms
    private let maxSamples = 120

    // Clock sync (NTP-style): offset = macClock − phoneClock, taken from the
    // ping/pong sample with the lowest RTT (least asymmetric).
    private var offsetSamples: [(rtt: Double, offset: Double)] = []
    /// Receiver Swift6: narrow, lock-free owner for `clockOffsetMs` and
    /// `photonWindow` — the two pieces of state `recordPresented`'s
    /// `@Sendable` closure needs without capturing `self` (the non-Sendable
    /// `StreamReceiver`), so the closure captures this stable `let` value
    /// directly instead (same pattern as `videoTelemetry`/`pipeline`/
    /// `uiSink` above).
    ///
    /// Plain vars, no lock: this changes nothing about either field's
    /// existing thread-safety profile, it only gives them a Sendable-safe
    /// home. `clockOffsetMs` is written only from `queue` (the "pong"
    /// handler) but read from both `queue` and `@MainActor`
    /// (`sendTouch`/`sendPencil`) with no hop today — an existing benign
    /// race on a value that only nudges a few times a session; moving its
    /// storage here does not add or remove that race. `photonWindow` is
    /// exclusively `queue`-confined on every side (append/snapshot/reset).
    private let presentationTiming = ReceiverPresentationTimingState()
    private var lastRttMs = 0.0
    private var e2eWindow: [Double] = []        // capture→display, ms
    private var encodeWindow: [Double] = []     // capture→socket on the Mac, ms
    private var e2eRing: [Double] = []          // per-frame, for the overlay graph
    private var statsReportCounter = 0
    // B2.3: storage moved to `transportState` (a narrow, lock-protected
    // owner — see its doc comment) so the `clearTransport` host effect
    // below can write it without capturing `self`. This computed property
    // keeps every other read/write site (`updateTransport`, the stats
    // snapshot, `setStatusConnected`) unchanged.
    private var transport: String {
        get { transportState.get() }
        set { transportState.set(newValue) }
    }
    private let transportState = ReceiverTransportState()
    private var macDrops = 0
    private var macEncDrops = 0
    private var macNetDrops = 0
    private var macPending = 0
    private var macInputP50 = 0.0
    private var macInputP95 = 0.0
    private var macCapFps = 0

    #if DEBUG
    // Rolling ~1s receiver-pipeline instrumentation (LAN FPS-collapse
    // diagnosis). All touched only from `queue` — the VTDecompressionSession
    // output callback here does not lock, same as the existing `decodeWindow`
    // counter it sits beside, so this follows that convention.
    private var debugFramesReceivedWindow = 0    // complete AnnexB frames off the wire
    private var debugFramesToDecoderWindow = 0   // submitted to VTDecompressionSession
    // Receiver Swift6-B1: the "handed to the display layer" counter moved
    // into `videoTelemetry` (`presentedWindowCount`) — see that file.
    // Receiver Swift6: the "decode succeeded" counter (formerly
    // `debugFramesDecodedWindow`) moved into `videoTelemetry`
    // (`decodedWindowCount`) too — `decodedFrameReady`'s effect needed a
    // `self`-free owner to drop its `StreamReceiver` capture.
    private var debugArrivalIntervals: [Double] = []
    private var debugLastArrivalAt: Date?
    #endif

    private var nowMs: Double { Date().timeIntervalSince1970 * 1000 }

    // Local cursor echo (both called on the main thread): position is
    // normalized [0,1] in video space; the sprite arrives as a PNG with its
    // hotspot anchor and size normalized against the Mac display. The anchor
    // and normalized coordinates use a TOP-LEFT origin (video space).
    var onCursor: ((_ x: Double, _ y: Double, _ visible: Bool) -> Void)?
    var onCursorImage: ((_ image: CGImage, _ anchor: CGPoint, _ normSize: CGSize) -> Void)?
    var onDisplayStateChange: ((DisplayState) -> Void)?
    // The video view attaches only once frames are on screen — usually AFTER
    // the connect-time sprite already arrived (the sender re-sends it only
    // when the cursor changes shape, so a plain arrow would stay invisible
    // forever). Keep the latest of each so a late-attaching view replays
    // them. Main-thread, like the callbacks.
    @MainActor private(set) var cursorState: (x: Double, y: Double, visible: Bool) = (0.5, 0.5, false)
    @MainActor private(set) var cursorSprite: (image: CGImage, anchor: CGPoint, normSize: CGSize)?

    // Metal renderer path (experimental, "metalRenderer" setting): we decode
    // explicitly and hand BGRA buffers out; called on the receiver queue.
    // The decode itself (session, generation, DEBUG luma probe) is C4:
    // `ReceiverVideoDecoder` below — this remains only the telemetry ring
    // its `decodeDurationMs` effect feeds, and the app-facing sink.
    /// Receiver Swift6: storage delegates to `decodedFrameSink`
    /// (`ReceiverDecodedFrameSink`, see its file header) — a lock-protected
    /// owner `makePresenter()`'s `decodedFrameReady` effect can read the
    /// live value from without capturing `self`. This computed property is
    /// the entire compatibility surface: external callers (`onDecodedFrame
    /// = ...` / `= nil` in `iOS/OpenSidecarPhoneApp.swift`) are unchanged.
    var onDecodedFrame: ((_ pixelBuffer: CVPixelBuffer, _ captureMs: Double?) -> Void)? {
        get { decodedFrameSink.get() }
        set { decodedFrameSink.set(newValue) }
    }
    private let decodedFrameSink = ReceiverDecodedFrameSink()
    /// Receiver Swift6-B1: decode-duration samples + the cumulative flush
    /// count moved into this narrow lock-backed owner — see its file
    /// header. Never captured directly by a `@Sendable` closure that also
    /// needs `self`; those closures capture this `let` value on its own.
    private let videoTelemetry = ReceiverVideoTelemetry()
    private var loggedDisplayPath = false
    // Default OFF: A/B measurement showed the system video layer reaches
    // glass faster than our CAMetalLayer path (iOS gives AVSBDL a dedicated
    // compositor plane). Kept as an experimental toggle + for its metrics.
    private var useMetalPath: Bool { UserDefaults.standard.bool(forKey: "metalRenderer") }

    /// Called by the renderer's presented handler: maps the CACurrentMediaTime-
    /// based glass timestamp into wall-clock ms and computes true photon e2e.
    func recordPresented(presentedTime: CFTimeInterval, captureMs: Double?) {
        guard let captureMs, presentedTime > 0 else { return }
        let presentedWallMs = nowMs - (CACurrentMediaTime() - presentedTime) * 1000
        // Captured once, locally, for the same reason as `uiSink`/`pipeline`
        // elsewhere in this file: the closure below must reach the Sendable
        // `presentationTiming` directly rather than through `self.
        // presentationTiming` (which would re-capture non-Sendable
        // `StreamReceiver`). `clockOffsetMs` is still read only when this
        // block actually executes on `queue`, not here at call time.
        let presentationTiming = self.presentationTiming
        queue.async {
            guard let offset = presentationTiming.clockOffsetMs else { return }
            let photon = (presentedWallMs + offset) - captureMs
            if photon > -50, photon < 5000 {
                presentationTiming.appendPhoton(max(photon, 0))
            }
        }
    }

    let displayLayer: AVSampleBufferDisplayLayer

    /// Native panel size in pixels + scale, announced to the Mac in a "hello"
    /// message so it can size the virtual display. Orientation-dependent:
    /// rotating the phone re-announces with swapped dimensions and the Mac
    /// rebuilds the virtual display as a portrait/landscape monitor.
    private var nativeLong = 0
    private var nativeShort = 0
    // Name advertised over Bonjour for the Mac's WiFi picker. iOS 16+ returns
    // a generic "iPhone" from UIDevice.current.name (the user-assigned name
    // needs an entitlement Apple gates behind approval and personal teams
    // can't get), so this is user-editable in Settings. The USB picker gets
    // the real name host-side via lockdownd regardless.
    /// Thin compatibility accessor over `advertisementState` (sole storage
    /// authority) — a direct assignment (as `MacReceiver`/`OpenSidecarPhoneApp`
    /// startup do, before any listener exists) writes straight through with
    /// no republish side effect, exactly matching the old plain stored
    /// property's behavior; `setServiceName(_:)` below is the only path that
    /// also re-publishes a live listener.
    var serviceName: String {
        get { advertisementState.currentServiceName() }
        set { advertisementState.setServiceName(newValue) }
    }
    private let advertisementState = ReceiverAdvertisementState(serviceName: "MeowDisplay")
    private let pipelineBox = ReceiverPipelineActorBox()
    private let selfBox = StreamReceiverSelfBox()

    // Platform identity, injected at init so this file stays UI-framework-free.
    /// "iPhone" / "iPad" / "Mac" — announced in the hello (the sender names
    /// the virtual display after it) and used in peer-update copy.
    private let deviceKind: String
    // Decode ceiling advertised in hello (PROTOCOL.md 6.5): the largest
    // stream this machine can actually sustain, which a big panel says
    // nothing about. nil = advertise nothing (sender streams full size).
    private let maxEncodeWide: Int?
    private let maxEncodeHigh: Int?
    // This receiver's real maximum display refresh rate in Hz (high-refresh
    // milestone), e.g. 60 or 120 on ProMotion — injected at init from the
    // platform's actual screen capability, never assumed. nil = don't
    // advertise (sender falls back to `StreamingFPSPolicy.defaultReceiverMaxFPS`).
    private let maxFPS: Int?
    /// HEVC milestone: real, hardware-decode-capable codec list, computed
    /// once per process from `VTIsHardwareDecodeSupported` — never an OS-
    /// version guess. H.264 is unconditional (matches today's behavior);
    /// `.hevc` only when the platform actually proves a hardware decoder.
    static let supportedCodecs: [StreamCodec] = CodecCapabilityProbe.supportedCodecs(
        hevcHardwareDecodeSupported: VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC))
    /// What to advertise when the user-set service name is empty.
    private let fallbackServiceName: String

    // Stable per-install identity, advertised in the Bonjour TXT record and
    // sent in every hello. The Mac uses it to recognize "same device, other
    // transport" — the service name can't serve that role since it's
    // user-editable, and iOS offers no public API for the hardware UDID
    // that usbmuxd reports.
    static let installID: String = {
        if let existing = UserDefaults.standard.string(forKey: "installID") {
            return existing
        }
        let fresh = UUID().uuidString
        UserDefaults.standard.set(fresh, forKey: "installID")
        return fresh
    }()

    private var advertisedService: NWListener.Service {
        advertisementState.mediaService(installID: Self.installID, protocolVersion: advertisedProtocolVersion)
    }

    private var advertisedPairingService: NWListener.Service {
        advertisementState.pairingService(
            installID: Self.installID, protocolVersion: advertisedProtocolVersion,
            pairingProtocolVersion: WireProtocol.pairingVersion)
    }

    /// Update the advertised name and re-publish if already listening.
    func setServiceName(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved = trimmed.isEmpty ? fallbackServiceName : trimmed
        let advertisementState = self.advertisementState
        let tlsListenerState = self.tlsListenerState
        let pairingListenerState = self.pairingListenerState
        let installID = Self.installID
        let advertisedProtocolVersion = self.advertisedProtocolVersion
        queue.async {
            guard advertisementState.setServiceName(resolved) else { return }
            if let tlsListener = tlsListenerState.currentListener() {
                tlsListener.service = advertisementState.mediaService(
                    installID: installID, protocolVersion: advertisedProtocolVersion)
                pairingListenerState.currentListener()?.service = advertisementState.pairingService(
                    installID: installID, protocolVersion: advertisedProtocolVersion,
                    pairingProtocolVersion: WireProtocol.pairingVersion)
                Log.info("re-advertising as \"\(resolved)\"")
            }
        }
    }

    func setNativePanel(long: Int, short: Int, scale: Double) {
        nativeLong = long
        nativeShort = short
        // default landscape until the view reports; seeds only if unset.
        displayGeometryState.seedNativePanelIfUnset(pixelsWide: long, pixelsHigh: short, scale: scale)
    }

    func setOrientation(portrait: Bool) {
        guard nativeLong > 0 else { return }
        setPanel(pixelsWide: portrait ? nativeShort : nativeLong,
                 pixelsHigh: portrait ? nativeLong : nativeShort,
                 scale: displayGeometryState.snapshot().scale)
    }

    func setReceiverUIPreferencesForHello(trayEnabled: Bool, keyboardButtonEnabled: Bool) {
        let helloState = self.helloState
        let sendTargetBox = self.sendTargetBox
        let displayGeometryState = self.displayGeometryState
        let avSyncPreference = self.avSyncPreference
        let deviceKind = self.deviceKind
        let maxEncodeWide = self.maxEncodeWide
        let maxEncodeHigh = self.maxEncodeHigh
        let maxFPS = self.maxFPS
        let advertisedProtocolVersion = self.advertisedProtocolVersion
        let advertisesAddresses = self.advertisesAddresses
        queue.async {
            helloState.updateTrayAndKeyboard(
                trayEnabled: trayEnabled, keyboardButtonEnabled: keyboardButtonEnabled)
            if let connection = sendTargetBox.current()?.connection, connection.state == .ready {
                Self.sendHello(
                    on: connection, helloState: helloState, displayGeometryState: displayGeometryState,
                    avSyncPreference: avSyncPreference, sendTargetBox: sendTargetBox, deviceKind: deviceKind,
                    maxEncodeWide: maxEncodeWide, maxEncodeHigh: maxEncodeHigh, maxFPS: maxFPS,
                    advertisedProtocolVersion: advertisedProtocolVersion, advertisesAddresses: advertisesAddresses)
            }
        }
    }

    /// Same "update the announced value(s), resend hello now if connected"
    /// contract as `setReceiverUIPreferencesForHello`, generalized to the
    /// rest of `ReceiverControlPreferences` a connected Mac's per-device
    /// Settings detail reports — called alongside it on every local
    /// preference change so Mac visibility never lags what's actually set.
    func announceReceiverPreferences(_ preferences: ReceiverControlPreferences) {
        let helloState = self.helloState
        let avSyncPreference = self.avSyncPreference
        let sendTargetBox = self.sendTargetBox
        let displayGeometryState = self.displayGeometryState
        let deviceKind = self.deviceKind
        let maxEncodeWide = self.maxEncodeWide
        let maxEncodeHigh = self.maxEncodeHigh
        let maxFPS = self.maxFPS
        let advertisedProtocolVersion = self.advertisedProtocolVersion
        let advertisesAddresses = self.advertisesAddresses
        queue.async {
            helloState.updatePreferences(
                functionTrayEnabled: preferences.functionTrayEnabled,
                inputMode: preferences.inputMode,
                trackpadSensitivity: preferences.trackpadSensitivity,
                hapticsEnabled: preferences.hapticsEnabled,
                avoidNotch: preferences.avoidNotch,
                pinchTarget: preferences.pinchTarget,
                rotateTarget: preferences.rotateTarget,
                snapRotation: preferences.snapRotation,
                appGestureCommands: preferences.appGestureCommands)
            avSyncPreference.set(preferences.avSyncOffsetMs)
            if let connection = sendTargetBox.current()?.connection, connection.state == .ready {
                Self.sendHello(
                    on: connection, helloState: helloState, displayGeometryState: displayGeometryState,
                    avSyncPreference: avSyncPreference, sendTargetBox: sendTargetBox, deviceKind: deviceKind,
                    maxEncodeWide: maxEncodeWide, maxEncodeHigh: maxEncodeHigh, maxFPS: maxFPS,
                    advertisedProtocolVersion: advertisedProtocolVersion, advertisesAddresses: advertisesAddresses)
            }
        }
    }

    /// Announce the panel this receiver renders onto. Called before start()
    /// and again whenever it changes (iOS rotation via setOrientation, macOS
    /// display-mode changes) — a live connection re-sends hello so the sender
    /// rebuilds the virtual display for the new dimensions.
    func setPanel(pixelsWide w: Int, pixelsHigh h: Int, scale: Double) {
        let result = displayGeometryState.update(pixelsWide: w, pixelsHigh: h, scale: scale)
        guard result.dimensionsChanged else { return }
        Log.info("panel changed -> \(w)x\(h) @\(scale)x")
        if let connection = sendTargetBox.current()?.connection { sendHello(on: connection) }
    }

    @MainActor
    init(displayLayer: AVSampleBufferDisplayLayer, deviceKind: String,
         fallbackServiceName: String,
         maxEncodeWide: Int? = nil, maxEncodeHigh: Int? = nil, maxFPS: Int? = nil) {
        self.displayLayer = displayLayer
        self.deviceKind = deviceKind
        self.fallbackServiceName = fallbackServiceName
        self.maxEncodeWide = maxEncodeWide
        self.maxEncodeHigh = maxEncodeHigh
        self.maxFPS = maxFPS
        // Seed the box with the real initial preference — `didSet` above
        // only fires on a subsequent change, never for this stored
        // property's own initial value.
        reconnectContext.update { $0.autoReconnectPreferenceEnabled = autoReconnectEnabled }
        // Receiver Swift6-B2.2: force `presenter` then `videoDecoder` into
        // existence NOW, in this deterministic order, rather than leaving
        // them to whichever of the two happens to be touched first at
        // runtime (unprovable — e.g. release builds skip the DEBUG-only
        // `videoDecoder.enqueueProbeDecodedLuma` call in
        // `presentDecodedSample` that would otherwise happen to touch
        // `videoDecoder` before `presenter` on every frame). `self` is
        // fully initialized at this point (every non-lazy stored property
        // above is already set), so it's legal for `makePresenter()`/
        // `makeVideoDecoder()` to capture `self` weakly for their
        // unrelated coordinator hops (`onDecodedFrame`/
        // `onDecodedFrame`) — see their own doc comments for why the
        // cross-owner (sibling) references no longer need to. (`requestKeyframe`
        // itself no longer captures `self` at all — see `KeyframeThrottle`.)
        _ = presenter
        _ = videoDecoder
        selfBox.install(self)
        uiSink.target = self
        pairingPrompt.ownerAuthenticator = LocalOwnerAuthenticator()
        pairingPrompt.trustPinLookup = { TrustStore.shared.pin(peerID: $0) }
        pairingObservation = pairingPrompt.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        pairingPrompt.onPending = { [weak self] pending in
            Log.info("pairDebug: onPending peerID=\(pending.peerID)")
            self?.beginExplicitPairing(peerID: pending.peerID)
        }
        displayLayer.videoGravity = .resizeAspect
    }

    func start() {
        let queue = self.queue
        let tlsListenerState = self.tlsListenerState
        let pairingSuppressionState = self.pairingSuppressionState
        let advertisementState = self.advertisementState
        let pipeline = self.pipeline
        let advertisedProtocolVersion = self.advertisedProtocolVersion
        let selfBox = self.selfBox
        queue.async {
            TrustStore.shared.refreshSnapshot()
            Self.startTLSListener(
                queue: queue, tlsListenerState: tlsListenerState,
                pairingSuppressionState: pairingSuppressionState,
                advertisementState: advertisementState, pipeline: pipeline,
                installID: Self.installID, advertisedProtocolVersion: advertisedProtocolVersion)
            selfBox.currentOnQueue()?.startPairingListener()
            selfBox.currentOnQueue()?.startMacPairingBrowser()
        }
        Task { await pipeline.armLivenessTimers() }
    }

    /// Leave receiver duty for good: announce "closing" to a live sender (so
    /// it ends the session instead of waiting for a wake), drop the
    /// connection and the listener, and silence the liveness timers. The Mac
    /// app calls this when the user leaves receiver mode or quits; the
    /// instance is discarded afterwards (start() re-arms if it isn't).
    func stop(completion: (@Sendable () -> Void)? = nil) {
        let pipeline = self.pipeline
        Task { await pipeline.teardownForStop() }
        let selfBox = self.selfBox
        queue.async {
            guard let receiver = selfBox.currentOnQueue() else { return }
            receiver.macPairingBrowser?.cancel(); receiver.macPairingBrowser = nil
        }
        closeSession(announcing: WireMessage.closing, status: "Stopped",
                     completion: completion)
    }

    func forgetPeer(_ peerID: String) {
        TrustStore.shared.forget(peerID: peerID)
        let uiSink = self.uiSink
        DispatchQueue.main.async { uiSink.publishLastForgottenPeerID(peerID) }
        let pipeline = self.pipeline
        queue.async {
            // A live TLS session may have authenticated before the pin was
            // removed. End it immediately so forgetting takes effect now.
            Task { await pipeline.disconnectCurrentConnection(reason: .explicitDisconnect) }
        }
    }

    @MainActor
    func notePairingSucceeded() { pairingSuccessCount += 1 }

    @MainActor
    func pairWithMac(_ result: NWBrowser.Result) {
        let expectedPeerID: String? = if case .bonjour(let txt) = result.metadata {
            txt["id"]
        } else {
            nil
        }
        beginExplicitPairing(peerID: expectedPeerID)
        let connection = NWConnection(to: result.endpoint, using: .tcp)
        Task { @MainActor in
            defer { connection.cancel() }
            do {
                let paired = try await PairingNetwork.runInitiator(
                    connection: connection, localID: Self.installID,
                    localName: serviceName, prompt: pairingPrompt,
                    expectedPeerID: expectedPeerID, allowIdentityChange: false)
                pairingPrompt.finish("Paired with \(paired.peerName)")
                notePairingSucceeded()
                finishExplicitPairing(success: true)
            } catch {
                pairingPrompt.finish(error.localizedDescription)
                let promptStillPending = await MainActor.run { pairingPrompt.pending != nil }
                if !promptStillPending {
                    finishExplicitPairing(success: false)
                } else {
                    Log.info("pairDebug: duplicate initiator ended without disturbing pending confirmation")
                }
            }
        }
    }

    /// Pairs with a Mac at an explicit host (e.g. Tailscale IP / MagicDNS)
    /// instead of a Bonjour result. The host is an untrusted routing hint: it
    /// is saved as the peer's Remote endpoint only after the handshake
    /// confirmed and pinned the peer, keyed by the confirmed peer ID. A changed
    /// key for an existing peer is a hard failure.
    @MainActor
    func pairWithRemoteHost(_ endpoint: RemotePairingEndpoint) {
        guard let generation = remotePairingAttempt.begin() else { return }
        remotePairingRetry.remember(endpoint)
        let token = UUID()
        remotePairingToken = token
        Log.info("remotePairing: attempt generation=\(generation) hostCategory=\(Self.hostCategory(endpoint.host))")
        remotePairingState = .connecting
        beginExplicitPairing(peerID: nil)
        let validity = PairingAttemptValidity()
        let deadlineFired = PairingFlag()
        let handshakeReached = PairingFlag()
        remotePairingValidity = validity
        let connection = NWConnection(to: endpoint.nwEndpoint, using: .tcp)
        remotePairingConnection = connection
        remotePairingDeadline = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(RemotePairingWindow.attemptDeadline * 1_000_000_000))
            guard !Task.isCancelled else { return }
            deadlineFired.set()
            validity.invalidate()
            connection.cancel()
            self?.pairingPrompt.cancel(ownedBy: token)
        }
        Task { @MainActor in
            var outcome: RemotePairingUIState
            do {
                let paired = try await PairingNetwork.runInitiator(
                    connection: connection, localID: Self.installID,
                    localName: serviceName, prompt: pairingPrompt,
                    allowIdentityChange: false, isCurrent: { validity.isValid },
                    remoteHost: endpoint.host, attemptToken: token,
                    onHandshakeReached: { handshakeReached.set() })
                Log.info("remotePairing: attempt generation=\(generation) completed peer=\(paired.peerID)")
                scheduleTLSListenerRefresh()
                notePairingSucceeded()
                outcome = .succeeded
            } catch {
                Log.info("remotePairing: attempt generation=\(generation) failed error=\(error)")
                let kind = RemotePairingFailure.classify(
                    error, cancelledByUser: !validity.isValid && !deadlineFired.isSet,
                    deadlineFired: deadlineFired.isSet, handshakeReached: handshakeReached.isSet)
                outcome = kind.map { .failed($0) } ?? .idle
            }
            connection.cancel()
            // A cancelled/superseded attempt (generation no longer live)
            // reports nothing and touches no state.
            guard remotePairingAttempt.finish(generation) else { return }
            remotePairingDeadline?.cancel(); remotePairingDeadline = nil
            remotePairingConnection = nil
            remotePairingValidity = nil
            remotePairingToken = nil
            pairingPrompt.cancel(ownedBy: token)
            remotePairingState = outcome
            finishExplicitPairing(success: outcome == .succeeded)
        }
    }

    /// Cancels the real attempt: invalidates its generation and liveness flag,
    /// tears down the connection and deadline, and closes any SAS prompt.
    @MainActor
    func cancelRemotePairing() {
        // Goes through the attempt's commit gate: sends an authenticated abort
        // and is refused if the attempt already reached its commit point.
        if let token = remotePairingToken, !pairingPrompt.cancelAttempt(token: token) {
            Log.info("remotePairing: cancel refused, attempt already committing")
            return
        }
        remotePairingDeadline?.cancel(); remotePairingDeadline = nil
        remotePairingValidity?.invalidate(); remotePairingValidity = nil
        remotePairingConnection?.cancel(); remotePairingConnection = nil
        if remotePairingAttempt.active != nil {
            remotePairingAttempt.cancel()
            if let token = remotePairingToken { pairingPrompt.cancel(ownedBy: token) }
            remotePairingToken = nil
            Log.info("remotePairing: attempt cancelled by user")
            finishExplicitPairing(success: false)
        }
        remotePairingState = .idle
    }

    /// The Try Again action: a fresh attempt (new generation, connection and
    /// deadline) to the last attempted host, only after a retryable failure.
    @MainActor
    @discardableResult
    func retryRemotePairing() -> Bool {
        guard let endpoint = remotePairingRetry.endpointForRetry(state: remotePairingState) else { return false }
        pairWithRemoteHost(endpoint)
        return remotePairingAttempt.active != nil
    }

    /// Dismisses a finished result (failure or success banner) back to idle.
    @MainActor
    func acknowledgeRemotePairingResult() {
        guard remotePairingAttempt.active == nil else { return }
        remotePairingState = .idle
    }

    private static func hostCategory(_ host: String) -> String {
        if host.hasSuffix(".ts.net") { return "magicDNS" }
        if host.hasPrefix("100.") { return "tailscaleIPv4" }
        return host.contains(":") ? "ipv6" : (host.first?.isNumber == true ? "ipv4" : "hostname")
    }

    private func beginExplicitPairing(peerID: String?) {
        Log.info("pairDebug: explicit pairing started peerID=\(peerID ?? "unknown")")
        let pairingSuppressionState = self.pairingSuppressionState
        let pipeline = self.pipeline
        queue.async {
            pairingSuppressionState.setSuppressed(true)
            Task { await pipeline.disconnectCurrentConnection(reason: .explicitDisconnect) }
        }
    }

    private func finishExplicitPairing(success: Bool) {
        Self.finishExplicitPairing(queue: queue, pairingSuppressionState: pairingSuppressionState, success: success)
    }

    /// Static, self-free twin of the instance method above (Receiver
    /// Swift6-Pairing-Listener) — the pairing listener's `newConnectionHandler`/
    /// nested `Task` calls this directly instead of a bound `self?.
    /// finishExplicitPairing` closure, so that closure graph carries zero
    /// `StreamReceiver` capture. Exact same body; the instance method above
    /// delegates here so every other call site's behavior is unchanged.
    private static func finishExplicitPairing(
        queue: DispatchQueue, pairingSuppressionState: PairingSuppressionState, success: Bool
    ) {
        queue.async {
            pairingSuppressionState.setSuppressed(false)
            Log.info("pairDebug: pairing finished success=\(success)")
        }
    }

    func pairingMacName(_ result: NWBrowser.Result) -> String {
        if case .service(let name, _, _, _) = result.endpoint { return name }
        return "Mac"
    }

    func pairingMacIsPaired(_ result: NWBrowser.Result) -> Bool {
        guard case .bonjour(let txt) = result.metadata, let id = txt["id"] else { return false }
        return TrustStore.shared.hasPin(peerID: id)
    }

    /// The peer install ID a discovered Mac's Bonjour TXT record advertises —
    /// the same key `WakeMetadataStore` and `TrustStore` use, so a caller can
    /// look up that specific Mac's saved wake hint or trust pin. `nil` for a
    /// result that hasn't published one (predates the handshake, or is mid-
    /// resolve).
    func pairingMacPeerID(_ result: NWBrowser.Result) -> String? {
        guard case .bonjour(let txt) = result.metadata else { return nil }
        return txt["id"]
    }

    /// Recreate the listener if it isn't healthy — called when the app
    /// returns to the foreground (iOS may have torn it down while suspended,
    /// or enterSleep deliberately took it down on lock).
    func ensureListening() {
        let queue = self.queue
        let selfBox = self.selfBox
        queue.async {
            selfBox.currentOnQueue()?.ensureTLSListening()
        }
    }

    /// The pinned-TLS listener (LAN/WoL reconnection path) has no restart
    /// state machine of its own like the plaintext listener does — it is
    /// long-lived and only ever torn down by an explicit `closeSession`
    /// (device lock, Forget, app quit). Wake/foreground and every automatic
    /// reconnect attempt must re-arm it if that happened, or a trusted Mac
    /// redialing in has nothing to connect to (`reconnectDebug: listenerReady`
    /// never fires again and the session gets stuck oscillating in/out of
    /// Reconnecting).
    private func ensureTLSListening() {
        guard !tlsListenerState.hasCurrent() else { return }
        Log.info("reconnectDebug: retryScheduled TLS listener rearm")
        Self.startTLSListener(
            queue: queue, tlsListenerState: tlsListenerState,
            pairingSuppressionState: pairingSuppressionState, advertisementState: advertisementState,
            pipeline: pipeline, installID: Self.installID, advertisedProtocolVersion: advertisedProtocolVersion)
    }

    /// iOS lifecycle seam. Backgrounding parks an in-flight recovery run
    /// (nothing can be dialed at us while suspended, and burning the budget
    /// there would land us in Connection Lost for no reason); foregrounding
    /// resumes it from where it stopped.
    func setAppActive(_ active: Bool) {
        let pipeline = self.pipeline
        Task {
            if active {
                await pipeline.resumeReconnectIfNeeded()
            } else {
                await pipeline.suspendReconnectForBackground()
            }
        }
    }

    // Set while the app lingers in the background with the session alive
    // (brief app switch): decoding is pointless and hardware decode sessions
    // fail off-screen, so frames are dropped before the sample stage.
    private var renderingPaused = false

    /// Pause/resume the video sink around a background linger. Resuming
    /// flushes the layer and asks the Mac for a keyframe so the picture
    /// re-syncs immediately (the Mac replays a static screen as IDR too).
    ///
    /// Receiver Swift6: `framePipelineSyncState`/`presenter`/`sendTargetBox`
    /// are already-Sendable owners captured directly (`framePipelineSyncState`
    /// is the exact instance `framePipeline.syncState` exposes — see
    /// `ReceiverFramePipeline.init`); only `renderingPaused` itself is raw
    /// queue-confined `StreamReceiver` storage, so it alone goes through
    /// `selfBox`. Unlike the old strong-`self` capture, this now no-ops if
    /// the receiver has already been torn down by the time the queue hop
    /// runs — acceptable here: an already-deallocated receiver has no
    /// `presenter`/connection left to flush or signal.
    func setRenderingPaused(_ paused: Bool) {
        let queue = self.queue
        let selfBox = self.selfBox
        let framePipelineSyncState = self.framePipelineSyncState
        let presenter = self.presenter
        let sendTargetBox = self.sendTargetBox
        queue.async {
            guard let receiver = selfBox.currentOnQueue(), paused != receiver.renderingPaused else { return }
            receiver.renderingPaused = paused
            // C3: mirrored synchronously for `framePipeline`, which checks
            // this before building a sample buffer — see
            // `FramePipelineSyncState`.
            framePipelineSyncState.setRenderingPaused(paused)
            Log.info(paused ? "rendering paused (backgrounded)" : "rendering resumed")
            if !paused {
                presenter.enqueueFlush()
                if sendTargetBox.current()?.connection.state == .ready {
                    Self.sendControl(["type": "kf"], sendTargetBox: sendTargetBox)
                }
            }
        }
    }

    /// The device locked — nobody can see the stream, so tell the Mac and go
    /// silent. Sends "sleeping" (the Mac drops its virtual display so the
    /// cursor isn't stranded on an invisible screen and arms a reconnect),
    /// then closes the connection AND the listener: while asleep we must not
    /// accept connections, or the Mac's wake retries would rebuild the
    /// display before anyone can see it. ensureListening() re-arms
    /// everything when the scene becomes active again.
    func enterSleep(completion: (@Sendable () -> Void)? = nil) {
        closeSession(announcing: WireMessage.sleeping,
                     status: "Asleep — resumes on wake", completion: completion)
    }

    /// The app is being terminated (user swiped it away). Same close, but
    /// announced as "closing": quitting the app is deliberate, so the Mac
    /// ends the session without waiting around for a wake.
    func shutDown(completion: (@Sendable () -> Void)? = nil) {
        closeSession(announcing: WireMessage.closing,
                     status: "Closed", completion: completion)
    }

    /// The user explicitly ended THIS session from the live receiver UI —
    /// unlike `shutDown()`/`stop()` (leaving receiver mode entirely), this
    /// does not touch the listener, TLS listener, or pairing browser:
    /// pairing/trust, the Remote endpoint, and Wake metadata all remain, and
    /// this device stays reachable for a future manual Connect. Reuses the
    /// exact same authenticated "closing" wire message `shutDown()` sends
    /// (PROTOCOL.md 6.1) — the Mac already treats a received `closing` as a
    /// deliberate goodbye and suppresses its own auto-reconnect for this
    /// peer (`onPeerClosed` -> `autoConnectPolicy.suppress` in
    /// OpenSidecarMacApp.swift), so no protocol or Mac-side change was
    /// needed for that half of the contract.
    func disconnect(completion: (@Sendable () -> Void)? = nil) {
        let queue = self.queue
        let sendTargetBox = self.sendTargetBox
        let reconnectContext = self.reconnectContext
        let pipeline = self.pipeline
        let uiSink = self.uiSink
        let pendingDisconnectFinishBox = self.pendingDisconnectFinishBox
        let selfBox = self.selfBox
        queue.async {
            let finishedOnce = OnceGuard()
            // Self-free by construction (Receiver Swift6-Teardown): every
            // owner `finish` touches — `pendingDisconnectFinishBox`,
            // `reconnectContext`, `pipeline`, `uiSink`, `queue`,
            // `finishedOnce` — is a narrow, already-`Sendable` owner
            // captured above, so `finish` itself can be a genuinely
            // `@Sendable () -> Void` without capturing non-Sendable
            // `StreamReceiver`. It is stored into `pendingDisconnectFinishBox`
            // and passed to both `NWConnection.send`'s completion and
            // `queue.asyncAfter`, both of which require exactly that.
            let finish: @Sendable () -> Void = {
                guard finishedOnce.fireOnce() else { return }
                pendingDisconnectFinishBox.clear()
                reconnectContext.update { $0.manualConnectPeerID = nil }
                // Deliberate teardown by this device: no automatic recovery,
                // and any retry already scheduled is invalidated so it
                // cannot resurrect the session afterwards. A subsequent
                // manual Connect (`requestConnect()`) clears this the same
                // way it already clears a Mac-initiated disconnect.
                //
                // C1 review fix: `await` the actor's own teardown (which
                // sets its own status, e.g. "Waiting for Mac") BEFORE
                // setting "Disconnected" below. Both the UI reset
                // (`uiSink.publishTeardownUIReset`, MainActor-hopped) and
                // the queue-confined audio reset below are only reached
                // after this `await` completes, so the ordering the C1 fix
                // established — actor teardown status first, "Disconnected"
                // after — is unchanged.
                Task {
                    await pipeline.disconnectCurrentConnection(reason: .explicitDisconnect)
                    await uiSink.publishTeardownUIReset(status: "Disconnected")
                    // `resetAudioPlayback()` still needs `self` — it mutates
                    // `audioFormatDescription`/`audioCodecKind` and calls
                    // `deactivateAudioSessionIfNeeded()` directly on the
                    // instance, state this narrow teardown pass does not
                    // relocate into an owner of its own (see the review
                    // notes on `StreamReceiver.disconnect`). Unlike before,
                    // the pipeline/reconnect/UI teardown above no longer
                    // depends on the receiver staying alive — only this
                    // final `weak self` leg does. If the receiver has
                    // already been deallocated by this point (e.g.
                    // `ReceiverController.stop()` drops its last strong
                    // reference right after kicking teardown off), the
                    // audio reset and `completion` are skipped, but
                    // everything above them still runs regardless.
                    queue.async {
                        guard let self = selfBox.currentOnQueue() else { return }
                        self.resetAudioPlayback()
                        completion?()
                    }
                }
            }
            pendingDisconnectFinishBox.set(finish)
            guard let conn = sendTargetBox.current()?.connection, conn.state == .ready else {
                Log.info("disconnecting — no live connection")
                finish()
                return
            }
            Log.info("disconnecting — announcing closing to the Mac")
            StreamReceiver.sendControl(["type": WireMessage.closing], on: conn, sendTargetBox: sendTargetBox) {
                queue.async { finish() }
            }
            // The send completion may never fire on a dying link — don't
            // let that keep this session looking connected after going dark.
            queue.asyncAfter(deadline: .now() + 1) { finish() }
        }
    }

    private func closeSession(announcing type: String, status: String,
                              completion: (@Sendable () -> Void)?) {
        let queue = self.queue
        let sendTargetBox = self.sendTargetBox
        let reconnectContext = self.reconnectContext
        let pipeline = self.pipeline
        let uiSink = self.uiSink
        let tlsListenerState = self.tlsListenerState
        let pairingListenerState = self.pairingListenerState
        let selfBox = self.selfBox
        queue.async {
            let finishedOnce = OnceGuard()
            // Self-free for the same reason as `disconnect()`'s `finish` —
            // see its comment.
            let finish: @Sendable () -> Void = {
                guard finishedOnce.fireOnce() else { return }
                tlsListenerState.cancelCurrent()
                pairingListenerState.cancelCurrent()
                reconnectContext.update { $0.manualConnectPeerID = nil }
                // Deliberate teardown by this device: no automatic recovery,
                // and any retry already scheduled is invalidated so it cannot
                // resurrect the session afterwards.
                //
                // C1 review fix: same status-order fix as `disconnect()` —
                // await the actor's teardown before writing `status` here.
                Task {
                    await pipeline.disconnectCurrentConnection(reason: .explicitDisconnect)
                    await uiSink.publishTeardownUIReset(status: status)
                    // FORGET DEVICE / app quit: queued audio dies with the
                    // session. Same `self`/`weak self` reasoning as
                    // `disconnect()` — see its comment.
                    queue.async {
                        guard let self = selfBox.currentOnQueue() else { return }
                        self.resetAudioPlayback()
                        completion?()
                    }
                }
            }
            guard let conn = sendTargetBox.current()?.connection, conn.state == .ready else {
                Log.info("closing session (\(type)) — no live connection")
                finish()
                return
            }
            Log.info("closing session — announcing \(type) to the Mac")
            StreamReceiver.sendControl(["type": type], on: conn, sendTargetBox: sendTargetBox) {
                queue.async { finish() }
            }
            // The send completion may never fire on a dying link — don't
            // let that keep us accepting connections after going dark.
            queue.asyncAfter(deadline: .now() + 1) { finish() }
        }
    }

    /// Static, self-free TLS media listener construction/rearm (Receiver
    /// Swift6-TLS): captures no `StreamReceiver` — only the stable owners
    /// (`TLSListenerState`/`PairingSuppressionState`/`ReceiverAdvertisementState`),
    /// the `pipeline` actor reference, `queue`, and plain wire-identity
    /// values, so its `newConnectionHandler`/`stateUpdateHandler`/retry
    /// closures below carry the same zero-`StreamReceiver` capture graph.
    /// Trust material stays live and self-free via `TrustStore.shared`/
    /// `TLSConfigurator` (both already self-free singletons/statics) — in
    /// particular `pinnedSPKIs` stays a live closure calling
    /// `TrustStore.shared.allPinnedPeerSPKIs()` at handshake time, never a
    /// snapshotted array, so a pin added mid-session is honored without a
    /// listener rebuild. The `guard !hasCurrent()` and `install(_:)` below
    /// happen synchronously with no `await`/`Task`/queue hop between them,
    /// so two overlapping calls on `queue` can never install two listeners.
    private static func startTLSListener(
        queue: DispatchQueue, tlsListenerState: TLSListenerState,
        pairingSuppressionState: PairingSuppressionState, advertisementState: ReceiverAdvertisementState,
        pipeline: ReceiverPipelineActor, installID: String, advertisedProtocolVersion: Int
    ) {
        guard !tlsListenerState.hasCurrent(), let identity = TrustStore.shared.ownIdentity(),
              let tls = TLSConfigurator.mutualTLSOptions(
                identity: identity,
                pinnedSPKIs: { TrustStore.shared.allPinnedPeerSPKIs() },
                isListener: true, queue: queue) else {
            Log.info("secure listener unavailable — refusing network media")
            return
        }
        do {
            let tcp = NWProtocolTCP.Options(); tcp.noDelay = true
            let params = NWParameters(tls: tls, tcp: tcp)
            params.includePeerToPeer = true
            params.allowLocalEndpointReuse = true
            params.serviceClass = .interactiveVideo
            let listener = try NWListener(using: params,
                on: NWEndpoint.Port(rawValue: WireCrypto.tlsPort)!)
            tlsListenerState.install(listener)
            listener.service = advertisementState.mediaService(
                installID: installID, protocolVersion: advertisedProtocolVersion)
            listener.newConnectionHandler = { [weak listener] connection in
                guard let listener, tlsListenerState.isCurrent(listener) else { connection.cancel(); return }
                guard !pairingSuppressionState.isSuppressed() else {
                    Log.info("pairDebug: media auto-connect suppressed reason=pairingInProgress")
                    connection.cancel()
                    return
                }
                // Same race the plaintext listener above already guards
                // against (see its comment): the Mac's own restartAll()
                // cancels the old connection and immediately dials a
                // replacement, but `NWConnection.cancel()` doesn't retract a
                // handshake already in this listener's accept queue — a
                // straggler from the connection just cancelled can complete
                // its TLS handshake moments after the real replacement is
                // already live. C1: the decision (park pending proof, or
                // adopt outright) now lives in `pipeline`
                // (`ReceiverPipelineActor.handleIncomingConnection`), which
                // owns `connection`/`pendingConnections` and reads/writes
                // them coherently.
                Task { await pipeline.handleIncomingConnection(connection) }
            }
            listener.stateUpdateHandler = { [weak listener] state in
                switch state {
                case .ready:
                    Log.info("reconnectDebug: listenerReady TLS port=\(WireCrypto.tlsPort)")
                case .failed(let error):
                    Log.info("secure listener failed: \(error)")
                    guard let listener, tlsListenerState.clearIfCurrent(listener) else { return }
                    // Fixed short backoff: mirrors the plaintext listener's
                    // retry cadence and avoids a busy loop if the port stays
                    // unavailable for a moment (e.g. right after a sleep/wake
                    // teardown/rebind race). If another listener is already
                    // installed by the time this fires, `hasCurrent()` inside
                    // the recursive call below no-ops it — no duplicate
                    // listener.
                    queue.asyncAfter(deadline: .now() + 1) {
                        startTLSListener(
                            queue: queue, tlsListenerState: tlsListenerState,
                            pairingSuppressionState: pairingSuppressionState,
                            advertisementState: advertisementState, pipeline: pipeline,
                            installID: installID, advertisedProtocolVersion: advertisedProtocolVersion)
                    }
                default: break
                }
            }
            listener.start(queue: queue)
        } catch {
            Log.info("secure listener could not be created: \(error)")
        }
    }

    /// Hops onto `queue` to rebuild the TLS listener so its pinned-peer
    /// verification snapshot picks up the peer that just finished pairing.
    /// Kept as its own method (rather than a closure inlined at the call
    /// site) so the pairing-listener's completion `Task` can trigger it
    /// without itself capturing `self` into a second escaping closure.
    private func scheduleTLSListenerRefresh() {
        Self.scheduleTLSListenerRefresh(
            queue: queue, tlsListenerState: tlsListenerState,
            pairingSuppressionState: pairingSuppressionState, advertisementState: advertisementState,
            pipeline: pipeline, installID: Self.installID, advertisedProtocolVersion: advertisedProtocolVersion)
    }

    /// Static, self-free twin of the instance method above (Receiver
    /// Swift6-Pairing-Listener), same delegation shape as the
    /// `finishExplicitPairing` pair — the pairing listener's success `Task`
    /// calls this directly with the stable owners it already captured for
    /// `startTLSListener`, so it never needs `self.pipeline`/`self`.
    private static func scheduleTLSListenerRefresh(
        queue: DispatchQueue, tlsListenerState: TLSListenerState,
        pairingSuppressionState: PairingSuppressionState, advertisementState: ReceiverAdvertisementState,
        pipeline: ReceiverPipelineActor, installID: String, advertisedProtocolVersion: Int
    ) {
        queue.async {
            tlsListenerState.cancelCurrent()
            startTLSListener(
                queue: queue, tlsListenerState: tlsListenerState,
                pairingSuppressionState: pairingSuppressionState, advertisementState: advertisementState,
                pipeline: pipeline, installID: installID, advertisedProtocolVersion: advertisedProtocolVersion)
        }
    }

    /// Receiver Swift6-Pairing-Listener: the pairing listener's
    /// `newConnectionHandler`/nested `Task` capture only stable owners
    /// (`PairingListenerState`, `ReceiverAdvertisementState`, the stable
    /// `let pairingPrompt`, `uiSink`, `queue`, `PairingSuppressionState`,
    /// `TLSListenerState`, `pipeline`, immutable `installID`/protocol
    /// version) — never `self`/a bound `StreamReceiver` method — same
    /// "capture directly instead of `self`" idiom as `startTLSListener`.
    private func startPairingListener() {
        guard !pairingListenerState.hasCurrent() else { return }
        let pairingListenerState = self.pairingListenerState
        let advertisementState = self.advertisementState
        let prompt = self.pairingPrompt
        let uiSink = self.uiSink
        let queue = self.queue
        let tlsListenerState = self.tlsListenerState
        let pairingSuppressionState = self.pairingSuppressionState
        let pipeline = self.pipeline
        let installID = Self.installID
        let advertisedProtocolVersion = self.advertisedProtocolVersion
        do {
            let params = NWParameters.tcp
            params.includePeerToPeer = true
            params.allowLocalEndpointReuse = true
            let listener = try NWListener(using: params,
                on: NWEndpoint.Port(rawValue: WireCrypto.pairingPort)!)
            pairingListenerState.install(listener)
            listener.service = advertisedPairingService
            #if DEBUG
            Log.info("pairing listener starting: type=_opendisplay-pair._tcp port=\(WireCrypto.pairingPort) id=\(Self.installID) peerToPeer=true")
            #endif
            listener.newConnectionHandler = { [weak listener] connection in
                guard let listener, pairingListenerState.isCurrent(listener) else { connection.cancel(); return }
                let localName = advertisementState.currentServiceName()
                Task {
                    defer { connection.cancel() }
                    do {
                        let paired = try await PairingNetwork.runResponder(
                            connection: connection, localID: installID,
                            localName: localName, prompt: prompt, allowIdentityChange: false)
                        await prompt.finish("Paired with \(paired.peerName)")
                        await uiSink.publishPairingSucceeded()
                        Self.finishExplicitPairing(
                            queue: queue, pairingSuppressionState: pairingSuppressionState, success: true)
                        Self.scheduleTLSListenerRefresh(
                            queue: queue, tlsListenerState: tlsListenerState,
                            pairingSuppressionState: pairingSuppressionState, advertisementState: advertisementState,
                            pipeline: pipeline, installID: installID, advertisedProtocolVersion: advertisedProtocolVersion)
                    } catch {
                        await prompt.finish(error.localizedDescription)
                        let promptStillPending = await MainActor.run { prompt.pending != nil }
                        if !promptStillPending {
                            Self.finishExplicitPairing(
                                queue: queue, pairingSuppressionState: pairingSuppressionState, success: false)
                        } else {
                            Log.info("pairDebug: duplicate responder ended without disturbing pending confirmation")
                        }
                    }
                }
            }
            listener.stateUpdateHandler = { state in
                #if DEBUG
                switch state {
                case .ready: Log.info("pairing listener ready: port=\(WireCrypto.pairingPort) type=_opendisplay-pair._tcp")
                case .failed(let error): Log.info("pairing listener failed: \(error)")
                case .waiting(let error): Log.info("pairing listener waiting: \(error)")
                case .cancelled: Log.info("pairing listener cancelled")
                default: break
                }
                #endif
            }
            listener.start(queue: queue)
        } catch {
            Log.info("pairing listener could not be created: \(error)")
        }
    }

    private func startMacPairingBrowser() {
        guard macPairingBrowser == nil else { return }
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjourWithTXTRecord(
            type: "_opendisplay-mac-pair._tcp", domain: nil), using: parameters)
        let uiSink = uiSink
        browser.browseResultsChangedHandler = { results, _ in
            let discovered = Array(results)
            DispatchQueue.main.async {
                uiSink.publishDiscoveredMacs(discovered)
                #if DEBUG
                Log.info("Mac pairing browser changed: results=\(results.count)")
                for result in results {
                    let id: String?
                    if case .bonjour(let txt) = result.metadata { id = txt["id"] } else { id = nil }
                    Log.info("Mac pairing browser result: endpoint=\(result.endpoint) id=\(id ?? "missing")")
                }
                #endif
            }
        }
        browser.stateUpdateHandler = { state in
            #if DEBUG
            Log.info("Mac pairing browser state: \(state)")
            #endif
        }
        browser.start(queue: queue)
        macPairingBrowser = browser
    }

    // C1: connection adoption (including the pending-connection race and
    // the pathUpdateHandler/stateUpdateHandler pair that decide adoption's
    // outcome) moved into `pipeline` (`ReceiverPipelineActor`). The pieces
    // below are the host-side effects it calls out to, in the exact order
    // the original inline `adopt`/`onReady` closures ran them.

    /// Runs before/alongside `pipeline` starting (or resuming) `conn` — see
    /// `ReceiverPipelineActor.adopt`. Only the display/decoder/audio reset
    /// this method still owns directly (see `resetStreamState`); the
    /// frame-assembly reset (`buffer`/SPS/PPS/VPS/`formatDesc`/the active
    /// receive generation, AND its liveness-timestamp reset) is
    /// `framePipeline.beginAdoption` — sequenced by `ReceiverPipelineActor.
    /// adopt`, not from here — see `ReceiverFramePipeline`'s file header.
    private func beginAdoptionHostWork(_ conn: NWConnection, generation: Int) {
        resetStreamState()
        receivedVideoEnabled = true
        lastCursorSeq = 0   // the sender restarts its cursor sequence per session
        // Hide the previous sender's cursor: replayed into a fresh video view
        // it would ghost over a new sender that never sends one (mirror mode
        // hides no local cursor and streams no sprite).
        let uiSink = self.uiSink
        DispatchQueue.main.async { uiSink.publishCursorReset() }
    }

    /// The host-only half of the former `onReady` closure: everything except
    /// `setConnected(true)` itself, which stays inside `pipeline`. Refreshes
    /// the liveness timestamp again at actual readiness (in addition to
    /// `framePipeline.beginAdoption`'s reset at accept time) — closes the
    /// specific window a review of this seam found: a watchdog tick racing
    /// between `pipeline` marking `conn` `.ready` and adoption's own reset
    /// would otherwise see an arbitrarily stale timestamp for a connection
    /// that just proved itself.
    ///
    /// Receiver Swift6-E1: static, taking every owner explicitly, so
    /// `makePipelineHostEffects()`'s `onConnectionReady` closure below can
    /// call it without capturing `self` — same shape as `updateTransport(for:
    /// path:transportState:)` above. `syncState`/`transportState`/
    /// `reconnectContext`/`uiSink` are the same stable, directly-captured
    /// owners already used elsewhere in that closure builder.
    private static func onConnectionReadyHostWork(
        _ conn: NWConnection, reconnectContext: ReconnectContext,
        syncState: FramePipelineSyncState, transportState: ReceiverTransportState,
        uiSink: ReceiverUISink
    ) {
        reconnectContext.update { $0.manualConnectPeerID = nil }
        syncState.recordDataReceived(Date())
        if let path = conn.currentPath {
            updateTransport(for: conn, path: path, transportState: transportState)
        }
        let resolvedPeerID = resolveAuthenticatedPeerID(from: conn)
        reconnectContext.update { $0.authenticatedPeerIDHint = resolvedPeerID }
        DispatchQueue.main.async { uiSink.publishAuthenticatedPeerID(resolvedPeerID) }
    }

    /// The address-watch liveness timer's host-only work — see
    /// `ReceiverPipelineActor.addrWatchTick`, which only checks readiness.
    /// Static, self-free (Receiver Swift6-Hello-Final): captures no
    /// `StreamReceiver` state directly — `helloState` is the sole address-
    /// dedup authority (`ReceiverHelloState.addressesChanged`), and the
    /// resend goes through the static `sendHello` below. Same comparison
    /// semantics as before: `Self.reachableAddresses()` recomputed fresh,
    /// compared order-sensitively against the last advertised list.
    private static func checkAddressChangeAndSendHello(
        _ conn: NWConnection, helloState: ReceiverHelloState,
        displayGeometryState: ReceiverDisplayGeometryState, avSyncPreference: AVSyncPreference,
        sendTargetBox: SendTargetBox, deviceKind: String, maxEncodeWide: Int?, maxEncodeHigh: Int?,
        maxFPS: Int?, advertisedProtocolVersion: Int, advertisesAddresses: Bool
    ) {
        let now = reachableAddresses()
        guard helloState.addressesChanged(now) else { return }
        // A cable was plugged (or pulled) mid-session: tell the sender,
        // it re-probes on the fresh list (PROTOCOL.md 6.4).
        Log.info("reachable addresses changed — re-sending hello")
        sendHello(
            on: conn, helloState: helloState, displayGeometryState: displayGeometryState,
            avSyncPreference: avSyncPreference, sendTargetBox: sendTargetBox, deviceKind: deviceKind,
            maxEncodeWide: maxEncodeWide, maxEncodeHigh: maxEncodeHigh, maxFPS: maxFPS,
            advertisedProtocolVersion: advertisedProtocolVersion, advertisesAddresses: advertisesAddresses)
    }

    private func updateTransport(for conn: NWConnection, path: NWPath) {
        Self.updateTransport(for: conn, path: path, transportState: transportState)
    }

    /// Static so `onPathUpdate`'s host-effect closure can call it with a
    /// directly-captured `transportState` instead of `self` — this is the
    /// only state the original instance method touched (see the call-site
    /// comment in `makePipelineHostEffects()`).
    private static func updateTransport(for conn: NWConnection, path: NWPath, transportState: ReceiverTransportState) {
        let peer = String(describing: path.remoteEndpoint ?? conn.endpoint)
        let isLoopbackPeer = peer.hasPrefix("127.0.0.1") || peer.hasPrefix("::1")
            || peer.hasPrefix("localhost") || peer.hasPrefix("[::1]")
        let route = ConnectionRoute.classify(
            isUSB: path.usesInterfaceType(.loopback) || isLoopbackPeer,
            interfaceNames: path.availableInterfaces.map(\.name),
            remoteEndpointDescription: peer)
        transportState.set(route.rawValue)
        let names = path.availableInterfaces.map(\.name).joined(separator: ",")
        Log.info("connection path from \(peer): \(names) route=\(route.rawValue)")
    }

    /// Same same-source SPKI re-encode `TrustStore`/`TLSConfigurator` use
    /// everywhere else, mirroring `OpenSidecarMacApp.resolvePinnedPeerID`
    /// (the Mac's own remote-connect-request listener) and `MacSender`'s
    /// hello-time SPKI check. `TLSConfigurator`'s verify block already
    /// refused the handshake for any certificate that isn't currently
    /// pinned, so a `nil` here only means "no TLS metadata" (the loopback
    /// USB transport, which never negotiates TLS) — never an unpinned peer
    /// that somehow still connected.
    private static func resolveAuthenticatedPeerID(from connection: NWConnection) -> String? {
        guard let metadata = connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata else {
            return nil
        }
        var resolved: String?
        sec_protocol_metadata_access_peer_certificate_chain(metadata.securityProtocolMetadata) { certificate in
            guard resolved == nil else { return }
            let secCert = sec_certificate_copy_ref(certificate).takeRetainedValue()
            guard let key = SecCertificateCopyKey(secCert),
                  let x963 = SecKeyCopyExternalRepresentation(key, nil) as Data?,
                  let pub = try? P256.Signing.PublicKey(x963Representation: x963) else { return }
            resolved = TrustStore.shared.peerID(forSPKI: pub.derRepresentation)
        }
        return resolved
    }

    // MARK: - Liveness (ping + watchdog)
    //
    // C1: the ping/addrWatch/watchdog timers themselves now live in
    // `pipeline` (`ReceiverPipelineActor.armLivenessTimers`), armed from
    // `start()`. Their host-only work is `checkAddressChangeAndSendHello`
    // above; ping and the watchdog need nothing else from the host.

    /// JSON on the video channel (pong, ping liveness) — payloads starting '{'.
    private func handleVideoChannelJSON(_ data: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else { return }
        // Captured once, locally: every `uiSink.publish*` call below crosses
        // to `@MainActor` via `DispatchQueue.main.async`, and must reach the
        // Sendable `uiSink` value directly rather than through `self.uiSink`
        // (which would re-capture non-Sendable `StreamReceiver`).
        let uiSink = self.uiSink
        // Captured once, locally, for the same reason as `uiSink` above —
        // the `Task { await pipeline... }` sites below must reach the
        // Sendable pipeline actor directly rather than through `self.pipeline`.
        let pipeline = self.pipeline
        switch type {
        case "pong":
            guard let t1 = obj["t"] as? Double, let mt = obj["mt"] as? Double else { return }
            let t2 = nowMs
            let rtt = t2 - t1
            guard rtt >= 0, rtt < 2000 else { return }
            let offset = mt - (t1 + t2) / 2
            offsetSamples.append((rtt, offset))
            if offsetSamples.count > 15 { offsetSamples.removeFirst() }
            if let best = offsetSamples.min(by: { $0.rtt < $1.rtt }) {
                presentationTiming.clockOffsetMs = best.offset
            }
            lastRttMs = rtt
        case "ping":
            // The Mac piggybacks its send-side health on liveness pings.
            if let enc = obj["encDrops"] as? Int {
                macEncDrops = enc
            } else if let drops = obj["drops"] as? Int {
                macEncDrops = drops
            }
            if let net = obj["netDrops"] as? Int {
                macNetDrops = net
            }
            macDrops = macEncDrops + macNetDrops
            macPending = obj["pending"] as? Int ?? macPending
            macInputP50 = obj["inp50"] as? Double ?? macInputP50
            macInputP95 = obj["inp95"] as? Double ?? macInputP95
            macCapFps = obj["capFps"] as? Int ?? macCapFps
        case "cursor":
            applyCursor(obj)
        case "cursorImg":
            guard let b64 = obj["png"] as? String,
                  let png = Data(base64Encoded: b64),
                  let source = CGImageSourceCreateWithData(png as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
                  let nw = obj["nw"] as? Double, let nh = obj["nh"] as? Double else {
                #if DEBUG
                Log.info("cursorTrace: cursorImg message failed to decode: keys=\(obj.keys.sorted())")
                #endif
                return
            }
            let anchor = CGPoint(x: obj["ax"] as? Double ?? 0, y: obj["ay"] as? Double ?? 0)
            let normSize = CGSize(width: nw, height: nh)
            #if DEBUG
            Log.info("cursorTrace: cursorImg received bytes=\(png.count) nw=\(nw) nh=\(nh) anchor=\(anchor)")
            #endif
            DispatchQueue.main.async { uiSink.publishCursorSprite(image: image, anchor: anchor, normSize: normSize) }
        case "displayState":
            guard let state = DisplayState.decode(messageType: type,
                                                  value: obj["state"] as? String) else { return }
            // Pause is intentional, not a failure: it shares the interruption
            // presentation but must never start automatic recovery.
            Task { await pipeline.applyDisplayPauseTransition(paused: state == .paused) }
            // PAUSE stops both media: release/flush audio here so Resume
            // starts on a clean synchronized timeline (SESSION BEHAVIOR).
            // The Mac's own capture pipeline dies underneath a pause too, so
            // no more packets would arrive anyway — this just makes sure
            // nothing already-scheduled keeps playing into the pause.
            if state == .paused { resetAudioPlayback() }
            publishDisplayState(state)
        case WireMessage.displayModeState:
            guard let rawMode = obj["mode"] as? String,
                  let mode = ReceiverDisplayMode(rawValue: rawMode) else { return }
            DispatchQueue.main.async { uiSink.publishConfirmedDisplayMode(mode) }
        case WireMessage.mirrorUnavailable:
            // Whichever offer applies (Mirror-unavailable vs. already-
            // extending-rejected) is decided from `confirmedDisplayMode`
            // once on `@MainActor` — see `applyMirrorAvailabilitySignal`.
            DispatchQueue.main.async { uiSink.publishMirrorAvailabilitySignal() }
        case WireMessage.mirrorDisplayState:
            guard let update = MirrorDisplayStateUpdate(message: obj) else { return }
            DispatchQueue.main.async { uiSink.publishMirrorDisplayState(update) }
        case WireMessage.extendShapeState:
            guard let preference = ExtendDisplayShapePreference(message: obj) else { return }
            DispatchQueue.main.async { uiSink.publishConfirmedExtendShape(preference) }
        case WireMessage.streamingProfileState:
            guard let raw = obj["profile"] as? String,
                  let profile = StreamingProfile(rawValue: raw) else { return }
            DispatchQueue.main.async { uiSink.publishStreamingProfile(profile) }
        case WireMessage.streamingPriorityState:
            guard let raw = obj["priority"] as? String,
                  let priority = StreamingPriority(rawValue: raw) else { return }
            DispatchQueue.main.async { uiSink.publishStreamingPriority(priority) }
        case WireMessage.maxFPSState:
            guard let update = MaxFPSStateUpdate(message: obj) else { return }
            DispatchQueue.main.async { uiSink.publishConfirmedMaxFPS(update) }
        case WireMessage.welcome:
            // The Mac identified itself (issue #132). If it speaks a protocol
            // older than we support, it's the Mac that needs updating — and an
            // old Mac can't diagnose that itself, so we surface it here.
            let macPV = obj["pv"] as? Int ?? WireProtocol.assumedWhenAbsent
            DispatchQueue.main.async { uiSink.publishMacProtocolVersion(macPV) }
            if macPV < WireProtocol.minSupportedPeer {
                reconnectContext.update { $0.peerIsIncompatible = true }
                let msg = "The MeowDisplay app on your Mac is too old for this \(deviceKind) app. Update MeowDisplay on your Mac to reconnect."
                DispatchQueue.main.async { uiSink.publishPeerSignal(.updateMac(message: msg)) }
            }
            // Reassert this receiver's audio preference on every welcome —
            // covers first connect, reconnect, and transport migration in
            // one place, with no separate "did we already ask" state to
            // fall out of sync (SESSION BEHAVIOR: migration must not reset
            // the user's Audio preference).
            if macPV >= WireProtocol.audioWireVersion {
                sendControl(["type": WireMessage.audioRequest, "enabled": audioPreferredBox.get()])
            } else {
                DispatchQueue.main.async { uiSink.publishAudioEnabled(false) }
            }
        case WireMessage.closing:
            // The Mac explicitly ended this session. Do not treat it as a transport failure.
            Log.info("Mac explicitly closed the session")
            Task { await pipeline.disconnectCurrentConnection(reason: .peerClosed) }
        case WireMessage.wakeInfo:
            // The Mac self-labels this with its own install ID purely as a
            // cache key — this is a network hint only (Remote Wake-on-LAN
            // foundation) and never affects trust or pairing.
            guard let peerID = obj["peer"] as? String, let mac = obj["mac"] as? String,
                  let interface = obj["interface"] as? String else { return }
            let metadata = WakeMetadata(macAddress: mac, interfaceName: interface,
                                        ipv4: obj["ipv4"] as? String,
                                        subnetMask: obj["subnet"] as? String,
                                        broadcastAddress: obj["broadcast"] as? String,
                                        updatedAt: Date())
            WakeMetadataStore.setMetadata(metadata, forPeerID: peerID)
        case WireMessage.promoteInteractiveWakeResult:
            let text: String
            if obj["success"] as? Bool == true {
                let assertionID = obj["assertionID"] as? Int ?? 0
                text = "Success (assertionID=\(assertionID))"
            } else {
                text = "Failed: \(obj["code"] as? Int ?? -1)"
            }
            Log.info("wakeDebug: promoteInteractiveWake result=\(text)")
            DispatchQueue.main.async { uiSink.publishPromoteInteractiveWakeResult(text) }
        case WireMessage.updateRequired:
            // The Mac refuses this pairing until we update from the App Store.
            // Retrying cannot fix that, so the eventual loss is terminal.
            reconnectContext.update { $0.peerIsIncompatible = true }
            let message = obj["message"] as? String
                ?? "Update MeowDisplay from the App Store to keep using your second display."
            let store = (obj["store"] as? String).flatMap { URL(string: $0) } ?? AppStore.updateURL
            DispatchQueue.main.async { uiSink.publishPeerSignal(.updateReceiver(message: message, storeURL: store)) }
        case WireMessage.receiverUI:
            guard let update = ReceiverUIPreferenceUpdate(message: obj) else { return }
            DispatchQueue.main.async { uiSink.publishReceiverUIPreferences(update) }
        case WireMessage.inputReset:
            DispatchQueue.main.async { uiSink.publishInputResetBump() }
        case WireMessage.allowInputState:
            guard let allowed = obj["allowed"] as? Bool else { return }
            // `state` is additive (pv 18+) — an older Mac never sends it, so
            // fall back to the coarse allowed/off split every peer already
            // understands. See `SessionInputWireState`.
            let state = (obj["state"] as? String).flatMap(SessionInputWireState.init(rawValue:))
                ?? (allowed ? .allowed : .off)
            DispatchQueue.main.async { uiSink.publishAllowInputStateChange(state) }
        case WireMessage.videoState:
            guard let update = VideoStateUpdate(message: obj) else { return }
            let changed = update.enabled != receivedVideoEnabled
            receivedVideoEnabled = update.enabled
            if changed || !update.enabled {
                resetDecoderForVideoStateChange()
            }
            DispatchQueue.main.async { uiSink.publishVideoState(width: update.width, height: update.height, enabled: update.enabled) }
        case WireMessage.audioState:
            guard let update = AudioStateUpdate(message: obj) else { return }
            if !update.enabled { resetAudioPlayback() }
            DispatchQueue.main.async { uiSink.publishAudioEnabled(update.enabled) }
        case WireMessage.streamCodecState:
            guard let update = StreamCodecStateUpdate(message: obj) else { return }
            if update.codec != receivedStreamCodec {
                receivedStreamCodec = update.codec
                resetDecoderForCodecChange()
            }
            Log.info("effective codec: \(update.codec.wireValue) reason: \(update.reason)")
            DispatchQueue.main.async { uiSink.publishActiveStreamCodec(update.codec) }
        default:
            break
        }
    }

    /// Shared by the TCP control path and the UDP side channel so both feed
    /// the same cursorState buffering and onCursor callback. The sequence
    /// floor lives here so the two paths can't reorder each other: around a
    /// channel switch a TCP frame queued behind video would otherwise land
    /// after (and override) a newer UDP position. Old senders put no `s` on
    /// TCP frames; those apply unconditionally, as before.
    private func applyCursor(_ obj: [String: Any]) {
        if let seq = (obj["s"] as? NSNumber)?.uint64Value {
            guard seq > lastCursorSeq else { return }
            lastCursorSeq = seq
        }
        let visible = (obj["v"] as? Int ?? 0) == 1
        let x = obj["x"] as? Double ?? 0
        let y = obj["y"] as? Double ?? 0
        cursorUpdatesThisWindow += 1
        #if DEBUG
        logCursorPositionTraceIfDue(x: x, y: y, visible: visible)
        #endif
        let uiSink = self.uiSink
        DispatchQueue.main.async { uiSink.publishCursorPosition(x: x, y: y, visible: visible) }
    }

    private func resetStreamState() {
        // C3: `buffer`/`formatDesc`/`sps`/`pps`/`vps` reset moved into
        // `framePipeline.beginAdoption` — sequenced by `ReceiverPipelineActor.
        // adopt` strictly ahead of this method (see its call site,
        // `beginAdoptionHostWork`, and `ReceiverFramePipeline`'s file
        // header). Everything below is display/decoder/audio state this
        // method still owns directly.
        lastFrameAt = nil
        frameIntervals.removeAll()
        videoTelemetry.reset()
        // A new session replaces the old one wholesale here (`adopt`) — a
        // different sender, or the same one after a full reconnect, may
        // never send a geometry this old frame's dimensions even loosely
        // match. `flushAndRemoveImage()`, unlike plain `flush()`, also
        // retires the currently-DISPLAYED image, so the previous session's
        // last frame can't linger on screen through the gap before the new
        // session's first IDR decodes. Stage D: ordered through `presenter`
        // instead of touching `displayLayer` directly.
        presenter.enqueueFlushAndRemoveImage()
        videoDecoder.enqueueReset()
        presentationTiming.resetPhotonWindow()
        // A new connection is a new generation (RECONNECT — never play
        // stale audio, and never present a video frame delayed by a
        // negative offset from the superseded connection). Shadow bump
        // first, then the ordered command — see `presentationGeneration`'s
        // doc comment.
        presentationGeneration &+= 1
        presenter.enqueueAdvanceGeneration()
        resetAudioPlayback()
    }

    // MARK: - Control messages (phone -> Mac)

    /// Every receiver platform advertises the build's full `WireProtocol.version`:
    /// iOS and MacReceiver both present the pv 17 `mirrorUnavailable` offer,
    /// MacReceiver sends no input (pv 18 state is additive), and codecs are
    /// negotiated from `hello.codecs`, never from `pv` (pv 19).
    private var advertisedProtocolVersion: Int { WireProtocol.version }

    /// Thin instance wrapper for ordinary (non-`HostEffects`) call sites —
    /// `setReceiverUIPreferencesForHello`, `announceReceiverPreferences`,
    /// `setPanel` — which are plain instance methods, not `@Sendable`
    /// closures, so referencing `self` here is not the Swift 6 problem the
    /// static helper below exists to solve.
    private func sendHello(on conn: NWConnection) {
        Self.sendHello(
            on: conn, helloState: helloState, displayGeometryState: displayGeometryState,
            avSyncPreference: avSyncPreference, sendTargetBox: sendTargetBox, deviceKind: deviceKind,
            maxEncodeWide: maxEncodeWide, maxEncodeHigh: maxEncodeHigh, maxFPS: maxFPS,
            advertisedProtocolVersion: advertisedProtocolVersion, advertisesAddresses: advertisesAddresses)
    }

    /// Static, self-free (Receiver Swift6-Hello-Final): builds and sends the
    /// exact same "hello" payload the old instance method did, from
    /// explicit owners instead of `self` — so the `@Sendable` `HostEffects`
    /// closure (`makePipelineHostEffects()`'s `sendHello`) can call it
    /// directly without capturing a `StreamReceiver`. `conn` mirrors the old
    /// method's implicit `sendControl`-via-`sendTargetBox` fallback (`nil`
    /// falls through to the current send target, exactly like
    /// `Self.sendControl`).
    private static func sendHello(
        on conn: NWConnection?, helloState: ReceiverHelloState,
        displayGeometryState: ReceiverDisplayGeometryState, avSyncPreference: AVSyncPreference,
        sendTargetBox: SendTargetBox, deviceKind: String, maxEncodeWide: Int?, maxEncodeHigh: Int?,
        maxFPS: Int?, advertisedProtocolVersion: Int, advertisesAddresses: Bool
    ) {
        // Receiver Swift6-Geometry-1: one atomic snapshot instead of three
        // separate unsynchronized field reads — see
        // `ReceiverDisplayGeometryState`'s type doc.
        let geometry = displayGeometryState.snapshot()
        var hello: [String: Any] = [
            "type": "hello",
            "pixelsWide": geometry.pixelsWide,
            "pixelsHigh": geometry.pixelsHigh,
            "scale": geometry.scale,
            "device": deviceKind,
            "id": Self.installID,
            "pv": advertisedProtocolVersion,   // issue #132 — absent on old receivers
            "pp": WireProtocol.pairingVersion, // unauthenticated pairing-version hint, early UX only
        ]
        if deviceKind != "Mac" {
            // Receiver Swift6-Hello-2: the 11 announced preference mirrors
            // now come from `helloState`'s snapshot — the sole authoritative
            // store — instead of `self`'s own stored properties.
            let prefs = helloState.snapshot()
            hello["trayEnabled"] = prefs.trayEnabled
            hello["keyboardButtonEnabled"] = prefs.keyboardButtonEnabled
            // Read visibility for the connected Mac's per-device Settings
            // detail (PRODUCT: per-device receiver settings) — the receiver
            // stays the authoritative store for all of these; this only
            // reports the current value, exactly like tray/keyboard above.
            hello["functionTrayEnabled"] = prefs.functionTrayEnabled
            hello["inputMode"] = prefs.inputMode.rawValue
            hello["trackpadSensitivity"] = prefs.trackpadSensitivity
            hello["hapticsEnabled"] = prefs.hapticsEnabled
            hello["avoidNotch"] = prefs.avoidNotch
            hello["pinchTarget"] = prefs.pinchTarget.rawValue
            hello["rotateTarget"] = prefs.rotateTarget.rawValue
            hello["snapRotation"] = prefs.snapRotation
            // Reuses `AppGestureCommands`'s own `Codable` conformance rather
            // than a hand-written field list — see `ReceiverUIPreferenceUpdate`.
            if let data = try? JSONEncoder().encode(prefs.appGestureCommands),
               let obj = try? JSONSerialization.jsonObject(with: data) {
                hello["appGestureCommands"] = obj
            }
            // Receiver-local playback timing — never Mac-pushed (only the
            // receiver can judge its own speaker/headphone latency), but
            // reported so Streaming/device detail can show the real value
            // instead of a fake always-zero placeholder.
            hello["avSyncOffsetMs"] = avSyncPreference.get()
        }
        // Additive capability: only offered while the UDP listener is bound,
        // so a sender never dials a port nobody answers on.
        // Additive: decode ceiling (PROTOCOL.md 6.5) — ask for the full
        // desktop but a stream no larger than this machine can decode.
        if let maxEncodeWide, let maxEncodeHigh {
            hello["maxEncodeWide"] = maxEncodeWide
            hello["maxEncodeHigh"] = maxEncodeHigh
        }
        // Additive: this receiver's real maximum display refresh rate
        // (high-refresh milestone) — the Mac clamps every Streaming Profile
        // to it (`StreamingFPSPolicy`), same "don't advertise capability we
        // don't actually have" contract as maxEncodeWide/High above.
        if let maxFPS { hello["maxFPS"] = maxFPS }
        // Additive: hardware-decode-capable codec list (HEVC milestone,
        // PROTOCOL.md 6.9 / `WireProtocol.hevcCodecWireVersion`) — H.264 is
        // always included (advertised as today, unconditionally); `"hevc"`
        // is added only when `Self.supportsHardwareHEVCDecode` actually
        // proved a real hardware decoder exists, never guessed from OS
        // version.
        hello["codecs"] = Self.supportedCodecs.map(\.wireValue)
        // Additive: the addresses this receiver can be reached on, so the
        // sender can probe for a better (cabled) path and migrate a WiFi
        // session onto it — mDNS resolution under an interface-restricted
        // dial stalls, a literal address does not (PROTOCOL.md 6.4).
        // Mac receivers only: a cabled phone reaches the sender over
        // usbmuxd, and advertising a phone's WiFi fe80 would invite a
        // false "upgrade" onto a bridged-LAN path that still crosses the
        // phone's radio — and then have the session classified as a cable
        // whose loss must end it instead of reconnecting.
        let addrs = advertisesAddresses ? reachableAddresses() : []
        if !addrs.isEmpty { hello["addrs"] = addrs }
        // Sole address-dedup authority is `helloState`
        // (`ReceiverHelloState.recordAdvertisedAddresses`) — matches its
        // exact contract: unconditional overwrite regardless of send
        // success, including the empty-list case (see that method's doc).
        helloState.recordAdvertisedAddresses(addrs)
        sendControl(hello, on: conn, sendTargetBox: sendTargetBox)
        Log.info("hello sent")
    }

    /// Every IP address of an up, non-loopback interface, for hello.addrs.
    /// Link-local IPv6 is sent bare (no scope): the zone id only means
    /// something on the machine holding the interface, so the sender scopes
    /// it to each of its own candidate interfaces when probing. Virtual and
    /// peer-to-peer interfaces (awdl/llw/utun) never carry this traffic and
    /// are skipped.
    private static func reachableAddresses() -> [String] {
        var result: [String] = []
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return result }
        defer { freeifaddrs(list) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            let flags = Int32(ifa.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0,
                  let sa = ifa.ifa_addr else { continue }
            let name = String(cString: ifa.ifa_name)
            // anpi* is Apple's internal peripheral/debug interface: TCP
            // handshakes complete over it but it cannot carry the stream —
            // a session migrated onto it stalls within seconds (field log
            // 18:59). The user-facing USB-C host-to-host link is a plain en.
            if name.hasPrefix("awdl") || name.hasPrefix("llw") || name.hasPrefix("utun")
                || name.hasPrefix("pdp_ip") || name.hasPrefix("anpi") { continue }
            let family = sa.pointee.sa_family
            guard family == UInt8(AF_INET) || family == UInt8(AF_INET6) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let len = family == UInt8(AF_INET)
                ? socklen_t(MemoryLayout<sockaddr_in>.size)
                : socklen_t(MemoryLayout<sockaddr_in6>.size)
            guard getnameinfo(sa, len, &host, socklen_t(host.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let hostLength = host.firstIndex(of: 0) ?? host.count
            var addr = String(decoding: host[..<hostLength].map(UInt8.init(bitPattern:)), as: UTF8.self)
            // getnameinfo appends %scope to link-local IPv6 — strip it, the
            // receiver-side zone id is meaningless to the sender.
            if let percent = addr.firstIndex(of: "%") { addr = String(addr[..<percent]) }
            if !result.contains(addr) { result.append(addr) }
            if result.count >= 12 { break }
        }
        return result
    }

    /// Touch events: x/y normalized [0,1] in video space, origin top-left.
    /// Stamped in *Mac* clock time (our clock + sync offset) so the Mac can
    /// measure touch→injection latency without doing its own clock sync.
    @MainActor func sendTouch(phase: String, x: Double, y: Double) {
        guard displayState == .running else { return }
        var msg: [String: Any] = ["type": "touch", "phase": phase, "x": x, "y": y]
        if let offset = presentationTiming.clockOffsetMs { msg["t"] = nowMs + offset }
        sendUIControl(msg)
    }

    /// Two-finger scroll: dx/dy in video pixels (natural-scrolling sign).
    @MainActor func sendScroll(dx: Double, dy: Double) {
        guard displayState == .running else { return }
        sendUIControl(["type": "scroll", "dx": dx, "dy": dy])
    }

    /// Send a semantic gesture without changing the meaning of touch/scroll input.
    @MainActor func sendGesture(name: String) {
        sendUIControl(["type": "gesture", "name": name])
    }

    /// M7 pointer/click messages (pv 5). Callers MUST check
    /// `macSupportsPointerWire` first — see `PointerGestureEngine` and its
    /// use from `iOS/OpenSidecarPhoneApp.swift`'s `VideoView`.
    ///
    /// Absolute cursor move: `x`/`y` normalized [0,1] in video space, no
    /// button implied.
    @MainActor func sendPointerMove(x: Double, y: Double) {
        guard displayState == .running else { return }
        sendUIControl(["type": "pointer", "action": "move", "x": x, "y": y])
    }

    /// Relative cursor move: `dx`/`dy` in video pixels (same convention as
    /// `scroll`), no button implied.
    @MainActor func sendPointerMoveRelative(dx: Double, dy: Double) {
        guard displayState == .running else { return }
        sendUIControl(["type": "pointer", "action": "moveRelative", "dx": dx, "dy": dy])
    }

    /// Presses `button` down at the Mac's current cursor position with the
    /// given click count (1 = single, 2 = double, 3 = triple — mirrors
    /// `NSEvent.clickCount`/`CGEventClickState`).
    @MainActor func sendPointerDown(button: PointerButton, clickCount: Int) {
        guard displayState == .running else { return }
        sendUIControl(["type": "pointer", "action": "down", "button": button.wireValue, "clickCount": clickCount])
    }

    /// Releases `button`. Every `down` a receiver sends MUST be followed by
    /// a matching `up` (or disconnect — senders MUST release a still-held
    /// button on session loss regardless, mirroring `keyboard`'s down/up
    /// contract).
    @MainActor func sendPointerUp(button: PointerButton, clickCount: Int) {
        guard displayState == .running else { return }
        sendUIControl(["type": "pointer", "action": "up", "button": button.wireValue, "clickCount": clickCount])
    }

    /// Apple Pencil stroke/hover. azimuth and altitude are radians.
    /// rotation is always 0 until Apple Pencil Pro barrel roll is wired up.
    @MainActor func sendPencil(phase: String, x: Double, y: Double,
                    pressure: Double, azimuth: Double, altitude: Double) {
        guard displayState == .running else { return }
        var msg: [String: Any] = [
            "type": "pencil",
            "phase": phase,
            "x": x, "y": y,
            "pressure": pressure,
            "azimuth": azimuth,
            "altitude": altitude,
            "rotation": 0,   // TODO: UIKit rollAngle once Pencil Pro is available
        ]
        if let offset = presentationTiming.clockOffsetMs { msg["t"] = nowMs + offset }
        sendUIControl(msg)
    }

    @MainActor func sendProximity(entering: Bool, x: Double, y: Double) {
        guard displayState == .running else { return }
        sendUIControl(["type": "proximity", "entering": entering, "x": x, "y": y])
    }

    /// Committed Unicode text from the native software/hardware keyboard
    /// (M4). Never carries marked/IME-intermediate text — callers commit
    /// only finished text (see `RemoteKeyboardInputView`).
    @MainActor func sendKeyboardText(_ text: String) {
        guard displayState == .running, macSupportsKeyboardWire, !text.isEmpty else { return }
        sendUIControl(["type": "keyboard", "action": "text", "text": text])
    }

    /// An atomic special key from the software keyboard (e.g. Return,
    /// Backspace) with no down/up lifecycle to track. `usage` is a USB HID
    /// keyboard-page usage number.
    @MainActor func sendKeyboardPress(usage: Int, modifiers: [String] = []) {
        guard displayState == .running, macSupportsKeyboardWire else { return }
        #if DEBUG
        // 42 = HID usage keyboardDeleteOrBackspace (UIKeyboardHIDUsage's raw
        // value) — this file also compiles into the macOS receiver, which
        // has no UIKit, so the literal is used instead of that enum.
        if usage == 42 {
            Log.info("keyboardDebug: specialPress sent usage=\(usage)")
        }
        #endif
        sendUIControl(["type": "keyboard", "action": "press", "usage": usage,
                     "modifiers": modifiers])
    }

    @MainActor func sendModifier(_ modifier: ControlModifier, down: Bool) {
        guard displayState == .running,
              macProtocolVersion >= WireProtocol.receiverControlsWireVersion else { return }
        sendUIControl(["type": "keyboard", "action": down ? "modifierDown" : "modifierUp",
                     "modifier": modifier.rawValue])
    }

    @MainActor func sendCancelActiveInput() {
        guard macProtocolVersion >= WireProtocol.receiverControlsWireVersion else { return }
        sendUIControl(["type": "keyboard", "action": "cancel"])
    }

    /// `true`: requests control of THIS session — never an assignment, the
    /// Mac may show its owner a prompt, auto-grant, or auto-deny per that
    /// peer's policy, and the confirmed result always arrives back via
    /// `onAllowInputStateChange`, whether or not it matches what was
    /// requested. `false`: releases this session's own grant, always
    /// honored immediately with no Mac decision needed (narrowing is always
    /// safe). A no-op against an older Mac (pre `allowInputWireVersion`) or
    /// while disconnected.
    @MainActor func requestAllowInput(_ allowed: Bool) {
        guard connected, macProtocolVersion >= WireProtocol.allowInputWireVersion else { return }
        sendUIControl(["type": WireMessage.allowInputRequest, "allowed": allowed])
    }

    @MainActor func requestVideoEnabled(_ enabled: Bool) {
        guard connected, macSupportsVideoControl else { return }
        sendUIControl(["type": WireMessage.videoRequest, "enabled": enabled])
    }

    /// Requests a Mac-side streaming profile over the existing authenticated
    /// control channel. The Mac remains authoritative and reports the
    /// accepted profile back through `streamingProfileState`.
    @MainActor func requestStreamingProfile(_ profile: StreamingProfile,
                                 customFrameRate: CustomFrameRateSelection = .auto) {
        guard connected else { return }
        sendUIControl(["type": WireMessage.streamingProfileRequest,
                     "profile": profile.rawValue,
                     "customFrameRate": customFrameRate.rawValue])
    }

    /// Requests a Mac-side Streaming Priority change over the existing
    /// authenticated control channel. The Mac remains authoritative and
    /// reports the accepted priority back through `streamingPriorityState`.
    @MainActor func requestStreamingPriority(_ priority: StreamingPriority) {
        guard connected else { return }
        sendUIControl(["type": WireMessage.streamingPriorityRequest,
                     "priority": priority.rawValue])
    }

    /// Turns Mac system audio on/off for this receiver. Persists the
    /// preference in-memory and resends it on every subsequent `welcome`
    /// (see the `WireMessage.welcome` handler) so reconnection, transport
    /// migration, and a fresh pairing after Forget Device all restore it —
    /// never a stale callback re-enabling audio after those transitions,
    /// because each one re-derives the request from this single value
    /// rather than replaying anything queued.
    @MainActor func requestAudioEnabled(_ enabled: Bool) {
        let box = audioPreferredBox
        queue.async { box.set(enabled) }
        guard connected, macSupportsAudio else { return }
        sendUIControl(["type": WireMessage.audioRequest, "enabled": enabled])
    }

    /// Seeds the preference to resend on connect/reconnect without sending
    /// anything yet (e.g. restoring a persisted Settings value at launch,
    /// before there is a connection). Use `requestAudioEnabled` for a live
    /// user toggle.
    func primeAudioPreference(_ enabled: Bool) {
        let box = audioPreferredBox
        queue.async { box.set(enabled) }
    }

    /// Asks the connected Mac to call IOPMAssertionDeclareUserActivity, over
    /// the same authenticated session as every other control message — there
    /// is no separate channel for it, so an unauthenticated/unpaired peer
    /// could never send this even if it wanted to. Driven automatically by
    /// `WakeConnectCoordinator`; `PromoteInteractiveWakeView` (DEBUG-only)
    /// also exposes it as a manual diagnostic.
    @MainActor @Published var promoteInteractiveWakeResult: String?

    @MainActor func requestPromoteInteractiveWake() {
        guard connected else { return }
        Log.info("wakeDebug: promoteInteractiveWake request sent")
        sendUIControl(["type": WireMessage.promoteInteractiveWake])
    }

    @MainActor func sendNativeAppGesture(kind: NativeAppGestureKind,
                              phase: NativeAppGesturePhase,
                              delta: Double) {
        guard displayState == .running,
              macProtocolVersion >= WireProtocol.nativeAppGestureWireVersion else { return }
        sendUIControl(["type": WireMessage.nativeAppGesture,
                     "kind": kind.rawValue,
                     "phase": phase.rawValue,
                     "delta": delta])
    }

    /// Retire every decoded/presented frame without forgetting `videoSize`:
    /// that geometry is still the Direct Touch mapping surface while video is
    /// off. The next video-on stream begins from fresh SPS/PPS + an IDR.
    /// C3: `framePipeline` independently notices this same `videoState`
    /// message (see `ReceiverFramePipeline.applyControlStateIfNeeded`) and
    /// clears its own `formatDesc`/SPS/PPS/VPS there — this method now only
    /// owns the display/decoder (C4/D) half of the reset.
    private func resetDecoderForVideoStateChange() {
        presenter.enqueueFlushAndRemoveImage()
        videoDecoder.enqueueReset()
    }

    /// HEVC milestone: a codec change (Auto re-deciding, an explicit
    /// preference flip, or a runtime HEVC->H.264 fallback on the Mac) needs
    /// the exact same clean boundary a video-state change gets — no mixed-
    /// codec decode state, ever. Requests a fresh keyframe so the next
    /// frame carries the new codec's parameter sets.
    private func resetDecoderForCodecChange() {
        resetDecoderForVideoStateChange()
        sendControl(["type": "kf"])
    }

    /// Requests a mode transition without predicting its outcome. The Mac
    /// confirms the actual mode after its existing capture setup succeeds.
    @MainActor
    @discardableResult
    func requestDisplayMode(_ mode: ReceiverDisplayMode) -> Bool {
        guard connected,
              macProtocolVersion >= WireProtocol.displayModeWireVersion,
              videoEnabled || mode == .mirror,
              displayModeRequestState.request(mode) else { return false }
        pendingDisplayMode = displayModeRequestState.pendingMode
        controlResetGeneration &+= 1
        sendCancelActiveInput()
        sendUIControl(["type": WireMessage.displayModeRequest, "mode": mode.rawValue])
        // A mode switch rebuilds the Mac's session, so the confirmation
        // legitimately arrives after a reconnect — the pending flag must
        // survive that. It must never survive a Mac that simply never
        // answered, so every request is also retired on a deadline.
        let generation = displayModeRequestState.pendingGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.displayModeRequestTimeout) { [weak self] in
            self?.expirePendingDisplayMode(generation: generation)
        }
        return true
    }

    /// How long the receiver waits for the Mac's authoritative reply before
    /// giving the control back to the user. Generous: the reply only lands
    /// once the rebuilt capture session is actually streaming.
    private static let displayModeRequestTimeout: TimeInterval = 15

    @MainActor
    private func expirePendingDisplayMode(generation: Int) {
        guard displayModeRequestState.expirePending(generation: generation) else { return }
        pendingDisplayMode = nil
        Log.info("display mode request timed out — keeping \(displayModeRequestState.confirmedMode?.rawValue ?? "unknown")")
    }

    /// "Use Extend" from the Mirror-unavailable offer: sends the EXISTING
    /// authoritative `displayModeRequest` (`requestDisplayMode`) — never a
    /// parallel mode-switch mechanism. Clearing the offer first means a fast
    /// double-tap cannot present the alert a second time; `requestDisplayMode`
    /// itself already guards against a second in-flight request regardless.
    @MainActor
    func acceptMirrorUnavailableOffer() {
        mirrorUnavailable = false
        requestDisplayMode(.extend)
    }

    /// "Cancel" from the Mirror-unavailable offer: deliberately end this
    /// attempted session — identical semantics to the live Disconnect
    /// action (`disconnect()`). Trust, pairing, the Remote endpoint, and
    /// Wake metadata all remain; only this attempt ends.
    func declineMirrorUnavailableOffer() {
        let uiSink = self.uiSink
        DispatchQueue.main.async { uiSink.publishMirrorUnavailableClear() }
        disconnect()
    }

    /// Dismisses the simple informational "Mirror requires an active
    /// physical display" state — no wire message, purely local UI state
    /// (unlike the offer, there is nothing to accept/decline here).
    func dismissMirrorRejection() {
        let uiSink = self.uiSink
        DispatchQueue.main.async { uiSink.publishMirrorRejectionClear() }
    }

    /// Asks the connected Mac to change its Mirror capture source. The Mac
    /// remains the single canonical owner (`SenderController.mirrorDisplayUUID`,
    /// the same setting its own Settings picker writes) — this only requests;
    /// the confirmed state always arrives back via a fresh `mirrorDisplayState`.
    /// `uuid: nil` requests Auto. A no-op against an older Mac, while
    /// disconnected, or for a display not in the Mac's own last-reported
    /// inventory (never trust a stale/local UUID the Mac hasn't vouched for).
    @MainActor func requestMirrorDisplaySelection(_ uuid: String?) {
        guard connected, macProtocolVersion >= WireProtocol.mirrorDisplayWireVersion else { return }
        let knownUUIDs = Set(mirrorDisplayState?.displays.map(\.uuid) ?? [])
        if let uuid, !knownUUIDs.contains(uuid) { return }
        var dict: [String: Any] = ["type": WireMessage.mirrorDisplayRequest]
        if let uuid { dict["selectedUUID"] = uuid }
        sendUIControl(dict)
    }

    /// Deliberate session teardown (stop/sleep/close): the Mac's mode is no
    /// longer known and any in-flight request dies with the session.
    func resetDisplayModeState() {
        let uiSink = self.uiSink
        DispatchQueue.main.async { uiSink.publishDisplayModeStateReset() }
    }

    @MainActor
    func applyConfirmedDisplayMode(_ mode: ReceiverDisplayMode) {
        let shouldConfirmWithHaptic = displayModeRequestState.confirm(mode)
        confirmedDisplayMode = displayModeRequestState.confirmedMode
        pendingDisplayMode = displayModeRequestState.pendingMode
        if shouldConfirmWithHaptic { displayModeConfirmationGeneration &+= 1 }
        // Any authoritative mode confirmation — Mirror resuming on its own
        // because a physical display returned, or Extend actually starting
        // — means a still-showing Mirror-unavailable offer is moot. This is
        // what makes the offer disappear from the screen if the Mac already
        // resolved it before the user answered, so a stale tap can no
        // longer reach a "Use Extend" button that isn't there anymore.
        mirrorUnavailable = false
        mirrorRejectedWhileExtending = false
    }

    /// Requests an Extend display shape change without predicting its
    /// outcome — same request/confirm contract as `requestDisplayMode`. A
    /// no-op against a Mac below `extendShapeWireVersion`, while
    /// disconnected, or with a request already outstanding.
    @MainActor
    @discardableResult
    func requestExtendShape(_ preference: ExtendDisplayShapePreference) -> Bool {
        guard connected,
              macProtocolVersion >= WireProtocol.extendShapeWireVersion,
              extendShapeRequestState.request(preference) else { return false }
        pendingExtendShape = extendShapeRequestState.pending
        var dict = preference.wireFields
        dict["type"] = WireMessage.extendShapeRequest
        sendUIControl(dict)
        let generation = extendShapeRequestState.pendingGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.displayModeRequestTimeout) { [weak self] in
            self?.expirePendingExtendShape(generation: generation)
        }
        return true
    }

    @MainActor
    private func expirePendingExtendShape(generation: Int) {
        guard extendShapeRequestState.expirePending(generation: generation) else { return }
        pendingExtendShape = nil
        Log.info("extend shape request timed out — keeping \(extendShapeRequestState.confirmed?.shape.rawValue ?? "unknown")")
    }

    /// Deliberate session teardown: the Mac's active shape is no longer
    /// known and any in-flight request dies with the session.
    func resetExtendShapeState() {
        let uiSink = self.uiSink
        DispatchQueue.main.async { uiSink.publishExtendShapeStateReset() }
    }

    @MainActor
    func applyConfirmedExtendShape(_ preference: ExtendDisplayShapePreference) {
        _ = extendShapeRequestState.confirm(preference)
        confirmedExtendShape = extendShapeRequestState.confirmed
        pendingExtendShape = extendShapeRequestState.pending
    }

    /// Requests a receiver-enforced max-FPS change without predicting its
    /// outcome — same request/confirm contract as `requestExtendShape`. A
    /// no-op against a Mac below `maxFPSWireVersion`, while disconnected, or
    /// with a request already outstanding.
    @MainActor
    @discardableResult
    func requestMaxFPS(_ preference: ReceiverMaxFPSPreference) -> Bool {
        guard connected,
              macProtocolVersion >= WireProtocol.maxFPSWireVersion,
              maxFPSRequestState.request(preference) else { return false }
        pendingMaxFPS = maxFPSRequestState.pending
        var dict = preference.wireFields
        dict["type"] = WireMessage.maxFPSRequest
        sendUIControl(dict)
        let generation = maxFPSRequestState.pendingGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.displayModeRequestTimeout) { [weak self] in
            self?.expirePendingMaxFPS(generation: generation)
        }
        return true
    }

    @MainActor
    private func expirePendingMaxFPS(generation: Int) {
        guard maxFPSRequestState.expirePending(generation: generation) else { return }
        pendingMaxFPS = nil
        Log.info("max FPS request timed out — keeping \(maxFPSRequestState.confirmed.map(String.init(describing:)) ?? "unknown")")
    }

    /// Deliberate session teardown: the Mac's active max-FPS state is no
    /// longer known and any in-flight request dies with the session.
    func resetMaxFPSState() {
        let uiSink = self.uiSink
        DispatchQueue.main.async { uiSink.publishMaxFPSStateReset() }
    }

    @MainActor
    func applyConfirmedMaxFPS(_ update: MaxFPSStateUpdate) {
        _ = maxFPSRequestState.confirm(update.preference)
        confirmedMaxFPS = maxFPSRequestState.confirmed
        pendingMaxFPS = maxFPSRequestState.pending
        lastMaxFPSState = update
    }

    /// A hardware key going down, for keys the Mac must hold (arrows,
    /// modified shortcuts). `modifiers` are named protocol modifiers, not
    /// raw UIKit flags.
    @MainActor func sendKeyboardDown(usage: Int, modifiers: [String]) {
        guard displayState == .running, macSupportsKeyboardWire else { return }
        sendUIControl(["type": "keyboard", "action": "down", "usage": usage, "modifiers": modifiers])
    }

    /// The matching release for `sendKeyboardDown`.
    @MainActor func sendKeyboardUp(usage: Int, modifiers: [String]) {
        guard displayState == .running, macSupportsKeyboardWire else { return }
        sendUIControl(["type": "keyboard", "action": "up", "usage": usage, "modifiers": modifiers])
    }

    private func sendControl(_ message: [String: Any], on conn: NWConnection? = nil,
                             completion: (@Sendable () -> Void)? = nil) {
        Self.sendControl(message, on: conn, sendTargetBox: sendTargetBox, completion: completion)
    }

    /// Static so `sendPing`'s host-effect closure (E1a) can call it with a
    /// directly-captured `sendTargetBox` instead of `self` — this is the
    /// only state the instance method touched beyond its parameters.
    ///
    /// `completion` is `@Sendable`: its only two callers (`disconnect`'s and
    /// `closeSession`'s `finish` legs) pass `{ queue.async { finish() } }`,
    /// where `queue` is a `DispatchQueue` and `finish` is already declared
    /// `@Sendable () -> Void` — both genuinely safe to cross into
    /// `NWConnection.send`'s `@Sendable` completion context.
    private static func sendControl(_ message: [String: Any], on conn: NWConnection? = nil,
                                     sendTargetBox: SendTargetBox, completion: (@Sendable () -> Void)? = nil) {
        // C1: `connection` moved into `pipeline`; every background-queue-
        // confined caller that used to fall through to it (liveness ping,
        // decoder-reset keyframe requests, the periodic stats report) now
        // falls through to `sendTargetBox` instead — the same synchronous,
        // generation-guarded mirror the `@MainActor` input surface already
        // reads via `sendUIControl`.
        guard let conn = conn ?? sendTargetBox.current()?.connection,
              let payload = try? JSONSerialization.data(withJSONObject: message) else {
            completion?()
            return
        }
        var header = UInt32(payload.count).bigEndian
        var frame = Data(bytes: &header, count: 4)
        frame.append(payload)
        conn.send(content: frame, completion: .contentProcessed { error in
            if let error { Log.info("control send error: \(error)") }
            completion?()
        })
    }

    /// RC-3 SendTarget checkpoint: the entry point for the `@MainActor`
    /// input/request surface (touch, pointer, keyboard, modifiers, gestures,
    /// and the `request*` preference methods). Reads `sendTargetBox`
    /// synchronously — always instantaneously current, no publication lag.
    @MainActor
    private func sendUIControl(_ message: [String: Any]) {
        sendControl(message, on: sendTargetBox.current()?.connection)
    }

    // MARK: - Socket read + length-prefixed deframing + Annex B parse

    // C3: the ordered receive loop, length-prefixed deframing, and Annex-B/
    // SPS-PPS-VPS/format-description parsing that used to live here all
    // moved into `framePipeline` (`ReceiverFramePipeline`) as one coherent
    // high-frequency cluster — see its file header for the ingress-
    // ordering and reset/adoption-seam invariants it preserves.
    // `handleVideoChannelJSON` below is unchanged and still owns every
    // control-message effect; it is now reached via `OutputEffects.
    // controlMessage` (see `makeFramePipelineOutputEffects`) instead of a
    // direct call from what was `handleAnnexB`.

    // MARK: - Mac system audio (PROTOCOL.md section 5A)

    private func handleAudioMediaFrame(_ payload: Data) {
        guard let frame = AudioMediaFrame.decode(payload) else {
            #if DEBUG
            audioFrameDecodeFailureCount += 1
            Log.info("audioTrace: ⚠️ audio media frame decode failed (count=\(audioFrameDecodeFailureCount)) byteCount=\(payload.count)")
            #endif
            return
        }
        switch frame {
        case .config(let config):
            applyAudioConfig(config)
        case .packet(let packet):
            scheduleAudioPacket(packet)
        case .pcmConfig(let config):
            applyPCMConfig(config)
        case .pcmPacket(let packet):
            schedulePCMPacket(packet)
        }
    }

    private func applyAudioConfig(_ config: AudioConfigFrame) {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: Double(config.sampleRate),
            mFormatID: kAudioFormatMPEG4AAC,
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: 1024,
            mBytesPerFrame: 0,
            mChannelsPerFrame: UInt32(config.channelCount),
            mBitsPerChannel: 0,
            mReserved: 0)
        var formatDescription: CMAudioFormatDescription?
        let status = config.cookie.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> OSStatus in
            CMAudioFormatDescriptionCreate(
                allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil,
                magicCookieSize: raw.count, magicCookie: raw.baseAddress,
                extensions: nil, formatDescriptionOut: &formatDescription)
        }
        guard status == noErr, let formatDescription else {
            Log.info("audio format description creation failed: \(status)")
            return
        }
        beginAudioGenerationIfCodecChanged(.aac)
        #if DEBUG
        logIfAudioConfigChanged("AAC rate=\(config.sampleRate) ch=\(config.channelCount) cookieBytes=\(config.cookie.count)")
        #endif
        audioSampleRate = Double(config.sampleRate)
        audioFormatDescription = formatDescription
        ensureAudioPlaybackChain()
    }

    /// DEBUG-only diagnostic PCM bypass A/B mode counterpart of
    /// `applyAudioConfig` — see `MacSender.audioDebugPCMMode`. Builds an
    /// `lpcm` format description (32-bit Float32, interleaved, constant
    /// bytes-per-frame — same fixed wire layout `AudioCaptureEncoder.encodePCM`
    /// always produces) and reuses the exact same playback chain/anchor/
    /// timing machinery as the AAC path.
    private func applyPCMConfig(_ config: PCMConfigFrame) {
        let bytesPerFrame = UInt32(4 * Int(config.channelCount))
        var asbd = AudioStreamBasicDescription(
            mSampleRate: Double(config.sampleRate),
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: bytesPerFrame,
            mFramesPerPacket: 1,
            mBytesPerFrame: bytesPerFrame,
            mChannelsPerFrame: UInt32(config.channelCount),
            mBitsPerChannel: 32,
            mReserved: 0)
        var formatDescription: CMAudioFormatDescription?
        let status = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil, extensions: nil,
            formatDescriptionOut: &formatDescription)
        guard status == noErr, let formatDescription else {
            Log.info("PCM bypass format description creation failed: \(status)")
            return
        }
        beginAudioGenerationIfCodecChanged(.pcm)
        #if DEBUG
        logIfAudioConfigChanged("PCM rate=\(config.sampleRate) ch=\(config.channelCount)")
        pcmChannelCount = config.channelCount
        pcmPacketsSinceSanityLog = 0
        #endif
        audioSampleRate = Double(config.sampleRate)
        audioFormatDescription = formatDescription
        ensureAudioPlaybackChain()
    }

    /// A config frame whose codec differs from `audioCodecKind` means the
    /// sender began a brand-new audio generation (see `audioCodecKind`'s
    /// doc comment) — tear the whole playback chain down and rebuild fresh
    /// rather than let a live `AVSampleBufferAudioRenderer` see samples in
    /// a format it wasn't built for. Also resets every piece of
    /// generation-scoped monotonicity state (`lastAudioSequence` here,
    /// `audioPresenter`'s own `lastAudioTarget` via `reset()`) so a new
    /// generation's counters, which restart
    /// from a fresh baseline on the sender, are never compared against the
    /// previous generation's — that mismatch is exactly what produced the
    /// "expected=4856 got=1" / "non-monotonic audio playout target" log
    /// lines from the un-isolated A/B test.
    private func beginAudioGenerationIfCodecChanged(_ codec: AudioCodecKind) {
        guard audioCodecKind != codec else { return }
        if audioCodecKind != nil {
            resetAudioPlayback()
        }
        audioCodecKind = codec
        #if DEBUG
        audioGenerationCount += 1
        lastAudioSequence = nil
        lastAudioDiagnosticCaptureMs = nil
        audioPresenter.debugResetEnqueueCount()
        Log.info("audioTrace: generation=\(audioGenerationCount) codec=\(codec == .aac ? "AAC" : "PCM") playbackPath=\(activePlaybackPath == .pcmEngine ? "pcmEngine" : "legacyRenderer") starting bundleID=\(Bundle.main.bundleIdentifier ?? "?") audioReceiverLocalDecode=\(receiverAACLocalDecodeEnabled) audioReceiverDumpEnabled=\(audioDecoder.dumpEnabled) audioAACIntegrityLogging=\(aacIntegrityLoggingEnabled) dumpDirectory=\(ReceiverAudioDecoder.dumpDirectory().path)")
        #endif
    }

    #if DEBUG
    private func logIfAudioConfigChanged(_ description: String) {
        if let lastAppliedAudioConfigDescription, lastAppliedAudioConfigDescription != description {
            Log.info("audioTrace: ⚠️ audio config changed mid-session was=[\(lastAppliedAudioConfigDescription)] now=[\(description)]")
        }
        lastAppliedAudioConfigDescription = description
    }
    #endif

    private func ensureAudioPlaybackChain() {
        audioPresenter.ensurePlaybackChain(activateSession: activateAudioSessionIfNeeded)
    }

    /// Stops and releases playback state. Called on Audio Off, pause, a new
    /// connection/generation, and session teardown — never leaves a stale
    /// renderer that could play audio from a previous session (SESSION
    /// BEHAVIOR: reconnect/pause/Forget Device must not produce stale audio).
    ///
    /// `keepingFormat` is true only for a local `resync()`: the Mac's
    /// capture generation hasn't changed, so its one-time `audioState`
    /// config frame won't be resent, and this receiver must keep the
    /// format description it already has to keep decoding the packets that
    /// keep arriving. A new connection/Audio Off DOES drop it — the next
    /// audio start (if any) resends a fresh one anyway. RC-3 Stage E2:
    /// `audioPresenter.reset()` itself does not distinguish this flag — see
    /// its file header's "Reset modes" note — it always tears the
    /// renderer/synchronizer/anchor down; `keepingFormat` only gates the
    /// host-owned state below.
    private func resetAudioPlayback(keepingFormat: Bool = false) {
        audioPresenter.reset()
        if !keepingFormat {
            audioFormatDescription = nil
            audioCodecKind = nil
            deactivateAudioSessionIfNeeded()
        }
        if !keepingFormat {
            audioDecoder.reset()
        }
        // Unconditional (not gated on `!keepingFormat`, not DEBUG-only):
        // every reset call site — Audio Off, reconnect, pause, codec
        // change, Resync, playback-path switch, AND AVAudioSession
        // interruption/route-change recovery — must be able to stop PCM
        // Engine playback cleanly and flush its queue. Cheap no-op when
        // the engine was never started.
        pcmPlaybackEngine.reset()
        #if DEBUG
        lastAudioDiagnosticCaptureMs = nil
        lastAudioSequence = nil
        if !keepingFormat { lastAppliedAudioConfigDescription = nil }
        #endif
    }

    /// Deterministic, receiver-local media-clock resynchronization —
    /// exposed to the UI as "Resync". Never touches the wire, never
    /// pretends to measure physical speaker/display latency: it just
    /// discards the current audio anchor (so the next packet re-derives it
    /// from current capture timing, folding in a fresh baseline
    /// correction) and invalidates in-flight delayed video work so a
    /// negative offset can't show a stale frame after the recalibration.
    /// The user's manual A/V Sync value is untouched — only the automatic
    /// baseline term changes.
    func resync() {
        let queue = self.queue
        let selfBox = self.selfBox
        let presenter = self.presenter
        queue.async {
            guard let receiver = selfBox.currentOnQueue() else { return }
            receiver.presentationGeneration &+= 1
            presenter.enqueueAdvanceGeneration()
            receiver.resetAudioPlayback(keepingFormat: true)
            #if DEBUG
            Log.info("audioTrace: resync — anchor cleared, video generation advanced to \(receiver.presentationGeneration)")
            #endif
        }
    }

    #if os(iOS)
    private func activateAudioSessionIfNeeded() {
        registerAudioSessionObserversIfNeeded()
        guard !audioSessionActive else { return }
        do {
            try AVAudioSession.sharedInstance().setCategory(
                .playback, mode: .default, options: [.mixWithOthers])
            try AVAudioSession.sharedInstance().setActive(true)
            audioSessionActive = true
        } catch {
            Log.info("audio session activation failed: \(error)")
        }
    }

    /// Real recovery (GOAL requirement 5), not just logging: an
    /// interruption (phone call, another app's audio) or a route change
    /// (headphones/AirPods/speaker) that neither playback path reacted to
    /// at all would produce exactly the "intermittent, uncorrelated with
    /// video" glitch pattern this investigation chased for several
    /// passes — this was previously entirely unobserved. Registered once
    /// per session (`AVAudioSession` notifications aren't scoped to a
    /// generation), self-guarded by `audioSessionObserversRegistered`.
    private func registerAudioSessionObserversIfNeeded() {
        guard !audioSessionObserversRegistered else { return }
        audioSessionObserversRegistered = true
        let center = NotificationCenter.default
        center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: nil) { [weak self] note in
            let typeRaw = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt) ?? 0
            let type = AVAudioSession.InterruptionType(rawValue: typeRaw)
            let optionsRaw = (note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt) ?? 0
            let shouldResume = AVAudioSession.InterruptionOptions(rawValue: optionsRaw).contains(.shouldResume)
            self?.queue.async {
                Log.info("audioTrace: AVAudioSession interruption type=\(type == .began ? "began" : "ended") shouldResume=\(shouldResume)")
                // `.began`: the system already silenced/deactivated us —
                // there is nothing to recover yet, only something to stop
                // adding to (a stale anchor/engine would otherwise sit
                // there believing it's still playing). `.ended`: recover
                // ONLY if the system says resumption is appropriate — do
                // NOT blindly resume stale audio otherwise (GOAL: "Do not
                // blindly resume stale audio after an interruption").
                if type == .began {
                    self?.handleAudioSessionDisruption(reactivateSession: false)
                } else if type == .ended, shouldResume {
                    self?.handleAudioSessionDisruption(reactivateSession: true)
                }
            }
        }
        center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: nil) { [weak self] note in
            let reasonRaw = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt) ?? 0
            let reason = AVAudioSession.RouteChangeReason(rawValue: reasonRaw) ?? .unknown
            self?.queue.async {
                Log.info("audioTrace: AVAudioSession route change reason=\(reason)")
                switch reason {
                case .newDeviceAvailable, .oldDeviceUnavailable, .routeConfigurationChange, .categoryChange:
                    // A genuinely new/changed output route needs a fresh
                    // anchor (the old one's host-time mapping may no
                    // longer correspond to when the NEW route actually
                    // renders audio) — reactivate defensively since some
                    // route changes leave the session inactive.
                    self?.handleAudioSessionDisruption(reactivateSession: true)
                default:
                    break   // e.g. `.noSuitableRouteForCategory`, `.override` — nothing to recover from
                }
            }
        }
    }

    /// Shared recovery for both interruption-ended and a route change:
    /// flushes whichever playback path is active (legacy renderer via
    /// `resetAudioPlayback`, which now also resets `pcmPlaybackEngine`
    /// unconditionally) and, if requested, force-reactivates the
    /// `AVAudioSession` category. `audioFormatDescription` is preserved
    /// (`keepingFormat: true`) — the codec/format hasn't changed, only the
    /// output device/session state has, so the next packet re-anchors and
    /// resumes cleanly without waiting for a brand-new `AudioConfigFrame`.
    private func handleAudioSessionDisruption(reactivateSession: Bool) {
        if reactivateSession {
            audioSessionActive = false
            activateAudioSessionIfNeeded()
        }
        resetAudioPlayback(keepingFormat: true)
    }

    private func deactivateAudioSessionIfNeeded() {
        guard audioSessionActive else { return }
        audioSessionActive = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
    #else
    private func activateAudioSessionIfNeeded() {}
    private func deactivateAudioSessionIfNeeded() {}
    #endif

    private func scheduleAudioPacket(_ packet: AudioPacketFrame) {
        #if DEBUG
        checkAudioSequenceDiscontinuity(packet.sequence)
        // Receiver-side counterpart of `MacSender.sendAudioPacket`'s
        // periodic checksum — same cadence, same generation/sequence keys,
        // so the two logs line up for a by-eye comparison.
        if aacIntegrityLoggingEnabled, packet.sequence % 100 == 1 {
            Log.info("audioTrace: AAC integrity side=receiver generation=\(audioGenerationCount) seq=\(packet.sequence) capturedAtMs=\(packet.capturedAtMs) durationMs=\(packet.durationMs) payloadBytes=\(packet.payload.count) checksum=\(PCMChecksum.fnv1a(packet.payload))")
        }
        #endif
        switchPlaybackPathIfNeeded()

        switch activePlaybackPath {
        case .pcmEngine:
            // Production path: decode via the SAME shared decoder DEBUG
            // diagnostics validated (`ReceiverAudioDecoder.decode`), then
            // hand the PCM straight to `PCMPlaybackEngine` — the legacy
            // compressed-`CMSampleBuffer` path below is not touched at all.
            guard let audioFormatDescription, let clockOffsetMs = presentationTiming.clockOffsetMs else { return }
            guard let decoded = audioDecoder.decode(packet.payload, formatDescription: audioFormatDescription) else {
                Log.info("audioTrace: ⚠️ PCM engine: decode failed, dropping packet seq=\(packet.sequence)")
                return
            }
            #if DEBUG
            if receiverAACLocalDecodeEnabled { audioDecoder.analyze(decoded) }
            #endif
            let receiverCaptureMs = Double(packet.capturedAtMs) - clockOffsetMs
            pcmPlaybackEngine.enqueue(decoded, captureMs: receiverCaptureMs, avSyncOffsetMs: avSyncPreference.get())
            #if DEBUG
            // GOAL requirement 7: baseline latency/queue instrumentation,
            // not tuning — same periodic cadence as the AAC integrity log.
            if packet.sequence % 100 == 1 {
                let arrivalMs = Date().timeIntervalSince1970 * 1000 - receiverCaptureMs
                Log.info("audioTrace: PCM engine stats seq=\(packet.sequence) queuedMs=\(Int(pcmPlaybackEngine.queuedMs)) scheduled=\(pcmPlaybackEngine.scheduledCount) starvationCount=\(pcmPlaybackEngine.starvationCount) overflowDropCount=\(pcmPlaybackEngine.overflowDropCount) captureToArrivalMs=\(Int(arrivalMs))")
            }
            #endif

        case .legacyRenderer:
            scheduleDecodedAudio(
                capturedAtMs: packet.capturedAtMs, payload: packet.payload,
                sampleCount: 1,   // one AAC access unit = one compressed "sample"
                duration: AudioPacketTiming.exactSampleDuration(sampleRate: audioSampleRate),
                sampleSizeEntryCount: 1) { [payload = packet.payload] in [payload.count] }
            #if DEBUG
            if receiverAACLocalDecodeEnabled, let audioFormatDescription,
               let decoded = audioDecoder.decode(packet.payload, formatDescription: audioFormatDescription) {
                audioDecoder.analyze(decoded)
            }
            #endif
        }
        #if DEBUG
        logAudioTimingDiagnostic(sequence: packet.sequence, capturedAtMs: packet.capturedAtMs,
                                 durationMs: packet.durationMs, byteCount: packet.payload.count)
        #endif
    }

    /// DEBUG-only diagnostic PCM bypass A/B mode counterpart of
    /// `scheduleAudioPacket` — see `MacSender.audioDebugPCMMode`. Shares the
    /// exact same anchor/timing/renderer/reconnect-generation machinery via
    /// `scheduleDecodedAudio`; only the sample-buffer shape differs (many
    /// constant-size LPCM frames instead of one compressed access unit).
    private func schedulePCMPacket(_ packet: PCMPacketFrame) {
        #if DEBUG
        checkAudioSequenceDiscontinuity(packet.sequence)
        logReceiverPCMSanityIfDue(packet)
        #endif
        scheduleDecodedAudio(
            capturedAtMs: packet.capturedAtMs, payload: packet.payload,
            sampleCount: Int(packet.frameCount),
            duration: CMTime(value: 1, timescale: Int32(audioSampleRate)),
            // 0/nil: the lpcm format description already declares a
            // constant `mBytesPerFrame`, so per-sample sizes are implicit —
            // see `applyPCMConfig`.
            sampleSizeEntryCount: 0, sampleSizes: { [] })
        #if DEBUG
        logAudioTimingDiagnostic(sequence: packet.sequence, capturedAtMs: packet.capturedAtMs,
                                 durationMs: UInt32(Double(packet.frameCount) / audioSampleRate * 1000),
                                 byteCount: packet.payload.count)
        #endif
    }

    /// Shared core for both the production AAC path (`scheduleAudioPacket`)
    /// and the DEBUG-only PCM bypass path (`schedulePCMPacket`): resolves
    /// the capture-timeline anchor, builds one `CMSampleBuffer` from
    /// `payload` against whatever `audioFormatDescription` is currently
    /// active, and enqueues it. `sampleSizes` is only consulted when
    /// `sampleSizeEntryCount > 0` (compressed formats); pass `{ [] }` for an
    /// uncompressed format whose description already fixes the frame size.
    private func scheduleDecodedAudio(
        capturedAtMs: Int64, payload: Data, sampleCount: Int, duration: CMTime,
        sampleSizeEntryCount: Int, sampleSizes: () -> [Int]
    ) {
        guard let audioFormatDescription else { return }
        guard let clockOffsetMs = presentationTiming.clockOffsetMs else { return }   // clock sync not settled yet (first ~2s) — drop
        let timing = ReceiverAudioPresenter.AudioTimingSnapshot(
            clockOffsetMs: clockOffsetMs, avSyncOffsetMs: avSyncPreference.get(),
            lastVideoLatencySeconds: lastVideoLatencySeconds,
            lastVideoLatencyUpdatedAtWallMs: lastVideoLatencyUpdatedAtWallMs, nowMs: nowMs)
        audioPresenter.scheduleDecodedAudio(
            capturedAtMs: capturedAtMs, payload: payload, sampleCount: sampleCount, duration: duration,
            sampleSizeEntryCount: sampleSizeEntryCount, sampleSizes: sampleSizes,
            formatDescription: audioFormatDescription, timing: timing,
            activateSession: activateAudioSessionIfNeeded)
    }

    #if DEBUG
    /// Throttled to once every ~2s of steady playback, but logs immediately
    /// whenever the inter-packet capture-time delta looks wrong (not the
    /// expected ~21.333 ms for a 1024-sample AAC-LC frame at 48 kHz) — the
    /// signal for a timestamp discontinuity or a framing bug, not ordinary
    /// jitter, since capture-time deltas are computed from the sender's own
    /// PTS and are unaffected by network timing.
    private func logAudioTimingDiagnostic(sequence: UInt32, capturedAtMs: Int64, durationMs: UInt32, byteCount: Int) {
        guard let clockOffsetMs = presentationTiming.clockOffsetMs else { return }
        let receiverCaptureMs = Double(capturedAtMs) - clockOffsetMs
        defer { lastAudioDiagnosticCaptureMs = receiverCaptureMs }
        let deltaMs = lastAudioDiagnosticCaptureMs.map { receiverCaptureMs - $0 }
        let unexpectedDelta = deltaMs.map { !(10...40).contains($0) } ?? false
        audioDiagnosticLogCounter += 1
        guard unexpectedDelta || audioDiagnosticLogCounter % 100 == 0 else { return }
        let queuedMs = audioPresenter.debugQueuedMs(
            receiverCaptureMs: receiverCaptureMs, avSyncOffsetMs: avSyncPreference.get()) ?? 0
        // Latency characterization (GOAL "LATENCY" — measurement only, not
        // tuning): `captureToArrivalMs` is capture→"this packet is being
        // processed right now" (encode + transport + demux), computed on
        // the SAME capture-timeline coordinate space `capMs` already uses
        // (Mac wall clock, translated via `clockOffsetMs`) — never confused
        // with the A/V Sync slider, which only relates streamed video to
        // streamed audio on THIS device and has no opinion on how far
        // behind the Mac's own local speaker either one is.
        // `captureToPlayoutMs` adds the scheduled queue depth on top, i.e.
        // capture→the moment this sample buffer is actually due to sound.
        let captureToArrivalMs = Date().timeIntervalSince1970 * 1000 - receiverCaptureMs
        let captureToPlayoutMs = captureToArrivalMs + queuedMs
        let deltaText = deltaMs.map { String(format: "%.1f", $0) } ?? "-"
        Log.info("audioTrace: seq=\(sequence) capMs=\(Int(receiverCaptureMs)) deltaMs=\(deltaText) durMs=\(durationMs) bytes=\(byteCount) queuedMs=\(Int(queuedMs)) captureToArrivalMs=\(Int(captureToArrivalMs)) captureToPlayoutMs=\(Int(captureToPlayoutMs)) enqueued=\(audioPresenter.debugEnqueueCount)\(unexpectedDelta ? " ⚠️ unexpected delta" : "")")
    }

    /// Anomaly-only (GOAL section 7 "WIRE"): a gap or repeat in the sender's
    /// monotonic sequence counter means a packet was dropped/reordered
    /// somewhere between encode and here — framing corruption or a lost TCP
    /// segment recovered out of order would both show up as this.
    private func checkAudioSequenceDiscontinuity(_ sequence: UInt32) {
        defer { lastAudioSequence = sequence }
        guard let lastAudioSequence, sequence != lastAudioSequence &+ 1 else { return }
        if sequence == lastAudioSequence {
            Log.info("audioTrace: ⚠️ duplicate audio sequence \(sequence)")
        } else {
            Log.info("audioTrace: ⚠️ audio sequence discontinuity expected=\(lastAudioSequence &+ 1) got=\(sequence)")
        }
    }

    /// GOAL #4/#5/#6: verifies the payloadBytes==frameCount*channelCount*4
    /// wire invariant every packet (cheap), and logs a checksum + sample
    /// sanity summary every 100th — the receiver-side counterpart of
    /// `AudioCaptureEncoder.logPCMSanityIfDue`, using the IDENTICAL
    /// `PCMChecksum.fnv1a` algorithm so a reported sender checksum and
    /// receiver checksum for corresponding frames can be compared by eye.
    private func logReceiverPCMSanityIfDue(_ packet: PCMPacketFrame) {
        let expectedBytes = Int(packet.frameCount) * Int(pcmChannelCount) * 4
        if packet.payload.count != expectedBytes {
            Log.info("audioTrace: ⚠️ received PCM payload size invariant violated: got \(packet.payload.count) bytes, expected frameCount(\(packet.frameCount))*channelCount(\(pcmChannelCount))*4=\(expectedBytes)")
        }
        pcmPacketsSinceSanityLog += 1
        guard pcmPacketsSinceSanityLog % 100 == 1 else { return }
        let samples: [Float] = packet.payload.withUnsafeBytes { raw in
            Array(raw.bindMemory(to: Float.self))
        }
        guard !samples.isEmpty else { return }
        var minV: Float = .greatestFiniteMagnitude
        var maxV: Float = -.greatestFiniteMagnitude
        var sumSquares: Double = 0
        var peakAbs: Float = 0
        var nanCount = 0
        var infCount = 0
        for v in samples {
            if v.isNaN { nanCount += 1; continue }
            if v.isInfinite { infCount += 1; continue }
            if v < minV { minV = v }
            if v > maxV { maxV = v }
            let a = abs(v)
            if a > peakAbs { peakAbs = a }
            sumSquares += Double(v) * Double(v)
        }
        let rms = (sumSquares / Double(samples.count)).squareRoot()
        let checksum = PCMChecksum.fnv1a(samples)
        Log.info("audioTrace: PCM sanity side=receiver frameCount=\(packet.frameCount) channels=\(pcmChannelCount) min=\(minV) max=\(maxV) rms=\(String(format: "%.4f", rms)) peakAbs=\(peakAbs) nanCount=\(nanCount) infCount=\(infCount) checksum=\(checksum)")
    }
    #endif

    // MARK: - Playback path (PROTOCOL.md 5A milestone note). Mac source
    // PCM, Mac AAC encode, the wire transport (checksum-verified), and this
    // device's own AAC decode all proved clean across a multi-pass forensic
    // investigation, while `AVSampleBufferAudioRenderer` compressed-sample
    // scheduling ("Legacy SampleBuffer Renderer") kept glitching and a
    // physical A/B confirmed the SAME decoded PCM played cleanly through
    // `PCMPlaybackEngine` ("PCM Engine"). PCM Engine is now the default —
    // the legacy renderer stays fully intact as a selectable DEBUG-only
    // fallback/reference, never deleted. The wire codec is unchanged: AAC
    // is still the only thing ever sent over the network. NOT `#if DEBUG`
    // — this is the production playback path now.

    private enum PlaybackPath: Equatable { case pcmEngine, legacyRenderer }

    private var playbackPath: PlaybackPath {
        #if DEBUG
        // Normal users get no picker — this reads a DEBUG-only developer
        // toggle (Settings → Developer / Audio Diagnostics → Playback
        // Path). A Release build always returns `.pcmEngine`.
        return UserDefaults.standard.string(forKey: "audioPlaybackPath") == "legacyRenderer" ? .legacyRenderer : .pcmEngine
        #else
        return .pcmEngine
        #endif
    }
    /// Latched, never read live mid-packet — only at a
    /// `switchPlaybackPathIfNeeded` boundary, so a change never splits one
    /// packet's handling across both paths.
    private var activePlaybackPath: PlaybackPath = .pcmEngine
    private let pcmPlaybackEngine = PCMPlaybackEngine()

    /// Called once per packet — cheap (a property read + enum compare)
    /// unless the path actually changed. A change is treated exactly like
    /// any other fresh-generation reset: flush/reset the legacy renderer
    /// AND bump the PCM engine's generation, so stale audio from whichever
    /// path was just deactivated can never keep playing after a switch.
    private func switchPlaybackPathIfNeeded() {
        let desired = playbackPath
        guard desired != activePlaybackPath else { return }
        activePlaybackPath = desired
        resetAudioPlayback(keepingFormat: true)
        #if DEBUG
        Log.info("audioTrace: playbackPath=\(desired == .pcmEngine ? "pcmEngine" : "legacyRenderer")")
        #endif
    }

    // RC-3 Stage E2: the non-monotonic-playout-target anomaly check moved
    // to `ReceiverAudioPresenter.checkNonMonotonicTarget` together with the
    // `target` computation it inspects.

    // C3: `buildFormatDescription`/`buildHEVCFormatDescription` and the
    // first half of what was `enqueueFrame` (AVCC framing through
    // `CMSampleBufferCreateReady`) moved into `framePipeline`
    // (`ReceiverFramePipeline`) — see its file header. Everything from the
    // presentation-ready sample buffer onward is `presentDecodedSample`
    // below, reached via `OutputEffects.presentationFrame` instead of a
    // direct call from what was `enqueueFrame`.

    /// The tail of what was `enqueueFrame`: decode/present a sample buffer
    /// `framePipeline` already built (stopping at `CMSampleBufferCreateReady`)
    /// and record its telemetry. `sample`'s own format description (set by
    /// `framePipeline` from the SAME `formatDesc` this method used to read
    /// as a stored property) is used directly wherever C4 code needs it —
    /// see `ReceiverVideoDecoder`'s `decode`/`probeDecodedLuma` — since this
    /// class no longer keeps a copy of its own.
    private func presentDecodedSample(_ sample: CMSampleBuffer, captureMs: Double?, sendMs: Double?) {
        // Backgrounded linger is already gated in `framePipeline` before it
        // builds a sample at all; `renderingPaused` itself stays host-owned
        // since C4/D (decode/presentation) still read it below.
        if renderingPaused { return }
        // Proxy for wire throughput: the AVCC-framed size of this one video
        // frame dominates real throughput next to audio/control traffic,
        // and is more precise than counting raw TCP chunks (which could
        // span multiple frames or arrive as a fraction of one).
        bytesThisWindow += CMSampleBufferGetTotalSampleSize(sample)
        #if DEBUG
        debugFramesReceivedWindow += 1
        let arrivalNow = Date()
        if let last = debugLastArrivalAt {
            debugArrivalIntervals.append(arrivalNow.timeIntervalSince(last) * 1000)
            if debugArrivalIntervals.count > maxSamples { debugArrivalIntervals.removeFirst() }
        }
        debugLastArrivalAt = arrivalNow
        videoDecoder.enqueueProbeDecodedLuma(FrameMediaBox(sample))
        #endif

        if loggedDisplayPath != (useMetalPath && onDecodedFrame != nil) {
            loggedDisplayPath = useMetalPath && onDecodedFrame != nil
            Log.info("display path: metal=\(useMetalPath) sink=\(onDecodedFrame != nil)")
        }
        // A cheap, one-shot-consulted measurement of video's real latency —
        // updated every frame at negligible cost, but only ever READ when
        // `establishAudioAnchor` needs a fresh baseline (never used to
        // continuously steer an anchor already in play; see its doc
        // comment for why that was the actual cause of the audio stutter).
        // Measured before any deliberate negative-offset delay below, so
        // it reflects video's NATURAL latency, not one this receiver
        // intentionally added.
        if let captureMs {
            lastVideoLatencySeconds = (nowMs - captureMs) / 1000.0
            lastVideoLatencyUpdatedAtWallMs = nowMs
        }
        // Stage D: `presenter` (`ReceiverVideoPresenter`) is the sole
        // authoritative owner of `displayLayer` and the actual presentation
        // generation from here on — this closure only decides host POLICY
        // (Metal-vs-direct routing) and snapshots `presentationGeneration`,
        // the zero-hop shadow, before handing off. See `ReceiverVideoPresenter`'s
        // file header for why a snapshot taken here (rather than re-read at
        // presentation time) is still stale-safe.
        let scheduledVideoGeneration = presentationGeneration
        let viaMetalPath = useMetalPath && onDecodedFrame != nil
        let present = { [weak self] in
            guard let self else { return }
            #if DEBUG
            if viaMetalPath { self.debugFramesToDecoderWindow += 1 }
            #endif
            self.presenter.enqueuePresentSample(
                FrameMediaBox(sample), generation: scheduledVideoGeneration,
                viaMetalPath: viaMetalPath, captureMs: captureMs)
        }
        // A/V Sync: negative offset delays video by holding this specific,
        // already-decoded-or-decodable frame — a genuine per-frame
        // presentation delay, not a sleep on the network/decode path. The
        // delay is constant across frames, so arrival order is preserved.
        let videoDelayMs = AVSyncOffset.videoDelayMs(for: avSyncPreference.get())
        if videoDelayMs > 0 {
            queue.asyncAfter(deadline: .now() + .milliseconds(videoDelayMs), execute: present)
        } else {
            present()
        }

        // Per-frame timing for the performance overlay.
        let now = Date()
        if let last = lastFrameAt {
            let ms = now.timeIntervalSince(last) * 1000
            frameIntervals.append(ms)
            if frameIntervals.count > maxSamples { frameIntervals.removeFirst() }
            if ms > 50 { stallsThisWindow += 1 }
        }
        lastFrameAt = now

        // True end-to-end latency: Mac capture timestamp vs our clock mapped
        // onto the Mac's via the ping/pong offset.
        if let captureMs, let sendMs {
            encodeWindow.append(sendMs - captureMs)
            if let offset = presentationTiming.clockOffsetMs {
                let e2e = (nowMs + offset) - captureMs
                if e2e > -50, e2e < 5000 {
                    e2eWindow.append(e2e)
                    e2eRing.append(max(e2e, 0))
                    if e2eRing.count > maxSamples { e2eRing.removeFirst() }
                }
            }
        }

        framesThisWindow += 1
        let elapsed = now.timeIntervalSince(fpsWindowStart)
        if elapsed >= 1.0 {
            let fps = Int(Double(framesThisWindow) / elapsed)
            var stats = PerfStats()
            stats.fps = fps
            stats.mbps = Double(bytesThisWindow) * 8 / elapsed / 1_000_000
            stats.samples = frameIntervals
            if !frameIntervals.isEmpty {
                stats.avgFrameMs = frameIntervals.reduce(0, +) / Double(frameIntervals.count)
                stats.maxFrameMs = frameIntervals.max() ?? 0
            }
            stats.stalls = stallsThisWindow
            stats.cursorPerSec = Int(Double(cursorUpdatesThisWindow) / elapsed)
            stats.cursorLost = cursorLostThisWindow
            stats.decodeFlushes = videoTelemetry.currentFlushCount()
            stats.e2eP50 = percentile(e2eWindow, 0.5)
            stats.e2eP95 = percentile(e2eWindow, 0.95)
            stats.encodeP50 = percentile(encodeWindow, 0.5)
            stats.rttMs = lastRttMs
            stats.e2eSamples = e2eRing
            stats.transport = transport
            stats.macDrops = macDrops
            stats.macEncDrops = macEncDrops
            stats.macNetDrops = macNetDrops
            stats.macPending = macPending
            stats.inputP50 = macInputP50
            stats.inputP95 = macInputP95
            stats.capFps = macCapFps
            stats.decodeP50 = percentile(videoTelemetry.snapshotDecodeDurationsMs(), 0.5)
            let photonSamples = presentationTiming.snapshotPhotonWindow()
            stats.photonP50 = percentile(photonSamples, 0.5)
            stats.photonP95 = percentile(photonSamples, 0.95)
            framesThisWindow = 0
            bytesThisWindow = 0
            stallsThisWindow = 0
            cursorUpdatesThisWindow = 0
            cursorLostThisWindow = 0
            fpsWindowStart = now

            #if DEBUG
            let arrivalSorted = debugArrivalIntervals.sorted()
            let arrivalP50 = arrivalSorted.isEmpty ? 0 : arrivalSorted[arrivalSorted.count / 2]
            let arrivalP95 = arrivalSorted.isEmpty ? 0 :
                arrivalSorted[min(arrivalSorted.count - 1, Int(Double(arrivalSorted.count) * 0.95))]
            let arrivalMax = arrivalSorted.last ?? 0
            // Receiver Swift6-B1: atomic read-then-reset from `videoTelemetry`
            // — see `drainDebugPresentedCount()`'s doc comment.
            let debugPresentedWindow = videoTelemetry.drainDebugPresentedCount()
            // Receiver Swift6: same atomic read-then-reset, now covering the
            // decoded-frame count too — see `drainDebugDecodedCount()`.
            let debugDecodedWindow = videoTelemetry.drainDebugDecodedCount()
            Log.info("receiverPipeline: recv=\(debugFramesReceivedWindow) toDecoder=\(debugFramesToDecoderWindow) "
                + "decoded=\(debugDecodedWindow) presented=\(debugPresentedWindow) "
                + "arrivalMs(p50=\(String(format: "%.1f", arrivalP50)) p95=\(String(format: "%.1f", arrivalP95)) max=\(String(format: "%.1f", arrivalMax))) "
                + "fps=\(fps) stalls=\(stats.stalls)")
            debugFramesReceivedWindow = 0
            debugFramesToDecoderWindow = 0
            #endif

            // Every 5s, report the aggregate to the Mac so its log holds the
            // full pipeline picture for offline analysis.
            statsReportCounter += 1
            if statsReportCounter >= 5 {
                statsReportCounter = 0
                sendControl([
                    "type": "stats",
                    "transport": transport,
                    "fps": fps,
                    "mbps": (stats.mbps * 10).rounded() / 10,
                    "e2e50": stats.e2eP50.rounded(),
                    "e2e95": stats.e2eP95.rounded(),
                    "enc50": stats.encodeP50.rounded(),
                    "rtt": lastRttMs.rounded(),
                    "stalls": stats.stalls,
                    "cur": stats.cursorPerSec,
                    "curLost": stats.cursorLost,
                    "inp50": macInputP50.rounded(),
                    "capFps": macCapFps,
                    "dec50": stats.decodeP50.rounded(),
                    "ph50": stats.photonP50.rounded(),
                    "ph95": stats.photonP95.rounded(),
                    "offsetKnown": presentationTiming.clockOffsetMs != nil,
                ])
                e2eWindow.removeAll(keepingCapacity: true)
                encodeWindow.removeAll(keepingCapacity: true)
                videoTelemetry.clearDecodeDurationWindow()
                presentationTiming.resetPhotonWindow()
            }

            let uiSink = self.uiSink
            DispatchQueue.main.async { uiSink.publishPerf(fps: fps, perf: stats) }
        }
    }

    // MARK: - Explicit decode (Metal renderer path) — C4: ReceiverVideoDecoder
    //
    // The session, its generation, and the DEBUG luma probe all moved to
    // `ReceiverVideoDecoder` — see its file header. This class now only
    // decides WHETHER to route a frame through it (`present`, above) and
    // wires its `OutputEffects` back onto `queue` — see
    // `makeVideoDecoder` and `videoDecoder` below.

    /// Receiver Swift6-B2.4-E2a: the sole authoritative owner of the
    /// keyframe-request throttle timestamp — narrow lock-backed, exactly
    /// like `SendTargetBox` above, so `makeVideoDecoder()`'s `requestKeyframe`
    /// effect can capture it directly instead of `self`. `@unchecked
    /// Sendable`: `lastRequest` is a private `var` touched only inside
    /// `lock`/`unlock`, `shouldSend` is the single exposed operation, its
    /// check-and-update happens as one atomic critical section, and no
    /// mutable reference ever escapes. `internal` (not `private`), unlike
    /// its siblings here, solely so `KeyframeThrottleTests` can exercise its
    /// check-and-update math directly with injected `Date`s — no wall-clock
    /// sleeps.
    final class KeyframeThrottle: @unchecked Sendable {
        private let lock = NSLock()
        private var lastRequest: Date = .distantPast

        func shouldSend(now: Date, minimumInterval: TimeInterval) -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard now.timeIntervalSince(lastRequest) > minimumInterval else { return false }
            lastRequest = now
            return true
        }
    }

    private let keyframeThrottle = KeyframeThrottle()

    private func percentile(_ values: [Double], _ p: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let idx = min(sorted.count - 1, Int(Double(sorted.count) * p))
        return sorted[idx]
    }

    // MARK: - Session state + automatic recovery
    //
    // C1: the authoritative `sessionState`, its transitions (`mutateSession`),
    // the reconnect timer/`armReconnect`, and `cancelAutomaticRecoveryIfNeeded`
    // all moved into `pipeline` (`ReceiverPipelineActor`) — see that file.

    /// The user tapped Reconnect on the Connection Lost presentation. Runs
    /// one clean recovery run through exactly the same path as automatic
    /// recovery — no second flow, no stacked attempts.
    /// Explicit receiver-originated Connect: the trusted, paired Mac is
    /// currently disconnected (e.g. the user pressed Disconnect on the Mac,
    /// or the Mac's session died and its reconnect grace expired), so there
    /// is no live connection this side can rearm — the Mac is always the
    /// dialer. This asks the Mac to actually dial by publishing a one-shot
    /// token on the existing `_opensidecar._tcp` Bonjour advertisement the
    /// Mac already browses; see `signalConnectRequest` and the Mac-side
    /// `receiverConnectRequest` handling in OpenSidecarMacApp.
    func requestConnect() {
        let pendingDisconnectFinishBox = self.pendingDisconnectFinishBox
        let reconnectContext = self.reconnectContext
        let pipeline = self.pipeline
        let queue = self.queue
        let selfBox = self.selfBox
        queue.async {
            Log.info("connectDebug: receiverConnectRequest peer=local")
            pendingDisconnectFinishBox.callIfPresent()
            reconnectContext.update { $0.peerIsIncompatible = false }
            Task {
                await pipeline.requestManualReconnectTransition()
                queue.async {
                    selfBox.currentOnQueue()?.signalConnectRequest()
                }
            }
        }
    }

    /// Publishes a fresh one-shot token in the advertised TXT record, then
    /// clears it after a short window so a stale token can't re-trigger a
    /// connect on a later, unrelated browse update.
    private func signalConnectRequest() {
        let token = advertisementState.beginConnectRequest()
        connectRequestClearWorkItem?.cancel()
        if let tlsListener = tlsListenerState.currentListener() { tlsListener.service = advertisedService }
        let clear = DispatchWorkItem { [weak self] in
            guard let self, self.advertisementState.clearConnectRequestIfCurrent(token) else { return }
            if let tlsListener = self.tlsListenerState.currentListener() { tlsListener.service = self.advertisedService }
        }
        connectRequestClearWorkItem = clear
        queue.asyncAfter(deadline: .now() + 8.0, execute: clear)
    }

    /// Wake & Connect (`WakeConnectCoordinator`): re-publishes the one-shot
    /// receiver Connect token without touching reconnect/session state —
    /// unlike `requestConnect()`, this never cancels an in-flight recovery
    /// or resets `automaticReconnectEnabled`. The underlying token expires
    /// after ~8s (see `signalConnectRequest`); a real sleep/wake interval can
    /// easily outlast that, so the coordinator calls this on a bounded
    /// cadence while a wake attempt is active.
    func refreshConnectRequest() {
        let queue = self.queue
        let selfBox = self.selfBox
        queue.async {
            selfBox.currentOnQueue()?.signalConnectRequest()
        }
    }

    /// Unified primary Connect for one specific paired Mac: rearms the
    /// local listener and Bonjour `cr` signal exactly as `requestConnect()`
    /// always has (covers same-LAN/"Mac visible locally", for any paired
    /// Mac), then, only if `peerID` itself has a saved Remote Access
    /// endpoint, also fires one authenticated remote connect-request knock
    /// (`requestRemoteConnect`) at that Mac so it can dial back over
    /// Tailscale/private networking. Deliberately never broadcasts a knock
    /// to every paired Mac — the caller always has one deterministic
    /// target, matching the row/button that was actually tapped. All of it
    /// is explicit/user-initiated, so it runs regardless of the
    /// Auto-Reconnect preference (see `requestConnect`), and whichever
    /// route's dial completes first simply becomes the session — `adopt(_:)`
    /// already replaces any in-flight connection, so there is no risk of a
    /// duplicate session from racing routes.
    func connectPrimary(peerID: String) {
        reconnectContext.update { $0.manualConnectPeerID = peerID }
        requestConnect()
    }

    /// Sends one authenticated "please connect" knock to a paired Mac's
    /// saved Remote Access endpoint (`WireCrypto.remoteRequestPort`). The
    /// knock carries no payload — completing pinned mutual TLS against the
    /// Mac's remote connect-request listener, as this device's own already-
    /// pinned identity, *is* the entire request; the Mac resolves which
    /// peer knocked from the certificate itself, never from anything sent
    /// over the wire. This device never claims the Mac's identity and never
    /// sends host/port information the Mac is expected to trust — it only
    /// dials a locally-persisted hint the user configured themselves.
    func requestRemoteConnect(peerID: String) {
        Self.requestRemoteConnect(peerID: peerID, queue: queue)
    }

    // Receiver Swift6-RC1: self-free helper — `requestRemoteConnect` only
    // ever consumes already-established trust/endpoint data (`TrustStore`,
    // `RemoteEndpointStore`) and never mutates `StreamReceiver` state, so it
    // needs no `self` capture, matching the "static helper + stable owner"
    // idiom used by `startTLSListener` above.
    private static func requestRemoteConnect(peerID: String, queue: DispatchQueue) {
        guard let hint = RemoteEndpointStore.connectRequestEndpoint(forPeerID: peerID),
              let port = NWEndpoint.Port(rawValue: hint.port),
              let pin = TrustStore.shared.pin(peerID: peerID),
              let identity = TrustStore.shared.ownIdentity(),
              let tls = TLSConfigurator.mutualTLSOptions(
                identity: identity,
                pinnedSPKIs: { [pin] },
                isListener: false, queue: queue) else {
            Log.info("routeDebug: remote connect-request not sent for peer=\(peerID) — no endpoint/trust available")
            return
        }
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(hint.host), port: port)
        let params = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        params.includePeerToPeer = true
        let connection = NWConnection(to: endpoint, using: params)
        Log.info("routeDebug: remote connect-request knock peer=\(peerID) endpoint=\(hint.host):\(hint.port)")
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready, .failed, .cancelled:
                connection.cancel()
            default: break
            }
        }
        connection.start(queue: queue)
        // Bounded: never leave a knock connection open waiting on a Mac that
        // never answers — the handshake either completes or this tears it
        // down itself.
        queue.asyncAfter(deadline: .now() + 8.0) { connection.cancel() }
    }

    func reconnectNow() {
        let pendingDisconnectFinishBox = self.pendingDisconnectFinishBox
        let pipeline = self.pipeline
        let queue = self.queue
        let selfBox = self.selfBox
        let reconnectContext = self.reconnectContext
        queue.async {
            pendingDisconnectFinishBox.callIfPresent()
            Task {
                let phase = await pipeline.currentPhase
                if phase == .peerDisconnected {
                    // Fresh explicit intent after the Mac ended the session:
                    // the same single path Home → Connect uses.
                    Log.info("connectDebug: peerDisconnected reconnect -> requestConnect")
                    queue.async {
                        selfBox.currentOnQueue()?.requestConnect()
                    }
                    return
                }
                guard phase == .reconnectFailed || phase == .disconnected else { return }
                Log.info("manual reconnect requested")
                reconnectContext.update { $0.peerIsIncompatible = false }
                await pipeline.requestManualReconnectTransition()
                // If the listener is healthy, `armReconnect` (fired reactively)
                // won't rebuild it. A manual retry is explicitly a user asking
                // to un-stick a broken state, so force a rebind.
                queue.async {
                    selfBox.currentOnQueue()?.ensureTLSListening()
                }
            }
        }
    }

    // C1: `suspendReconnectForBackground`/`resumeReconnectIfNeeded` moved
    // into `pipeline` (`ReceiverPipelineActor`) — called directly from
    // `setAppActive` above.

    // MARK: - Helpers

    private func setStatus(_ text: String) {
        let uiSink = self.uiSink
        DispatchQueue.main.async { uiSink.publishStatus(text) }
    }

    /// `@MainActor` counterpart of `disconnect(_:)`/`closeSession(...)`'s
    /// teardown-completion UI reset, reached via `ReceiverUISink.
    /// publishTeardownUIReset(status:)` instead of the `queue`-confined
    /// `self.resetDisplayModeState()`/etc. sequence those methods used to
    /// call directly from inside a `Task`'s `queue.async` continuation —
    /// same effects, same order, just reached without capturing
    /// non-Sendable `StreamReceiver` in a `@Sendable` closure. Note that
    /// `resetDisplayModeState()`/`resetExtendShapeState()`/
    /// `resetMaxFPSState()`/`setStatus()`/`publishDisplayState()` all route
    /// through `uiSink`, i.e. `DispatchQueue.main.async` inside `ReceiverUISink`'s
    /// `@MainActor` methods, even when already running on the main actor
    /// here — so awaiting this method
    /// only guarantees those five updates have been *scheduled* from the
    /// main-actor boundary, not that their `@Published` mutations have
    /// actually applied by the time the `await` returns.
    @MainActor
    func applyTeardownUIReset(status: String) {
        resetDisplayModeState()
        resetExtendShapeState()
        resetMaxFPSState()
        setStatus(status)
        publishDisplayState(.running)
    }

    /// RC-3 SendTarget checkpoint: preparation for the C1 connection/session
    /// actor. `NWConnection` is natively `Sendable` in this project's SDK
    /// (verified directly against the toolchain under
    /// `-strict-concurrency=complete`), so this is a plain `Sendable` value,
    /// not an `@unchecked` one. It is a read-only, generation-tagged capability
    /// for best-effort outbound control sends — never a second authoritative
    /// owner: nothing reads this to cancel, replace, or adopt a connection,
    /// and nothing here participates in inbound generation/staleness
    /// decisions (those stay entirely in `adopt`/`setConnected`, the sole
    /// writers, below).
    struct SendTarget: Sendable {
        let connection: NWConnection
        let generation: Int
    }

    /// A synchronous, lock-protected holder for the current `SendTarget`.
    ///
    /// An earlier version of this checkpoint mirrored `SendTarget` into an
    /// `@MainActor` property, installed/cleared via `publishToUI`'s
    /// `DispatchQueue.main.async` hop from `adopt`/`setConnected` (both still
    /// `queue`-confined today). That hop is asynchronous, so the mirror could
    /// briefly hold a stale-but-non-nil target after a fresh `adopt()` — and
    /// because `sendUIControl` passed it as an *explicit* `on:` argument,
    /// `sendControl`'s `conn ?? connection` fallback could never see past a
    /// stale-non-nil value to the real, already-current `connection`. That is
    /// a real change in connection-selection semantics versus today, not a
    /// bounded/benign one, so it was wrong to accept.
    ///
    /// The fix is to stop treating this as something that needs an
    /// actor-style mirror at all: a `SendTarget` is a tiny `Sendable` value
    /// behind a lock, and `NSLock` lets `adopt`/`setConnected` (today) and
    /// the eventual actor (C1) install/clear it **synchronously, from
    /// whatever thread they run on** — no `@MainActor` hop, no lag, no
    /// staleness window at all, and no `Task` on the read side either.
    ///
    /// No `Sendable` conformance is declared, and none is needed:
    /// `OpenSidecarMacReceiver`'s macOS 12 deployment floor rules out
    /// `OSAllocatedUnfairLock` (macOS 13+) and `Mutex` (`Synchronization`,
    /// macOS 15+), so a checked concurrency-safe lock isn't available here —
    /// but this box is never sent across an isolation boundary as a value
    /// (it's a plain stored property on `StreamReceiver`, reached only via
    /// `self.sendTargetBox.method()`), so the compiler never asks it to
    /// prove `Sendable` in the first place. Its actual thread-safety comes
    /// entirely from the lock, verified by construction: `target` is a
    /// private `var` never touched outside `lock`/`unlock`, and the type
    /// exposes exactly three synchronized operations and nothing else — it
    /// cannot be used to bypass isolation for anything but this one
    /// send-only capability.
    /// C1: `ReceiverPipelineActor` now holds a reference to this box (to
    /// install/clear it as the sole authoritative writer) and stores it as
    /// an actor property, which requires `Sendable`. The narrow `@unchecked`
    /// conformance is safe by the same construction described above: `target`
    /// is a private `var` touched only inside `lock`/`unlock`, exactly three
    /// synchronized operations are exposed, and no mutable reference ever
    /// escapes a critical section — the class was already thread-safe by
    /// construction before this conformance made that fact visible to the
    /// type system.
    final class SendTargetBox: @unchecked Sendable {
        private let lock = NSLock()
        private var target: SendTarget?

        /// Installs `newTarget` unless a newer generation is already held —
        /// monotonic so an out-of-order call (e.g. two rapid replacements)
        /// can never regress a newer target back to a superseded one.
        func install(_ newTarget: SendTarget) {
            lock.lock(); defer { lock.unlock() }
            guard newTarget.generation >= (target?.generation ?? Int.min) else { return }
            target = newTarget
        }

        /// Clears the held target only if it still belongs to `generation` —
        /// a late clear for a superseded generation must never remove a
        /// newer target that has already replaced it.
        func clear(forGeneration generation: Int) {
            lock.lock(); defer { lock.unlock() }
            guard target?.generation == generation else { return }
            target = nil
        }

        func current() -> SendTarget? {
            lock.lock(); defer { lock.unlock() }
            return target
        }
    }

    private let sendTargetBox = SendTargetBox()

    /// The synchronized replacement for what was an unsynchronized-getter
    /// design: `pipeline`'s reconnect logic reads this instead of calling
    /// back into `StreamReceiver` off its own isolation domain. Every write
    /// site below updates it at the same point it updates its own field —
    /// see `ReceiverPipelineActor.ReconnectContext`.
    private let reconnectContext = ReconnectContext()

    /// Swift6-B2.1: the lock-backed generation/liveness snapshot shared
    /// with `framePipeline` below — held here directly, eagerly (not via
    /// the lazy actor), so `makePipelineHostEffects()`'s
    /// `getReceiveLiveness` can capture this Sendable owner on its own
    /// instead of a weak `self` reaching through `framePipeline` only to
    /// get to this same object. `framePipeline` is handed this exact
    /// instance below — there is no second, duplicated sync-state.
    private let framePipelineSyncState = FramePipelineSyncState()

    /// C3: the sole authoritative owner of the high-frequency receive/
    /// frame-assembly cluster (`buffer`/SPS/PPS/VPS/`formatDesc`/the active
    /// receive generation) — see its file header. `lazy` for the same
    /// reason as `pipeline` below: `makeFramePipelineOutputEffects()`
    /// captures `self` weakly, and actual use starts well after `init`.
    private lazy var framePipeline = ReceiverFramePipeline(
        outputEffects: makeFramePipelineOutputEffects(), syncState: framePipelineSyncState)

    /// Receiver Swift6-B2.2: the exactly-once, thread-safe binding that lets
    /// `presenter`'s `decodeViaVideoDecoder` effect (constructed BEFORE
    /// `videoDecoder` exists — `presenter` is force-constructed first in
    /// `init`, see the tail of `init` below) reach the decoder without
    /// capturing `self` (`StreamReceiver`, not `Sendable`). Bound exactly
    /// once, by `makeVideoDecoder()`, immediately after `videoDecoder` is
    /// constructed and before either owner's pump can process any command
    /// (nothing enqueues one until `start()`/network activity, both well
    /// after `init` returns). `@unchecked Sendable`: the only mutable state
    /// is `decoder`, guarded by `lock`, written exactly once by `bind`
    /// (which asserts it was never written before) and only ever read
    /// through the same lock thereafter — no other mutable reference
    /// escapes.
    private final class VideoDecoderRef: @unchecked Sendable {
        private let lock = NSLock()
        private var decoder: ReceiverVideoDecoder?

        func bind(_ decoder: ReceiverVideoDecoder) {
            lock.lock(); defer { lock.unlock() }
            precondition(self.decoder == nil, "VideoDecoderRef bound twice")
            self.decoder = decoder
        }

        func get() -> ReceiverVideoDecoder? {
            lock.lock(); defer { lock.unlock() }
            return decoder
        }
    }

    /// Plain eager stored property (no `self` dependency at all — unlike
    /// `videoDecoder`/`presenter` themselves) so both owners' factories can
    /// close over it directly. See `VideoDecoderRef` above.
    private let videoDecoderRef = VideoDecoderRef()

    /// C4: the sole authoritative owner of the VideoToolbox decode domain
    /// (Metal renderer path) — see its file header. `lazy`, same as before
    /// B2.2 — Swift's two-phase init forbids capturing `self` (even
    /// weakly, even for the unrelated `requestKeyframe` coordinator hop
    /// below) in a closure built inside `init` before every stored
    /// property (including this one) has a value, so this still can't be a
    /// plain eagerly-assigned `let` constructed inline in `init`. What
    /// changed under B2.2 is ordering and sibling access, not laziness
    /// itself: `init` now force-touches `presenter` then `videoDecoder`, in
    /// that order, at its tail — AFTER every non-lazy stored property is
    /// set, so `self` is already fully initialized at that point and the
    /// existing self-capturing coordinator hops remain legal. Neither
    /// owner is ever reassigned or recreated afterward (only reset
    /// internally) — see `presenter` below for the full stability
    /// argument.
    private lazy var videoDecoder: ReceiverVideoDecoder = makeVideoDecoder()

    private func makeVideoDecoder() -> ReceiverVideoDecoder {
        let telemetry = videoTelemetry
        // `presenter` direct + WEAK: `self` is fully initialized by the
        // time this runs (forced at the tail of `init`, after `presenter`
        // itself is force-touched first), so capturing `presenter` here
        // needs no deferred box — unlike the reverse direction, `presenter`
        // already exists. WEAK (not the strong default) because
        // `presenter`'s own effects (below) hold `videoDecoderRef`, which
        // will hold this decoder strongly the moment `bind` runs a few
        // lines down — a strong capture here too would close a
        // decoder<->presenter reference cycle that neither `self`
        // releasing `videoDecoder` nor `self` releasing `presenter` could
        // break. `self.videoDecoder`/`self.presenter` (this class's own two
        // independent strong references) are what actually keep both alive
        // for exactly as long as this instance lives.
        let presenter = self.presenter
        // Receiver Swift6-B2.4-E2a: `queue`/`keyframeThrottle`/`sendTargetBox`
        // captured directly instead of `self` — same style as `sendPing` in
        // `makePipelineHostEffects()` below.
        let queue = self.queue
        let keyframeThrottle = self.keyframeThrottle
        let sendTargetBox = self.sendTargetBox
        let decoder = ReceiverVideoDecoder(outputEffects: .init(
            decodedFrameReady: { [weak presenter] box, generation, captureMs in
                presenter?.enqueuePresentDecoded(box, generation: generation, captureMs: captureMs)
            },
            // Receiver Swift6-B1: `telemetry` (`ReceiverVideoTelemetry`) is a
            // Sendable value captured on its own — no `self`, no queue hop,
            // just the lock-protected append. Per-frame hot path.
            decodeDurationMs: { ms in
                telemetry.recordDecodeDuration(ms)
            },
            requestKeyframe: {
                queue.async {
                    let now = Date()
                    guard keyframeThrottle.shouldSend(now: now, minimumInterval: 1.0) else { return }
                    Log.info("requesting keyframe (decoder needs sync)")
                    Self.sendControl(["type": "kf"], sendTargetBox: sendTargetBox)
                }
            }))
        // Exactly once, immediately after construction, strictly before
        // `init` returns — no command can have reached either owner's pump
        // yet (nothing enqueues one until `start()`/network activity).
        videoDecoderRef.bind(decoder)
        return decoder
    }

    /// RC-3 Stage D: the sole authoritative owner of `displayLayer`
    /// enqueue/flush/flushAndRemoveImage and the presentation generation —
    /// see its file header. `lazy` — see `videoDecoder` above for why (the
    /// same two-phase-init constraint applies here too, since this
    /// property's own factory needs `self` for `decodedFrameReady`'s
    /// `onDecodedFrame` queue-hop). Force-touched FIRST at the tail of
    /// `init` (before `videoDecoder`): its `decodeViaVideoDecoder` effect
    /// only ever resolves the decoder through `videoDecoderRef` (never
    /// `self.videoDecoder` directly), so it needs no decoder to exist yet.
    /// Neither this nor `videoDecoder` is ever reassigned or recreated
    /// after construction — both are reset via `enqueueReset`/
    /// `enqueueFlushAndRemoveImage`/`enqueueAdvanceGeneration` instead,
    /// which is why an exactly-once mutual binding (rather than
    /// coordinator self-capture re-resolved per call) is sound here.
    private lazy var presenter: ReceiverVideoPresenter = makePresenter()

    private func makePresenter() -> ReceiverVideoPresenter {
        let telemetry = videoTelemetry
        let decoderRef = videoDecoderRef
        // Receiver Swift6: captured directly instead of `self` — same style
        // as `telemetry`/`decoderRef` above. `decodedFrameSink` is the sole
        // storage authority behind the `onDecodedFrame` computed property
        // (see its file header); reading it per-invocation, INSIDE the
        // queue hop below, keeps live-reassignment semantics identical to
        // the old `self.onDecodedFrame?(...)` read.
        let queue = self.queue
        let decodedFrameSink = self.decodedFrameSink
        return ReceiverVideoPresenter(
            displayLayer: displayLayer,
            outputEffects: .init(
                decodeViaVideoDecoder: { box, generation, captureMs in
                    decoderRef.get()?.enqueueDecode(box, generation: generation, captureMs: captureMs)
                },
                decodedFrameReady: { box, captureMs in
                    queue.async {
                        #if DEBUG
                        telemetry.incrementDebugDecodedCount()
                        #endif
                        decodedFrameSink.get()?(box.value, captureMs)
                    }
                },
                // Receiver Swift6-B1: both effects below now capture only
                // `telemetry` — a Sendable value, no `self`, no queue hop.
                // Per-frame (flush) / per-window (debug presented) hot
                // path.
                decodeFlushIncurred: {
                    telemetry.incrementFlushCount()
                },
                debugFramePresented: {
                    #if DEBUG
                    telemetry.incrementDebugPresentedCount()
                    #endif
                }))
    }

    /// C1: the sole authoritative owner of `connection`/`pendingConnections`/
    /// `sessionState` and the coupled reconnect/liveness timers. `lazy`
    /// purely so `makePipelineUIEffects()`/`makePipelineHostEffects()` can
    /// capture `self` weakly — actual use starts from `start()`, well after
    /// `init` completes.
    private lazy var pipeline: ReceiverPipelineActor = {
        let actor = ReceiverPipelineActor(
            queue: queue, sendTargetBox: sendTargetBox, reconnectContext: reconnectContext,
            uiEffects: makePipelineUIEffects(), hostEffects: makePipelineHostEffects(),
            framePipeline: framePipeline)
        // `pipelineBox` lets `makePipelineHostEffects()`'s `ensureTLSListening`
        // closure reach this actor at call time with zero `StreamReceiver`
        // capture — see `ReceiverPipelineActorBox`'s doc comment for why a
        // direct `self.pipeline` read there is not an option.
        pipelineBox.install(actor)
        return actor
    }()

    /// The permanent facade/UI-mirror outputs `pipeline` calls out to — see
    /// `ReceiverPipelineActor.UIEffects`. Each closure captures `self`
    /// weakly and its only job is producing a UI update.
    private func makePipelineUIEffects() -> ReceiverPipelineActor.UIEffects {
        let sink = uiSink
        // Receiver Swift6-C1: `queue`/`transportState` captured directly
        // instead of `self` — both are Sendable (`DispatchQueue` is
        // `@unchecked Sendable`, `transportState` is its own lock-protected
        // owner, same as `makePipelineHostEffects()`'s `transportState`
        // capture). The `queue.async` hop is preserved (not just dropped for
        // a direct read) because `hostEffects.onPathUpdate` — called
        // synchronously just before this in `ReceiverPipelineActor.
        // handlePathUpdate` — enqueues its own `transport`-writing work onto
        // the same `queue` first; staying on `queue` keeps this read
        // ordered after that write, exactly as before.
        let queue = self.queue
        let transportState = self.transportState
        // Receiver Swift6-C2: same `reconnectContext` instance already
        // captured directly (not through `self`) by `pipeline`'s own init
        // and by `makePipelineHostEffects()` — its own lock keeps `update`
        // safe to call from any thread, so `applyConnectedUIMirror` below
        // needs no queue hop to touch it.
        let reconnectContext = self.reconnectContext
        return .init(
            // Receiver Swift6-B1: both publish through `uiSink`, a Sendable
            // @MainActor proxy — see its file header — instead of capturing
            // `self` to call `StreamReceiver`'s own `publishSessionSnapshot`/
            // `setStatus`. Same `DispatchQueue.main.async` ordering as the
            // `publishToUI` hop those methods use internally.
            publishSessionSnapshot: { snapshot in
                DispatchQueue.main.async { sink.publishSessionSnapshot(snapshot) }
            },
            setStatus: { text in
                DispatchQueue.main.async { sink.publishStatus(text) }
            },
            setStatusConnected: {
                queue.async {
                    let text = "Connected · \(transportState.get())"
                    Log.info("status: \(text)")
                    DispatchQueue.main.async { sink.publishStatus(text) }
                }
            },
            // Receiver Swift6-C2: split at the ownership boundary the
            // original `applyConnectedUIMirror` blurred — the
            // `reconnectContext` clear is host state with its own existing
            // Sendable owner (already captured directly above, in
            // `makePipelineHostEffects`), so it runs here with no queue hop
            // and no `self`, synchronously before the UI mirror publish,
            // exactly as the original ordering required. The UI-mirror
            // fields stay behind `sink`, same as `publishSessionSnapshot`/
            // `setStatus` above.
            applyConnectedUIMirror: { value in
                if !value {
                    reconnectContext.update { $0.authenticatedPeerIDHint = nil }
                }
                DispatchQueue.main.async { sink.publishConnectedUIMirror(value) }
            })
    }

    /// The transitional host-control callbacks `pipeline` calls out to for
    /// every side effect outside its own state that is NOT a UI publish —
    /// see `ReceiverPipelineActor.HostControlEffects`. Each closure captures
    /// `self` weakly and is responsible for its own thread-safety: one that
    /// touches `queue`-confined state hops onto `queue` itself before
    /// touching it.
    private func makePipelineHostEffects() -> ReceiverPipelineActor.HostControlEffects {
        let syncState = framePipelineSyncState
        // B2.3: both captured as plain Sendable values, no `self`/queue hop
        // needed — `transportState` is its own lock-protected owner, and
        // `advertisesAddresses` (`deviceKind == "Mac"`) never changes after
        // `init` since `deviceKind` is a `let`.
        let transportState = self.transportState
        let advertises = advertisesAddresses
        // Receiver Swift6-B2.4-E1a: `queue`/`sendTargetBox` captured
        // directly instead of `self` — both already stable owners captured
        // this way elsewhere in this file (`makePipelineUIEffects()`,
        // `pipeline`'s own init).
        let queue = self.queue
        let sendTargetBox = self.sendTargetBox
        // Receiver Swift6-E1: `reconnectContext`/`uiSink` captured directly
        // instead of `self` — both already stable owners captured this way
        // elsewhere in this file (`makePipelineUIEffects()`'s
        // `reconnectContext`, `makePipelineHostEffects()`'s own `syncState`/
        // `transportState` above). `onConnectionReadyHostWork` is now a
        // static helper taking these plus `syncState`/`transportState`
        // explicitly, so the closure below needs no `self` at all.
        let reconnectContext = self.reconnectContext
        let uiSink = self.uiSink
        // Receiver Swift6-Hello-Final: the remaining stable owners
        // `sendHello`/`checkAddressChangeAndSendHello` need to call the
        // static, self-free helpers below with no `StreamReceiver` capture
        // at all — same "captured directly instead of `self`" idiom as
        // every owner above.
        let helloState = self.helloState
        let displayGeometryState = self.displayGeometryState
        let avSyncPreference = self.avSyncPreference
        let deviceKind = self.deviceKind
        let maxEncodeWide = self.maxEncodeWide
        let maxEncodeHigh = self.maxEncodeHigh
        let maxFPS = self.maxFPS
        let advertisedProtocolVersion = self.advertisedProtocolVersion
        // Site 6 (Receiver Swift6-TLS): the stable owners `ensureTLSListening`
        // below needs to call `Self.startTLSListener` with zero `StreamReceiver`
        // capture — `pipelineBox` stands in for `self.pipeline` (see its doc
        // comment for why a direct read isn't safe here).
        let tlsListenerState = self.tlsListenerState
        let pairingSuppressionState = self.pairingSuppressionState
        let advertisementState = self.advertisementState
        let pipelineBox = self.pipelineBox
        // `selfBox` lets `beginAdoption` below reach `beginAdoptionHostWork`
        // at call time with zero `StreamReceiver` capture — see
        // `StreamReceiverSelfBox`'s doc comment.
        let selfBox = self.selfBox
        let installID = Self.installID
        return .init(
            clearTransport: {
                transportState.clear()
            },
            ensureTLSListening: {
                queue.async {
                    guard let pipeline = pipelineBox.current(), !tlsListenerState.hasCurrent() else { return }
                    Log.info("reconnectDebug: retryScheduled TLS listener rearm")
                    Self.startTLSListener(
                        queue: queue, tlsListenerState: tlsListenerState,
                        pairingSuppressionState: pairingSuppressionState, advertisementState: advertisementState,
                        pipeline: pipeline, installID: installID, advertisedProtocolVersion: advertisedProtocolVersion)
                }
            },
            requestRemoteConnect: { peerID in
                queue.async { Self.requestRemoteConnect(peerID: peerID, queue: queue) }
            },
            getReceiveLiveness: {
                syncState.snapshot()
            },
            advertisesAddresses: { advertises },
            beginAdoption: { conn, generation in
                queue.async { selfBox.currentOnQueue()?.beginAdoptionHostWork(conn, generation: generation) }
            },
            onConnectionReady: { conn in
                queue.async {
                    Self.onConnectionReadyHostWork(
                        conn, reconnectContext: reconnectContext, syncState: syncState,
                        transportState: transportState, uiSink: uiSink)
                }
            },
            sendHello: { conn in
                queue.async {
                    Self.sendHello(
                        on: conn, helloState: helloState, displayGeometryState: displayGeometryState,
                        avSyncPreference: avSyncPreference, sendTargetBox: sendTargetBox,
                        deviceKind: deviceKind, maxEncodeWide: maxEncodeWide, maxEncodeHigh: maxEncodeHigh,
                        maxFPS: maxFPS, advertisedProtocolVersion: advertisedProtocolVersion,
                        advertisesAddresses: advertises)
                }
            },
            onPathUpdate: { conn, path in
                queue.async {
                    Self.updateTransport(for: conn, path: path, transportState: transportState)
                }
            },
            // E1a: sends the ping frame through the static `sendControl`
            // (see its definition above), capturing `sendTargetBox`
            // directly instead of `self` — a bound `self.sendControl`
            // would still capture `self`. `nowMs` is a pure `Date()` read,
            // no `self` state.
            sendPing: {
                queue.async {
                    Self.sendControl(["type": "ping", "t": Date().timeIntervalSince1970 * 1000],
                                      sendTargetBox: sendTargetBox)
                }
            },
            checkAddressChangeAndSendHello: { conn in
                queue.async {
                    Self.checkAddressChangeAndSendHello(
                        conn, helloState: helloState, displayGeometryState: displayGeometryState,
                        avSyncPreference: avSyncPreference, sendTargetBox: sendTargetBox,
                        deviceKind: deviceKind, maxEncodeWide: maxEncodeWide, maxEncodeHigh: maxEncodeHigh,
                        maxFPS: maxFPS, advertisedProtocolVersion: advertisedProtocolVersion,
                        advertisesAddresses: advertises)
                }
            })
    }

    /// The narrow, purpose-built output surface `framePipeline` calls out
    /// to for everything downstream of its presentation-ready
    /// `CMSampleBuffer` boundary — see `ReceiverFramePipeline.
    /// OutputEffects`. Each closure captures stable `Sendable` references
    /// (`queue`, `selfBox`, etc.) instead of `self`, hops onto `queue`, and
    /// only then resolves the weak receiver via `selfBox.currentOnQueue()`
    /// before touching any `queue`-confined state — see
    /// `StreamReceiverSelfBox`'s doc comment for why a direct `self`
    /// capture isn't legal here. Otherwise the same shape as
    /// `makePipelineHostEffects()` above.
    private func makeFramePipelineOutputEffects() -> ReceiverFramePipeline.OutputEffects {
        // B2.4-B / CR1 fix: `connectionFailed`/`connectionClosedByPeer`
        // capture `queue` and `pipelineBox` instead of `self` or `pipeline`
        // directly. A direct `self.pipeline` read here would re-enter
        // `pipeline`'s own lazy initializer (which calls this factory to
        // build `framePipeline`'s outputEffects BEFORE `pipeline` is
        // constructed) — unbounded recursion until the stack overflows.
        // `pipelineBox` is installed once `pipeline`'s initializer finishes,
        // exactly the same seam `makePipelineHostEffects()`'s
        // `ensureTLSListening` already uses for the identical reason — see
        // `ReceiverPipelineActorBox`'s doc comment.
        let queue = queue
        let pipelineBox = self.pipelineBox
        // `selfBox` lets `controlMessage`/`audioPayload`/`presentationFrame`
        // below reach their handlers at call time with zero `StreamReceiver`
        // capture — see `StreamReceiverSelfBox`'s doc comment. `self` is
        // already fully initialized by the time this factory can run (it is
        // only reachable through `framePipeline`, itself built after
        // `selfBox.install(self)` in `init`), so `selfBox.currentOnQueue()` is safe.
        let selfBox = self.selfBox
        // D1: `codecConfigurationChanged` is a pure pass-through — presenter
        // flush, DEBUG decoder notification, then a UI publish — with no
        // coordinator logic of its own, so it captures its stable owners
        // directly instead of `self`. `presenter` is force-created at the
        // tail of `init` (before this factory's caller ever runs) and never
        // reassigned afterward — see `presenter`'s own doc comment — so
        // evaluating it here is safe and does not re-enter the
        // decoder/presenter construction cycle B2.2 guards against.
        let presenter = presenter
        let videoDecoderRef = videoDecoderRef
        let uiSink = uiSink
        return .init(
            controlMessage: { data in
                queue.async { selfBox.currentOnQueue()?.handleVideoChannelJSON(data) }
            },
            audioPayload: { data in
                queue.async { selfBox.currentOnQueue()?.handleAudioMediaFrame(data) }
            },
            codecConfigurationChanged: { box, videoSize in
                queue.async {
                    // Retires the previous session's/format's currently-
                    // displayed frame — see `handleAnnexB`'s old inline
                    // comment (now `ReceiverFramePipeline.handleAnnexB`)
                    // for why this must happen before any sample built
                    // from the new format description is presented. Stage D:
                    // ordered through `presenter` instead of touching
                    // `displayLayer` directly.
                    presenter.enqueueFlushAndRemoveImage()
                    #if DEBUG
                    // BLACK-VIDEO forensics: a fresh SPS/PPS means a new
                    // decode generation — re-arm the decoded-frame luma probe.
                    // Resolved through `videoDecoderRef` (not `self.
                    // videoDecoder` directly) — same seam B2.2 established
                    // for cross-owner decoder access.
                    videoDecoderRef.get()?.enqueueFormatDescriptionChanged()
                    #endif
                    let statusText = "Receiving \(Int(videoSize.width))×\(Int(videoSize.height))"
                    DispatchQueue.main.async {
                        uiSink.publishVideoSize(videoSize)
                        uiSink.publishStatus(statusText)
                    }
                }
            },
            presentationFrame: { box, captureMs, sendMs in
                queue.async { selfBox.currentOnQueue()?.presentDecodedSample(box.value, captureMs: captureMs, sendMs: sendMs) }
            },
            connectionFailed: { error in
                queue.async {
                    // FORENSIC FIX (media-death-with-input-still-working):
                    // see the original `processReceivedData`'s doc comment
                    // this replaces — any receive error is this
                    // connection's own health, not a per-call fluke, and
                    // must mark the session down exactly like EOF.
                    Log.info("receive error: \(error)")
                    guard let pipeline = pipelineBox.current() else { return }
                    Task { await pipeline.setConnected(false) }
                }
            },
            connectionClosedByPeer: {
                queue.async {
                    Log.info("peer closed connection")
                    guard let pipeline = pipelineBox.current() else { return }
                    Task { await pipeline.setConnected(false) }
                }
            })
    }

    /// The `displayState` mirror and its callback always change together —
    /// duplicated verbatim at three call sites before this consolidation.
    private func publishDisplayState(_ state: DisplayState) {
        let uiSink = self.uiSink
        DispatchQueue.main.async { uiSink.publishDisplayState(state) }
    }

    /// The `session` mirror snapshot — called by `pipeline`
    /// (`ReceiverPipelineActor`) as its `UIEffects.publishSessionSnapshot`,
    /// from `mutateSession`, `armReconnect`, `suspendReconnectForBackground`
    /// before this consolidation. Callers still capture the snapshot at the
    /// same point they always did; this only names the hop.
    private func publishSessionSnapshot(_ snapshot: ReceiverSessionState) {
        let uiSink = self.uiSink
        DispatchQueue.main.async { uiSink.publishSessionSnapshot(snapshot) }
    }

    /// Receiver Swift6-B1: `session`'s only external mutator — `ReceiverUISink`
    /// (a different type, so `private(set)` alone doesn't admit it) calls
    /// this instead of writing `session` directly across that boundary.
    /// Same single assignment `publishSessionSnapshot` above does, just
    /// reachable from `ReceiverUISink`.
    @MainActor func applyUISessionSnapshot(_ snapshot: ReceiverSessionState) {
        session = snapshot
    }

    /// The `authenticatedPeerID` UI-publish half of the former
    /// `onConnectionReadyHostWork` — see `ReceiverUISink.
    /// publishAuthenticatedPeerID`, its sole caller. Same single-assignment,
    /// `private(set)`-admitting shape as `applyUISessionSnapshot` above.
    @MainActor func applyAuthenticatedPeerIDUpdate(_ peerID: String?) {
        authenticatedPeerID = peerID
    }

    /// `discoveredMacs`'s only external mutator — see `ReceiverUISink.
    /// publishDiscoveredMacs`, its sole caller. Same single-assignment,
    /// `private(set)`-admitting shape as `applyAuthenticatedPeerIDUpdate`
    /// above.
    @MainActor func applyDiscoveredMacsUpdate(_ results: [NWBrowser.Result]) {
        discoveredMacs = results
    }

    /// `pairingSuccessCount`'s external-boundary mutator for the pairing
    /// listener's `newConnectionHandler`/nested `Task` — see `ReceiverUISink.
    /// publishPairingSucceeded`, its sole caller. Exact same +1 as
    /// `notePairingSucceeded()`, which other call sites (`pairWithMac`,
    /// `pairWithRemoteHost`) keep calling directly, untouched by this.
    @MainActor func applyPairingSucceededUpdate() {
        pairingSuccessCount += 1
    }

    /// The `UIEffects.applyConnectedUIMirror` half of the former
    /// `setConnected` — the UI-mirror-only side effects, unrelated to
    /// session/generation ownership, which stays inside `pipeline`
    /// (`ReceiverPipelineActor.setConnected`) — see `ReceiverSessionLossReason`.
    ///
    /// Receiver Swift6-C2: this is now reached only through `ReceiverUISink.
    /// publishConnectedUIMirror(_:)` (same one-way, immutable-payload-in,
    /// `@MainActor`-only shape as `applyUISessionSnapshot`), already on
    /// `MainActor` by the time it runs — the `reconnectContext` host-state
    /// clear that used to open this method now happens directly in
    /// `makePipelineUIEffects()`'s closure, before this is ever called, so
    /// the original clear-before-publish ordering is unchanged.
    @MainActor func applyConnectedUIMirrorFields(_ value: Bool) {
        connected = value
        if !value {
            self.authenticatedPeerID = nil
            self.macProtocolVersion = WireProtocol.assumedWhenAbsent
            self.videoEnabled = true
            // The mode is only ever known from a live Mac. A request
            // already in flight is deliberately kept: switching modes
            // rebuilds the Mac's session, so the drop is part of the
            // transition and the reply arrives on the next one.
            self.confirmedDisplayMode = nil
            // Same reasoning as confirmedDisplayMode: stale inventory/
            // selection from a dead session must not linger as if it
            // were still current — a fresh mirrorDisplayState arrives on
            // the next hello.
            self.mirrorDisplayState = nil
            // Same reasoning again: the Mac's active shape is only ever
            // known from a live Mac; a fresh extendShapeState arrives on
            // the next hello.
            self.confirmedExtendShape = nil
            // Same reasoning again: only ever known from a live Mac.
            self.confirmedMaxFPS = nil
            self.lastMaxFPSState = nil
            // The offer belonged to a specific attempt on a specific
            // connection — any disconnect (deliberate or not) ends it;
            // a fresh one arrives on the Mac's own next attempt, if any.
            self.mirrorUnavailable = false
            self.mirrorRejectedWhileExtending = false
        }
    }

    // MARK: - Cluster A: `ReceiverUISink` apply methods
    //
    // Each of these is the `@MainActor` mutation half of a former
    // `publishToUI { self... }` call site — reached only through the
    // matching `ReceiverUISink.publish*` method above, never called
    // directly from queue-isolated code. Same one-way, no-read-back,
    // no-policy shape as `applyUISessionSnapshot`/`applyConnectedUIMirrorFields`.

    @MainActor func applyLastForgottenPeerIDUpdate(_ peerID: String) {
        lastForgottenPeerID = peerID
    }

    @MainActor func applyCursorReset() {
        cursorState = (0.5, 0.5, false)
        cursorSprite = nil
        onCursor?(0.5, 0.5, false)
    }

    @MainActor func applyCursorPositionUpdate(x: Double, y: Double, visible: Bool) {
        cursorState = (x, y, visible)
        onCursor?(x, y, visible)
    }

    @MainActor func applyCursorSpriteUpdate(image: CGImage, anchor: CGPoint, normSize: CGSize) {
        cursorSprite = (image, anchor, normSize)
        onCursorImage?(image, anchor, normSize)
    }

    /// The Mirror-unavailable/rejected offer split: whichever applies is
    /// decided from `confirmedDisplayMode`, already-`@MainActor` state by
    /// the time this runs — same decision `handleVideoChannelJSON`'s
    /// `mirrorUnavailable` case made inline before this boundary existed.
    @MainActor func applyMirrorAvailabilitySignal() {
        if confirmedDisplayMode == .extend {
            mirrorRejectedWhileExtending = true
        } else {
            mirrorUnavailable = true
        }
    }

    @MainActor func applyMirrorDisplayStateUpdate(_ update: MirrorDisplayStateUpdate) {
        mirrorDisplayState = update
    }

    @MainActor func applyStreamingProfileUpdate(_ profile: StreamingProfile) {
        streamingProfile = profile
    }

    @MainActor func applyStreamingPriorityUpdate(_ priority: StreamingPriority) {
        streamingPriority = priority
    }

    @MainActor func applyMacProtocolVersionUpdate(_ macPV: Int) {
        macProtocolVersion = macPV
        if macPV < WireProtocol.videoControlWireVersion {
            videoEnabled = true
        }
    }

    @MainActor func applyPeerSignalUpdate(_ signal: PeerUpdateSignal) {
        peerSignal = signal
    }

    @MainActor func applyAudioEnabledUpdate(_ enabled: Bool) {
        audioEnabled = enabled
    }

    @MainActor func applyPromoteInteractiveWakeResultUpdate(_ text: String) {
        promoteInteractiveWakeResult = text
    }

    @MainActor func applyReceiverUIPreferencesUpdate(_ update: ReceiverUIPreferenceUpdate) {
        onReceiverUIPreferences?(update)
    }

    @MainActor func applyInputResetBump() {
        inputResetGeneration &+= 1
    }

    @MainActor func applyAllowInputStateChangeUpdate(_ state: SessionInputWireState) {
        onAllowInputStateChange?(state)
    }

    @MainActor func applyVideoStateUpdate(width: Int?, height: Int?, enabled: Bool) {
        if let width, let height {
            videoSize = CGSize(width: width, height: height)
        }
        videoEnabled = enabled
    }

    @MainActor func applyActiveStreamCodecUpdate(_ codec: StreamCodec) {
        activeStreamCodec = codec
    }

    @MainActor func applyMirrorUnavailableClear() {
        mirrorUnavailable = false
    }

    @MainActor func applyMirrorRejectionClear() {
        mirrorRejectedWhileExtending = false
    }

    @MainActor func applyDisplayModeStateReset() {
        displayModeRequestState.reset()
        confirmedDisplayMode = nil
        pendingDisplayMode = nil
        mirrorRejectedWhileExtending = false
    }

    @MainActor func applyExtendShapeStateReset() {
        extendShapeRequestState.reset()
        confirmedExtendShape = nil
        pendingExtendShape = nil
    }

    @MainActor func applyMaxFPSStateReset() {
        maxFPSRequestState.reset()
        confirmedMaxFPS = nil
        pendingMaxFPS = nil
        lastMaxFPSState = nil
    }

    @MainActor func applyPerfUpdate(fps: Int, perf: PerfStats) {
        self.fps = fps
        self.perf = perf
    }

    @MainActor func applyDisplayStateUpdate(_ state: DisplayState) {
        displayState = state
        onDisplayStateChange?(state)
    }
}
