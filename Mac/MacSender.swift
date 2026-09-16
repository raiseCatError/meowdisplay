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
    let cursorPort: Int?  // UDP port for the cursor side channel (PROTOCOL.md
                          // 6.3); absent = cursor stays on TCP
    let addrs: [String]?  // every address the receiver is reachable on
                          // (PROTOCOL.md 6.4); probed for a cable upgrade
    let maxEncodeWide: Int?  // receiver's decode ceiling in pixels (PROTOCOL.md
    let maxEncodeHigh: Int?  //  6.5): cap the stream, keep the desktop size
    let trayEnabled: Bool?   // receiver-local control UI state (protocol 6)
    let keyboardButtonEnabled: Bool?

    var kind: String { device ?? "device" }
    var protocolVersion: Int { pv ?? WireProtocol.assumedWhenAbsent }
}

/// How the sender reaches the receiver. Reconnects re-dial from scratch, so
/// a USB device that was replugged (new usbmuxd DeviceID) is found again.
struct TLSSessionConfig {
    let identity: SecIdentity
    let pinnedPeerSPKI: Data
    let peerID: String
}

enum SenderTransport {
    case tcp(NWEndpoint, tls: TLSSessionConfig?) // nil is allowed only for explicit local debugging
    case usb(udid: String?, port: UInt16)  // native usbmuxd dial; nil = first device
}

@available(macOS 14.0, *)
final class MacSender: NSObject, SCStreamOutput, SCStreamDelegate {

    // Status surfaced to the UI (updated on main thread).
    @MainActor var onStatus: ((String) -> Void)?
    @MainActor var onStats: ((Int, Double) -> Void)?   // framesSent, mbps
    @MainActor var onCaptureLifecycleChanged: ((CaptureLifecyclePhase) -> Void)?
    // Fired when a previously connected device stays gone past the grace
    // period — the controller ends the session (capture, virtual display,
    // recording indicator all torn down) instead of dialing forever or
    // silently coming back over a different transport.
    @MainActor var onDisconnected: (() -> Void)?
    // Fired when the receiver announces its device locked. The controller
    // ends this session — an invisible display strands the cursor — and
    // starts a fresh one that waits for the wake.
    @MainActor var onPeerSleeping: (() -> Void)?
    // Fired when the receiver announces the app is quitting: deliberate,
    // so the controller ends the session without arming a reconnect.
    @MainActor var onPeerClosed: (() -> Void)?
    // Fired when an established connection's actual Network.framework path
    // changes. Nil while disconnected; the UI never infers a route from the
    // requested target.
    @MainActor var onTransportPath: ((ConnectionRoute?) -> Void)?
    // Fired on every hello — carries the receiver's install id so the
    // controller can deduplicate USB/WiFi sessions to the same device.
    @MainActor var onHello: ((PhoneInfo) -> Void)?
    // Fired when the user stopped the capture from the system UI (menu-bar
    // recording indicator / "Stop Extending"). The controller disconnects
    // the session — teardown plus auto-connect opt-out — so the app honors
    // the stop instead of fighting it.
    @MainActor var onCaptureStoppedByUser: (() -> Void)?
    // Fired when the device's display identity had to be abandoned (macOS
    // saved hostile state for it — see setupExtend) and a bumped identity
    // came online instead: carries the validated TOTAL offset from the
    // device's base identity, for the controller to store as-is. Absolute,
    // not a delta — repeated bumps in one session must not accumulate into
    // an offset nothing ever validated.
    @MainActor var onDisplayIdentityBumped: ((UInt32) -> Void)?
    /// Receiver requests are handed to SenderController, which owns the
    /// existing authoritative session-rebuild mode-switch path.
    @MainActor var onDisplayModeRequest: ((ReceiverDisplayMode) -> Void)?
    /// A receiver asked to change Allow Input. Handed to `AppController`,
    /// which owns the single, global `allowInput` toggle (see its `didSet`
    /// — Mac remains authoritative and broadcasts the result to every
    /// connected receiver, this one included).
    @MainActor var onAllowInputRequest: ((Bool) -> Void)?
    /// Receiver video requests are handed to the controller, which persists
    /// the Mac-authoritative setting and broadcasts it to every session.
    @MainActor var onVideoEnabledRequest: ((Bool) -> Void)?
    /// Pinned TLS failures are terminal trust failures, never packet-loss retries.
    @MainActor var onTrustFailure: ((String) -> Void)?

    private var stream: SCStream?
    private var encoder: VTCompressionSession?
    private var connection: NWConnection?
    private var virtualDisplay: VirtualDisplay?
    private let queue = DispatchQueue(label: "sender.video")
    private let startCode: [UInt8] = [0, 0, 0, 1]

    // The dial target. Written on `queue` only (after init): the controller
    // can migrate a live session between transports via switchTransport.
    private var transport: SenderTransport
    private let endpointName: String
    private var mode: CaptureMode
    private let quality: StreamQuality
    // Stable per-device serial for the virtual display, so macOS can tell
    // multiple OpenDisplay monitors apart and persist their arrangement.
    private let displaySerial: UInt32
    // How far this device's identity has already moved off its base serial
    // and productID (identities macOS saved hostile state for are abandoned
    // permanently — see setupExtend). Advanced in-session when a fallback
    // identity is validated, so a rotation rebuild doesn't re-probe the
    // poisoned one.
    private var baseIdentityOffset: UInt32

    // ── Encoder parallelism limiter (maxPendingEncodes = 1) ─────────────────
    //
    // VTCompressionSessionEncodeFrame returns immediately; the hardware H.264
    // encoder runs asynchronously. If ScreenCaptureKit delivers the next frame
    // before the previous encode callback fires, VideoToolbox will run multiple
    // encodes in parallel inside the same session.
    //
    // Capping pendingEncodes at 1 enforces “latest frame wins” on the encoder:
    // skip captures while an encode is in flight (enc drops), then feed the next
    // fresh buffer when the callback clears the slot. The H.264 reference chain
    // stays valid (pre-encode skip → normal P-frame n→n+2); we do NOT force
    // keyframes on enc drops.
    private var pendingEncodes = 0
    private let maxPendingEncodes = 1

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
    private var pendingSends = 0
    private let maxPendingSends = 3
    private let pipelineLock = NSLock()
    private var dropsEncThisWindow = 0
    private var dropsNetThisWindow = 0
    private var dropsEncTotal = 0
    private var dropsNetTotal = 0
    private var needsKeyframe = true
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
    // pause, reconnect). Guarded by `pipelineLock` like `captureGeneration`
    // because it's read from the SCStream audio callback (not `queue`) and
    // compared again once that callback's async encode work completes back
    // on `queue` — the same stale-completion guard `captureGenerationNow`
    // already provides for video, extended to cover an audio-only generation
    // change too (Audio Off→On doesn't necessarily bump `captureGeneration`).
    private var audioGeneration: UInt64 = 0
    private var audioGenerationNow: UInt64 {
        pipelineLock.lock()
        defer { pipelineLock.unlock() }
        return audioGeneration
    }
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
        pipelineLock.lock()
        audioGeneration &+= 1
        let generation = audioGeneration
        pipelineLock.unlock()
        #if DEBUG
        pcmConfigSent = false
        pcmPacketSeq = 0
        activeAudioIsPCM = UserDefaults.standard.string(forKey: "audioDebugMode") == "pcm"
        // FORENSIC NOTE: a previous pass's instructions told the user to
        // `defaults write com.peetzweg.opensidecar.mac.debug ...` — the
        // upstream/tracked bundle ID (`project.yml`). This checkout's local
        // signing override (`project.local.yml`, see repo CLAUDE.md) rebuilds
        // the Debug target as `com.raisecaterror.opendisplay.mac.debug`, so
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
    private var connectionReady = false
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

    private var lastHello: PhoneInfo?
    private var helloContinuation: CheckedContinuation<PhoneInfo, Error>?
    private var inputInjector: InputInjector?
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
    private var dropsTotal: Int { dropsEncTotal + dropsNetTotal }

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
    // iPhone's WiFi→USB transport switch. All confined to `queue`.
    private var upgradeTimer: DispatchSourceTimer?
    private var upgradeProbes: [NWConnection] = []
    private var probeRoundGeneration = 0
    private var lastLoggedCandidates: [String] = []
    private var peerAddrs: [String] = []
    // The Mac-to-Mac USB link takes ~25-30s to negotiate, and either side
    // can finish last. Peer-side lateness arrives as a re-hello; this
    // monitor catches OUR side coming up, so a probe fires the moment the
    // local interface is routable instead of up to 10s later.
    private var wiredPathMonitor: NWPathMonitor?
    // Probing is gated on this, not on wired-ness: the upgrade exists to get
    // OFF WiFi, and any non-WiFi path (bridge, USB-C link, even loopback)
    // is already as good as a probe could find — re-probing there would
    // migrate in a circle.
    private var currentPathUsesWiFi = false
    // Set while the live session rides the direct cable link (USB-C /
    // Thunderbolt host-to-host to a Mac receiver, link-local addressed).
    // Losing that link is treated as intent — see linkDied(). A merely-
    // wired path (a docked Mac on Ethernet streaming to a phone on WiFi)
    // must NOT count: silence there is a backgrounded receiver or the
    // phone's radio, and undocking should fall back to WiFi like it always
    // has. Computed by refreshDirectLinkClassification, cleared the moment
    // the session decides to redial (scheduleReconnect/switchTransport):
    // dial-phase failures take the grace/refusal rules, never this exit.
    private var currentPathDirectLink = false
    private var lastCursorSent: (x: Double, y: Double, visible: Bool) = (-1, -1, false)
    private var lastCursorPNGHash = 0
    // Cursor side channel (UDP, WiFi only): positions queue behind video
    // frames on the shared TCP socket and stutter under head-of-line
    // blocking. Opened when hello advertises cursorPort; while ready,
    // pollCursorPosition sends there instead. Sprites stay on TCP (up to
    // 24 KB, must arrive intact). All state lives on `queue`.
    private var cursorConnection: NWConnection?
    private var cursorChannelPort: NWEndpoint.Port?
    // True once the receiver acked a datagram (cursorAck). Until then every
    // position also rides TCP: UDP .ready proves only a local route, and a
    // silently firewalled port must not eat the cursor. Duplicates are
    // harmless — both paths carry the same sequence and the receiver drops
    // whatever is not newer.
    private var cursorChannelConfirmed = false
    private var cursorConnectionReady = false
    private var cursorSeq: UInt64 = 0
    private var captureDisplayID: CGDirectDisplayID = 0
    private let captureLifecycleLock = NSLock()
    private var captureLifecycle = CaptureLifecycleState()
    // ScreenCaptureKit and VideoToolbox finish work asynchronously. During a
    // rotation, an old capture callback or a late encoder completion must not
    // put a frame from the retired display onto this device's new socket.
    // Bumped on `queue` but read from the SCK sample queue and the VideoToolbox
    // callback queue, so it lives under `pipelineLock` like the other counters
    // those callbacks touch — read it via `captureGenerationNow`.
    private var captureGeneration: UInt64 = 0
    private var captureGenerationNow: UInt64 {
        pipelineLock.lock()
        defer { pipelineLock.unlock() }
        return captureGeneration
    }

    // Input latency: touches arrive stamped in our clock (the phone applies
    // its sync offset); delta to now = network + deframe + dispatch.
    private var inputLatencies: [Double] = []
    // These policies bound noisy paths while retaining an explicit record when
    // details were suppressed. Unknown types and unparseable messages live on
    // `queue` with the rest of the control-connection state; encoder failures
    // are guarded by `pipelineLock` with the other pipeline counters.
    private var unknownTypeLogPolicy = UnknownControlTypeLogPolicy()
    // Encode failures repeat every frame once the session goes bad; throttle
    // the log to one line a second and carry the count.
    private var encodeFailureLogPolicy = ThrottledLogPolicy<OSStatus>()
    // Same for the encoder output callback rejecting a frame; separate policy
    // so "submit failed" and "output rejected" stay distinguishable.
    private var encodeOutputFailureLogPolicy = ThrottledLogPolicy<OSStatus>()
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

    init(transport: SenderTransport, name: String, mode: CaptureMode,
         quality: StreamQuality = .best, displaySerial: UInt32 = 0x0001,
         identityOffset: UInt32 = 0, awaitingWake: Bool = false,
         videoEnabled: Bool = true) {
        self.transport = transport
        self.endpointName = name
        self.mode = mode
        self.quality = quality
        self.displaySerial = displaySerial
        self.baseIdentityOffset = identityOffset
        self.awaitingWake = awaitingWake
        self.desiredVideoEnabled = videoEnabled
        super.init()
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
        Task { @MainActor in self.onCaptureLifecycleChanged?(current) }
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
        queue.async { [weak self] in self?.sendDisplayModeState() }
    }

    /// Called on the sender queue. `InputPolicy.allowsInput()` reads
    /// straight from UserDefaults (the same static check every input-
    /// injection call site already gates on), so this always reports the
    /// Mac's real, current gate — never a stale cached copy.
    private func sendAllowInputState() {
        sendJSONObject(["type": WireMessage.allowInputState,
                        "allowed": InputPolicy.allowsInput()])
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
        Task {
            do {
                try await stream.updateConfiguration(config)
            } catch {
                Log.info("audio reconfigure failed: \(error)")
            }
            self.queue.async {
                guard self.stream === stream else { return }
                self.audioEnabled = enabled
                if !enabled {
                    Task { await self.audioCaptureEncoder.reset() }
                }
                self.beginAudioGeneration()
                self.sendAudioState()
                if !enabled, self.videoEnabled == false, self.desiredAudioEnabled == false {
                    // Nothing wants this stream anymore — release it the
                    // same way Video Off does on its own.
                    self.stream = nil
                    stream.stopCapture { _ in }
                    _ = self.updateCaptureState { $0.stop(); return true }
                }
            }
        }
    }

    private func sendAudioConfigIfNeeded() {
        Task {
            guard let config = await audioCaptureEncoder.formatConfig else { return }
            self.queue.async {
                guard !self.audioConfigSent else { return }
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
        Task {
            guard let config = await audioCaptureEncoder.pcmFormatConfig else { return }
            self.queue.async {
                guard !self.pcmConfigSent else { return }
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
        queue.async { [weak self] in self?.sendAllowInputState() }
    }

    func setVideoEnabled(_ enabled: Bool) {
        queue.async { [weak self] in
            guard let self else { return }
            self.desiredVideoEnabled = enabled
            guard let info = self.lastHello,
                  info.protocolVersion >= WireProtocol.videoControlWireVersion else { return }
            self.applyVideoEnabled(enabled)
        }
    }

    /// Performs the Extend -> Mirror -> Video Off sequence without replacing
    /// the transport/session. Input is retargeted to the physical display,
    /// the virtual display is released only after Extend capture has stopped,
    /// and video production is disabled only after Mirror setup completes.
    func transitionToMirrorAndDisableVideo(completion: @escaping @MainActor () -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            self.desiredVideoEnabled = false
            self.inputInjector?.cancelActiveInput()
            let oldStream = self.stream
            self.stream = nil
            self.invalidateCapturePipeline(discardingLastFrame: true)
            if let encoder = self.encoder { VTCompressionSessionInvalidate(encoder) }
            self.encoder = nil
            let continueTransition = {
                self.queue.async {
                    self.mode = .mirror
                    self.virtualDisplay = nil
                    Task {
                        do {
                            try await self.startMirrorCapture(preferredDisplayID: nil)
                        } catch {
                            Log.info("Extend to Mirror transition failed before Video Off: \(error)")
                        }
                        self.queue.async {
                            self.applyVideoEnabled(false)
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

    func start() async throws {
        stopped = false
        queue.async { self.connect() }   // dial state lives on `queue`
        if !monitorsStarted {
            monitorsStarted = true
            schedulePing()
            scheduleWatchdog()
        }

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

        switch mode {
        case .mirror:
            try await startMirrorCapture(preferredDisplayID: nil)

        case .extend:
            // awaitingWake is queue-confined — read it there before surfacing.
            queue.async { [weak self] in
                guard let self else { return }
                let text = self.awaitingWake
                    ? "\(self.endpointName) is asleep — reconnects when it wakes…"
                    : "Waiting for the device to connect…"
                Task { await self.status(text) }
            }
            let info = try await waitForHello()
            try await setupExtend(info)

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

    private func startMirrorCapture(preferredDisplayID: CGDirectDisplayID?) async throws {
        let content = try await SCShareableContent.current
        let display = preferredDisplayID.flatMap { id in
            content.displays.first(where: { $0.displayID == id })
        } ?? content.displays.first
        guard let display else {
            throw NSError(domain: "MacSender", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "no displays found"])
        }
        try await startMirrorCapture(display: display)
    }

    /// Build (or rebuild) the virtual display + capture for the announced
    /// phone dimensions. Called at startup and again whenever the phone
    /// rotates (it re-sends hello with swapped dimensions).
    private func setupExtend(_ info: PhoneInfo) async throws {
        Log.info("phone hello: \(info.pixelsWide)x\(info.pixelsHigh) @\(info.scale)x")

        // Phone panel is @3x; the virtual display runs @2x HiDPI, so points
        // = native pixels / 2 (rounded down to even for the encoder).
        let pointsWide = (info.pixelsWide / 2) & ~1
        let pointsHigh = (info.pixelsHigh / 2) & ~1
        // Rough physical size so macOS picks a sane default UI scale.
        let mm = info.pixelsWide >= info.pixelsHigh
            ? CGSize(width: 147, height: 68)
            : CGSize(width: 68, height: 147)

        // USB sessions can start before lockdown resolves the device name —
        // fall back to the kind from the hello rather than the generic label.
        let displayName = endpointName.hasPrefix("iPhone / iPad")
            ? "OpenDisplay — \(info.kind)"
            : "OpenDisplay — \(endpointName)"
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
        var vd: VirtualDisplay?
        var display: SCDisplay?
        var identityError = NSError(domain: "MacSender", code: 2,
                                    userInfo: [NSLocalizedDescriptionKey: "CGVirtualDisplay creation failed"])
        // Only a created-but-never-surfaced display proves the identity is
        // poisoned. Creation refusing outright usually means a twin still
        // holds the serial (just-quit instance, parallel debug build) —
        // moving to a fallback identity is fine for THIS session, but the
        // move must not be persisted over a merely-transient condition.
        var sawPoisonedIdentity = false
        identities: for probe in 0..<UInt32(3) {
            let totalOffset = baseIdentityOffset &+ probe
            // A lingering serial belongs to a just-quit twin of the CURRENT
            // identity; fresh fallback identities get a shorter window.
            var created: VirtualDisplay?
            for attempt in 0..<(probe == 0 ? 8 : 3) {
                if attempt > 0 { try await Task.sleep(for: .seconds(2)) }
                // A Disconnect during the retry window tore the session down. Bail
                // before creating/assigning the display: the serial the old display
                // held is likely free now, so a late attempt would *succeed* and
                // resurrect the very zombie this retry exists to avoid. (Mirrors the
                // `if stopped` checks in the permission-poll loops above.)
                if stopped { return }
                created = await MainActor.run {
                    let restoreOrigin = DisplayArrangement.origin(for: sizeInPoints, device: arrangementKey)
                    // The productID moves with the serial: field data in #206
                    // suggests some macOS versions key the hostile state on
                    // the product, not the serial — bumping both escapes
                    // either keying.
                    return VirtualDisplay(name: displayName,
                                          pointsWide: pointsWide, pointsHigh: pointsHigh,
                                          sizeInMillimeters: mm,
                                          serialNum: serial &+ totalOffset,
                                          productID: 0x4F53 &+ totalOffset,
                                          restoreOrigin: restoreOrigin,
                                          onOriginChange: { origin, currentSize in
                                              DisplayArrangement.save(origin: origin, size: currentSize,
                                                                      device: arrangementKey)
                                          })
                }
                if created != nil { break }
                Log.info("virtual display creation failed (identity +\(totalOffset), attempt \(attempt + 1)) — retrying")
                await status("Preparing virtual display…")
            }
            guard let candidate = created else { continue }
            virtualDisplay = candidate
            do {
                display = try await findSCDisplay(id: candidate.displayID)
                vd = candidate
                if probe > 0, sawPoisonedIdentity {
                    Log.info("display identity +\(totalOffset) came online — the previous one is "
                        + "poisoned by saved system state; persisting the offset")
                    baseIdentityOffset = totalOffset   // rebuilds skip the dead probe
                    Task { @MainActor in self.onDisplayIdentityBumped?(totalOffset) }
                }
                break identities
            } catch {
                virtualDisplay = nil   // release the dead display and its serial
                // No shareable displays at all is a permission-side failure —
                // a different identity cannot help there.
                if (error as NSError).domain == "MacSender", (error as NSError).code == 4 { throw error }
                identityError = error as NSError
                sawPoisonedIdentity = true
                if stopped { return }
                Log.info("virtual display (identity +\(totalOffset)) never came online — trying a fresh identity")
                await status("Display blocked by saved macOS state — trying a fresh identity…")
            }
        }
        guard let vd, let display else {
            if sawPoisonedIdentity {
                throw NSError(domain: "MacSender", code: 5, userInfo: [
                    NSLocalizedDescriptionKey: "saved display state in macOS is blocking "
                        + "OpenDisplay's displays — log out and back in (or restart the Mac), then reconnect"])
            }
            throw identityError
        }
        if let targetID = InputTargetResolver.displayID(
            mode: .extend, mirrorDisplayID: 0, virtualDisplayID: vd.displayID) {
            inputInjector = InputInjector(displayID: targetID)
        }
        // Quality scaling: capture/encode below native when requested — the
        // display itself stays native so window layout is unaffected.
        var captureW = (Int(Double(pointsWide * 2) * quality.scale)) & ~1
        var captureH = (Int(Double(pointsHigh * 2) * quality.scale)) & ~1
        // hello.maxEncodeWide/High (PROTOCOL.md 6.5): a big panel does not
        // imply a big decoder. Cap the stream at the receiver's advertised
        // decode ceiling — SCK scales the capture — while the desktop keeps
        // its announced size.
        if let maxW = info.maxEncodeWide, let maxH = info.maxEncodeHigh,
           maxW > 0, maxH > 0, captureW > maxW || captureH > maxH {
            let s = min(Double(maxW) / Double(captureW), Double(maxH) / Double(captureH))
            captureW = (Int(Double(captureW) * s)) & ~1
            captureH = (Int(Double(captureH) * s)) & ~1
            Log.info("stream capped at \(captureW)x\(captureH) by the receiver's decode ceiling \(maxW)x\(maxH)")
        }
        try await startCapture(display: display, pixelsWide: captureW, pixelsHigh: captureH)

        // Debug aid (`defaults write com.peetzweg.opensidecar.mac testPattern -bool true`):
        // an animated window on the virtual display generates a constant frame
        // stream so steady-state latency can be measured without user activity.
        if UserDefaults.standard.bool(forKey: "testPattern") {
            let id = vd.displayID
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
            if let encoder { VTCompressionSessionInvalidate(encoder) }
            encoder = nil
            needsKeyframe = true
            do {
                if try await resizeExistingDisplay(for: target) {
                    // The display identity survived, so WindowServer has no
                    // reason to migrate this device's windows to a sibling.
                } else {
                    // Safety fallback for a system that refuses an in-place
                    // mode switch. This keeps the old recovery behaviour.
                    virtualDisplay = nil
                    try await setupExtend(target)
                }
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
    private func resizeExistingDisplay(for info: PhoneInfo) async throws -> Bool {
        guard let vd = virtualDisplay else { return false }

        let pointsWide = (info.pixelsWide / 2) & ~1
        let pointsHigh = (info.pixelsHigh / 2) & ~1
        let arrangementKey = info.id ?? String(format: "serial-%08x", displaySerial)
        let size = CGSize(width: pointsWide, height: pointsHigh)
        let didResize = await MainActor.run {
            vd.resize(pointsWide: pointsWide, pointsHigh: pointsHigh,
                      movingTo: DisplayArrangement.origin(for: size, device: arrangementKey))
        }
        guard didResize else { return false }

        let display = try await findSCDisplay(id: vd.displayID, expectedSize: size)
        let captureW = (Int(Double(pointsWide * 2) * quality.scale)) & ~1
        let captureH = (Int(Double(pointsHigh * 2) * quality.scale)) & ~1
        try await startCapture(display: display, pixelsWide: captureW, pixelsHigh: captureH)
        if let targetID = InputTargetResolver.displayID(
            mode: .extend, mirrorDisplayID: 0, virtualDisplayID: vd.displayID) {
            inputInjector = InputInjector(displayID: targetID)
        }

        if UserDefaults.standard.bool(forKey: "testPattern") {
            let id = vd.displayID
            Task { @MainActor in TestPattern.show(on: id) }
        }
        return true
    }

    /// The virtual display takes a moment to show up in shareable content.
    private func findSCDisplay(id: CGDirectDisplayID, expectedSize: CGSize? = nil) async throws -> SCDisplay {
        var lastDisplayCount = 0
        for _ in 0..<20 {
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
        throw NSError(domain: "MacSender", code: 3,
                      userInfo: [NSLocalizedDescriptionKey: "virtual display never appeared in SCShareableContent"])
    }

    private func startCapture(display: SCDisplay, pixelsWide: Int, pixelsHigh: Int) async throws {
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
            }
            await status("Video off — controls remain connected")
            return
        }
        let filter = SCContentFilter(display: display, excludingWindows: [])

        let config = SCStreamConfiguration()
        config.width = pixelsWide
        config.height = pixelsHigh
        // Ask for 120 even though the virtual display is 60Hz: requesting
        // exactly 1/60 makes SCK's rate limiter skip frames that arrive a
        // hair early (beat frequency) — measured ~51fps instead of 60.
        config.minimumFrameInterval = CMTime(value: 1, timescale: 120)
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
        // down, and it MUST NOT pick up this Mac's own OpenDisplay audio
        // (there is none today, but excluding it is the documented,
        // future-proof way to avoid a feedback loop).
        config.capturesAudio = desiredAudioEnabled
        config.sampleRate = 48_000
        config.channelCount = 2
        config.excludesCurrentProcessAudio = true

        invalidateCapturePipeline(discardingLastFrame: true)
        let generation = captureGenerationNow
        if let encoder { VTCompressionSessionInvalidate(encoder) }
        encoder = nil
        if videoEnabled {
            try setupEncoder(width: pixelsWide, height: pixelsHigh)
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
        guard self.stream === stream, videoEnabled || desiredAudioEnabled,
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
        }
        Log.info("capture started: \(pixelsWide)x\(pixelsHigh) display \(display.displayID) generation \(generation) mode \(mode.rawValue) localCursor=\(localCursor) video=\(videoEnabled) audio=\(audioEnabled)")
        let kind = lastHello?.kind ?? "device"
        await status("\(mode == .extend ? "Extending to" : "Mirroring to") \(kind) (\(pixelsWide)×\(pixelsHigh))")
    }

    func stop() {
        stopped = true
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
        stream?.stopCapture { _ in }
        stream = nil
        audioEnabled = false
        beginAudioGeneration()
        Task { await self.audioCaptureEncoder.reset() }
        connection?.cancel()
        connection = nil
        // Cursor-channel state is confined to `queue` (the 120Hz poll and the
        // UDP callbacks run there); tearing it down from the main actor races
        // them.
        queue.async { [weak self] in
            self?.closeCursorChannel()
            self?.stopUpgradeProbing()
        }
        if let encoder { VTCompressionSessionInvalidate(encoder) }
        encoder = nil
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
        queue.async { [weak self] in
            self?.sendJSONObject([
                "type": WireMessage.receiverUI,
                "trayEnabled": trayEnabled,
                "keyboardButtonEnabled": keyboardButtonEnabled,
            ])
        }
    }

    func resetReceiverInputState() {
        queue.async { [weak self] in
            self?.inputInjector?.cancelActiveInput()
            self?.sendJSONObject(["type": WireMessage.inputReset])
        }
    }

    private func receiverInputIsAllowed() -> Bool {
        guard InputPolicy.allowsInput(),
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
        guard InputPolicy.allowsInput(),
              captureStateSnapshot().allowsKeyboardInput else {
            inputInjector?.cancelActiveInput()
            return false
        }
        return true
    }

    func pauseDisplay() {
        queue.async { [weak self] in
            guard let self,
                  self.updateCaptureState({ $0.requestPause() }) else { return }
            self.sendDisplayState(.paused)
            self.inputInjector?.cancelActiveInput()
            self.invalidateCapturePipeline()
            self.captureDisplayID = 0   // paused — no active capture until resumeDisplay()
            let activeStream = self.stream
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
                self.queue.async {
                    guard self.captureStateSnapshot().phase == .pausing else { return }
                    if stoppedCapture {
                        if self.stream === activeStream { self.stream = nil }
                        if let encoder = self.encoder { VTCompressionSessionInvalidate(encoder) }
                        self.encoder = nil
                        // Pause stops both media (SESSION BEHAVIOR): the
                        // stream is gone either way, so audio is not
                        // capturing — resumeDisplay's resumeCapture() always
                        // rebuilds the stream and re-applies
                        // `desiredAudioEnabled`, giving resume a clean,
                        // freshly-anchored audio timeline.
                        self.audioEnabled = false
                        self.beginAudioGeneration()
                        Task { await self.audioCaptureEncoder.reset() }
                    }
                    _ = self.updateCaptureState { $0.pauseCompleted() }
                    Task { await self.status("Display paused") }
                }
            }
        }
    }

    func resumeDisplay() {
        queue.async { [weak self] in
            guard let self,
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
            if let encoder { VTCompressionSessionInvalidate(encoder) }
            encoder = nil
            needsKeyframe = true
            // Video Off does not mean Audio Off (SESSION BEHAVIOR): if audio
            // still wants this SCStream, keep it running — the didOutput
            // callback's `videoEnabled` guard is what actually stops
            // encoding/sending, not stream teardown.
            if desiredAudioEnabled, stream != nil {
                Task { await self.status("Video off — controls remain connected") }
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
            Task { await self.status("Video off — controls remain connected") }
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
                try setupEncoder(width: capturePixelsWide, height: capturePixelsHigh)
            } catch {
                Log.info("video resume encoder setup failed: \(error) — entering capture recovery")
                guard updateCaptureState({ $0.unexpectedStop() }) else { return }
                scheduleCaptureRecovery()
            }
            return
        }
        Task { await self.restartVideoCapture() }
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
                let width = capturePixelsWide > 0
                    ? capturePixelsWide : (Int(Double(vd.pointsWide * 2) * quality.scale)) & ~1
                let height = capturePixelsHigh > 0
                    ? capturePixelsHigh : (Int(Double(vd.pointsHigh * 2) * quality.scale)) & ~1
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
        if let encoder { VTCompressionSessionInvalidate(encoder) }
        encoder = nil
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
                let width = (Int(Double(vd.pointsWide * 2) * quality.scale)) & ~1
                let height = (Int(Double(vd.pointsHigh * 2) * quality.scale)) & ~1
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
            self.connectionReady = false
            self.currentPathDirectLink = false   // the new transport re-classifies
            Task { @MainActor in self.onTransportPath?(nil) }
            self.dialGeneration += 1   // a dial still in flight must not adopt
            self.connection?.cancel()
            self.connection = nil
            self.closeCursorChannel()
            self.stopUpgradeProbing()
            self.pendingSends = 0
            self.pipelineLock.lock()
            self.pendingEncodes = 0
            self.pipelineLock.unlock()
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
        Task { @MainActor in self.onDisconnected?() }
    }

    /// A live connection just died (must be called on `queue`). On the
    /// direct cable link the death is almost always someone pulling the
    /// plug, and unplugging is how people intentionally end a session —
    /// falling back to WiFi would resurrect what they just killed. Every
    /// other path (WiFi, routed Ethernet, the dev loopback) keeps the
    /// redial loop: a drop there is never intent.
    private func linkDied(_ detail: String) {
        if currentPathDirectLink, case .tcp = transport {
            reportGone("cable link lost (\(detail)) — unplugging means disconnect, ending session")
        } else {
            scheduleReconnect()
        }
    }

    /// (Re)decide whether the live session rides the direct host-to-host
    /// cable (must be called on `queue`). Address shape alone is not
    /// enough: on a bridged LAN a phone's Bonjour record can resolve to
    /// its fe80, and a DHCP-less switch hands out 169.254 to everyone —
    /// so the peer must also be a Mac receiver, the only receiver a TCP
    /// cable session can exist with (phones ride usbmuxd). Runs again when
    /// hello arrives: a fresh dial reaches ready before the first hello
    /// names the device.
    private func refreshDirectLinkClassification(for conn: NWConnection) {
        guard connection === conn, case .tcp = transport,
              lastHello?.device == "Mac",
              let path = conn.currentPath else {
            currentPathDirectLink = false
            return
        }
        let wired = TransportSafety.isWiredDirectLinkPath(
            usesWiFi: path.usesInterfaceType(.wifi),
            usesLoopback: path.usesInterfaceType(.loopback),
            usesCellular: path.usesInterfaceType(.cellular),
            interfaceNames: path.availableInterfaces.map(\.name))
        currentPathDirectLink = wired
            && Self.endpointIsLinkLocal(path.remoteEndpoint ?? conn.endpoint)
    }

    private func reportRoute(for conn: NWConnection, path: NWPath) {
        guard connection === conn, connectionReady else { return }
        refreshDirectLinkClassification(for: conn)

        let names = path.availableInterfaces.map(\.name)
        let isUSBTransport: Bool
        if case .usb = transport {
            isUSBTransport = true
        } else {
            isUSBTransport = false
        }
        let route = ConnectionRoute.classify(
            isUSB: isUSBTransport,
            interfaceNames: names,
            remoteEndpointDescription: String(describing: path.remoteEndpoint ?? conn.endpoint))
        // AWDL is wireless even on systems where its NWPath does not report
        // `.wifi`; keep the existing wired-upgrade probe eligible there.
        currentPathUsesWiFi = path.usesInterfaceType(.wifi) || route == .awdl

        Log.info("connection path to \(endpointName): \(names.joined(separator: ","))"
            + " route=\(route.rawValue) direct=\(currentPathDirectLink)")
        Task { @MainActor in self.onTransportPath?(route) }
    }

    /// True when the far end of a connection is a link-local address
    /// (fe80::/10 or 169.254/16). The USB-C/Thunderbolt host-to-host link
    /// hands out nothing else — necessary for "riding the direct cable",
    /// but not sufficient: see refreshDirectLinkClassification.
    private static func endpointIsLinkLocal(_ endpoint: NWEndpoint?) -> Bool {
        guard case .hostPort(let host, _)? = endpoint else { return false }
        switch host {
        case .ipv4(let addr): return addr.isLinkLocal
        case .ipv6(let addr): return addr.isLinkLocal
        case .name(let name, _):
            // Literal probe targets dial as names ("fe80::1%en5").
            let bare = name.lowercased()
            return bare.hasPrefix("169.254.") || bare.hasPrefix("fe80:")
        @unknown default: return false
        }
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
                  !self.connectionReady else { return }
            self.reportGone("service withdrawn and connection down — receiver app is gone, ending session")
        }
    }

    /// Drop the current connection and dial again — fresh TCP through the
    /// tunnel, fresh accept on the phone. Bound to the UI Reconnect button.
    func forceReconnect() {
        queue.async { [weak self] in
            guard let self, !self.stopped else { return }
            Log.info("manual reconnect requested")
            self.disconnectedSince = Date()   // fresh grace window
            self.scheduleReconnect()
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        queue.async { [weak self] in
            self?.handleCaptureStopped(stream, error: error)
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
            Task { @MainActor in self.onCaptureStoppedByUser?() }
            return
        }
        guard !stopped,
              updateCaptureState({ $0.unexpectedStop() }) else { return }
        Log.info("unexpected SCStream stop mode=\(mode.rawValue) domain=\(nsError.domain) "
            + "code=\(nsError.code): \(error.localizedDescription)")
        Task { await status("Capture stopped: \(error.localizedDescription)") }
        // An unplanned stop is exactly the kind of drop a held keyboard key
        // (or mouse/Pencil contact) must not survive — the recovery window
        // that follows has no live session for it to belong to.
        inputInjector?.cancelActiveInput()
        invalidateCapturePipeline()
        stream = nil
        scheduleCaptureRecovery()
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
        queue.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            guard let self else { return }
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
            targetAvailable = captureDisplayID != 0 && !CGDisplayBounds(captureDisplayID).isEmpty
        case .extend:
            if let virtualDisplay {
                targetAvailable = !CGDisplayBounds(virtualDisplay.displayID).isEmpty
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
        queue.async { self.recoveryRoundEnded() }
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

    private func startMirrorCapture(display: SCDisplay) async throws {
        if let targetID = InputTargetResolver.displayID(
            mode: .mirror,
            mirrorDisplayID: display.displayID,
            virtualDisplayID: nil
        ) {
            inputInjector = InputInjector(displayID: targetID)
        }

        let displayMode = CGDisplayCopyDisplayMode(display.displayID)
        let pixelsW = displayMode?.pixelWidth ?? display.width
        let pixelsH = displayMode?.pixelHeight ?? display.height
        let captureW = (Int(Double(pixelsW) * quality.scale)) & ~1
        let captureH = (Int(Double(pixelsH) * quality.scale)) & ~1
        try await startCapture(display: display, pixelsWide: captureW, pixelsHigh: captureH)
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
        let display = try await findSCDisplay(id: vd.displayID)
        let captureW = (Int(Double(vd.pointsWide * 2) * quality.scale)) & ~1
        let captureH = (Int(Double(vd.pointsHigh * 2) * quality.scale)) & ~1
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
            if captureStateSnapshot().phase == .resuming {
                _ = updateCaptureState { $0.resumeFailed() }
                Task { await status("Resume failed — try again") }
                return
            }
            _ = updateCaptureState { $0.recoveryFailed() }
            Task { await status("Capture could not be restarted") }
            reportGone("capture recovery failed \(captureRecoveryBudget.failedAttempts)x — ending session")
            return
        }
        scheduleCaptureRecovery()
    }

    // MARK: - Connection (with retry)

    // Guards against a stale async USB dial adopting after a newer one (or a
    // manual reconnect) superseded it. Only touched on `queue`.
    private var dialGeneration = 0

    private func connect() {
        guard !stopped else { return }
        switch transport {
        case .tcp(let endpoint, let tls): connectTCP(endpoint, tls: tls)
        case .usb(let udid, let port): connectUSB(udid: udid, port: port)
        }
    }

    /// Bookkeeping shared by both transports once a connection is live.
    private func becomeReady(_ conn: NWConnection) {
        Log.info("connection ready to \(endpointName)")
        connectionReady = true
        cursorSeq = 0   // per-session; the receiver rewound its floor with the connection
        everConnected = true
        awaitingWake = false
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
        // FORENSIC FIX (media-death-after-reconnect): a reconnecting peer's
        // `StreamReceiver` always resets its own `audioFormatDescription` to
        // nil (see `resetStreamState`/`resetAudioPlayback`) because it is a
        // new session — but before this fix, `audioConfigSent` stayed true
        // across the reconnect (nothing here reset it), so this sender
        // never sent the fresh `AudioConfigFrame` the new session needs,
        // and `scheduleAudioPacket` silently dropped every packet forever
        // afterward. Video recovers because `needsKeyframe = true` above
        // forces a fresh SPS/PPS + IDR every reconnect; audio needs the
        // exact same "resend what a new peer needs" treatment.
        // A reconnect is also a fresh audio generation (the receiver's own
        // `resetStreamState` always drops its format description and
        // audio-codec/sequence tracking too — see `StreamReceiver`) — this
        // is also the one place a DEBUG `audioDebugMode` change is picked
        // up if the user chose reconnect over Audio Off→On to switch it.
        if audioEnabled {
            beginAudioGeneration()
        }
        // An established connection whose interface vanishes does NOT get a
        // .failed/.waiting state update — NW keeps it and flags it non-viable
        // (field-tested: pulling the USB-C cable left the state handler
        // silent and only the 5s watchdog noticed). Viability is the prompt
        // unplug signal. Only the direct cable link acts on it: WiFi blips
        // go non-viable routinely and NW rides them out on its own, and a
        // docked Mac losing its Ethernet (undock) should fall back to WiFi,
        // not end the session.
        conn.viabilityUpdateHandler = { [weak self] viable in
            guard let self, self.connection === conn, !viable,
                  self.currentPathDirectLink else { return }
            self.linkDied("path no longer viable")
        }
        conn.pathUpdateHandler = { [weak self] path in
            guard let self, self.connection === conn else { return }
            self.reportRoute(for: conn, path: path)
        }
        receiveControl(on: conn)
        if let path = conn.currentPath {
            reportRoute(for: conn, path: path)
        }
        // -forceUpgradeProbe YES: dev knob — loopback runs never look like
        // WiFi, so this is the only way to exercise probe+migrate on one Mac.
        if currentPathUsesWiFi || UserDefaults.standard.bool(forKey: "forceUpgradeProbe") {
            startUpgradeProbing()
        } else {
            stopUpgradeProbing()   // already off WiFi — nothing better to find
        }
        Task { await self.status("Connected") }
    }

    // MARK: - Cable upgrade (PROTOCOL.md 6.4)

    /// Arm the periodic probe. Cheap when there is nothing to find: with no
    /// advertised addresses, or on the USB transport, it never fires a dial.
    private func startUpgradeProbing() {
        lastLoggedCandidates = []
        upgradeTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 2.0, repeating: 10.0)
        timer.setEventHandler { [weak self] in self?.probeForCablePath() }
        timer.resume()
        upgradeTimer = timer
        wiredPathMonitor?.cancel()
        let monitor = NWPathMonitor(requiredInterfaceType: .wiredEthernet)
        // The handler also fires once at start with the current state; only
        // a transition to satisfied means a cable was just plugged.
        var wasSatisfied: Bool? = nil
        monitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            defer { wasSatisfied = satisfied }
            guard let self, satisfied, wasSatisfied == false else { return }
            Log.info("local wired path appeared — probing cable paths now")
            self.probeForCablePath(force: true)
        }
        monitor.start(queue: queue)
        wiredPathMonitor = monitor
    }

    private func stopUpgradeProbing() {
        upgradeTimer?.cancel()
        upgradeTimer = nil
        wiredPathMonitor?.cancel()
        wiredPathMonitor = nil
        probeRoundGeneration += 1   // orphan any pending sweep
        upgradeProbes.forEach { $0.cancel() }
        upgradeProbes.removeAll()
    }

    /// One probe round: dial every candidate (receiver address × local
    /// interface for link-local IPv6) with WiFi forbidden. mDNS resolution
    /// stalls under interface restrictions; literal addresses do not.
    private func probeForCablePath(force: Bool = false) {
        guard !stopped, connectionReady,
              currentPathUsesWiFi || UserDefaults.standard.bool(forKey: "forceUpgradeProbe"),
              case .tcp = transport, !peerAddrs.isEmpty else { return }
        if force {
            // Something changed (peer re-hello, local interface up): a round
            // of stale candidates still in flight must not swallow this one.
            upgradeProbes.forEach { $0.cancel() }
            upgradeProbes.removeAll()
        } else {
            guard upgradeProbes.isEmpty else { return }   // a round is still in flight
        }

        // Directly-dialable addresses first (IPv4, routable IPv6): they are
        // one candidate each and usually enough. Link-local IPv6 needs a
        // local zone and fans out across interfaces, so it goes last and
        // only across interfaces that hold a link-local themselves — a cap
        // eaten by dead scopes would starve the real candidates.
        var candidates: [NWEndpoint.Host] = []
        var linkLocal: [NWEndpoint.Host] = []
        let scopes = Self.candidateInterfaceNames()
        for addr in peerAddrs {
            if addr.lowercased().hasPrefix("fe80:") {
                for iface in scopes {
                    linkLocal.append(NWEndpoint.Host("\(addr)%\(iface)"))
                }
            } else {
                candidates.append(NWEndpoint.Host(addr))
            }
        }
        candidates.append(contentsOf: linkLocal)
        guard !candidates.isEmpty else { return }
        // Log a round only when its candidate set differs from the last
        // logged one: the first round of a session and every cable-plug
        // transition show up, an unchanged set repeating every 10s does not.
        let candidateNames = candidates.prefix(16).map { "\($0)" }
        if candidateNames != lastLoggedCandidates {
            lastLoggedCandidates = candidateNames
            Log.info("probing \(candidateNames.count) candidate cable paths"
                     + " (direct \(candidates.count - linkLocal.count),"
                     + " fe80 scopes \(scopes.joined(separator: ","))) — repeats every 10s")
        }
        probeRoundGeneration += 1
        let round = probeRoundGeneration

        for host in candidates.prefix(16) {
            let tcp = NWProtocolTCP.Options()
            tcp.noDelay = true
            let tlsOptions: NWProtocolTLS.Options?
            if case .tcp(_, let config?) = transport {
                tlsOptions = TLSConfigurator.mutualTLSOptions(
                    identity: config.identity,
                    pinnedSPKIs: { [config.pinnedPeerSPKI] },
                    isListener: false, queue: queue)
            } else {
                tlsOptions = nil
            }
            let allowsPlaintext: Bool
            if case .tcp(_, nil) = transport { allowsPlaintext = true }
            else { allowsPlaintext = false }
            guard allowsPlaintext || tlsOptions != nil else { continue }
            let params = NWParameters(tls: tlsOptions, tcp: tcp)
            params.prohibitedInterfaceTypes = [.wifi, .cellular]
            let probePort: NWEndpoint.Port = if case .tcp(_, .some) = transport {
                NWEndpoint.Port(rawValue: WireCrypto.tlsPort)!
            } else {
                9000
            }
            let probe = NWConnection(host: host, port: probePort, using: params)
            upgradeProbes.append(probe)
            probe.stateUpdateHandler = { [weak self] state in
                guard let self, self.upgradeProbes.contains(where: { $0 === probe }) else { return }
                switch state {
                case .ready:
                    if let path = probe.currentPath, !path.usesInterfaceType(.wifi) {
                        self.migrate(to: probe)
                    } else {
                        self.upgradeProbes.removeAll { $0 === probe }
                        probe.cancel()
                    }
                case .failed, .waiting:
                    self.upgradeProbes.removeAll { $0 === probe }
                    probe.cancel()
                default: break
                }
            }
            probe.start(queue: queue)
        }
        // Sweep stragglers so the next round starts clean. Generation-gated:
        // a forced round may have replaced this one, and the old sweep must
        // not cancel the new round's probes mid-dial.
        queue.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            guard let self, self.probeRoundGeneration == round else { return }
            self.upgradeProbes.forEach { $0.cancel() }
            self.upgradeProbes.removeAll()
        }
    }

    /// Swap the live session onto the probed connection. Same shape as a
    /// reconnect: the receiver parks the newcomer, adopts it on our first
    /// bytes, and the abandoned WiFi socket's EOF is ignored as stale.
    private func migrate(to conn: NWConnection) {
        let names = conn.currentPath?.availableInterfaces.map(\.name)
            .joined(separator: ",") ?? "?"
        Log.info("cable path answered (\(names)) — migrating the session off WiFi")
        // Same reasoning as switchTransport: the underlying connection is
        // being replaced, so any held hardware key must not survive it.
        inputInjector?.cancelActiveInput()
        upgradeProbes.removeAll { $0 === conn }
        stopUpgradeProbing()
        dialGeneration += 1   // a redial in flight must not clobber this
        closeCursorChannel()  // rebuilt from the next hello on the new path
        // Detach the old connection's handler BEFORE cancelling: its
        // .cancelled callback arrives after becomeReady below and would
        // reset connectionReady, silently blackholing every send on the
        // migrated connection.
        connection?.stateUpdateHandler = nil
        connection?.viabilityUpdateHandler = nil
        connection?.cancel()
        connection = conn
        conn.stateUpdateHandler = { [weak self] state in
            guard let self, self.connection === conn else { return }
            switch state {
            case .failed(let error):
                Log.info("connection failed: \(error)")
                self.connectionReady = false
                self.linkDied("failed: \(error)")
            case .waiting(let error):
                Log.info("connection waiting: \(error) — will retry")
                self.connectionReady = false
                self.linkDied("waiting: \(error)")
            case .cancelled:
                self.connectionReady = false
            default: break
            }
        }
        becomeReady(conn)
    }

    /// Local zones a link-local probe could ride: interfaces that are up,
    /// not loopback, and hold a link-local IPv6 address of their own (a
    /// scope with no fe80 of its own answers every dial with "network is
    /// down"). Names only — the probe carries the actual restriction via
    /// prohibitedInterfaceTypes.
    private static func candidateInterfaceNames() -> [String] {
        var result: [String] = []
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return result }
        defer { freeifaddrs(list) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            let flags = Int32(ifa.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0,
                  let sa = ifa.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET6) else { continue }
            let name = String(cString: ifa.ifa_name)
            // anpi* completes TCP handshakes but cannot carry the stream —
            // see the matching exclusion in StreamReceiver.
            if name.hasPrefix("awdl") || name.hasPrefix("llw") || name.hasPrefix("utun")
                || name.hasPrefix("gif") || name.hasPrefix("stf")
                || name.hasPrefix("anpi") { continue }
            let isLinkLocal = sa.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) {
                var a = $0.pointee.sin6_addr
                return withUnsafeBytes(of: &a) { $0[0] == 0xfe && ($0[1] & 0xc0) == 0x80 }
            }
            guard isLinkLocal else { continue }
            if !result.contains(name) { result.append(name) }
        }
        return result
    }

    private func connectTCP(_ endpoint: NWEndpoint, tls: TLSSessionConfig?) {
        let options = NWProtocolTCP.Options()
        options.noDelay = true   // latency matters more than throughput here
        // No interface steering: macOS already ranks a Thunderbolt Bridge or
        // Ethernet link above WiFi, so a plain dial lands on the cable when
        // there is one (field-tested: en10 chosen over en0). A WiFi-prohibited
        // pre-dial was tried and only ever hung until its timeout, adding 2s
        // to every connect. becomeReady reports which path won.
        let tlsOptions: NWProtocolTLS.Options?
        if let tls {
            tlsOptions = TLSConfigurator.mutualTLSOptions(
                identity: tls.identity,
                pinnedSPKIs: { [tls.pinnedPeerSPKI] },
                isListener: false, queue: queue)
            guard tlsOptions != nil else {
                Task { await self.status("Secure connection unavailable") }
                return
            }
        } else {
            tlsOptions = nil
        }
        let params = NWParameters(tls: tlsOptions, tcp: options)
        params.includePeerToPeer = true
        let conn = NWConnection(to: endpoint, using: params)
        connection = conn
        // A dial to a withdrawn Bonjour service (receiver asleep or app
        // closed) sits in .preparing forever — it neither fails nor resolves
        // when the service later returns, observed on macOS 26. Give every
        // dial a deadline and redial fresh: a new NWConnection re-runs
        // Bonjour resolution, so the retry loop reaches the receiver the
        // moment it advertises again.
        let generation = dialGeneration
        queue.asyncAfter(deadline: .now() + 5.0) { [weak self] in
            guard let self, generation == self.dialGeneration, !self.stopped,
                  self.connection === conn, conn.state != .ready else { return }
            Log.info("dial timed out in \(conn.state) — redialing")
            self.scheduleReconnect()
        }
        conn.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.becomeReady(conn)
            case .failed(let error):
                Log.info("connection failed: \(error)")
                self.connectionReady = false
                if tls != nil, Self.isTLSFailure(error) {
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
                // (e.g. a manual -host tunnel not started yet) — treat
                // waiting as failure and poll by reconnecting.
                Log.info("connection waiting: \(error) — will retry")
                self.connectionReady = false
                if tls != nil, Self.isTLSFailure(error) {
                    self.reportTrustFailure()
                    return
                }
                // Read the queue-confined flag here (handler runs on queue),
                // not inside the detached status Task.
                let text = self.awaitingWake
                    ? "\(self.endpointName) is asleep — reconnects when it wakes…"
                    : "Waiting for receiver at \(self.endpointName)…"
                Task { await self.status(text) }
                self.scheduleReconnect()
            case .cancelled:
                self.connectionReady = false
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
        stopped = true
        connection?.cancel()
        Task { @MainActor in
            self.onTrustFailure?("OpenDisplay could not verify this device. Forget it and pair again if its identity was reset.")
        }
    }

    /// Dial through macOS's built-in usbmuxd — no external tunnel needed.
    /// The handshake is async, so adoption is gated on `dialGeneration`.
    private func connectUSB(udid: String?, port: UInt16) {
        dialGeneration += 1
        let generation = dialGeneration
        Task { [weak self] in
            guard let self else { return }
            do {
                let conn = try await Usbmux.dial(udid: udid, port: port, queue: queue)
                queue.async {
                    guard generation == self.dialGeneration, !self.stopped else {
                        conn.cancel()
                        return
                    }
                    self.connection = conn
                    conn.stateUpdateHandler = { [weak self] state in
                        guard let self else { return }
                        switch state {
                        case .failed(let error):
                            Log.info("usb connection failed: \(error)")
                            self.connectionReady = false
                            self.scheduleReconnect()
                        case .cancelled:
                            self.connectionReady = false
                        default:
                            break
                        }
                    }
                    self.becomeReady(conn)
                }
            } catch {
                queue.async {
                    guard generation == self.dialGeneration, !self.stopped else { return }
                    // Distinct guidance per failure: cable missing vs app
                    // closed. Composed on `queue`: awaitingWake lives there.
                    let hint: String
                    switch error as? Usbmux.Failure {
                    case .noDevice:
                        hint = "Waiting for a USB device — plug in the iPhone or iPad…"
                    case .refused:
                        self.dialRefused()
                        hint = self.awaitingWake
                            ? "\(self.endpointName) is asleep — reconnects when it wakes…"
                            : "Device found — open the OpenDisplay app on it…"
                    default:
                        Log.info("usb dial failed: \(error)")
                        hint = "USB connection failed: \(error.localizedDescription)"
                    }
                    Task { await self.status(hint) }
                    self.scheduleReconnect()
                }
            }
        }
    }

    private func scheduleReconnect() {
        guard !stopped else { return }
        // Same reasoning as switchTransport/migrate: the connection this
        // session held input on is gone, so nothing may stay held across
        // the reconnect attempt.
        inputInjector?.cancelActiveInput()
        if everConnected {
            if let since = disconnectedSince {
                if Date().timeIntervalSince(since) > disconnectGraceSeconds {
                    reportGone("device gone for >\(Int(disconnectGraceSeconds))s — ending session")
                    return
                }
            } else {
                disconnectedSince = Date()
                Task { await status("Connection lost — retrying for \(Int(disconnectGraceSeconds))s…") }
            }
        }
        connectionReady = false
        // Whatever this session rode is gone; deciding to redial means it is
        // an ordinary reconnecting session now. A stale direct-link flag here
        // would let the first dial hiccup end the session via linkDied.
        currentPathDirectLink = false
        Task { @MainActor in self.onTransportPath?(nil) }
        dialGeneration += 1   // a USB dial still in flight must not adopt
        let generation = dialGeneration
        connection?.cancel()
        connection = nil
        closeCursorChannel()   // rebuilt from the next hello
        pendingSends = 0
        pipelineLock.lock()
        pendingEncodes = 0
        pipelineLock.unlock()
        queue.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            // Generation-guarded so a switchTransport (or another reconnect)
            // that landed in this 1s window supersedes this dial instead of
            // racing it — otherwise the queued connect() re-dials the new
            // transport, briefly running two live connections. (No bare
            // self-rescheduling asyncAfter — the pattern banned in #76.)
            guard let self, generation == self.dialGeneration, !self.stopped else { return }
            self.connect()
        }
    }

    // MARK: - Liveness (ping + watchdog)

    private func schedulePing() {
        queue.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self, !self.stopped else { return }
            if self.connectionReady {
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
                self.sendJSONFrame("{\"type\":\"ping\",\"drops\":\(self.dropsTotal),\"encDrops\":\(self.dropsEncTotal),\"netDrops\":\(self.dropsNetTotal),\"pending\":\(self.pendingSends),\"inp50\":\(inp50),\"inp95\":\(inp95),\"capFps\":\(capFps)\(audioSuffix)}")
            }
            self.schedulePing()
        }
    }

    private func scheduleWatchdog() {
        queue.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self, !self.stopped else { return }
            if self.connectionReady, Date().timeIntervalSince(self.lastReceived) > 5 {
                // A suspended receiver app (user switched apps) goes silent
                // like this while its kernel still accepts redials — the
                // session and display are kept on purpose so the user's
                // window arrangement survives until they come back. Genuine
                // network loss fails the redials and ends via the grace.
                if self.currentPathDirectLink, case .tcp = self.transport {
                    // Backstop for the viability handler: silence on the
                    // direct cable is an unplug (or a dead peer) — never
                    // redial onto WiFi.
                    self.linkDied("silent for >5s")
                } else {
                    Log.info("watchdog: nothing from the phone for >5s — reconnecting")
                    // Can't tell a backgrounded receiver from a brief stall here
                    // (both go silent while redials still succeed) — hedge.
                    Task { await self.status("\(self.endpointName) is silent — keeping the display (app in background or brief stall)") }
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
            if self.connectionReady, self.pendingSends > 0,
               Date().timeIntervalSince(self.lastSendCompletionAt) > 5 {
                if !self.sendStallReported {
                    self.sendStallReported = true
                    Log.info("watchdog: outbound writer stalled — pendingSends=\(self.pendingSends) "
                        + "idle for >5s — reconnecting")
                }
                if self.currentPathDirectLink, case .tcp = self.transport {
                    self.linkDied("outbound writer stalled")
                } else {
                    self.scheduleReconnect()
                }
            }
            // The disconnect grace is otherwise only evaluated when a dial
            // changes state — a dial stuck in .preparing (withdrawn Bonjour
            // service) would keep a dead session's display up forever.
            // Enforce it from here too, where the clock always ticks.
            if !self.connectionReady, self.everConnected,
               let since = self.disconnectedSince,
               Date().timeIntervalSince(since) > self.disconnectGraceSeconds {
                self.reportGone("device gone for >\(Int(self.disconnectGraceSeconds))s — ending session")
            }
            // A reconnect on a static screen produces no capture frames, so
            // the receiver would stay black — replay the last frame as IDR.
            if self.connectionReady, self.needsKeyframe,
               Date().timeIntervalSince(self.lastCaptureAt) > 1,
                let pixelBuffer = self.lastPixelBuffer {
                Log.info("static screen after reconnect to \(self.endpointName) — replaying last frame as keyframe")
                self.encode(pixelBuffer, pts: CMClockGetTime(CMClockGetHostTimeClock()),
                            generation: self.captureGenerationNow)
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
        guard connectionReady, captureDisplayID != 0,
              let loc = CGEvent(source: nil)?.location else {
            #if DEBUG
            logCursorTraceIfDue(reason: "gated: connectionReady=\(connectionReady) captureDisplayID=\(captureDisplayID)")
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

    /// Cursor position: UDP side channel while it is up, TCP otherwise. The
    /// datagram carries a sequence so the receiver can drop reordered ones;
    /// the TCP frame is byte-identical to the pre-side-channel wire. Never
    /// blocks: a send on a dead UDP socket just fails in its completion.
    private func sendCursor(_ fields: String) {
        cursorSeq &+= 1
        let message = "{\"type\":\"cursor\",\(fields),\"s\":\(cursorSeq)}"
        let udpAvailable = cursorConnection != nil && cursorConnectionReady
        if let cursorConnection, cursorConnectionReady {
            cursorConnection.send(content: Data(message.utf8),
                                  completion: .contentProcessed { _ in })
        }
        if CursorTransportPolicy.shouldSendOnPrimary(
            udpAvailable: udpAvailable, udpConfirmed: cursorChannelConfirmed) {
            sendJSONFrame(message)
        }
    }

    /// Dial the receiver's UDP cursor port (must be called on `queue`). WiFi
    /// only: usbmuxd tunnels TCP streams, there is no UDP through it. The
    /// host is the one the live TCP connection actually reached, so a
    /// Bonjour or Thunderbolt-bridged dial lands on the same interface. Any
    /// failure here is silent: the cursor keeps riding TCP.
    private func openCursorChannel(port: Int) {
        guard case .tcp = transport, let conn = connection, connectionReady,
              port > 0, port <= Int(UInt16.max),
              let udpPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            closeCursorChannel()
            return
        }
        if let existing = cursorConnection, cursorChannelPort == udpPort {
            switch existing.state {
            case .failed, .cancelled: break   // dead flow, dial again below
            default: return   // rotation re-hello: keep the flow and its sequence
            }
        }
        guard case .hostPort(let host, _)? = conn.currentPath?.remoteEndpoint else {
            Log.info("cursor channel: no remote host for \(endpointName), cursor stays on TCP")
            closeCursorChannel()
            return
        }
        closeCursorChannel()
        let params = NWParameters.udp
        params.includePeerToPeer = true
        params.serviceClass = .responsiveData
        let udp = NWConnection(host: host, port: udpPort, using: params)
        cursorConnection = udp
        cursorChannelPort = udpPort
        // cursorSeq is session-scoped (reset in becomeReady), not per flow:
        // TCP frames carry the same sequence, and a flow-local restart would
        // read as stale against a floor the TCP path already advanced.
        udp.stateUpdateHandler = { [weak self] state in
            guard let self, self.cursorConnection === udp else { return }
            switch state {
            case .ready:
                self.cursorConnectionReady = true
                Log.info("cursor channel ready: udp \(host):\(udpPort)")
                // Probe immediately: positions only flow while the cursor is
                // on the captured display, which can be minutes away — the
                // ack round-trip must not wait for that.
                if self.lastCursorSent.visible {
                    self.sendCursor(String(format: "\"x\":%.4f,\"y\":%.4f,\"v\":1",
                                           self.lastCursorSent.x, self.lastCursorSent.y))
                } else {
                    self.sendCursor("\"v\":0")
                }
                // No ack = nobody is listening (firewall, dead listener):
                // drop the channel and let the TCP fallback carry on.
                self.queue.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                    guard let self, self.cursorConnection === udp,
                          !self.cursorChannelConfirmed else { return }
                    Log.info("cursor channel: no ack after 3s — staying on TCP")
                    self.closeCursorChannel()
                }
            case .failed(let error):
                Log.info("cursor channel failed: \(error), cursor stays on TCP")
                self.closeCursorChannel()
            case .waiting(let error):
                Log.info("cursor channel waiting: \(error), cursor stays on TCP")
                self.cursorConnectionReady = false
            case .cancelled:
                self.cursorConnectionReady = false
            default:
                break
            }
        }
        udp.start(queue: queue)
    }

    private func closeCursorChannel() {
        cursorChannelConfirmed = false
        cursorConnectionReady = false
        cursorConnection?.cancel()
        cursorConnection = nil
        cursorChannelPort = nil
    }

    private static let maxCursorPNGBytes = 24_000

    private func pollCursorImage() {
        // Display size read LIVE, not snapshotted at capture start: the
        // HiDPI mode settles (and macOS re-flips it) asynchronously, and a
        // sprite normalized against the 1x size renders at half size on the
        // device. Mixing the size into the dedup hash re-sends the sprite
        // whenever the mode flips, so the proportion always heals.
        guard connectionReady, captureDisplayID != 0,
              let cursor = NSCursor.currentSystem else {
            #if DEBUG
            logCursorTraceIfDue(reason: "cursorImg gated: connectionReady=\(connectionReady) "
                + "captureDisplayID=\(captureDisplayID) currentSystem=\(NSCursor.currentSystem != nil)")
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
        queue.async { self.sendJSONFrame(msg) }
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
            guard let self, error == nil, let data, data.count == 4 else {
                if let error {
                    Log.info("control receive ended: \(error)")
                    // A receive error on the live connection is fatal to it.
                    // Route through linkDied so a cable session ends instead
                    // of silently waiting for the watchdog to redial. Skip
                    // ECANCELED: that is our own cancel (stop, migrate,
                    // redial), not the link dying.
                    var isOwnCancel = false
                    if case .posix(let code) = error, code == .ECANCELED { isOwnCancel = true }
                    if let self, self.connection === conn, !isOwnCancel {
                        self.linkDied("receive failed: \(error)")
                    }
                }
                return
            }
            let len = Int(UInt32(bigEndian: data.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }))
            guard len > 0, len < 1 << 20 else { return }
            conn.receive(minimumIncompleteLength: len, maximumLength: len) { [weak self] payload, _, _, error in
                guard let self, error == nil, let payload, payload.count == len else { return }
                self.handleControl(payload)
                self.receiveControl(on: conn)
            }
        }
    }

    private func handleControl(_ payload: Data) {
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
                Log.info("PHONE-STATS \(line) | mac enc↓=\(dropsEncThisWindow) net↓=\(dropsNetThisWindow) pending=\(pendingSends)")
                dropsEncThisWindow = 0
                dropsNetThisWindow = 0
            }
        case "cursorAck":
            // The receiver saw our first datagram: the side channel delivers,
            // stop mirroring positions onto TCP (PROTOCOL.md 6.3).
            if cursorConnection != nil, !cursorChannelConfirmed {
                cursorChannelConfirmed = true
                Log.info("cursor channel confirmed by the receiver")
            }
        case "hello":
            if let info = try? JSONDecoder().decode(PhoneInfo.self, from: payload) {
                if case .tcp(_, let tls?) = transport, info.id != tls.peerID {
                    Log.info("SECURITY: authenticated key claimed unexpected peer id")
                    stopped = true
                    connection?.cancel()
                    Task { @MainActor in
                        self.onTrustFailure?("Device identity changed. Forget the device and pair again if you intentionally reset it.")
                    }
                    return
                }
                let previous = lastHello
                lastHello = info
                // A fresh dial classifies before the hello names the device —
                // now that it has, decide again (see the comment on the func).
                if let conn = connection { refreshDirectLinkClassification(for: conn) }
                Task { @MainActor in self.onHello?(info) }
                let secureNetworkSession: Bool = if case .tcp(_, .some) = transport { true } else { false }
                if CursorTransportPolicy.shouldOpenUDP(
                    isSecureNetworkSession: secureNetworkSession,
                    advertisedPort: info.cursorPort), let port = info.cursorPort {
                    openCursorChannel(port: port)
                } else {
                    closeCursorChannel()
                }
                let addrs = info.addrs ?? []
                if addrs != peerAddrs {
                    let firstHello = peerAddrs.isEmpty
                    peerAddrs = addrs
                    // A re-hello with a changed address set usually means a
                    // cable was just plugged — probe now, not in up to 10s,
                    // and cancel any stale round still in flight.
                    if upgradeTimer != nil, !firstHello {
                        Log.info("receiver addrs changed (\(addrs.count)) — probing cable paths now")
                        probeForCablePath(force: true)
                    }
                }
                // Version handshake (issue #132). Reply with our identity, and
                // if the receiver is below the version we support, tell it to
                // update. Both are additive: older receivers ignore unknown
                // message types. Sending on every hello is idempotent — the
                // phone dedupes by content.
                sendWelcome()
                sendDisplayModeState()
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
                    continuation.resume(returning: info)
                } else if mode == .extend, virtualDisplay != nil, let previous,
                          previous.pixelsWide != info.pixelsWide
                          || previous.pixelsHigh != info.pixelsHigh {
                    // Phone rotated — rebuild after a short debounce so a
                    // flurry of orientation flips settles into one rebuild.
                    Task {
                        try? await Task.sleep(for: .milliseconds(300))
                        guard let current = self.lastHello,
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
                Task { @MainActor in self.onDisplayModeRequest?(requestedMode) }
            }
        case WireMessage.allowInputRequest:
            guard let info = lastHello,
                  info.protocolVersion >= WireProtocol.allowInputWireVersion,
                  let requested = obj["allowed"] as? Bool else { return }
            if requested == InputPolicy.allowsInput() {
                // Already in the requested state — just re-confirm it,
                // covering a receiver that missed an earlier push (e.g. it
                // connected mid-flight).
                sendAllowInputState()
            } else {
                Task { @MainActor in self.onAllowInputRequest?(requested) }
            }
        case WireMessage.videoRequest:
            guard let info = lastHello,
                  info.protocolVersion >= WireProtocol.videoControlWireVersion,
                  let requested = obj["enabled"] as? Bool else { return }
            if requested == desiredVideoEnabled {
                applyVideoEnabled(requested)
            } else {
                Task { @MainActor in self.onVideoEnabledRequest?(requested) }
            }
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
                  let gesture = ReceiverGesture(rawValue: name) else { return }
            let inputAllowed = InputPolicy.allowsInput()
            guard ReceiverGesture.shouldRoute(name: name, inputAllowed: inputAllowed),
                  receiverInputIsAllowed() else { return }
            // The receiver normally sent a touch cancellation immediately
            // before this semantic message. Release again here as a safeguard
            // against an in-flight or missing cancellation.
            inputInjector?.cancelActiveInput()
            Task { @MainActor in
                guard InputPolicy.allowsInput() else { return }
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
            Task { @MainActor in self.onPeerSleeping?() }
        case WireMessage.closing:
            // The app on the device is quitting for real — end the session
            // without the silence grace and without waiting for a wake.
            Log.info("receiver app closed — ending session")
            Task { @MainActor in self.onPeerClosed?() }
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

    private func waitForHello() async throws -> PhoneInfo {
        if let lastHello { return lastHello }
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                if let hello = self.lastHello {
                    continuation.resume(returning: hello)
                } else {
                    self.helloContinuation = continuation
                }
            }
        }
    }

    // MARK: - Encoder setup

    /// Create the compression session into `encoder`, optionally requiring an
    /// encoder that supports low-latency rate control.
    private func createCompressionSession(width: Int, height: Int, lowLatency: Bool) -> OSStatus {
        let spec: CFDictionary? = lowLatency
            ? [kVTVideoEncoderSpecification_EnableLowLatencyRateControl: kCFBooleanTrue] as CFDictionary
            : nil
        return VTCompressionSessionCreate(
            allocator: nil,
            width: Int32(width), height: Int32(height),
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: spec,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &encoder
        )
    }

    private func setupEncoder(width: Int, height: Int) throws {
        // Low-latency rate control: the hardware encoder emits every frame
        // immediately instead of pipelining. (`-lowlatency NO` for A/B.)
        let lowLatency = UserDefaults.standard.object(forKey: "lowlatency") == nil
            || UserDefaults.standard.bool(forKey: "lowlatency")
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
        var status = createCompressionSession(width: width, height: height, lowLatency: lowLatency)
        var usedFallback = false
        if encoder == nil, lowLatency {
            Log.info("VTCompressionSessionCreate failed with low-latency rate control (status \(status)) — retrying without an encoder specification")
            status = createCompressionSession(width: width, height: height, lowLatency: false)
            usedFallback = true
        }
        guard let encoder else {
            // Returning here used to leave the session "connected, all green"
            // with a dead encoder and a black receiver. Throw so the failure
            // reaches the UI as a red "Failed:" status.
            Log.info("FATAL: VTCompressionSessionCreate failed (status \(status))")
            throw NSError(domain: "MacSender", code: 4, userInfo: [
                NSLocalizedDescriptionKey:
                    "This Mac's video encoder could not be started (VideoToolbox error \(status))"
            ])
        }
        // Low-latency settings: real-time, no B-frames, periodic keyframes.
        VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_High_AutoLevel)
        // No periodic IDRs: each one is a bitrate spike → transmit-time hiccup.
        // TCP never loses data, and we force a keyframe on reconnect/drop.
        VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: 3600 as CFNumber)
        VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: 60 as CFNumber)
        VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_MaxFrameDelayCount, value: 0 as CFNumber)
        VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_AverageBitRate, value: quality.bitrate as CFNumber)
        VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: 60 as CFNumber)
        VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, value: kCFBooleanTrue)
        VTCompressionSessionPrepareToEncodeFrames(encoder)
        Log.info("encoder ready: \(width)x\(height) H.264 \(quality.bitrate / 1_000_000)Mbps quality=\(quality.rawValue) lowLatencyRC=\(lowLatency && !usedFallback)\(usedFallback ? " (fallback)" : "")")
    }

    // MARK: - Capture callback

    func stream(_ stream: SCStream,
                didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard stream === self.stream, CMSampleBufferIsValid(sampleBuffer) else { return }

        switch type {
        case .screen:
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            let generation = captureGenerationNow

            lastPixelBuffer = pixelBuffer
            lastCaptureAt = Date()
            capFrames += 1

            // No receiver, video off, or a pipeline stage is backed up: skip
            // this frame. Video off never tears down an audio-only stream
            // (see startCapture), so this guard — not stream teardown — is
            // what makes "no encoding, no network video packets" true then.
            guard connectionReady, videoEnabled else { return }
            if shouldDropFrame(reason: "pending_encode") { return }  // encoder busy
            if shouldDropFrame(reason: "pending_sends") { return }   // TCP send queue full

            encode(pixelBuffer, pts: CMSampleBufferGetPresentationTimeStamp(sampleBuffer), generation: generation)

        case .audio:
            guard connectionReady, audioEnabled else { return }
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
        pipelineLock.lock()
        defer { pipelineLock.unlock() }
        return pendingEncodes >= maxPendingEncodes || pendingSends >= maxPendingSends
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
        guard !stopped, connectionReady, let pixelBuffer = lastPixelBuffer else { return }
        if isPipelineBackedUp() {
            scheduleDropReplayTimer()
            return
        }
        encode(pixelBuffer, pts: CMClockGetTime(CMClockGetHostTimeClock()),
               generation: captureGenerationNow)
    }

    /// Drop when encode or send pipeline is busy.
    /// Pre-encode drops are invisible to the decoder — the H.264 reference
    /// chain stays intact, so the next frame can be a normal P-frame (n → n+2).
    /// Do NOT force keyframes here; that causes IDR pulsing / blockiness.
    private func shouldDropFrame(reason: String) -> Bool {
        pipelineLock.lock()
        let drop: Bool
        switch reason {
        case "pending_encode":
            drop = pendingEncodes >= maxPendingEncodes
        case "pending_sends":
            drop = pendingSends >= maxPendingSends
        default:
            drop = false
        }
        pipelineLock.unlock()
        guard drop else { return false }
        scheduleDropReplayTimer()
        switch reason {
        case "pending_encode":
            dropsEncThisWindow += 1
            dropsEncTotal += 1
        case "pending_sends":
            dropsNetThisWindow += 1
            dropsNetTotal += 1
        default:
            break
        }
        return true
    }

    private func encode(_ pixelBuffer: CVPixelBuffer, pts: CMTime, generation: UInt64) {
        guard generation == captureGenerationNow, let encoder else { return }
        pipelineLock.lock()
        pendingEncodes += 1
        pipelineLock.unlock()
        let capturedAtMs = Int64(Date().timeIntervalSince1970 * 1000)
        var frameProperties: CFDictionary?
        if needsKeyframe {
            frameProperties = [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue!] as CFDictionary
            needsKeyframe = false
        }
        let submitStatus = VTCompressionSessionEncodeFrame(
            encoder,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: pts,
            duration: .invalid,
            frameProperties: frameProperties,
            infoFlagsOut: nil
        ) { [weak self] status, _, buffer in
            guard let self else { return }
            defer {
                self.pipelineLock.lock()
                self.pendingEncodes = max(0, self.pendingEncodes - 1)
                self.pipelineLock.unlock()
            }
            guard status == noErr, let buffer else {
                // A session rejecting every frame looks healthy in all other
                // counters — the receiver just stays black. Don't be silent.
                self.pipelineLock.lock()
                let logAction = self.encodeOutputFailureLogPolicy.record(
                    status,
                    at: ProcessInfo.processInfo.systemUptime
                )
                self.pipelineLock.unlock()
                self.handleEncodeOutputFailureLogAction(logAction)
                return
            }
            guard generation == self.captureGenerationNow else { return }
            if let data = self.annexB(from: buffer) {
                let sndMs = Int64(Date().timeIntervalSince1970 * 1000)
                var framed = Data("{\"cap\":\(capturedAtMs),\"snd\":\(sndMs)}".utf8)
                framed.append(data)
                self.sendFramed(framed)
            }
        }
        if submitStatus == noErr {
            // Encode submission commits this frame to the pipeline; stale in-flight
            // encodes started before a drop won't reach here again, so cancel replay.
            cancelDropReplayTimer()
        } else {
            pipelineLock.lock()
            pendingEncodes = max(0, pendingEncodes - 1)
            // A dead encoder session keeps failing, and this runs per frame, so
            // an unthrottled line here is ~60/sec for as long as the problem
            // lasts. Report at most once a second and carry the count: the
            // status code is the diagnosis, the rate is just a number.
            let logAction = encodeFailureLogPolicy.record(
                submitStatus,
                at: ProcessInfo.processInfo.systemUptime
            )
            pipelineLock.unlock()
            handleEncodeFailureLogAction(logAction)
        }
    }

    private func handleEncodeFailureLogAction(_ action: ThrottledLogPolicy<OSStatus>.Action) {
        switch action {
        case .report(let report):
            reportEncodeFailures(report)
        case .schedule(let delay):
            queue.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.flushEncodeFailureLog()
            }
        case .none:
            break
        }
    }

    private func flushEncodeFailureLog() {
        pipelineLock.lock()
        let report = encodeFailureLogPolicy.flush(at: ProcessInfo.processInfo.systemUptime)
        pipelineLock.unlock()
        if let report { reportEncodeFailures(report) }
    }

    private func reportEncodeFailures(_ report: ThrottledLogPolicy<OSStatus>.Report) {
        Log.info("VTCompressionSessionEncodeFrame failed: \(report.detail) (\(report.count) since last report)")
    }

    private func handleEncodeOutputFailureLogAction(_ action: ThrottledLogPolicy<OSStatus>.Action) {
        switch action {
        case .report(let report):
            reportEncodeOutputFailures(report)
        case .schedule(let delay):
            queue.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.flushEncodeOutputFailureLog()
            }
        case .none:
            break
        }
    }

    private func flushEncodeOutputFailureLog() {
        pipelineLock.lock()
        let report = encodeOutputFailureLogPolicy.flush(at: ProcessInfo.processInfo.systemUptime)
        pipelineLock.unlock()
        if let report { reportEncodeOutputFailures(report) }
    }

    private func reportEncodeOutputFailures(_ report: ThrottledLogPolicy<OSStatus>.Report) {
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
            queue.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.flushUnparseableControlLog()
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

    private func annexB(from sample: CMSampleBuffer) -> Data? {
        guard let block = CMSampleBufferGetDataBuffer(sample) else { return nil }
        var len = 0, total = 0
        var ptr: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0,
                lengthAtOffsetOut: &len, totalLengthOut: &total,
                dataPointerOut: &ptr) == noErr, let ptr else { return nil }

        var out = Data(capacity: total + 128)
        // On keyframes, prepend SPS/PPS (they live in the format description).
        if isKeyframe(sample), let fmt = CMSampleBufferGetFormatDescription(sample) {
            for i in 0..<2 {           // index 0 = SPS, 1 = PPS
                var psPtr: UnsafePointer<UInt8>?
                var psLen = 0
                if CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                        fmt, parameterSetIndex: i,
                        parameterSetPointerOut: &psPtr,
                        parameterSetSizeOut: &psLen,
                        parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr,
                   let psPtr {
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

    private func isKeyframe(_ sample: CMSampleBuffer) -> Bool {
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

    /// Ask the receiver to update (built via JSONSerialization because the
    /// message text is user-facing prose). Dormant while minSupportedPeer is
    /// 1, but the copy must fit the platform the day a floor is raised: a
    /// Mac receiver updates via Sparkle/the site, not the App Store.
    private func sendUpdateRequired(kind: String) {
        let isMac = kind == "Mac"
        let dict: [String: Any] = [
            "type": WireMessage.updateRequired,
            "target": isMac ? "mac" : "ios",
            "store": isMac ? "https://opendisplay.app" : AppStore.updateURL.absoluteString,
            "message": isMac
                ? "The OpenDisplay Receiver app on that Mac is too old for this Mac. Use Check for Updates… there to reconnect."
                : "This \(kind) app is too old for this Mac. Update OpenDisplay from the App Store to reconnect.",
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

    private func sendJSONFrame(_ json: String) {
        guard let connection, connectionReady else { return }
        let payload = Data(json.utf8)
        var header = UInt32(payload.count).bigEndian
        var frame = Data(bytes: &header, count: 4)
        frame.append(payload)
        connection.send(content: frame, completion: .contentProcessed { _ in })
    }

    /// `kind` is DEBUG-only telemetry (never sent on the wire): identifies
    /// which media this write carried, so a slow completion can be
    /// attributed to "audio queued behind a video write already in
    /// flight" (TCP head-of-line blocking — PROTOCOL.md 5A implementer
    /// note) rather than guessed at. Video/audio share this single framed
    /// TCP/TLS stream by design (no separate UDP/second connection); this
    /// only measures that choice, it doesn't change it.
    private func sendFramed(_ payload: Data, kind: String = "video") {
        guard let connection, connectionReady else { return }
        var header = UInt32(payload.count).bigEndian
        var frame = Data(bytes: &header, count: 4)
        frame.append(payload)
        pendingSends += 1
        #if DEBUG
        let queuedAt = Date()
        let queuedByteCount = frame.count
        #endif
        connection.send(content: frame, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            self.pendingSends = TransportSafety.decrementedPendingCount(self.pendingSends)
            self.lastSendCompletionAt = Date()
            self.sendStallReported = false
            if let error {
                Log.info("send error: \(error)")
                return
            }
            self.framesSent += 1
            self.bytesSent += frame.count
            #if DEBUG
            if kind == "audio" {
                let writeMs = Date().timeIntervalSince(queuedAt) * 1000
                // A normal LAN write completes in low single-digit ms; a
                // multi-KB video keyframe already in flight ahead of this
                // small audio packet is the primary suspect for anything
                // much slower — this is evidence-gathering, not a fix.
                if writeMs > 15 {
                    Log.info("audioTrace: TCP write latency \(String(format: "%.1f", writeMs))ms bytes=\(queuedByteCount) pendingSends=\(self.pendingSends) lastVideoBytes=\(self.lastVideoFrameByteCount)")
                }
            } else {
                self.lastVideoFrameByteCount = queuedByteCount
            }
            #endif
            // Report stats roughly once a second.
            let elapsed = Date().timeIntervalSince(self.statsWindowStart)
            if elapsed >= 1.0 {
                let mbps = Double(self.bytesSent) * 8 / elapsed / 1_000_000
                let frames = self.framesSent
                self.bytesSent = 0
                self.statsWindowStart = Date()
                Task { @MainActor in self.onStats?(frames, mbps) }
            }
        })
    }

    // MARK: - Helpers

    private func status(_ text: String) async {
        await MainActor.run { onStatus?(text) }
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
        pipelineLock.lock()
        captureGeneration &+= 1
        pipelineLock.unlock()
        if discardingLastFrame {
            lastPixelBuffer = nil
            lastCaptureAt = .distantPast
        }
    }
}
