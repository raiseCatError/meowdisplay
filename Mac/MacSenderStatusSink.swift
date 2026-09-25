import Foundation

// MacSenderStatusSink — owns the MainActor-facing status/lifecycle callbacks
// that `MacSender` exposes to its controller/UI (`onStatus`, `onStats`,
// `onMediaState`, `onCaptureLifecycleChanged`, `onDisconnected`,
// `onPeerSleeping`, `onPeerClosed`, `onTransportPath`,
// `onCaptureStoppedByUser`).
//
// These are pure one-way broadcasts: `MacSender` computes a value on `queue`
// (or another background callback thread), hops to MainActor, and fires the
// closure — nothing reads back into `MacSender`'s queue-owned state to do
// so. Before this extraction, every one of those hops was
// `Task { @MainActor in self.onX?(value) } }`, which captures non-Sendable
// `MacSender` itself into a `@Sendable` closure purely to reach a callback
// property that isolation already guarantees is MainActor-only — that's
// what drove a large share of MacSender's strict-concurrency warnings.
//
// Because every stored property here is only ever touched while isolated to
// `MainActor`, the type can conform to `Sendable` for real (not
// `@unchecked`): the compiler verifies there is no unprotected mutable state
// crossing an isolation boundary. Callers reach it by capturing the sink
// itself (a genuinely Sendable reference) instead of `self`.
@MainActor
final class MacSenderStatusSink: Sendable {
    // Status surfaced to the UI (updated on main thread).
    var onStatus: ((String) -> Void)?
    var onStats: ((Int, Double) -> Void)?   // framesSent, mbps
    // Refreshed on the same ~1s cadence as onStats: this session's current
    // video/audio activity and capture geometry, for the canonical runtime
    // projection (Overview / Active Display / menu bar all read from the
    // one place this feeds — DeviceSession — rather than re-deriving it).
    var onMediaState: ((_ videoActive: Bool, _ audioActive: Bool,
                         _ width: Int, _ height: Int, _ fps: Int) -> Void)?
    var onCaptureLifecycleChanged: ((CaptureLifecyclePhase) -> Void)?
    // Fired when a previously connected device stays gone past the grace
    // period — the controller ends the session (capture, virtual display,
    // recording indicator all torn down) instead of dialing forever or
    // silently coming back over a different transport.
    var onDisconnected: (() -> Void)?
    // Fired when the receiver announces its device locked. The controller
    // ends this session — an invisible display strands the cursor — and
    // starts a fresh one that waits for the wake.
    var onPeerSleeping: (() -> Void)?
    // Fired when the receiver announces the app is quitting: deliberate,
    // so the controller ends the session without arming a reconnect.
    var onPeerClosed: (() -> Void)?
    // Fired when an established connection's actual Network.framework path
    // changes. Nil while disconnected; the UI never infers a route from the
    // requested target.
    var onTransportPath: ((ConnectionRoute?) -> Void)?
    // Fired when the user stopped the capture from the system UI (menu-bar
    // recording indicator / "Stop Extending"). The controller disconnects
    // the session — teardown plus auto-connect opt-out — so the app honors
    // the stop instead of fighting it.
    var onCaptureStoppedByUser: (() -> Void)?
    // Fires whenever this peer's Extend shape preference changes — from a
    // receiver's `extendShapeRequest` or from `requestExtendShape` (the
    // Mac's own per-device Settings control). Unlike Mirror/mode/streaming
    // profile, Extend shape is genuinely per-peer, so `MacSender` applies
    // and persists it directly rather than bubbling up to
    // `SenderController`; this callback only lets the UI mirror the current
    // value onto `DeviceSession` for display.
    var onExtendShapeChanged: ((ExtendDisplayShapePreference) -> Void)?
    var onMaxFPSChanged: ((ReceiverMaxFPSPreference) -> Void)?
    /// Fires whenever this session's own ephemeral input grant changes —
    /// purely so `DeviceSession` can mirror it for display
    /// (`ReceiverDeviceDetailView`'s "Current session" row). The
    /// authoritative bit lives in `sessionInputGrant`, not here.
    var onSessionInputGrantChanged: ((Bool) -> Void)?
    /// Session-invitation negotiation progress (pv 21) — see
    /// `MacSender.awaitSessionAdmission`.
    var onInvitationProgress: ((SessionInvitationProgress) -> Void)?
    // Fired when the device's display identity had to be abandoned (macOS
    // saved hostile state for it — see setupExtend) and a bumped identity
    // came online instead: carries the validated TOTAL offset from the
    // device's base identity, for the controller to store as-is. Absolute,
    // not a delta — repeated bumps in one session must not accumulate into
    // an offset nothing ever validated.
    var onDisplayIdentityBumped: ((UInt32) -> Void)?

    // `nonisolated` so `MacSender`'s own (non-MainActor) init can create one
    // without an `await` — safe because it only assigns the optionals to
    // nil, none of which needs actor isolation to write once at construction.
    nonisolated init() {}

    func publishStatus(_ text: String) {
        onStatus?(text)
    }

    func publishStats(frames: Int, mbps: Double) {
        onStats?(frames, mbps)
    }

    func publishMediaState(videoActive: Bool, audioActive: Bool, width: Int, height: Int, fps: Int) {
        onMediaState?(videoActive, audioActive, width, height, fps)
    }

    func publishCaptureLifecycleChanged(_ phase: CaptureLifecyclePhase) {
        onCaptureLifecycleChanged?(phase)
    }

    func publishDisconnected() {
        onDisconnected?()
    }

    func publishPeerSleeping() {
        onPeerSleeping?()
    }

    func publishPeerClosed() {
        onPeerClosed?()
    }

    func publishTransportPath(_ route: ConnectionRoute?) {
        onTransportPath?(route)
    }

    func publishCaptureStoppedByUser() {
        onCaptureStoppedByUser?()
    }

    func publishExtendShapeChanged(_ preference: ExtendDisplayShapePreference) {
        onExtendShapeChanged?(preference)
    }

    func publishMaxFPSChanged(_ preference: ReceiverMaxFPSPreference) {
        onMaxFPSChanged?(preference)
    }

    func publishInvitationProgress(_ progress: SessionInvitationProgress) {
        onInvitationProgress?(progress)
    }

    func publishSessionInputGrantChanged(_ granted: Bool) {
        onSessionInputGrantChanged?(granted)
    }

    func publishDisplayIdentityBumped(_ totalOffset: UInt32) {
        onDisplayIdentityBumped?(totalOffset)
    }
}
