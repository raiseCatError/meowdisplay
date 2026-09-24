import Foundation
import Network
import CoreGraphics

/// Receiver Swift6-B1: the MainActor-facing publication proxy for the
/// narrow subset of `StreamReceiver`'s own UI-facing state that a
/// `@Sendable` coordinator (`ReceiverPipelineActor`, via its `UIEffects`)
/// needs to publish across an isolation boundary without capturing
/// non-Sendable `StreamReceiver` to do it.
///
/// Unlike `MacSender`/`MacSenderStatusSink` — where the sink is itself the
/// authoritative store for callback-shaped UI state external code
/// subscribes to — `StreamReceiver` IS the `ObservableObject` SwiftUI views
/// bind to directly (`status`, `session`, ... stay `@Published` on
/// `StreamReceiver`; moving that storage here would change every existing
/// view-binding call site, which B1 explicitly does not do). This sink is
/// therefore a thin, one-way WRITE proxy: it holds a `weak` reference back
/// to the `StreamReceiver` whose properties it publishes into (never
/// strong — see `StreamReceiver.init`, which hands this sink `self` weakly
/// right after construction) and every method here does exactly one
/// publish, never a read-back, never a policy decision, never anything
/// `StreamReceiver`'s own internal call sites still do directly (most
/// `setStatus`/session-snapshot call sites are ordinary method calls inside
/// `StreamReceiver` itself, with no `@Sendable` closure involved, and are
/// untouched by this — see that file's B1 audit).
///
/// Because `target` is only ever touched while isolated to `MainActor`, this
/// type can conform to `Sendable` for real (not `@unchecked`) — same
/// reasoning as `MacSenderStatusSink`.
@MainActor
final class ReceiverUISink: Sendable {
    /// Weak by design: this sink must never extend `StreamReceiver`'s
    /// lifetime. `StreamReceiver` owns it via a strong `let` property and
    /// assigns this once, right after `init` completes (see
    /// `StreamReceiver.init`'s existing `Task { @MainActor ... }` block).
    weak var target: StreamReceiver?

    /// `nonisolated` so `StreamReceiver`'s own (non-MainActor) init can
    /// create one without an `await` — safe because it only leaves `target`
    /// at its default `nil`, which needs no actor isolation to write once
    /// at construction (same convention as `MacSenderStatusSink.init`).
    nonisolated init() {}

    /// Mirrors `StreamReceiver.setStatus(_:)` (log, then publish) for the
    /// one boundary crossing that used to need a `@Sendable` closure
    /// capturing `self` to reach it: `ReceiverPipelineActor.UIEffects.
    /// setStatus`. `StreamReceiver`'s many other, ordinary-method-call
    /// sites keep calling `setStatus(_:)` directly — untouched by B1.
    func publishStatus(_ text: String) {
        Log.info("status: \(text)")
        target?.status = text
    }

    /// Mirrors `StreamReceiver.publishSessionSnapshot(_:)` for the same
    /// single boundary crossing (`UIEffects.publishSessionSnapshot`).
    func publishSessionSnapshot(_ snapshot: ReceiverSessionState) {
        target?.applyUISessionSnapshot(snapshot)
    }

    /// Mirrors `StreamReceiver.applyConnectedUIMirror(_:)` for the same
    /// single boundary crossing (`UIEffects.applyConnectedUIMirror`) — the
    /// UI-mirror-only fields that reset when a connection drops, distinct
    /// from the `reconnectContext` host-state clear that stays on the
    /// pipeline side of that boundary.
    func publishConnectedUIMirror(_ value: Bool) {
        target?.applyConnectedUIMirrorFields(value)
    }

    /// Mirrors the `videoSize` publish half of `StreamReceiver`'s
    /// `codecConfigurationChanged` output effect — the other single boundary
    /// crossing this sink exists for, alongside `publishStatus` (used for
    /// the accompanying "Receiving WxH" text). UI-only: writes only the
    /// already-`@MainActor` `videoSize` field, no read-back, no policy.
    func publishVideoSize(_ size: CGSize) {
        target?.videoSize = size
    }

    /// Mirrors the UI-publish half of the former
    /// `onConnectionReadyHostWork` — the one boundary crossing that method
    /// needed `self` for, now that its other work (`reconnectContext`,
    /// `framePipeline.syncState`, `transportState`) runs through directly
    /// captured owners in `makePipelineHostEffects()`. UI-only: writes only
    /// the already-`@MainActor` `authenticatedPeerID` field via the
    /// existing `private(set)` setter, no read-back, no policy, no
    /// reconnect/network behavior.
    func publishAuthenticatedPeerID(_ peerID: String?) {
        target?.applyAuthenticatedPeerIDUpdate(peerID)
    }

    /// The UI-publish half of `startMacPairingBrowser`'s
    /// `browseResultsChangedHandler` — discovery results are UI-facing
    /// state (see `StreamReceiver.discoveredMacs`'s doc), so this is the
    /// same one-way, immutable-payload-in, `@MainActor`-only shape as
    /// `publishVideoSize` above, reached from the browser callback's
    /// existing `DispatchQueue.main.async` hop instead of a `weak self`
    /// capture.
    func publishDiscoveredMacs(_ results: [NWBrowser.Result]) {
        target?.applyDiscoveredMacsUpdate(results)
    }

    /// Mirrors `StreamReceiver.notePairingSucceeded()` for the pairing
    /// listener's `newConnectionHandler`/nested `Task` (Receiver
    /// Swift6-Pairing-Listener) — the one boundary crossing that closure
    /// graph needed `self` for. UI-only: bumps the already-`@MainActor`
    /// `pairingSuccessCount` via the existing `private(set)` setter, no
    /// read-back, no policy.
    func publishPairingSucceeded() {
        target?.applyPairingSucceededUpdate()
    }

    /// The combined UI-reset half of `StreamReceiver.disconnect(_:)`/
    /// `closeSession(...)`'s teardown completion — display mode, extend
    /// shape, max FPS, status, and `displayState`/`onDisplayStateChange` all
    /// reset together, once `pipeline.disconnectCurrentConnection` has been
    /// awaited. Bundled as one boundary crossing (rather than one method
    /// per mirror) because both call sites always fire this exact group
    /// together, differing only in `status`; this replaces the `self`
    /// capture the group previously needed to reach `resetDisplayModeState`/
    /// `resetExtendShapeState`/`resetMaxFPSState`/`setStatus`/
    /// `publishDisplayState` from inside a `queue.async` continuation
    /// nested in a `Task`.
    func publishTeardownUIReset(status: String) {
        target?.applyTeardownUIReset(status: status)
    }

    // MARK: - Cluster A: handleVideoChannelJSON / queue-side UI mirrors
    //
    // Everything below replaces a `publishToUI { self... }` call site that
    // used to capture non-Sendable `StreamReceiver` directly. Each method
    // takes only Sendable payloads and forwards to a matching `apply*`
    // method on `StreamReceiver`, mirroring the shape of the methods above.

    func publishLastForgottenPeerID(_ peerID: String) {
        target?.applyLastForgottenPeerIDUpdate(peerID)
    }

    func publishCursorReset() {
        target?.applyCursorReset()
    }

    func publishCursorPosition(x: Double, y: Double, visible: Bool) {
        target?.applyCursorPositionUpdate(x: x, y: y, visible: visible)
    }

    func publishCursorSprite(image: CGImage, anchor: CGPoint, normSize: CGSize) {
        target?.applyCursorSpriteUpdate(image: image, anchor: anchor, normSize: normSize)
    }

    func publishConfirmedDisplayMode(_ mode: ReceiverDisplayMode) {
        target?.applyConfirmedDisplayMode(mode)
    }

    func publishMirrorAvailabilitySignal() {
        target?.applyMirrorAvailabilitySignal()
    }

    func publishMirrorDisplayState(_ update: MirrorDisplayStateUpdate) {
        target?.applyMirrorDisplayStateUpdate(update)
    }

    func publishConfirmedExtendShape(_ preference: ExtendDisplayShapePreference) {
        target?.applyConfirmedExtendShape(preference)
    }

    func publishStreamingProfile(_ profile: StreamingProfile) {
        target?.applyStreamingProfileUpdate(profile)
    }

    func publishStreamingPriority(_ priority: StreamingPriority) {
        target?.applyStreamingPriorityUpdate(priority)
    }

    func publishConfirmedMaxFPS(_ update: MaxFPSStateUpdate) {
        target?.applyConfirmedMaxFPS(update)
    }

    func publishMacProtocolVersion(_ macPV: Int) {
        target?.applyMacProtocolVersionUpdate(macPV)
    }

    func publishPeerSignal(_ signal: PeerUpdateSignal) {
        target?.applyPeerSignalUpdate(signal)
    }

    func publishAudioEnabled(_ enabled: Bool) {
        target?.applyAudioEnabledUpdate(enabled)
    }

    func publishPromoteInteractiveWakeResult(_ text: String) {
        target?.applyPromoteInteractiveWakeResultUpdate(text)
    }

    func publishReceiverUIPreferences(_ update: ReceiverUIPreferenceUpdate) {
        target?.applyReceiverUIPreferencesUpdate(update)
    }

    func publishSmartTouchProbeResult(id: Int, scrollable: Bool) {
        target?.applySmartTouchProbeResult(id: id, scrollable: scrollable)
    }

    func publishInputResetBump() {
        target?.applyInputResetBump()
    }

    func publishAllowInputStateChange(_ state: SessionInputWireState) {
        target?.applyAllowInputStateChangeUpdate(state)
    }

    func publishVideoState(width: Int?, height: Int?, enabled: Bool) {
        target?.applyVideoStateUpdate(width: width, height: height, enabled: enabled)
    }

    func publishActiveStreamCodec(_ codec: StreamCodec) {
        target?.applyActiveStreamCodecUpdate(codec)
    }

    func publishMirrorUnavailableClear() {
        target?.applyMirrorUnavailableClear()
    }

    func publishMirrorRejectionClear() {
        target?.applyMirrorRejectionClear()
    }

    func publishDisplayModeStateReset() {
        target?.applyDisplayModeStateReset()
    }

    func publishExtendShapeStateReset() {
        target?.applyExtendShapeStateReset()
    }

    func publishMaxFPSStateReset() {
        target?.applyMaxFPSStateReset()
    }

    func publishPerf(fps: Int, perf: PerfStats) {
        target?.applyPerfUpdate(fps: fps, perf: perf)
    }

    func publishDisplayState(_ state: DisplayState) {
        target?.applyDisplayStateUpdate(state)
    }
}
