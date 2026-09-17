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
    var cursorLost = 0           // UDP cursor datagrams missing or reordered (this window)
    var macDrops = 0             // enc + net drops (legacy total)
    var macEncDrops = 0          // Mac skipped capture: encoder busy
    var macNetDrops = 0          // Mac skipped capture: TCP queue full
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

final class StreamReceiver: ObservableObject {

    @Published var status = "Starting…"
    @Published var fps = 0
    @Published var connected = false
    @Published var videoSize = CGSize.zero   // for touch coordinate mapping
    @Published private(set) var displayState = DisplayState.running
    @Published private(set) var videoEnabled = true
    /// Queue-confined copy used to distinguish an idempotent state push from
    /// an actual off/on transition that must retire decoder state.
    private var receivedVideoEnabled = true
    @Published var perf = PerfStats()
    // Compatibility signal from the connected Mac (issue #132). Nil = no signal.
    // Merged into the update gate by ReceiverScreen.
    @Published var peerSignal: PeerUpdateSignal?
    /// Mac protocol version from the most recent `welcome` message.
    @Published private(set) var macProtocolVersion = WireProtocol.assumedWhenAbsent
    @Published private(set) var inputResetGeneration = 0
    @Published private(set) var controlResetGeneration = 0
    @Published private(set) var confirmedDisplayMode: ReceiverDisplayMode?
    @Published private(set) var pendingDisplayMode: ReceiverDisplayMode?
    @Published private(set) var displayModeConfirmationGeneration = 0
    private var displayModeRequestState = DisplayModeRequestState()
    /// The connected Mac's canonical Mirror capture-source report — see
    /// `MirrorDisplayStateUpdate`. `nil` until a Mac speaking
    /// `mirrorDisplayWireVersion` has actually reported one (distinct from
    /// `selectedUUID == nil`, which means Auto).
    @Published private(set) var mirrorDisplayState: MirrorDisplayStateUpdate?

    /// The single authoritative session state the UI derives from. Mutated
    /// only on `queue` via `sessionState`; this is its main-thread mirror.
    @Published private(set) var session = ReceiverSessionState()
    /// Queue-confined authority. Every transition goes through
    /// `mutateSession` so there is exactly one logging and publishing path.
    private var sessionState = ReceiverSessionState()

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
    @Published private(set) var lastForgottenPeerID: String?

    /// Coarse, interruption-aware connection headline — "Connected", an
    /// interruption title ("Reconnecting…", "Display Paused", …), or
    /// "Waiting for a Mac…". Every receiver surface (iOS and Mac Receiver)
    /// that needs a phase-level label reads this instead of independently
    /// re-deriving it from `connected` alone, which used to miss states
    /// like reconnecting/paused.
    var canonicalPhaseTitle: String {
        session.interruption?.title ?? (session.phase == .connected ? "Connected" : "Waiting for a Mac…")
    }
    /// The one timer driving automatic recovery — never a second one.
    private var reconnectTimer: DispatchSourceTimer?
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
            UserDefaults.standard.set(autoReconnectEnabled, forKey: "autoReconnectEnabled")
            Log.info("reconnectPolicy: autoReconnect enabled=\(autoReconnectEnabled)")
            if autoReconnectEnabled {
                Log.info("reconnectPolicy: reenabled reevaluatingAvailability")
            } else {
                queue.async { [weak self] in self?.cancelAutomaticRecoveryIfNeeded() }
            }
        }
    }
    /// Set when the peer told us the two apps are version-incompatible. The
    /// live session is left alone; the flag only reclassifies the eventual
    /// loss so recovery never loops against a peer that cannot work with us.
    private var peerIsIncompatible = false

    /// UI-layer seam keeps this shared receiver free of UIKit/SwiftUI.
    var onReceiverUIPreferences: ((ReceiverUIPreferenceUpdate) -> Void)?
    private var announcedTrayEnabled = true
    private var announcedKeyboardButtonEnabled = true
    // The rest of the receiver-controls report — see `announceReceiverPreferences`/
    // `sendHello`. Same "resend on every hello, receiver stays authoritative"
    // pattern as tray/keyboard above, just for the fields a connected Mac's
    // per-device Settings detail also wants live visibility into.
    private var announcedFunctionTrayEnabled = true
    private var announcedInputMode = PointerInputMode.direct
    private var announcedTrackpadSensitivity = PointerGestureConfig.defaultTrackpadSensitivity
    private var announcedHapticsEnabled = true
    private var announcedAvoidNotch = true
    private var announcedPinchTarget = ReceiverGestureTarget.viewport
    private var announcedRotateTarget = ReceiverGestureTarget.viewport
    private var announcedSnapRotation = true
    private var announcedAppGestureCommands = AppGestureCommands.defaults

    /// The connected Mac's confirmed Allow Input state — pushed on connect
    /// and whenever it changes on the Mac (its own toggle, or an honored
    /// request from any receiver). The Mac remains the single authority;
    /// see `requestAllowInput`.
    var onAllowInputStateChange: ((Bool) -> Void)?

    /// True when the connected Mac understands pencil/proximity wire messages.
    var macSupportsPencilWire: Bool { macProtocolVersion >= WireProtocol.pencilWireVersion }

    var macSupportsVideoControl: Bool {
        macProtocolVersion >= WireProtocol.videoControlWireVersion
    }

    /// True when the connected Mac understands the `keyboard` message family (M4).
    var macSupportsKeyboardWire: Bool { macProtocolVersion >= WireProtocol.keyboardWireVersion }

    /// True when the connected Mac understands the `pointer` message family (M7).
    var macSupportsPointerWire: Bool { macProtocolVersion >= WireProtocol.pointerWireVersion }

    /// True when the connected Mac understands Mac system audio (`pv` 12).
    /// No legacy fallback, same as keyboard: below this, Audio simply stays
    /// unavailable rather than degrading to something else.
    var macSupportsAudio: Bool { macProtocolVersion >= WireProtocol.audioWireVersion }

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
    @Published var audioEnabled = false
    /// What this receiver last asked for — resent on every `welcome` so it
    /// survives reconnection and transport migration without the user
    /// re-enabling it (SESSION BEHAVIOR).
    private var audioPreferred = false
    private var audioRenderer: AVSampleBufferAudioRenderer?
    private var audioSynchronizer: AVSampleBufferRenderSynchronizer?
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
    /// only) each touch exactly what they claim to.
    private var avSyncOffsetMs = 0

    /// A stable capture-timeline -> host-time mapping, established ONCE per
    /// generation (first audio packet after a reset) or on `resync()`, and
    /// otherwise left alone. FORENSIC NOTE: an earlier version of this
    /// receiver recomputed this mapping from EVERY displayed video frame's
    /// own arrival time, which is itself jittery (that jitter is exactly
    /// why the video path displays immediately instead of scheduling on a
    /// timebase) — feeding it straight into audio's schedule made audio
    /// inherit video's arrival jitter, producing the stutter this fix
    /// addresses. A one-shot anchor plus audio's own evenly-spaced capture
    /// deltas (real AAC frames are ~21.333 ms apart at 48 kHz) schedules
    /// smoothly regardless of how jittery video's arrival is.
    private struct MediaAnchor {
        var captureMs: Double
        var hostTime: CFTimeInterval
    }
    private var audioAnchor: MediaAnchor?
    /// Small bounded preroll folded into a fresh anchor's lead time —
    /// ~3 AAC packets. Enough to absorb ordinary scheduling jitter without
    /// the renderer starving; nowhere near enough to feel like added
    /// interactive latency.
    private let audioPrerollSeconds = 0.064
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
    /// Bumped by `resetStreamState` (new connection) and `resync()`.
    /// Captured by each negative-offset delayed video presentation
    /// closure so stale work from a superseded generation can never
    /// touch a newer session's decoder/display layer — see `enqueueFrame`.
    private var videoGeneration: UInt64 = 0
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
    private var lastAudioTarget: CFTimeInterval?
    private var audioErrorObservation: NSKeyValueObservation?
    /// Last applied config (AAC sample rate/channels, or PCM sample
    /// rate/channels) — logged only when a fresh config frame changes it
    /// mid-session, which should never happen within one generation.
    private var lastAppliedAudioConfigDescription: String?
    #endif

    /// The shared AAC→PCM decoder — used both by `PCMPlaybackEngine`
    /// production playback (`scheduleAudioPacket`, when
    /// `activePlaybackPath == .pcmEngine`) and by the DEBUG-only
    /// `analyzeReceivedAACDecode`/`Audio Comparison Dump` diagnostics.
    /// Deliberately NOT `#if DEBUG` — this became core production
    /// playback infrastructure once PCM Engine became the default, and
    /// there must be exactly ONE AAC→PCM conversion chain, not a
    /// production one and an independently-maintained diagnostic one that
    /// could silently drift apart.
    private var receiverAACDecoder: AVAudioConverter?
    private var receiverAACDecoderFormatDescription: CMAudioFormatDescription?
    private var receiverDecodeAnomalyCount = 0

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
    /// Separate from `receiverAACLocalDecodeEnabled`: lets a physical
    /// device run the (cheap) decode+anomaly-log path without also paying
    /// for the ~5s CAF file write, or vice versa isn't meaningful — the
    /// dump needs a successful decode — but keeping them independent
    /// toggles matches what `SettingsView` exposes.
    private var receiverAACDumpEnabled: Bool {
        UserDefaults.standard.bool(forKey: "audioReceiverDumpEnabled")
    }
    /// Gates the periodic `AAC integrity side=receiver ...` checksum log
    /// (GOAL: was unconditional before this toggle existed — now default
    /// OFF, so it must be explicitly enabled for the sender/receiver
    /// checksum comparison to appear in the next retest's logs).
    private var aacIntegrityLoggingEnabled: Bool {
        UserDefaults.standard.bool(forKey: "audioAACIntegrityLogging")
    }
    private var lastReceiverDecodedSample: Float?
    private var receiverDecodeDumpFile: AVAudioFile?
    private var receiverDecodeDumpFrames = 0
    private static let receiverDecodeDumpFrameLimit = 48_000 * 5   // ~5s at 48kHz
    /// Total successful `audioRenderer.enqueue` calls this generation —
    /// `enqueue` itself returns no status, so this is only useful compared
    /// against the periodic `PCM sanity`/`AAC integrity` packet counts to
    /// spot silent enqueue-path attrition (e.g. every packet reaching
    /// `scheduleDecodedAudio` but a growing fraction failing
    /// `CMSampleBufferCreateReady` upstream of it).
    private var audioEnqueueCount = 0
    #endif

    private var listener: NWListener?
    private var tlsListener: NWListener?
    private var pairingListener: NWListener?
    // Receiver-originated Connect (see connectDebug): a short-lived token
    // published in the `_opensidecar._tcp` TXT record. The Mac already
    // browses that service continuously (it's how "Paired · Nearby" is
    // known), so this rides the existing discovery channel instead of
    // opening a new one. It carries no authority of its own — the Mac only
    // acts on it for an already-trusted/pinned peer, and the resulting
    // connection still runs the full pinned-TLS + hello handshake.
    private var connectRequestToken: String?
    private var connectRequestClearWorkItem: DispatchWorkItem?
    let pairingPrompt = PairingPromptModel()
    private var pairingObservation: AnyCancellable?
    private var mediaSuppressedForPairing = false
    @Published private(set) var discoveredMacs: [NWBrowser.Result] = []
    private var macPairingBrowser: NWBrowser?
    private var listenerHealthy = false
    private var listenerRestartState = StreamListenerRestartState()
    private var connection: NWConnection?
    // Cursor side channel: UDP on port+1. Cursor positions ride TCP behind
    // multi-hundred-KB video frames, so over WiFi one late frame stalls the
    // cursor with it (head-of-line blocking). UDP datagrams skip that queue.
    // Optional end to end: advertised in hello only once the listener is
    // ready, and the sender keeps using TCP when it is absent.
    private var cursorListener: NWListener?
    private var cursorListenerReady = false
    private var cursorConnection: NWConnection?
    private var cursorPortAnnounced = false
    // Newcomer connections still proving themselves against a live session
    // (see the listener). Tracked so stop() and adoption can cancel them —
    // an untracked silent socket would sit parked forever and could even
    // adopt into a receiver that was stopped in the meantime.
    private var pendingConnections: [NWConnection] = []
    // What the last hello advertised, to notice a cable appearing
    // mid-session: plugging one creates new interfaces, and a sender can
    // only probe addresses it has been told about.
    private var lastAdvertisedAddrs: [String] = []
    private var addrWatchTimer: DispatchSourceTimer?
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
    private var cursorPort: UInt16 { port &+ 1 }
    private let queue = DispatchQueue(label: "receiver.video")
    private var buffer = Data()
    private var formatDesc: CMVideoFormatDescription?
    private var sps: Data?
    private var pps: Data?

    // Liveness: the Mac streams video and pings every 2s; if nothing arrives
    // for 5s the connection is half-open (Mac killed, tunnel died) — drop it
    // so the listener can accept a fresh one.
    private var lastDataReceived = Date()
    private var port: UInt16 = 9000
    // Liveness monitors: cancel-and-replace timers (not self-rescheduling
    // asyncAfter chains) so stop() can actually silence them — see #75.
    private var pingTimer: DispatchSourceTimer?
    private var watchdogTimer: DispatchSourceTimer?

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
    private var clockOffsetMs: Double?
    private var lastRttMs = 0.0
    private var e2eWindow: [Double] = []        // capture→display, ms
    private var encodeWindow: [Double] = []     // capture→socket on the Mac, ms
    private var e2eRing: [Double] = []          // per-frame, for the overlay graph
    private var statsReportCounter = 0
    private var transport = "—"
    private var macDrops = 0
    private var macEncDrops = 0
    private var macNetDrops = 0
    private var macPending = 0
    private var macInputP50 = 0.0
    private var macInputP95 = 0.0
    private var macCapFps = 0

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
    private(set) var cursorState: (x: Double, y: Double, visible: Bool) = (0.5, 0.5, false)
    private(set) var cursorSprite: (image: CGImage, anchor: CGPoint, normSize: CGSize)?

    // Metal renderer path (experimental, "metalRenderer" setting): we decode
    // explicitly and hand BGRA buffers out; called on the receiver queue.
    var onDecodedFrame: ((_ pixelBuffer: CVPixelBuffer, _ captureMs: Double?) -> Void)?
    private var decompressionSession: VTDecompressionSession?
    private var decodeWindow: [Double] = []
    private var photonWindow: [Double] = []
    private var loggedDisplayPath = false
    private var decodeErrorCount = 0
    // Default OFF: A/B measurement showed the system video layer reaches
    // glass faster than our CAMetalLayer path (iOS gives AVSBDL a dedicated
    // compositor plane). Kept as an experimental toggle + for its metrics.
    private var useMetalPath: Bool { UserDefaults.standard.bool(forKey: "metalRenderer") }

    /// Called by the renderer's presented handler: maps the CACurrentMediaTime-
    /// based glass timestamp into wall-clock ms and computes true photon e2e.
    func recordPresented(presentedTime: CFTimeInterval, captureMs: Double?) {
        guard let captureMs, presentedTime > 0 else { return }
        let presentedWallMs = nowMs - (CACurrentMediaTime() - presentedTime) * 1000
        queue.async {
            guard let offset = self.clockOffsetMs else { return }
            let photon = (presentedWallMs + offset) - captureMs
            if photon > -50, photon < 5000 {
                self.photonWindow.append(max(photon, 0))
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
    private(set) var devicePixelsWide = 0
    private(set) var devicePixelsHigh = 0
    var deviceScale: Double = 2
    // Name advertised over Bonjour for the Mac's WiFi picker. iOS 16+ returns
    // a generic "iPhone" from UIDevice.current.name (the user-assigned name
    // needs an entitlement Apple gates behind approval and personal teams
    // can't get), so this is user-editable in Settings. The USB picker gets
    // the real name host-side via lockdownd regardless.
    var serviceName = "MeowDisplay"

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
        var txt = NWTXTRecord()
        txt["id"] = Self.installID
        txt["pv"] = String(WireProtocol.version)   // issue #132
        if let connectRequestToken { txt["cr"] = connectRequestToken }
        return NWListener.Service(name: serviceName, type: "_opensidecar._tcp",
                                  domain: nil, txtRecord: txt)
    }

    private var advertisedPairingService: NWListener.Service {
        var txt = NWTXTRecord()
        txt["id"] = Self.installID
        txt["pv"] = String(WireProtocol.version)
        return NWListener.Service(name: serviceName, type: "_opendisplay-pair._tcp",
                                  domain: nil, txtRecord: txt)
    }

    /// Update the advertised name and re-publish if already listening.
    func setServiceName(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved = trimmed.isEmpty ? fallbackServiceName : trimmed
        queue.async {
            guard resolved != self.serviceName else { return }
            self.serviceName = resolved
            if self.listener != nil {
                self.tlsListener?.service = self.advertisedService
                self.pairingListener?.service = self.advertisedPairingService
                Log.info("re-advertising as \"\(resolved)\"")
            }
        }
    }

    func setNativePanel(long: Int, short: Int, scale: Double) {
        nativeLong = long
        nativeShort = short
        deviceScale = scale
        if devicePixelsWide == 0 {   // default landscape until the view reports
            devicePixelsWide = long
            devicePixelsHigh = short
        }
    }

    func setOrientation(portrait: Bool) {
        guard nativeLong > 0 else { return }
        setPanel(pixelsWide: portrait ? nativeShort : nativeLong,
                 pixelsHigh: portrait ? nativeLong : nativeShort,
                 scale: deviceScale)
    }

    func setReceiverUIPreferencesForHello(trayEnabled: Bool, keyboardButtonEnabled: Bool) {
        queue.async {
            self.announcedTrayEnabled = trayEnabled
            self.announcedKeyboardButtonEnabled = keyboardButtonEnabled
            if let connection = self.connection, connection.state == .ready {
                self.sendHello(on: connection)
            }
        }
    }

    /// Same "update the announced value(s), resend hello now if connected"
    /// contract as `setReceiverUIPreferencesForHello`, generalized to the
    /// rest of `ReceiverControlPreferences` a connected Mac's per-device
    /// Settings detail reports — called alongside it on every local
    /// preference change so Mac visibility never lags what's actually set.
    func announceReceiverPreferences(_ preferences: ReceiverControlPreferences) {
        queue.async {
            self.announcedFunctionTrayEnabled = preferences.functionTrayEnabled
            self.announcedInputMode = preferences.inputMode
            self.announcedTrackpadSensitivity = preferences.trackpadSensitivity
            self.announcedHapticsEnabled = preferences.hapticsEnabled
            self.announcedAvoidNotch = preferences.avoidNotch
            self.announcedPinchTarget = preferences.pinchTarget
            self.announcedRotateTarget = preferences.rotateTarget
            self.announcedSnapRotation = preferences.snapRotation
            self.announcedAppGestureCommands = preferences.appGestureCommands
            self.avSyncOffsetMs = AVSyncOffset.clamped(preferences.avSyncOffsetMs)
            if let connection = self.connection, connection.state == .ready {
                self.sendHello(on: connection)
            }
        }
    }

    /// Announce the panel this receiver renders onto. Called before start()
    /// and again whenever it changes (iOS rotation via setOrientation, macOS
    /// display-mode changes) — a live connection re-sends hello so the sender
    /// rebuilds the virtual display for the new dimensions.
    func setPanel(pixelsWide w: Int, pixelsHigh h: Int, scale: Double) {
        deviceScale = scale
        guard w > 0, h > 0, w != devicePixelsWide || h != devicePixelsHigh else { return }
        devicePixelsWide = w
        devicePixelsHigh = h
        Log.info("panel changed -> \(w)x\(h) @\(scale)x")
        if let connection { sendHello(on: connection) }
    }

    init(displayLayer: AVSampleBufferDisplayLayer, deviceKind: String,
         fallbackServiceName: String,
         maxEncodeWide: Int? = nil, maxEncodeHigh: Int? = nil, maxFPS: Int? = nil) {
        self.displayLayer = displayLayer
        self.deviceKind = deviceKind
        self.fallbackServiceName = fallbackServiceName
        self.maxEncodeWide = maxEncodeWide
        self.maxEncodeHigh = maxEncodeHigh
        self.maxFPS = maxFPS
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.pairingObservation = self.pairingPrompt.objectWillChange.sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            self.pairingPrompt.onPending = { [weak self] pending in
                Log.info("pairDebug: onPending peerID=\(pending.peerID)")
                self?.beginExplicitPairing(peerID: pending.peerID)
            }
        }
        displayLayer.videoGravity = .resizeAspect
    }

    func start(port: UInt16 = 9000) {
        self.port = port
        queue.async {
            self.startListener()
            TrustStore.shared.refreshSnapshot()
            self.startTLSListener()
            self.startPairingListener()
            self.startMacPairingBrowser()
            self.armLivenessTimers()
        }
    }

    /// Leave receiver duty for good: announce "closing" to a live sender (so
    /// it ends the session instead of waiting for a wake), drop the
    /// connection and the listener, and silence the liveness timers. The Mac
    /// app calls this when the user leaves receiver mode or quits; the
    /// instance is discarded afterwards (start() re-arms if it isn't).
    func stop(completion: (() -> Void)? = nil) {
        queue.async {
            self.pingTimer?.cancel(); self.pingTimer = nil
            self.watchdogTimer?.cancel(); self.watchdogTimer = nil
            self.addrWatchTimer?.cancel(); self.addrWatchTimer = nil
            self.pendingConnections.forEach { $0.cancel() }
            self.pendingConnections.removeAll()
            self.macPairingBrowser?.cancel(); self.macPairingBrowser = nil
        }
        closeSession(announcing: WireMessage.closing, status: "Stopped",
                     completion: completion)
    }

    func forgetPeer(_ peerID: String) {
        TrustStore.shared.forget(peerID: peerID)
        DispatchQueue.main.async { self.lastForgottenPeerID = peerID }
        queue.async {
            // A live TLS session may have authenticated before the pin was
            // removed. End it immediately so forgetting takes effect now.
            self.connection?.cancel()
            self.connection = nil
            self.setConnected(false, reason: .explicitDisconnect)
        }
    }

    func pairWithMac(_ result: NWBrowser.Result) {
        let expectedPeerID: String? = if case .bonjour(let txt) = result.metadata {
            txt["id"]
        } else {
            nil
        }
        beginExplicitPairing(peerID: expectedPeerID)
        let connection = NWConnection(to: result.endpoint, using: .tcp)
        Task {
            defer { connection.cancel() }
            do {
                let paired = try await PairingNetwork.runInitiator(
                    connection: connection, localID: Self.installID,
                    localName: serviceName, prompt: pairingPrompt,
                    expectedPeerID: expectedPeerID)
                await pairingPrompt.finish("Paired with \(paired.peerName)")
                finishExplicitPairing(success: true)
            } catch {
                await pairingPrompt.finish(error.localizedDescription)
                let promptStillPending = await MainActor.run { pairingPrompt.pending != nil }
                if !promptStillPending {
                    finishExplicitPairing(success: false)
                } else {
                    Log.info("pairDebug: duplicate initiator ended without disturbing pending confirmation")
                }
            }
        }
    }

    private func beginExplicitPairing(peerID: String?) {
        Log.info("pairDebug: explicit pairing started peerID=\(peerID ?? "unknown")")
        queue.async {
            self.mediaSuppressedForPairing = true
            self.connection?.cancel()
            self.connection = nil
            self.setConnected(false, reason: .explicitDisconnect)
        }
    }

    private func finishExplicitPairing(success: Bool) {
        queue.async {
            self.mediaSuppressedForPairing = false
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
        queue.async {
            self.ensureTLSListening()
            guard !self.listenerHealthy else { return }
            guard !self.listenerRestartState.shouldDeferEnsureListening else {
                Log.info("listener start/restart already in flight — letting it finish")
                return
            }
            Log.info("listener not healthy — restarting")
            self.restartListener()
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
        guard tlsListener == nil else { return }
        Log.info("reconnectDebug: retryScheduled TLS listener rearm")
        startTLSListener()
    }

    /// iOS lifecycle seam. Backgrounding parks an in-flight recovery run
    /// (nothing can be dialed at us while suspended, and burning the budget
    /// there would land us in Connection Lost for no reason); foregrounding
    /// resumes it from where it stopped.
    func setAppActive(_ active: Bool) {
        queue.async {
            if active {
                self.resumeReconnectIfNeeded()
            } else {
                self.suspendReconnectForBackground()
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
    func setRenderingPaused(_ paused: Bool) {
        queue.async {
            guard paused != self.renderingPaused else { return }
            self.renderingPaused = paused
            Log.info(paused ? "rendering paused (backgrounded)" : "rendering resumed")
            if !paused {
                self.displayLayer.flush()
                if self.connection?.state == .ready {
                    self.sendControl(["type": "kf"])
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
    func enterSleep(completion: (() -> Void)? = nil) {
        closeSession(announcing: WireMessage.sleeping,
                     status: "Asleep — resumes on wake", completion: completion)
    }

    /// The app is being terminated (user swiped it away). Same close, but
    /// announced as "closing": quitting the app is deliberate, so the Mac
    /// ends the session without waiting around for a wake.
    func shutDown(completion: (() -> Void)? = nil) {
        closeSession(announcing: WireMessage.closing,
                     status: "Closed", completion: completion)
    }

    private func closeSession(announcing type: String, status: String,
                              completion: (() -> Void)?) {
        queue.async {
            var finished = false
            let finish = { [weak self] in
                guard let self, !finished else { return }
                finished = true
                self.connection?.cancel()
                self.connection = nil
                self.listener?.stateUpdateHandler = nil
                self.listener?.newConnectionHandler = nil
                self.listener?.cancel()
                self.listener = nil
                self.tlsListener?.cancel(); self.tlsListener = nil
                self.pairingListener?.cancel(); self.pairingListener = nil
                self.listenerHealthy = false
                self.listenerRestartState.invalidate()
                self.stopCursorListener()
                // Deliberate teardown by this device: no automatic recovery,
                // and any retry already scheduled is invalidated so it cannot
                // resurrect the session afterwards.
                self.cancelReconnect()
                self.setConnected(false, reason: .explicitDisconnect)
                self.resetDisplayModeState()
                self.resetAudioPlayback()   // FORGET DEVICE / app quit: queued audio dies with the session
                self.setStatus(status)
                DispatchQueue.main.async {
                    self.displayState = .running
                    self.onDisplayStateChange?(.running)
                }
                completion?()
            }
            guard let conn = self.connection, conn.state == .ready else {
                Log.info("closing session (\(type)) — no live connection")
                finish()
                return
            }
            Log.info("closing session — announcing \(type) to the Mac")
            self.sendControl(["type": type], on: conn) {
                self.queue.async { finish() }
            }
            // The send completion may never fire on a dying link — don't
            // let that keep us accepting connections after going dark.
            self.queue.asyncAfter(deadline: .now() + 1) { finish() }
        }
    }

    /// Re-arm the listener after cancellation has had time to release its
    /// fixed port. Duplicate requests collapse into the already-pending bind.
    private func restartListener(after delay: TimeInterval = 0) {
        guard let restart = listenerRestartState.scheduleRestart(after: delay) else { return }
        prepareListenerForRestart(restart)
    }

    private func scheduleListenerRetry() {
        guard let restart = listenerRestartState.scheduleRetry() else { return }
        Log.info("re-arming listener in \(restart.delay)s")
        prepareListenerForRestart(restart)
    }

    private func prepareListenerForRestart(
        _ restart: StreamListenerRestartState.ScheduledRestart
    ) {
        listenerHealthy = false
        if let old = listener {
            old.stateUpdateHandler = nil
            old.newConnectionHandler = nil
            old.cancel()
        }
        listener = nil
        stopCursorListener()
        queue.asyncAfter(deadline: .now() + restart.delay) { [weak self] in
            guard let self, self.listenerRestartState.consume(restart) else { return }
            self.startListener()
        }
    }

    /// The UDP cursor listener follows the TCP listener's lifecycle: created
    /// right after it, torn down with it. Losing it is never fatal; the
    /// sender falls back to TCP when hello carries no cursorPort.
    private func startCursorListener() {
        stopCursorListener()
        let params = NWParameters.udp
        params.allowLocalEndpointReuse = true
        params.includePeerToPeer = true
        params.serviceClass = .responsiveData
        let udp: NWListener
        do {
            udp = try NWListener(using: params, on: NWEndpoint.Port(rawValue: cursorPort)!)
        } catch {
            Log.info("cursor listener failed on udp :\(cursorPort): \(error) (cursor stays on TCP)")
            return
        }
        cursorListener = udp
        udp.newConnectionHandler = { [weak self] conn in
            guard let self, self.cursorListener === udp else { conn.cancel(); return }
            // A UDP "connection" is one remote host:port flow. The newest
            // one is the live sender (a rebuilt sender socket gets a fresh
            // ephemeral port) and starts its sequence over.
            self.cursorConnection?.cancel()
            self.cursorConnection = conn
            self.lastCursorSeq = 0
            conn.stateUpdateHandler = { [weak self] state in
                guard let self, self.cursorConnection === conn else { return }
                if case .failed(let error) = state {
                    Log.info("cursor channel failed: \(error)")
                    self.cursorConnection = nil
                }
            }
            conn.start(queue: self.queue)
            self.receiveCursorDatagrams(on: conn)
        }
        udp.stateUpdateHandler = { [weak self] state in
            guard let self, self.cursorListener === udp else { return }
            switch state {
            case .ready:
                self.cursorListenerReady = true
                Log.info("cursor listener ready on udp :\(self.cursorPort)")
                // hello may already be out without the port (the sender
                // connected before UDP bound); re-send so it can switch.
                if let connection, connection.state == .ready, !self.cursorPortAnnounced {
                    self.sendHello(on: connection)
                }
            case .failed(let error):
                Log.info("cursor listener failed: \(error) (cursor stays on TCP)")
                let wasAnnounced = self.cursorPortAnnounced
                self.stopCursorListener()
                // Withdraw the offer: a hello without cursorPort makes the
                // sender close its channel and return to TCP.
                if wasAnnounced, let connection = self.connection, connection.state == .ready {
                    self.sendHello(on: connection)
                }
            case .cancelled:
                self.cursorListenerReady = false
            default: break
            }
        }
        udp.start(queue: queue)
    }

    private func stopCursorListener() {
        cursorConnection?.cancel()
        cursorConnection = nil
        cursorListener?.cancel()
        cursorListener = nil
        cursorListenerReady = false
        cursorPortAnnounced = false
    }

    private func receiveCursorDatagrams(on conn: NWConnection) {
        conn.receiveMessage { [weak self] data, _, _, error in
            guard let self, self.cursorConnection === conn else { return }
            if let error {
                Log.info("cursor channel receive error: \(error)")
                return
            }
            if let data, !data.isEmpty { self.handleCursorDatagram(data) }
            self.receiveCursorDatagrams(on: conn)
        }
    }

    /// One datagram = one cursor JSON plus `s`, a per-flow sequence. UDP can
    /// reorder, and a stale position after a fresh one reads as jitter, so
    /// anything at or below the last seen sequence is dropped.
    private func handleCursorDatagram(_ data: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              obj["type"] as? String == "cursor",
              let seq = (obj["s"] as? NSNumber)?.uint64Value else { return }
        // Loss accounting only; the floor itself is enforced in applyCursor,
        // shared with TCP. Counts run slightly hot during the brief window
        // where the sender still mirrors to TCP (duplicates read as drops).
        guard seq > lastCursorSeq else { cursorLostThisWindow += 1; return }
        if lastCursorSeq == 0 {
            // First datagram of this flow: tell the sender the channel truly
            // delivers (UDP .ready proves only a local route — a firewalled
            // port would otherwise eat the cursor forever, PROTOCOL.md 6.3).
            Log.info("cursor channel: receiving datagrams")
            sendControl(["type": "cursorAck"])
        } else {
            cursorLostThisWindow += Int(seq - lastCursorSeq - 1)
        }
        applyCursor(obj)
    }

    private func startListener() {
        guard listener == nil, listenerRestartState.beginStarting() else { return }
        let newListener: NWListener
        do {
            // noDelay matters most in THIS direction: touch events are tiny
            // packets, and Nagle would hold each one until the previous is
            // ACKed — batched, late drags read as input lag.
            let tcp = NWProtocolTCP.Options()
            tcp.noDelay = true
            let params = NWParameters(tls: nil, tcp: tcp)
            params.allowLocalEndpointReuse = true
            params.includePeerToPeer = true
            params.serviceClass = .interactiveVideo
            params.requiredLocalEndpoint = .hostPort(
                host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
            newListener = try NWListener(using: params)
        } catch {
            listenerRestartState.listenerStopped()
            Log.info("listener could not be created: \(error)")
            setStatus("Listener failed — restarting…")
            scheduleListenerRetry()
            return
        }
        listener = newListener
        // Advertise on the local network so the Mac can discover us for WiFi
        // mode (USB/usbmux connects straight to the port and ignores this).
        // Plaintext media is deliberately loopback-only for usbmux. Bonjour
        // advertises the separate pinned-TLS listener below.
        newListener.newConnectionHandler = { [weak self] conn in
            guard let self, self.listener === newListener else {
                conn.cancel()
                return
            }
            Log.info("new connection from \(String(describing: conn.endpoint))")
            // A Bonjour dial races IPv6 and IPv4 and both handshakes can
            // complete; the sender cancels its loser within milliseconds.
            // Adopting every newcomer at once evicted the winner for a
            // connection that was already dying (seen in the field as a
            // reset-by-peer storm). With a connection in hand, a newcomer
            // has to stay alive for a moment before it replaces it.
            // A closed socket still reads as .ready until a receive hits
            // EOF, so the proof is bytes: greet the newcomer and adopt it
            // the moment it streams something back; a socket that closes
            // or errors first is discarded and the session stays put.
            if let current = self.connection, current.state != .cancelled,
               !Self.isFailed(current.state) {
                self.pendingConnections.append(conn)
                conn.stateUpdateHandler = { [weak self] state in
                    guard let self, case .ready = state else { return }
                    self.sendHello(on: conn)
                    conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 18) {
                        [weak self] data, _, isComplete, error in
                        guard let self else { return }
                        // Only a still-tracked candidate may adopt: adoption
                        // of a rival and stop() both clear the list, so a
                        // late callback can't evict a session or resurrect a
                        // stopped receiver.
                        guard self.pendingConnections.contains(where: { $0 === conn }) else {
                            conn.cancel()
                            return
                        }
                        self.pendingConnections.removeAll { $0 === conn }
                        if let data, !data.isEmpty {
                            self.adopt(conn, greeted: true, initialData: data)
                        } else {
                            Log.info("ignored a twin connection that closed at once"
                                     + (error.map { " (\($0))" } ?? ""))
                            conn.cancel()
                        }
                        _ = isComplete
                    }
                }
                conn.start(queue: self.queue)
            } else {
                self.adopt(conn)
            }
        }
        newListener.stateUpdateHandler = { [weak self] state in
            guard let self, self.listener === newListener else { return }
            switch state {
            case .ready:
                self.listenerRestartState.listenerReady()
                self.listenerHealthy = true
                self.setStatus("Waiting for Mac")
            case .waiting(let error):
                // Network.framework owns transient waiting states and may
                // recover without releasing/rebinding the fixed port.
                Log.info("listener waiting: \(error)")
            case .failed(let error):
                Log.info("listener failed: \(error)")
                self.listenerRestartState.listenerStopped()
                self.listenerHealthy = false
                self.setStatus("Listener failed — restarting…")
                self.scheduleListenerRetry()
            case .cancelled:
                self.listenerRestartState.listenerStopped()
                self.listenerHealthy = false
            default: break
            }
        }
        newListener.start(queue: queue)
        startCursorListener()
    }

    private func startTLSListener() {
        guard tlsListener == nil, let identity = TrustStore.shared.ownIdentity(),
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
            tlsListener = listener
            listener.service = advertisedService
            listener.newConnectionHandler = { [weak self, weak listener] connection in
                guard let self, self.tlsListener === listener else { connection.cancel(); return }
                guard !self.mediaSuppressedForPairing else {
                    Log.info("pairDebug: media auto-connect suppressed reason=pairingInProgress")
                    connection.cancel()
                    return
                }
                Log.info("reconnectDebug: incomingReplacement peer via TLS listener")
                self.adopt(connection)
            }
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                switch state {
                case .ready:
                    Log.info("reconnectDebug: listenerReady TLS port=\(WireCrypto.tlsPort)")
                case .failed(let error):
                    Log.info("secure listener failed: \(error)")
                    guard let self, self.tlsListener === listener else { return }
                    self.tlsListener = nil
                    // Fixed short backoff: mirrors the plaintext listener's
                    // retry cadence and avoids a busy loop if the port stays
                    // unavailable for a moment (e.g. right after a sleep/wake
                    // teardown/rebind race).
                    self.queue.asyncAfter(deadline: .now() + 1) { [weak self] in
                        self?.startTLSListener()
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
        queue.async { [weak self] in
            guard let self else { return }
            self.tlsListener?.cancel(); self.tlsListener = nil
            self.startTLSListener()
        }
    }

    private func startPairingListener() {
        guard pairingListener == nil else { return }
        do {
            let params = NWParameters.tcp
            params.includePeerToPeer = true
            params.allowLocalEndpointReuse = true
            let listener = try NWListener(using: params,
                on: NWEndpoint.Port(rawValue: WireCrypto.pairingPort)!)
            pairingListener = listener
            listener.service = advertisedPairingService
            #if DEBUG
            Log.info("pairing listener starting: type=_opendisplay-pair._tcp port=\(WireCrypto.pairingPort) id=\(Self.installID) peerToPeer=true")
            #endif
            listener.newConnectionHandler = { [weak self, weak listener] connection in
                guard let self, self.pairingListener === listener else { connection.cancel(); return }
                let localName = self.serviceName
                let prompt = self.pairingPrompt
                let autoConfirm = Self.isLoopback(connection.endpoint)
                Task { [weak self] in
                    defer { connection.cancel() }
                    do {
                        let paired = try await PairingNetwork.runResponder(
                            connection: connection, localID: Self.installID,
                            localName: localName, prompt: prompt,
                            autoConfirm: autoConfirm)
                        await prompt.finish("Paired with \(paired.peerName)")
                        self?.finishExplicitPairing(success: true)
                        self?.scheduleTLSListenerRefresh()
                    } catch {
                        await prompt.finish(error.localizedDescription)
                        let promptStillPending = await MainActor.run { prompt.pending != nil }
                        if !promptStillPending {
                            self?.finishExplicitPairing(success: false)
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
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            DispatchQueue.main.async {
                self?.discoveredMacs = Array(results)
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

    private static func isLoopback(_ endpoint: NWEndpoint) -> Bool {
        let peer = String(describing: endpoint).lowercased()
        return peer.hasPrefix("127.") || peer.hasPrefix("::1")
            || peer.hasPrefix("[::1]") || peer.hasPrefix("localhost")
    }

    /// Make `conn` the session: replace any existing connection and reset
    /// decoder state. `greeted` marks a newcomer that already got its hello
    /// while it proved itself (see the listener), with the bytes it sent
    /// back in `initialData`; a second hello would make the sender rebuild.
    private func adopt(_ conn: NWConnection, greeted: Bool = false, initialData: Data? = nil) {
        if greeted { Log.info("newcomer proved itself — adopting it as the session") }
        let supersededGeneration = sessionState.generation
        let hadPriorConnection = connection != nil
        connection?.cancel()
        connection = conn
        // A new session supersedes any recovery run: retries scheduled
        // against the old generation can no longer win.
        cancelReconnect()
        mutateSession { $0.connectionAdopted() }
        if hadPriorConnection {
            Log.info("reconnectDebug: superseded oldGeneration=\(supersededGeneration)"
                     + " newGeneration=\(sessionState.generation)")
        }
        // The race is decided: rival candidates die here.
        for pending in pendingConnections where pending !== conn { pending.cancel() }
        pendingConnections.removeAll()
        resetStreamState()
        receivedVideoEnabled = true
        lastCursorSeq = 0   // the sender restarts its cursor sequence per session
        cursorPortAnnounced = false
        // Hide the previous sender's cursor: replayed into a fresh video view
        // it would ghost over a new sender that never sends one (mirror mode
        // hides no local cursor and streams no sprite).
        DispatchQueue.main.async {
            self.cursorState = (0.5, 0.5, false)
            self.cursorSprite = nil
            self.onCursor?(0.5, 0.5, false)
        }
        let onReady: () -> Void = { [weak self] in
            guard let self else { return }
            self.lastDataReceived = Date()
            if let path = conn.currentPath {
                self.updateTransport(for: conn, path: path)
            }
            let resolvedPeerID = Self.resolveAuthenticatedPeerID(from: conn)
            DispatchQueue.main.async { self.authenticatedPeerID = resolvedPeerID }
            self.setConnected(true)
            if !greeted { self.sendHello(on: conn) }
        }
        conn.pathUpdateHandler = { [weak self] path in
            guard let self, conn === self.connection else { return }
            self.updateTransport(for: conn, path: path)
            if conn.state == .ready {
                self.setStatus("Connected · \(self.transport)")
            }
        }
        conn.stateUpdateHandler = { [weak self] state in
            guard let self, conn === self.connection else { return }   // replaced: stay quiet
            switch state {
            case .ready: onReady()
            case .failed, .cancelled: self.setConnected(false)
            default: break
            }
        }
        if conn.state == .ready {
            onReady()   // already up: the handler will not fire again
        } else {
            conn.start(queue: queue)
        }
        if let initialData, !initialData.isEmpty {
            bytesThisWindow += initialData.count
            buffer.append(initialData)
            drainFrames()
        }
        receive(on: conn)
    }

    private func updateTransport(for conn: NWConnection, path: NWPath) {
        let peer = String(describing: path.remoteEndpoint ?? conn.endpoint)
        let isLoopbackPeer = peer.hasPrefix("127.0.0.1") || peer.hasPrefix("::1")
            || peer.hasPrefix("localhost") || peer.hasPrefix("[::1]")
        let route = ConnectionRoute.classify(
            isUSB: path.usesInterfaceType(.loopback) || isLoopbackPeer,
            interfaceNames: path.availableInterfaces.map(\.name),
            remoteEndpointDescription: peer)
        transport = route.rawValue
        let names = path.availableInterfaces.map(\.name).joined(separator: ",")
        Log.info("connection path from \(peer): \(names) route=\(route.rawValue)")
    }

    private static func isFailed(_ state: NWConnection.State) -> Bool {
        if case .failed = state { return true }
        return false
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

    /// Arm (or re-arm) the ping and watchdog timers on the receiver queue.
    private func armLivenessTimers() {
        pingTimer?.cancel()
        let ping = DispatchSource.makeTimerSource(queue: queue)
        ping.schedule(deadline: .now() + 2.0, repeating: 2.0)
        ping.setEventHandler { [weak self] in
            guard let self, self.connection?.state == .ready else { return }
            self.sendControl(["type": "ping", "t": self.nowMs])
        }
        ping.resume()
        pingTimer = ping

        addrWatchTimer?.cancel()
        if advertisesAddresses {
            let addrWatch = DispatchSource.makeTimerSource(queue: queue)
            addrWatch.schedule(deadline: .now() + 5.0, repeating: 5.0)
            addrWatch.setEventHandler { [weak self] in
                guard let self, let conn = self.connection, conn.state == .ready else { return }
                let now = Self.reachableAddresses()
                guard now != self.lastAdvertisedAddrs else { return }
                // A cable was plugged (or pulled) mid-session: tell the sender,
                // it re-probes on the fresh list (PROTOCOL.md 6.4).
                Log.info("reachable addresses changed — re-sending hello")
                self.sendHello(on: conn)
            }
            addrWatch.resume()
            addrWatchTimer = addrWatch
        }

        watchdogTimer?.cancel()
        let watchdog = DispatchSource.makeTimerSource(queue: queue)
        watchdog.schedule(deadline: .now() + 2.0, repeating: 2.0)
        watchdog.setEventHandler { [weak self] in
            guard let self, let conn = self.connection, conn.state == .ready,
                  Date().timeIntervalSince(self.lastDataReceived) > 5 else { return }
            Log.info("watchdog: nothing from the Mac for >5s — dropping connection")
            conn.cancel()
            self.connection = nil
            self.setConnected(false)
        }
        watchdog.resume()
        watchdogTimer = watchdog
    }

    /// JSON on the video channel (pong, ping liveness) — payloads starting '{'.
    private func handleVideoChannelJSON(_ data: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else { return }
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
                clockOffsetMs = best.offset
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
            DispatchQueue.main.async {
                self.cursorSprite = (image, anchor, normSize)
                self.onCursorImage?(image, anchor, normSize)
            }
        case "displayState":
            guard let state = DisplayState.decode(messageType: type,
                                                  value: obj["state"] as? String) else { return }
            // Pause is intentional, not a failure: it shares the interruption
            // presentation but must never start automatic recovery.
            mutateSession { state == .paused ? $0.displayPaused() : $0.displayResumed() }
            // PAUSE stops both media: release/flush audio here so Resume
            // starts on a clean synchronized timeline (SESSION BEHAVIOR).
            // The Mac's own capture pipeline dies underneath a pause too, so
            // no more packets would arrive anyway — this just makes sure
            // nothing already-scheduled keeps playing into the pause.
            if state == .paused { resetAudioPlayback() }
            DispatchQueue.main.async {
                self.displayState = state
                self.onDisplayStateChange?(state)
            }
        case WireMessage.displayModeState:
            guard let rawMode = obj["mode"] as? String,
                  let mode = ReceiverDisplayMode(rawValue: rawMode) else { return }
            DispatchQueue.main.async { self.applyConfirmedDisplayMode(mode) }
        case WireMessage.mirrorDisplayState:
            guard let update = MirrorDisplayStateUpdate(message: obj) else { return }
            DispatchQueue.main.async { self.mirrorDisplayState = update }
        case WireMessage.welcome:
            // The Mac identified itself (issue #132). If it speaks a protocol
            // older than we support, it's the Mac that needs updating — and an
            // old Mac can't diagnose that itself, so we surface it here.
            let macPV = obj["pv"] as? Int ?? WireProtocol.assumedWhenAbsent
            DispatchQueue.main.async {
                self.macProtocolVersion = macPV
                if macPV < WireProtocol.videoControlWireVersion {
                    self.videoEnabled = true
                }
            }
            if macPV < WireProtocol.minSupportedPeer {
                peerIsIncompatible = true
                let msg = "The MeowDisplay app on your Mac is too old for this \(deviceKind) app. Update MeowDisplay on your Mac to reconnect."
                DispatchQueue.main.async { self.peerSignal = .updateMac(message: msg) }
            }
            // Reassert this receiver's audio preference on every welcome —
            // covers first connect, reconnect, and transport migration in
            // one place, with no separate "did we already ask" state to
            // fall out of sync (SESSION BEHAVIOR: migration must not reset
            // the user's Audio preference).
            if macPV >= WireProtocol.audioWireVersion {
                sendControl(["type": WireMessage.audioRequest, "enabled": audioPreferred])
            } else {
                DispatchQueue.main.async { self.audioEnabled = false }
            }
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
            DispatchQueue.main.async { self.promoteInteractiveWakeResult = text }
        case WireMessage.updateRequired:
            // The Mac refuses this pairing until we update from the App Store.
            // Retrying cannot fix that, so the eventual loss is terminal.
            peerIsIncompatible = true
            let message = obj["message"] as? String
                ?? "Update MeowDisplay from the App Store to keep using your second display."
            let store = (obj["store"] as? String).flatMap { URL(string: $0) } ?? AppStore.updateURL
            DispatchQueue.main.async { self.peerSignal = .updateReceiver(message: message, storeURL: store) }
        case WireMessage.receiverUI:
            guard let update = ReceiverUIPreferenceUpdate(message: obj) else { return }
            DispatchQueue.main.async { self.onReceiverUIPreferences?(update) }
        case WireMessage.inputReset:
            DispatchQueue.main.async { self.inputResetGeneration &+= 1 }
        case WireMessage.allowInputState:
            guard let allowed = obj["allowed"] as? Bool else { return }
            DispatchQueue.main.async { self.onAllowInputStateChange?(allowed) }
        case WireMessage.videoState:
            guard let update = VideoStateUpdate(message: obj) else { return }
            let changed = update.enabled != receivedVideoEnabled
            receivedVideoEnabled = update.enabled
            if changed || !update.enabled {
                resetDecoderForVideoStateChange()
            }
            DispatchQueue.main.async {
                if let width = update.width, let height = update.height {
                    self.videoSize = CGSize(width: width, height: height)
                }
                self.videoEnabled = update.enabled
            }
        case WireMessage.audioState:
            guard let update = AudioStateUpdate(message: obj) else { return }
            if !update.enabled { resetAudioPlayback() }
            DispatchQueue.main.async { self.audioEnabled = update.enabled }
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
        DispatchQueue.main.async {
            self.cursorState = (x, y, visible)
            self.onCursor?(x, y, visible)
        }
    }

    private func resetStreamState() {
        buffer.removeAll(keepingCapacity: true)
        formatDesc = nil
        sps = nil
        pps = nil
        lastFrameAt = nil
        frameIntervals.removeAll()
        decodeFlushes = 0
        displayLayer.flush()
        if let session = decompressionSession {
            VTDecompressionSessionInvalidate(session)
            decompressionSession = nil
        }
        decodeWindow.removeAll(keepingCapacity: true)
        photonWindow.removeAll(keepingCapacity: true)
        // A new connection is a new generation (RECONNECT — never play
        // stale audio, and never present a video frame delayed by a
        // negative offset from the superseded connection).
        videoGeneration &+= 1
        resetAudioPlayback()
    }

    // MARK: - Control messages (phone -> Mac)

    private func sendHello(on conn: NWConnection) {
        var hello: [String: Any] = [
            "type": "hello",
            "pixelsWide": devicePixelsWide,
            "pixelsHigh": devicePixelsHigh,
            "scale": deviceScale,
            "device": deviceKind,
            "id": Self.installID,
            "pv": WireProtocol.version,   // issue #132 — absent on old receivers
        ]
        if deviceKind != "Mac" {
            hello["trayEnabled"] = announcedTrayEnabled
            hello["keyboardButtonEnabled"] = announcedKeyboardButtonEnabled
            // Read visibility for the connected Mac's per-device Settings
            // detail (PRODUCT: per-device receiver settings) — the receiver
            // stays the authoritative store for all of these; this only
            // reports the current value, exactly like tray/keyboard above.
            hello["functionTrayEnabled"] = announcedFunctionTrayEnabled
            hello["inputMode"] = announcedInputMode.rawValue
            hello["trackpadSensitivity"] = announcedTrackpadSensitivity
            hello["hapticsEnabled"] = announcedHapticsEnabled
            hello["avoidNotch"] = announcedAvoidNotch
            hello["pinchTarget"] = announcedPinchTarget.rawValue
            hello["rotateTarget"] = announcedRotateTarget.rawValue
            hello["snapRotation"] = announcedSnapRotation
            // Reuses `AppGestureCommands`'s own `Codable` conformance rather
            // than a hand-written field list — see `ReceiverUIPreferenceUpdate`.
            if let data = try? JSONEncoder().encode(announcedAppGestureCommands),
               let obj = try? JSONSerialization.jsonObject(with: data) {
                hello["appGestureCommands"] = obj
            }
            // Receiver-local playback timing — never Mac-pushed (only the
            // receiver can judge its own speaker/headphone latency), but
            // reported so Streaming/device detail can show the real value
            // instead of a fake always-zero placeholder.
            hello["avSyncOffsetMs"] = avSyncOffsetMs
        }
        // Additive capability: only offered while the UDP listener is bound,
        // so a sender never dials a port nobody answers on.
        if cursorListenerReady { hello["cursorPort"] = Int(cursorPort) }
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
        // Additive: the addresses this receiver can be reached on, so the
        // sender can probe for a better (cabled) path and migrate a WiFi
        // session onto it — mDNS resolution under an interface-restricted
        // dial stalls, a literal address does not (PROTOCOL.md 6.4).
        // Mac receivers only: a cabled phone reaches the sender over
        // usbmuxd, and advertising a phone's WiFi fe80 would invite a
        // false "upgrade" onto a bridged-LAN path that still crosses the
        // phone's radio — and then have the session classified as a cable
        // whose loss must end it instead of reconnecting.
        let addrs = advertisesAddresses ? Self.reachableAddresses() : []
        if !addrs.isEmpty { hello["addrs"] = addrs }
        lastAdvertisedAddrs = addrs
        cursorPortAnnounced = cursorListenerReady
        sendControl(hello, on: conn)
        Log.info("hello sent\(cursorListenerReady ? " (cursorPort \(cursorPort))" : "")")
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
            var addr = String(cString: host)
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
    func sendTouch(phase: String, x: Double, y: Double) {
        guard displayState == .running else { return }
        var msg: [String: Any] = ["type": "touch", "phase": phase, "x": x, "y": y]
        if let offset = clockOffsetMs { msg["t"] = nowMs + offset }
        sendControl(msg)
    }

    /// Two-finger scroll: dx/dy in video pixels (natural-scrolling sign).
    func sendScroll(dx: Double, dy: Double) {
        guard displayState == .running else { return }
        sendControl(["type": "scroll", "dx": dx, "dy": dy])
    }

    /// Send a semantic gesture without changing the meaning of touch/scroll input.
    func sendGesture(name: String) {
        sendControl(["type": "gesture", "name": name])
    }

    /// M7 pointer/click messages (pv 5). Callers MUST check
    /// `macSupportsPointerWire` first — see `PointerGestureEngine` and its
    /// use from `iOS/OpenSidecarPhoneApp.swift`'s `VideoView`.
    ///
    /// Absolute cursor move: `x`/`y` normalized [0,1] in video space, no
    /// button implied.
    func sendPointerMove(x: Double, y: Double) {
        guard displayState == .running else { return }
        sendControl(["type": "pointer", "action": "move", "x": x, "y": y])
    }

    /// Relative cursor move: `dx`/`dy` in video pixels (same convention as
    /// `scroll`), no button implied.
    func sendPointerMoveRelative(dx: Double, dy: Double) {
        guard displayState == .running else { return }
        sendControl(["type": "pointer", "action": "moveRelative", "dx": dx, "dy": dy])
    }

    /// Presses `button` down at the Mac's current cursor position with the
    /// given click count (1 = single, 2 = double, 3 = triple — mirrors
    /// `NSEvent.clickCount`/`CGEventClickState`).
    func sendPointerDown(button: PointerButton, clickCount: Int) {
        guard displayState == .running else { return }
        sendControl(["type": "pointer", "action": "down", "button": button.wireValue, "clickCount": clickCount])
    }

    /// Releases `button`. Every `down` a receiver sends MUST be followed by
    /// a matching `up` (or disconnect — senders MUST release a still-held
    /// button on session loss regardless, mirroring `keyboard`'s down/up
    /// contract).
    func sendPointerUp(button: PointerButton, clickCount: Int) {
        guard displayState == .running else { return }
        sendControl(["type": "pointer", "action": "up", "button": button.wireValue, "clickCount": clickCount])
    }

    /// Apple Pencil stroke/hover. azimuth and altitude are radians.
    /// rotation is always 0 until Apple Pencil Pro barrel roll is wired up.
    func sendPencil(phase: String, x: Double, y: Double,
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
        if let offset = clockOffsetMs { msg["t"] = nowMs + offset }
        sendControl(msg)
    }

    func sendProximity(entering: Bool, x: Double, y: Double) {
        guard displayState == .running else { return }
        sendControl(["type": "proximity", "entering": entering, "x": x, "y": y])
    }

    /// Committed Unicode text from the native software/hardware keyboard
    /// (M4). Never carries marked/IME-intermediate text — callers commit
    /// only finished text (see `RemoteKeyboardInputView`).
    func sendKeyboardText(_ text: String) {
        guard displayState == .running, macSupportsKeyboardWire, !text.isEmpty else { return }
        sendControl(["type": "keyboard", "action": "text", "text": text])
    }

    /// An atomic special key from the software keyboard (e.g. Return,
    /// Backspace) with no down/up lifecycle to track. `usage` is a USB HID
    /// keyboard-page usage number.
    func sendKeyboardPress(usage: Int, modifiers: [String] = []) {
        guard displayState == .running, macSupportsKeyboardWire else { return }
        sendControl(["type": "keyboard", "action": "press", "usage": usage,
                     "modifiers": modifiers])
    }

    func sendModifier(_ modifier: ControlModifier, down: Bool) {
        guard displayState == .running,
              macProtocolVersion >= WireProtocol.receiverControlsWireVersion else { return }
        sendControl(["type": "keyboard", "action": down ? "modifierDown" : "modifierUp",
                     "modifier": modifier.rawValue])
    }

    func sendCancelActiveInput() {
        guard macProtocolVersion >= WireProtocol.receiverControlsWireVersion else { return }
        sendControl(["type": "keyboard", "action": "cancel"])
    }

    /// Asks the connected Mac to change its Allow Input gate. The Mac
    /// remains authoritative: this is a request, not an assignment — the
    /// confirmed state always arrives back via `onAllowInputStateChange`,
    /// whether or not it matches what was requested. A no-op against an
    /// older Mac (or while disconnected) — the local, receiver-only
    /// preference this drives from the UI side stays in effect either way.
    func requestAllowInput(_ allowed: Bool) {
        guard connected, macProtocolVersion >= WireProtocol.allowInputWireVersion else { return }
        sendControl(["type": WireMessage.allowInputRequest, "allowed": allowed])
    }

    func requestVideoEnabled(_ enabled: Bool) {
        guard connected, macSupportsVideoControl else { return }
        sendControl(["type": WireMessage.videoRequest, "enabled": enabled])
    }

    /// Turns Mac system audio on/off for this receiver. Persists the
    /// preference in-memory and resends it on every subsequent `welcome`
    /// (see the `WireMessage.welcome` handler) so reconnection, transport
    /// migration, and a fresh pairing after Forget Device all restore it —
    /// never a stale callback re-enabling audio after those transitions,
    /// because each one re-derives the request from this single value
    /// rather than replaying anything queued.
    func requestAudioEnabled(_ enabled: Bool) {
        audioPreferred = enabled
        guard connected, macSupportsAudio else { return }
        sendControl(["type": WireMessage.audioRequest, "enabled": enabled])
    }

    /// Seeds the preference to resend on connect/reconnect without sending
    /// anything yet (e.g. restoring a persisted Settings value at launch,
    /// before there is a connection). Use `requestAudioEnabled` for a live
    /// user toggle.
    func primeAudioPreference(_ enabled: Bool) {
        audioPreferred = enabled
    }

    /// Asks the connected Mac to call IOPMAssertionDeclareUserActivity, over
    /// the same authenticated session as every other control message — there
    /// is no separate channel for it, so an unauthenticated/unpaired peer
    /// could never send this even if it wanted to. Driven automatically by
    /// `WakeConnectCoordinator`; `PromoteInteractiveWakeView` (DEBUG-only)
    /// also exposes it as a manual diagnostic.
    @Published var promoteInteractiveWakeResult: String?

    func requestPromoteInteractiveWake() {
        guard connected else { return }
        Log.info("wakeDebug: promoteInteractiveWake request sent")
        sendControl(["type": WireMessage.promoteInteractiveWake])
    }

    func sendNativeAppGesture(kind: NativeAppGestureKind,
                              phase: NativeAppGesturePhase,
                              delta: Double) {
        guard displayState == .running,
              macProtocolVersion >= WireProtocol.nativeAppGestureWireVersion else { return }
        sendControl(["type": WireMessage.nativeAppGesture,
                     "kind": kind.rawValue,
                     "phase": phase.rawValue,
                     "delta": delta])
    }

    /// Retire every decoded/presented frame without forgetting `videoSize`:
    /// that geometry is still the Direct Touch mapping surface while video is
    /// off. The next video-on stream begins from fresh SPS/PPS + an IDR.
    private func resetDecoderForVideoStateChange() {
        formatDesc = nil
        sps = nil
        pps = nil
        displayLayer.flushAndRemoveImage()
        if let session = decompressionSession {
            VTDecompressionSessionInvalidate(session)
            decompressionSession = nil
        }
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
        sendControl(["type": WireMessage.displayModeRequest, "mode": mode.rawValue])
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

    /// Asks the connected Mac to change its Mirror capture source. The Mac
    /// remains the single canonical owner (`SenderController.mirrorDisplayUUID`,
    /// the same setting its own Settings picker writes) — this only requests;
    /// the confirmed state always arrives back via a fresh `mirrorDisplayState`.
    /// `uuid: nil` requests Auto. A no-op against an older Mac, while
    /// disconnected, or for a display not in the Mac's own last-reported
    /// inventory (never trust a stale/local UUID the Mac hasn't vouched for).
    func requestMirrorDisplaySelection(_ uuid: String?) {
        guard connected, macProtocolVersion >= WireProtocol.mirrorDisplayWireVersion else { return }
        let knownUUIDs = Set(mirrorDisplayState?.displays.map(\.uuid) ?? [])
        if let uuid, !knownUUIDs.contains(uuid) { return }
        var dict: [String: Any] = ["type": WireMessage.mirrorDisplayRequest]
        if let uuid { dict["selectedUUID"] = uuid }
        sendControl(dict)
    }

    /// Deliberate session teardown (stop/sleep/close): the Mac's mode is no
    /// longer known and any in-flight request dies with the session.
    func resetDisplayModeState() {
        DispatchQueue.main.async {
            self.displayModeRequestState.reset()
            self.confirmedDisplayMode = nil
            self.pendingDisplayMode = nil
        }
    }

    @MainActor
    private func applyConfirmedDisplayMode(_ mode: ReceiverDisplayMode) {
        let shouldConfirmWithHaptic = displayModeRequestState.confirm(mode)
        confirmedDisplayMode = displayModeRequestState.confirmedMode
        pendingDisplayMode = displayModeRequestState.pendingMode
        if shouldConfirmWithHaptic { displayModeConfirmationGeneration &+= 1 }
    }

    /// A hardware key going down, for keys the Mac must hold (arrows,
    /// modified shortcuts). `modifiers` are named protocol modifiers, not
    /// raw UIKit flags.
    func sendKeyboardDown(usage: Int, modifiers: [String]) {
        guard displayState == .running, macSupportsKeyboardWire else { return }
        sendControl(["type": "keyboard", "action": "down", "usage": usage, "modifiers": modifiers])
    }

    /// The matching release for `sendKeyboardDown`.
    func sendKeyboardUp(usage: Int, modifiers: [String]) {
        guard displayState == .running, macSupportsKeyboardWire else { return }
        sendControl(["type": "keyboard", "action": "up", "usage": usage, "modifiers": modifiers])
    }

    private func sendControl(_ message: [String: Any], on conn: NWConnection? = nil,
                             completion: (() -> Void)? = nil) {
        guard let conn = conn ?? connection,
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

    // MARK: - Socket read + length-prefixed deframing

    private func receive(on conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 18) {
            [weak self] data, _, isComplete, error in
            // A replaced connection's last callback must not touch the
            // session (its EOF used to flip `connected` off for the new one).
            guard let self, conn === self.connection else { return }
            if let data, !data.isEmpty {
                self.lastDataReceived = Date()
                self.bytesThisWindow += data.count
                self.buffer.append(data)
                self.drainFrames()
            }
            if let error {
                // FORENSIC FIX (media-death-with-input-still-working): this
                // used to just log and return WITHOUT re-arming `receive`
                // and WITHOUT calling `setConnected(false)` — the read loop
                // stopped forever while `connected` stayed true and nothing
                // ever told session state the connection was gone. TCP is
                // full-duplex: our own outbound writes (touch/pointer input)
                // keep working fine over the same socket, so from the user's
                // side "input still works" while nothing we're owed (video,
                // audio, cursor) ever arrives again, and no automatic
                // recovery ever kicks in because nothing marked the session
                // down. Treat any receive error exactly like EOF: it is
                // this connection's own health, not a per-call fluke.
                Log.info("receive error: \(error)")
                self.setConnected(false)
                return
            }
            if isComplete {
                Log.info("peer closed connection")
                self.setConnected(false)
                return
            }
            self.receive(on: conn)
        }
    }

    private func drainFrames() {
        // Cursor-based drain so we only compact the buffer once per batch.
        var cursor = buffer.startIndex
        while buffer.distance(from: cursor, to: buffer.endIndex) >= 4 {
            let len = buffer[cursor..<buffer.index(cursor, offsetBy: 4)]
                .withUnsafeBytes { Int(UInt32(bigEndian: $0.loadUnaligned(as: UInt32.self))) }
            guard buffer.distance(from: cursor, to: buffer.endIndex) >= 4 + len else { break }
            let start = buffer.index(cursor, offsetBy: 4)
            let end = buffer.index(start, offsetBy: len)
            let payload = Data(buffer[start..<end])
            if AudioMediaFrame.isAudioFrame(payload) {
                handleAudioMediaFrame(payload)
            } else {
                handleAnnexB(payload)
            }
            cursor = end
        }
        buffer.removeSubrange(buffer.startIndex..<cursor)
    }

    // MARK: - Annex B -> CMSampleBuffer

    private func handleAnnexB(_ data: Data) {
        // Pure JSON payload = control message (pong, cursor sprite etc.).
        // Video frames also begin with '{' (telemetry prefix) but always
        // contain start codes — the null bytes make them unambiguous even
        // against multi-KB JSON (cursor sprites are base64, NUL-free).
        if data.count < 32_768, data.first == UInt8(ascii: "{"), !data.contains(0x00) {
            handleVideoChannelJSON(data)
            return
        }

        // Split on 4-byte start codes (our sender only emits 00 00 00 01).
        // Bytes before the FIRST start code are the telemetry prefix
        // ({"cap":…,"snd":…} stamped by the Mac).
        var nalus: [Data] = []
        var metaPrefix: Data?
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let bytes = raw.bindMemory(to: UInt8.self)
            var naluStart: Int? = nil
            var firstSC: Int? = nil
            var i = 0
            while i + 4 <= bytes.count {
                if bytes[i] == 0, bytes[i+1] == 0, bytes[i+2] == 0, bytes[i+3] == 1 {
                    if firstSC == nil { firstSC = i }
                    if let s = naluStart, s < i { nalus.append(Data(bytes[s..<i])) }
                    naluStart = i + 4
                    i += 4
                } else {
                    i += 1
                }
            }
            if let s = naluStart, s < bytes.count { nalus.append(Data(bytes[s...])) }
            if let f = firstSC, f > 0 { metaPrefix = Data(bytes[0..<f]) }
        }

        var captureMs: Double?
        var sendMs: Double?
        if let metaPrefix,
           let meta = try? JSONSerialization.jsonObject(with: metaPrefix) as? [String: Any] {
            captureMs = meta["cap"] as? Double
            sendMs = meta["snd"] as? Double
        }

        var vclNALUs: [Data] = []
        for nalu in nalus {
            guard let first = nalu.first else { continue }
            switch first & 0x1F {
            case 7:                                  // SPS (stream may change
                if sps != nalu {                     //  size on rotation)
                    sps = nalu
                    formatDesc = nil
                }
            case 8:                                  // PPS
                if pps != nalu {
                    pps = nalu
                    formatDesc = nil
                }
            case 6: break                            // SEI — skip
            default: vclNALUs.append(nalu)           // slice data
            }
        }
        if formatDesc == nil, let sps, let pps {
            displayLayer.flush()   // drop any frames from the previous format
            buildFormatDescription(sps: sps, pps: pps)
        }
        guard !vclNALUs.isEmpty else { return }
        // All slices of one wire frame go into ONE sample buffer.
        enqueueFrame(vclNALUs, captureMs: captureMs, sendMs: sendMs)
    }


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
    /// generation-scoped monotonicity state (`lastAudioSequence`,
    /// `lastAudioTarget`) so a new generation's counters, which restart
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
        lastAudioTarget = nil
        lastAudioDiagnosticCaptureMs = nil
        audioEnqueueCount = 0
        Log.info("audioTrace: generation=\(audioGenerationCount) codec=\(codec == .aac ? "AAC" : "PCM") playbackPath=\(activePlaybackPath == .pcmEngine ? "pcmEngine" : "legacyRenderer") starting bundleID=\(Bundle.main.bundleIdentifier ?? "?") audioReceiverLocalDecode=\(receiverAACLocalDecodeEnabled) audioReceiverDumpEnabled=\(receiverAACDumpEnabled) audioAACIntegrityLogging=\(aacIntegrityLoggingEnabled) dumpDirectory=\(Self.receiverDecodeDumpDirectory().path)")
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
        guard audioRenderer == nil else { return }
        let renderer = AVSampleBufferAudioRenderer()
        let synchronizer = AVSampleBufferRenderSynchronizer()
        synchronizer.addRenderer(renderer)
        // Ties the synchronizer's virtual clock 1:1 to the host clock from
        // this instant on — every sample buffer's PTS is then simply "the
        // host time it should play at" (see `targetHostTime`), with no
        // separate anchor/rate bookkeeping needed on this end.
        synchronizer.setRate(1, time: CMClockGetTime(CMClockGetHostTimeClock()))
        audioRenderer = renderer
        audioSynchronizer = synchronizer
        activateAudioSessionIfNeeded()
        #if DEBUG
        // Anomaly diagnostic (GOAL section 7): `error` is KVO-observable on
        // AVSampleBufferAudioRenderer and fires if the renderer itself hits
        // an unrecoverable playback error — exactly the kind of event that
        // would explain a sudden dead-audio patch without a corresponding
        // network/framing symptom.
        audioErrorObservation = renderer.observe(\.error, options: [.new]) { [weak self] _, change in
            guard let error = change.newValue ?? nil else { return }
            Log.info("audioTrace: ⚠️ audio renderer reported error: \(error)")
            self?.queue.async { self?.audioAnchor = nil }
        }
        #endif
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
    /// audio start (if any) resends a fresh one anyway.
    private func resetAudioPlayback(keepingFormat: Bool = false) {
        audioRenderer?.stopRequestingMediaData()
        if let audioRenderer { audioRenderer.flush() }
        audioSynchronizer?.setRate(0, time: .zero)
        audioRenderer = nil
        audioSynchronizer = nil
        if !keepingFormat {
            audioFormatDescription = nil
            audioCodecKind = nil
            deactivateAudioSessionIfNeeded()
        }
        audioAnchor = nil
        if !keepingFormat {
            receiverAACDecoder = nil
            receiverAACDecoderFormatDescription = nil
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
        lastAudioTarget = nil
        if !keepingFormat { lastAppliedAudioConfigDescription = nil }
        audioErrorObservation = nil
        if !keepingFormat {
            finalizeReceiverDecodeDump()
            lastReceiverDecodedSample = nil
        }
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
        queue.async {
            self.videoGeneration &+= 1
            self.resetAudioPlayback(keepingFormat: true)
            #if DEBUG
            Log.info("audioTrace: resync — anchor cleared, video generation advanced to \(self.videoGeneration)")
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
            // diagnostics validated (`decodeReceivedAAC`), then hand the
            // PCM straight to `PCMPlaybackEngine` — the legacy compressed-
            // `CMSampleBuffer` path below is not touched at all.
            guard let audioFormatDescription, let clockOffsetMs else { return }
            guard let decoded = decodeReceivedAAC(packet.payload, formatDescription: audioFormatDescription) else {
                Log.info("audioTrace: ⚠️ PCM engine: decode failed, dropping packet seq=\(packet.sequence)")
                return
            }
            #if DEBUG
            if receiverAACLocalDecodeEnabled { analyzeReceivedAACDecode(decoded) }
            #endif
            let receiverCaptureMs = Double(packet.capturedAtMs) - clockOffsetMs
            pcmPlaybackEngine.enqueue(decoded, captureMs: receiverCaptureMs, avSyncOffsetMs: avSyncOffsetMs)
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
               let decoded = decodeReceivedAAC(packet.payload, formatDescription: audioFormatDescription) {
                analyzeReceivedAACDecode(decoded)
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
        ensureAudioPlaybackChain()   // lazily recreates the renderer after resync/reset
        guard let audioRenderer else { return }
        guard let clockOffsetMs else { return }   // clock sync not settled yet (first ~2s) — drop
        // Mac wall-clock ms -> this receiver's equivalent wall-clock ms
        // (section 8.1: offset = macClock - receiverClock).
        let receiverCaptureMs = Double(capturedAtMs) - clockOffsetMs

        if audioAnchor == nil {
            establishAudioAnchor(captureMs: receiverCaptureMs)
        }
        guard let anchor = audioAnchor else { return }

        let audioDelaySeconds = Double(AVSyncOffset.audioDelayMs(for: avSyncOffsetMs)) / 1000.0
        let target = anchor.hostTime + (receiverCaptureMs - anchor.captureMs) / 1000.0 + audioDelaySeconds
        #if DEBUG
        checkNonMonotonicTarget(target)
        #endif

        var blockBuffer: CMBlockBuffer?
        let blockStatus = payload.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> OSStatus in
            var buffer: CMBlockBuffer?
            let createStatus = CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: raw.count,
                blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
                dataLength: raw.count, flags: 0, blockBufferOut: &buffer)
            guard createStatus == noErr, let buffer else { return createStatus }
            let copyStatus = CMBlockBufferReplaceDataBytes(
                with: raw.baseAddress!, blockBuffer: buffer, offsetIntoDestination: 0, dataLength: raw.count)
            blockBuffer = buffer
            return copyStatus
        }
        guard blockStatus == noErr, let blockBuffer else {
            #if DEBUG
            Log.info("audioTrace: ⚠️ CMBlockBuffer creation/copy failed status=\(blockStatus) — sample dropped before reaching the renderer")
            #endif
            return
        }

        let pts = CMTime(seconds: target, preferredTimescale: 1_000_000)
        var timing = CMSampleTimingInfo(
            duration: duration, presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var sizes = sampleSizes()
        var sample: CMSampleBuffer?
        let createStatus = sizes.withUnsafeMutableBufferPointer { sizesPtr -> OSStatus in
            CMSampleBufferCreateReady(
                allocator: kCFAllocatorDefault, dataBuffer: blockBuffer,
                formatDescription: audioFormatDescription, sampleCount: sampleCount,
                sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                sampleSizeEntryCount: sampleSizeEntryCount,
                sampleSizeArray: sampleSizeEntryCount > 0 ? sizesPtr.baseAddress : nil,
                sampleBufferOut: &sample)
        }
        guard createStatus == noErr, let sample else {
            #if DEBUG
            Log.info("audioTrace: ⚠️ CMSampleBufferCreateReady failed status=\(createStatus) — sample dropped before reaching the renderer")
            #endif
            return
        }
        audioRenderer.enqueue(sample)
        #if DEBUG
        audioEnqueueCount += 1
        #endif
    }

    /// Establishes the ONE anchor mapping audio's capture timeline to host
    /// time for this generation (see the `audioAnchor` doc comment) — never
    /// called again until `resetAudioPlayback` clears it (new packet after
    /// a reset/resync/Video-Off-only-session).  Folds in a small preroll
    /// plus, if a recent video-latency measurement exists, an automatic
    /// baseline correction so audio settles near video's real latency
    /// instead of an arbitrary fixed lead — computed once, not chased.
    private func establishAudioAnchor(captureMs: Double) {
        let now = CACurrentMediaTime()
        var lead = audioPrerollSeconds
        var baselineMs = 0.0
        if let lastVideoLatencySeconds, nowMs - lastVideoLatencyUpdatedAtWallMs < 1_000 {
            // Sanity-bounded: a video path that is itself somehow stalled
            // must not inject an enormous lead into audio's schedule.
            baselineMs = min(max(lastVideoLatencySeconds, 0), 0.3) * 1000
            lead = max(lead, baselineMs / 1000)
        }
        audioAnchor = MediaAnchor(captureMs: captureMs, hostTime: now + lead)
        #if DEBUG
        Log.info("audioTrace: anchor established captureMs=\(Int(captureMs)) leadMs=\(Int(lead * 1000)) baselineMs=\(Int(baselineMs))")
        #endif
    }

    #if DEBUG
    /// Throttled to once every ~2s of steady playback, but logs immediately
    /// whenever the inter-packet capture-time delta looks wrong (not the
    /// expected ~21.333 ms for a 1024-sample AAC-LC frame at 48 kHz) — the
    /// signal for a timestamp discontinuity or a framing bug, not ordinary
    /// jitter, since capture-time deltas are computed from the sender's own
    /// PTS and are unaffected by network timing.
    private func logAudioTimingDiagnostic(sequence: UInt32, capturedAtMs: Int64, durationMs: UInt32, byteCount: Int) {
        guard let clockOffsetMs else { return }
        let receiverCaptureMs = Double(capturedAtMs) - clockOffsetMs
        defer { lastAudioDiagnosticCaptureMs = receiverCaptureMs }
        let deltaMs = lastAudioDiagnosticCaptureMs.map { receiverCaptureMs - $0 }
        let unexpectedDelta = deltaMs.map { !(10...40).contains($0) } ?? false
        audioDiagnosticLogCounter += 1
        guard unexpectedDelta || audioDiagnosticLogCounter % 100 == 0 else { return }
        var queuedMs = 0.0
        if let anchor = audioAnchor {
            let audioDelaySeconds = Double(AVSyncOffset.audioDelayMs(for: avSyncOffsetMs)) / 1000.0
            let target = anchor.hostTime + (receiverCaptureMs - anchor.captureMs) / 1000.0 + audioDelaySeconds
            queuedMs = (target - CACurrentMediaTime()) * 1000
        }
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
        Log.info("audioTrace: seq=\(sequence) capMs=\(Int(receiverCaptureMs)) deltaMs=\(deltaText) durMs=\(durationMs) bytes=\(byteCount) queuedMs=\(Int(queuedMs)) captureToArrivalMs=\(Int(captureToArrivalMs)) captureToPlayoutMs=\(Int(captureToPlayoutMs)) enqueued=\(audioEnqueueCount)\(unexpectedDelta ? " ⚠️ unexpected delta" : "")")
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

    /// The shared AAC→PCM decoder (see `receiverAACDecoder`'s doc comment
    /// on why this is NOT `#if DEBUG`): decodes the EXACT bytes just
    /// received into PCM, using a plain `AVAudioConverter` rather than the
    /// legacy compressed-`CMSampleBuffer` path. `PCMPlaybackEngine`
    /// playback calls this every packet in production; the DEBUG-only
    /// `analyzeReceivedAACDecode` (anomaly checks + optional CAF dump)
    /// calls it as an independent validation pass regardless of which
    /// playback path is active.
    private func decodeReceivedAAC(_ payload: Data, formatDescription: CMAudioFormatDescription) -> AVAudioPCMBuffer? {
        if receiverAACDecoderFormatDescription == nil
            || !CMFormatDescriptionEqual(receiverAACDecoderFormatDescription!, otherFormatDescription: formatDescription) {
            let compressedFormat = AVAudioFormat(cmAudioFormatDescription: formatDescription)
            guard let pcmFormat = AVAudioFormat(
                    commonFormat: .pcmFormatFloat32, sampleRate: compressedFormat.sampleRate,
                    channels: compressedFormat.channelCount, interleaved: false),
                  let decoder = AVAudioConverter(from: compressedFormat, to: pcmFormat) else {
                Log.info("audioTrace: ⚠️ could not build receiver-local AAC decoder from received format description")
                return nil
            }
            receiverAACDecoder = decoder
            receiverAACDecoderFormatDescription = formatDescription
        }
        guard let decoder = receiverAACDecoder else { return nil }

        let compressed = AVAudioCompressedBuffer(
            format: decoder.inputFormat, packetCapacity: 1, maximumPacketSize: payload.count)
        payload.withUnsafeBytes { raw in
            compressed.data.copyMemory(from: raw.baseAddress!, byteCount: payload.count)
        }
        compressed.byteLength = UInt32(payload.count)
        compressed.packetCount = 1
        compressed.packetDescriptions?[0] = AudioStreamPacketDescription(
            mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(payload.count))

        guard let pcmOut = AVAudioPCMBuffer(
            pcmFormat: decoder.outputFormat, frameCapacity: 1024) else { return nil }
        var suppliedInput = false
        var error: NSError?
        let status = decoder.convert(to: pcmOut, error: &error) { _, outStatus in
            if suppliedInput { outStatus.pointee = .noDataNow; return nil }
            suppliedInput = true
            outStatus.pointee = .haveData
            return compressed
        }
        guard status == .haveData, pcmOut.floatChannelData != nil else {
            receiverDecodeAnomalyCount += 1
            Log.info("audioTrace: ⚠️ receiver-local AAC decode failed status=\(status) error=\(String(describing: error)) (anomaly #\(receiverDecodeAnomalyCount))")
            return nil
        }
        return pcmOut
    }

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

    #if DEBUG
    /// Anomaly checks + optional CAF dump over an already-decoded packet —
    /// split from the decode itself (`decodeReceivedAAC`) so the
    /// production `PCMPlaybackEngine` path can reuse the identical decode
    /// without also paying for or depending on this DEBUG-only analysis.
    private func analyzeReceivedAACDecode(_ pcmOut: AVAudioPCMBuffer) {
        guard let channelData = pcmOut.floatChannelData else { return }
        let frameLength = Int(pcmOut.frameLength)
        var hasNaNOrInf = false
        var maxAbsSample: Float = 0
        var jumpDetected = false
        let buf0 = channelData[0]
        for i in 0..<frameLength {
            let v = buf0[i]
            if v.isNaN || v.isInfinite { hasNaNOrInf = true }
            let a = abs(v)
            if a > maxAbsSample { maxAbsSample = a }
            if let last = lastReceiverDecodedSample, abs(v - last) > 1.5 { jumpDetected = true }
            lastReceiverDecodedSample = v
        }
        if hasNaNOrInf {
            receiverDecodeAnomalyCount += 1
            Log.info("audioTrace: ⚠️ receiver-local AAC decode produced NaN/Inf (anomaly #\(receiverDecodeAnomalyCount)) — reconstruction/decoder-input defect on THIS device")
        }
        if maxAbsSample >= 0.999 {
            receiverDecodeAnomalyCount += 1
            Log.info("audioTrace: ⚠️ receiver-local AAC decode near/at full-scale (\(maxAbsSample)) — possible clipping (anomaly #\(receiverDecodeAnomalyCount))")
        }
        if jumpDetected {
            receiverDecodeAnomalyCount += 1
            Log.info("audioTrace: ⚠️ receiver-local AAC decode inter-sample discontinuity at packet boundary (anomaly #\(receiverDecodeAnomalyCount))")
        }
        if receiverAACDumpEnabled { dumpReceiverDecodedPCM(pcmOut) }
    }

    /// ~5s bounded dump of the receiver-local decode above, for an actual
    /// listening A/B on-device. Path is platform-specific (see
    /// `receiverDecodeDumpDirectory`) and self-reports every step — same
    /// no-silent-failure discipline as `AudioCaptureEncoder`'s dumps on the
    /// Mac side, after that class of bug bit the PCM diagnostic once
    /// already.
    private func dumpReceiverDecodedPCM(_ pcm: AVAudioPCMBuffer) {
        guard receiverDecodeDumpFrames < Self.receiverDecodeDumpFrameLimit else { return }
        if receiverDecodeDumpFile == nil {
            let dir = Self.receiverDecodeDumpDirectory()
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            } catch {
                Log.info("audioTrace: ⚠️ could not create \(dir.path): \(error)")
                return
            }
            let url = dir.appendingPathComponent("audio-compare-received-decoded-aac.caf")
            do {
                receiverDecodeDumpFile = try AVAudioFile(forWriting: url, settings: pcm.format.settings)
                Log.info("audioTrace: opened receiver-local AAC decode dump \(url.path) — pull it from the Files app (On My iPhone/iPad → MeowDisplay) or Xcode's Devices window on iOS, or open directly on macOS")
            } catch {
                Log.info("audioTrace: ⚠️ could not open \(url.path) for writing: \(error)")
                return
            }
        }
        guard let receiverDecodeDumpFile else { return }
        do {
            try receiverDecodeDumpFile.write(from: pcm)
            receiverDecodeDumpFrames += Int(pcm.frameLength)
            if receiverDecodeDumpFrames >= Self.receiverDecodeDumpFrameLimit {
                Log.info("audioTrace: audio-compare-received-decoded-aac.caf reached \(receiverDecodeDumpFrames) frames — finalizing")
                finalizeReceiverDecodeDump()
            }
        } catch {
            Log.info("audioTrace: ⚠️ audio-compare-received-decoded-aac.caf write failed: \(error)")
        }
    }

    private func finalizeReceiverDecodeDump() {
        if let receiverDecodeDumpFile {
            Log.info("audioTrace: finalized \(receiverDecodeDumpFile.url.lastPathComponent) frames=\(receiverDecodeDumpFrames)")
        }
        receiverDecodeDumpFile = nil
        receiverDecodeDumpFrames = 0
    }

    /// iOS: the app's own Documents directory, so the dump is reachable
    /// from the Files app (On My iPhone/iPad → MeowDisplay) without Xcode.
    /// macOS (the `OpenSidecarMacReceiver` test target): the same
    /// `Log.directory` the Mac sender's dumps already use, for one
    /// consistent place to look.
    private static func receiverDecodeDumpDirectory() -> URL {
        #if os(iOS)
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        #else
        return Log.directory
        #endif
    }

    /// Anomaly-only (GOAL section 7 "RECEIVER"): the renderer's playout
    /// schedule must be monotonic — a packet scheduled to play before the
    /// previous one means an anchor/offset computation went backwards,
    /// which would sound like a stutter/glitch right at that instant.
    private func checkNonMonotonicTarget(_ target: CFTimeInterval) {
        defer { lastAudioTarget = target }
        if let lastAudioTarget, target < lastAudioTarget {
            Log.info("audioTrace: ⚠️ non-monotonic audio playout target \(target) < previous \(lastAudioTarget)")
        }
    }
    #endif

    private func buildFormatDescription(sps: Data, pps: Data) {
        sps.withUnsafeBytes { spsBuf in
            pps.withUnsafeBytes { ppsBuf in
                let ptrs: [UnsafePointer<UInt8>] = [
                    spsBuf.bindMemory(to: UInt8.self).baseAddress!,
                    ppsBuf.bindMemory(to: UInt8.self).baseAddress!
                ]
                let sizes = [sps.count, pps.count]
                let status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: 2,
                    parameterSetPointers: ptrs,
                    parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &formatDesc
                )
                if status == noErr, let formatDesc {
                    let dims = CMVideoFormatDescriptionGetDimensions(formatDesc)
                    Log.info("format description built: \(dims.width)x\(dims.height)")
                    DispatchQueue.main.async {
                        self.videoSize = CGSize(width: Int(dims.width), height: Int(dims.height))
                    }
                    setStatus("Receiving \(dims.width)×\(dims.height)")
                } else {
                    Log.info("format description FAILED: \(status)")
                }
            }
        }
    }

    private func enqueueFrame(_ nalus: [Data], captureMs: Double? = nil, sendMs: Double? = nil) {
        guard let formatDesc else { return }
        // Backgrounded linger: hardware decode is off-limits there, so drop
        // frames at the door instead of feeding a failing display layer at
        // frame rate. setRenderingPaused(false) re-syncs with a keyframe.
        if renderingPaused { return }

        // Build one AVCC buffer: each NALU prefixed with 4-byte big-endian length.
        var avcc = Data(capacity: nalus.reduce(0) { $0 + $1.count + 4 })
        for nalu in nalus {
            var len = UInt32(nalu.count).bigEndian
            avcc.append(Data(bytes: &len, count: 4))
            avcc.append(nalu)
        }

        // Allocate a block buffer that OWNS its memory and copy the bytes in —
        // referencing a transient Swift buffer here is a use-after-free.
        var blockBuffer: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault,
                memoryBlock: nil,                   // let CoreMedia allocate
                blockLength: avcc.count,
                blockAllocator: kCFAllocatorDefault,
                customBlockSource: nil, offsetToData: 0,
                dataLength: avcc.count, flags: 0,
                blockBufferOut: &blockBuffer) == noErr,
              let blockBuffer else { return }
        let copyStatus = avcc.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(
                with: raw.baseAddress!, blockBuffer: blockBuffer,
                offsetIntoDestination: 0, dataLength: avcc.count)
        }
        guard copyStatus == noErr else { return }

        var sample: CMSampleBuffer?
        var sizeArr = [avcc.count]
        CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDesc,
            sampleCount: 1,
            sampleTimingEntryCount: 0, sampleTimingArray: nil,
            sampleSizeEntryCount: 1, sampleSizeArray: &sizeArr,
            sampleBufferOut: &sample)

        guard let sample else { return }

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
        let scheduledVideoGeneration = videoGeneration
        let present = { [weak self] in
            guard let self, self.videoGeneration == scheduledVideoGeneration else { return }
            if self.useMetalPath, self.onDecodedFrame != nil {
                self.decodeAndRender(sample, captureMs: captureMs)
            } else {
                // Display immediately: low latency, no PTS scheduling.
                if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
                   CFArrayGetCount(attachments) > 0 {
                    let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
                    CFDictionarySetValue(dict,
                        Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                        Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
                }

                if self.displayLayer.status == .failed {
                    Log.info("display layer failed (\(String(describing: self.displayLayer.error))) — flushing")
                    self.decodeFlushes += 1
                    self.displayLayer.flush()
                }
                self.displayLayer.enqueue(sample)
            }
        }
        // A/V Sync: negative offset delays video by holding this specific,
        // already-decoded-or-decodable frame — a genuine per-frame
        // presentation delay, not a sleep on the network/decode path. The
        // delay is constant across frames, so arrival order is preserved.
        let videoDelayMs = AVSyncOffset.videoDelayMs(for: avSyncOffsetMs)
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
            if let offset = clockOffsetMs {
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
            stats.decodeFlushes = decodeFlushes
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
            stats.decodeP50 = percentile(decodeWindow, 0.5)
            stats.photonP50 = percentile(photonWindow, 0.5)
            stats.photonP95 = percentile(photonWindow, 0.95)
            framesThisWindow = 0
            bytesThisWindow = 0
            stallsThisWindow = 0
            cursorUpdatesThisWindow = 0
            cursorLostThisWindow = 0
            fpsWindowStart = now

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
                    "offsetKnown": clockOffsetMs != nil,
                ])
                e2eWindow.removeAll(keepingCapacity: true)
                encodeWindow.removeAll(keepingCapacity: true)
                decodeWindow.removeAll(keepingCapacity: true)
                photonWindow.removeAll(keepingCapacity: true)
            }

            DispatchQueue.main.async {
                self.fps = fps
                self.perf = stats
            }
        }
    }

    // MARK: - Explicit decode (Metal renderer path)

    private func ensureDecompressionSession() {
        guard let formatDesc else { return }
        if let session = decompressionSession {
            if VTDecompressionSessionCanAcceptFormatDescription(session, formatDescription: formatDesc) {
                return
            }
            VTDecompressionSessionInvalidate(session)
            decompressionSession = nil
        }
        // NV12: the decoder's native output — BGRA would add a conversion
        // pass inside VideoToolbox (measured ~7ms); the YUV→RGB happens in
        // the renderer's fragment shader instead (~free).
        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        var session: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: nil, formatDescription: formatDesc, decoderSpecification: nil,
            imageBufferAttributes: attrs as CFDictionary, outputCallback: nil,
            decompressionSessionOut: &session)
        if status != noErr { Log.info("VTDecompressionSessionCreate failed: \(status)") }
        decompressionSession = session
    }

    /// Synchronous hardware decode — the handler runs before this returns,
    /// so blocking in the renderer (nextDrawable) is our frame pacing.
    private func decodeAndRender(_ sample: CMSampleBuffer, captureMs: Double?) {
        ensureDecompressionSession()
        guard let session = decompressionSession else { return }
        let t0 = nowMs
        let status = VTDecompressionSessionDecodeFrame(
            session, sampleBuffer: sample, flags: [], infoFlagsOut: nil
        ) { [weak self] status, _, imageBuffer, _, _ in
            guard let self else { return }
            if status == noErr, let imageBuffer {
                self.decodeWindow.append(self.nowMs - t0)
                self.onDecodedFrame?(imageBuffer, captureMs)
            } else {
                if self.decodeErrorCount % 60 == 0 {
                    Log.info("decode output error: \(status) imageBuffer=\(imageBuffer != nil)")
                }
                self.decodeErrorCount += 1
                // Joined mid-GOP (e.g. the renderer attached after the
                // connect-time IDR, and periodic keyframes are off) — ask
                // the Mac for a fresh sync point.
                self.requestKeyframeIfNeeded()
            }
        }
        if status != noErr {
            decodeFlushes += 1
            decodeErrorCount += 1
            if decodeErrorCount % 60 == 1 {
                Log.info("decode call error: \(status) (\(decodeErrorCount) total)")
            }
            requestKeyframeIfNeeded()
        }
    }

    private var lastKeyframeRequest = Date.distantPast
    private func requestKeyframeIfNeeded() {
        guard Date().timeIntervalSince(lastKeyframeRequest) > 1 else { return }
        lastKeyframeRequest = Date()
        Log.info("requesting keyframe (decoder needs sync)")
        sendControl(["type": "kf"])
    }

    private func percentile(_ values: [Double], _ p: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let idx = min(sorted.count - 1, Int(Double(sorted.count) * p))
        return sorted[idx]
    }

    // MARK: - Session state + automatic recovery

    /// Apply one transition to the authoritative session state, log it if it
    /// actually changed anything, mirror it to the UI, and let the recovery
    /// driver react. Must run on `queue`.
    private func mutateSession(_ transition: (inout ReceiverSessionState) -> Bool) {
        let previous = sessionState.phase
        let changed = transition(&sessionState)
        let snapshot = sessionState
        DispatchQueue.main.async { self.session = snapshot }
        guard changed else { return }
        #if DEBUG
        Log.info("sessionState: \(previous.rawValue) -> \(snapshot.phase.rawValue)"
                 + " reason=\(snapshot.lossReason?.rawValue ?? "none")"
                 + " generation=\(snapshot.generation)"
                 + " attempt=\(snapshot.reconnectAttempt)"
                 + " transport=\(transport)")
        #else
        Log.info("sessionState: \(previous.rawValue) -> \(snapshot.phase.rawValue)"
                 + " reason=\(snapshot.lossReason?.rawValue ?? "none")")
        #endif
        if snapshot.phase == .reconnecting {
            armReconnect()
        } else {
            cancelReconnect()
        }
    }

    private func cancelReconnect() {
        reconnectTimer?.cancel()
        reconnectTimer = nil
    }

    /// Auto-Reconnect turned off mid-recovery: settle into the stable
    /// "Connection Lost" state immediately rather than let an already-
    /// scheduled automatic attempt keep retrying behind the user's back.
    /// Manual Reconnect remains available from here, exactly as after normal
    /// attempt exhaustion. Must run on `queue`.
    private func cancelAutomaticRecoveryIfNeeded() {
        guard sessionState.phase == .reconnecting else { return }
        Log.info("reconnectPolicy: automaticRetry cancelled reason=disabled")
        mutateSession { $0.exhaustRecovery() }
        setStatus("Connection lost")
    }

    /// One automatic recovery step. The Mac is the dialing side (it runs its
    /// own bounded redial loop), so all this side can act on is its own
    /// listening half — re-arm it if it is unhealthy and wait out the
    /// backoff window. Never starts a second attempt or a second timer.
    private func armReconnect() {
        cancelReconnect()
        guard sessionState.phase == .reconnecting else { return }
        let delay = sessionState.nextReconnectDelay
        guard let attempt = sessionState.beginReconnectAttempt() else {
            mutateSession { $0.exhaustRecovery() }
            Log.info("reconnectDebug: retryExhausted generation=\(sessionState.generation)")
            setStatus("Connection lost")
            return
        }
        let generation = sessionState.generation
        let snapshot = sessionState   // never read queue-confined state off-queue
        DispatchQueue.main.async { self.session = snapshot }
        Log.info("reconnect attempt \(attempt)/\(ReceiverSessionState.maximumReconnectAttempts)"
                 + " generation=\(generation) in \(delay)s")
        Log.info("reconnectDebug: attemptStarted generation=\(generation) attempt=\(attempt) delay=\(delay)")
        setStatus("Reconnecting…")
        ensureTLSListening()
        if !listenerHealthy { restartListener() }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + delay)
        timer.setEventHandler { [weak self] in
            guard let self, self.sessionState.generation == generation else { return }
            _ = self.sessionState.endReconnectAttempt()
            self.armReconnect()
        }
        timer.resume()
        reconnectTimer = timer
        Log.info("reconnectDebug: retryScheduled generation=\(generation) in \(delay)s")
    }

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
        queue.async {
            Log.info("connectDebug: receiverConnectRequest peer=local")
            self.cancelReconnect()
            self.peerIsIncompatible = false
            self.mutateSession { $0.requestManualReconnect() }
            self.ensureTLSListening()
            self.restartListener()
            self.signalConnectRequest()
        }
    }

    /// Publishes a fresh one-shot token in the advertised TXT record, then
    /// clears it after a short window so a stale token can't re-trigger a
    /// connect on a later, unrelated browse update.
    private func signalConnectRequest() {
        let token = UUID().uuidString
        connectRequestToken = token
        connectRequestClearWorkItem?.cancel()
        if let tlsListener { tlsListener.service = advertisedService }
        let clear = DispatchWorkItem { [weak self] in
            guard let self, self.connectRequestToken == token else { return }
            self.connectRequestToken = nil
            if let tlsListener = self.tlsListener { tlsListener.service = self.advertisedService }
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
        queue.async { self.signalConnectRequest() }
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
        requestConnect()
        guard RemoteEndpointStore.endpoint(forPeerID: peerID) != nil else { return }
        requestRemoteConnect(peerID: peerID)
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
        guard let hint = RemoteEndpointStore.endpoint(forPeerID: peerID),
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
        queue.async {
            guard self.sessionState.phase == .reconnectFailed
                    || self.sessionState.phase == .disconnected else { return }
            Log.info("manual reconnect requested")
            self.cancelReconnect()
            self.peerIsIncompatible = false
            self.mutateSession { $0.requestManualReconnect() }
            // A manual retry always rebuilds the listening side, healthy or
            // not: "I pressed the button and nothing visibly happened" is
            // the failure mode worth spending one rebind on.
            self.restartListener()
        }
    }

    /// iOS is suspending us: recovery cannot run, so park the run instead of
    /// burning its budget against a radio we do not have.
    private func suspendReconnectForBackground() {
        cancelReconnect()
        // Deliberately not through `mutateSession`: the phase is unchanged
        // (still reconnecting), and its reactive arm would immediately
        // schedule the very attempt this is parking.
        guard sessionState.suspendRecoveryForBackground() else { return }
        Log.info("sessionState: recovery parked for background"
                 + " generation=\(sessionState.generation)"
                 + " attempt=\(sessionState.reconnectAttempt)")
        let snapshot = sessionState
        DispatchQueue.main.async { self.session = snapshot }
    }

    /// Foregrounding: resume a parked recovery run from where it stopped.
    private func resumeReconnectIfNeeded() {
        guard sessionState.phase == .reconnecting, reconnectTimer == nil else { return }
        armReconnect()
    }

    // MARK: - Helpers

    private func setStatus(_ text: String) {
        Log.info("status: \(text)")
        DispatchQueue.main.async { self.status = text }
    }

    /// The single funnel for connection up/down. `reason` classifies a loss
    /// so the session state can tell an interruption worth recovering from
    /// apart from a deliberate end — see `ReceiverSessionLossReason`.
    private func setConnected(_ value: Bool,
                              reason: ReceiverSessionLossReason = .transportLost) {
        DispatchQueue.main.async {
            self.connected = value
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
            }
        }
        if !value {
            let oldGeneration = sessionState.generation
            transport = "—"
            // A peer that already told us the two apps are incompatible must
            // not be retried; every other loss is transport-shaped.
            let classified: ReceiverSessionLossReason = {
                guard peerIsIncompatible, reason == .transportLost else { return reason }
                return .protocolIncompatible
            }()
            let wasConnected = sessionState.phase == .connected
                || sessionState.phase == .paused
            Log.info("reconnectDebug: lost reason=\(classified.rawValue) oldGeneration=\(oldGeneration)")
            mutateSession { $0.connectionLost(reason: classified,
                                              autoReconnectPreferenceEnabled: autoReconnectEnabled) }
            if sessionState.phase != .reconnecting {
                setStatus(wasConnected && classified != .explicitDisconnect
            ? "Connection lost" : "Waiting for Mac")
            }
        }
        else {
            peerIsIncompatible = false
            mutateSession { $0.connectionEstablished() }
            Log.info("reconnectDebug: authenticated generation=\(sessionState.generation)")
            setStatus("Connected · \(transport)")
            // Remember the first ever successful connection to a Mac so the
            // first-run onboarding hint never reappears (issue #49).
            if !UserDefaults.standard.bool(forKey: "hasConnectedBefore") {
                UserDefaults.standard.set(true, forKey: "hasConnectedBefore")
            }
        }
    }
}
