import Foundation

/// Pure decision logic for the headless-Mirror "Use Extend?" offer
/// (`WireMessage.mirrorUnavailable`) — kept separate from `MacSender`'s
/// networking/async-wait glue (`offerExtendOrFailMirror`) and from
/// `StreamReceiver`'s hello/advertisement code so the actual decisions are
/// testable without ScreenCaptureKit/AVFoundation. Lives in `Shared/`
/// (not `Mac/`) because both the sender's offer decision and the
/// receiver's advertised-capability decision use it. See PROTOCOL.md's
/// `mirrorUnavailable` section for the wire contract.
enum MirrorUnavailableOfferPolicy {
    /// Whether the Mac should offer Extend instead of failing Mirror
    /// immediately: only when there is truly no usable physical display AND
    /// the receiver's protocol version advertises understanding the offer.
    /// An older receiver always gets today's existing clean failure instead
    /// of sitting on a prompt it cannot show.
    static func shouldOffer(hasUsablePhysicalDisplay: Bool, receiverProtocolVersion: Int) -> Bool {
        !hasUsablePhysicalDisplay && receiverProtocolVersion >= WireProtocol.mirrorUnavailableWireVersion
    }

    /// Whether a previously-sent offer is still the one this poll iteration
    /// (or the eventual timeout) is entitled to act on. False once the
    /// authenticated session that owns it is no longer live (disconnect,
    /// Forget, route migration, a newer session) or its generation no
    /// longer matches (already superseded/cleared). A physical display
    /// reappearing does NOT by itself invalidate a pending offer — only
    /// these do; the receiver's eventual "Use Extend" tap is always
    /// honored through the existing, independent `displayModeRequest` path
    /// regardless of what the physical topology looks like by then.
    static func isOfferStillPending(
        offerGeneration: UInt64?, sessionGeneration: UInt64, sessionIsLive: Bool
    ) -> Bool {
        sessionIsLive && offerGeneration == sessionGeneration
    }

    /// Which protocol version a receiver should actually advertise in
    /// `hello`/its Bonjour TXT records: capped just below
    /// `mirrorUnavailableWireVersion` for a platform that cannot present
    /// the offer at all — a receiver advertising a `pv` MUST actually be
    /// able to handle everything that version implies. MacReceiver (the
    /// macOS "use a spare Mac as a display" app) has no display-mode UI
    /// whatsoever, so it cannot show the "Use Extend?" prompt; iOS/iPadOS
    /// can and do. `deviceKind` is the same `"hello.device"` discriminator
    /// (`"Mac"` vs. `"iPhone"`/`"iPad"`) already used elsewhere. Raise this
    /// the moment MacReceiver gets that UI — pv 17 introduces nothing else
    /// today, so this has no other effect in the meantime.
    static func advertisedProtocolVersion(deviceKind: String, latestVersion: Int) -> Int {
        deviceKind == "Mac" ? min(latestVersion, WireProtocol.mirrorUnavailableWireVersion - 1) : latestVersion
    }

    /// Whether the Mac may enter Mirror mode at all right now — the single
    /// authoritative gate `SenderController.requestMode` consults for BOTH
    /// a Mac-local mode change and a receiver's `displayModeRequest(.mirror)`,
    /// live-checked (never from a cached UI signal) so a stale/racing
    /// request can never push the Mac into an impossible Mirror state.
    /// Extend has no such requirement — it is always allowed. Not a
    /// permanent gate: the moment a usable physical display returns, this
    /// simply evaluates true again on the very next request.
    static func canEnterMirror(hasUsablePhysicalDisplay: Bool) -> Bool {
        hasUsablePhysicalDisplay
    }
}
