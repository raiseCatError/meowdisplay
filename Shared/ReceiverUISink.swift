import Foundation

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
}
