import Foundation

/// Tracks consecutive "physical display usable" poll samples so a
/// transient blip during wake/lid/topology churn cannot prematurely cancel
/// a pending Mirror-unavailable offer and resume Mirror against a display
/// that isn't actually stably back. Pure counter, fed one sample per poll
/// tick — kept separate from `MacSender`'s networking/wait glue so the
/// debounce itself is unit-testable.
struct DisplayStabilityTracker: Equatable {
    private(set) var consecutiveUsableSamples = 0

    /// Consecutive usable samples required before treating the display as
    /// stably back. At the existing ~500ms poll cadence this covers
    /// "roughly 1 second" per the product requirement.
    static let requiredConsecutiveSamples = 2

    /// Feeds one sample; returns whether the display should now be treated
    /// as stably usable. Any unusable sample resets the streak immediately
    /// — there is no partial credit across a blip.
    mutating func recordSample(usable: Bool) -> Bool {
        consecutiveUsableSamples = usable ? consecutiveUsableSamples + 1 : 0
        return consecutiveUsableSamples >= Self.requiredConsecutiveSamples
    }
}

/// A capture start that finds no display right after a sleep or a network
/// wake (#255): the display is usually asleep or still coming up, not gone.
/// Asks once for it to be woken, then polls a bounded number of times.
/// Pure sequencing — the caller supplies the wake call, the probe and the
/// pause — so the order and the bounds are testable without ScreenCaptureKit.
enum DisplayReadinessWait {
    /// How many polls fit in `grace` at `interval` (at least one).
    static func polls(grace: TimeInterval, interval: TimeInterval) -> Int {
        guard interval > 0 else { return 1 }
        return max(1, Int((grace / interval).rounded(.down)))
    }

    /// Whether a display wake may rebuild a capture stream on its own. Not
    /// while a start is waiting for that wake: the start builds the stream
    /// itself, and two starts collide.
    static func wakeMayRebuildCarrier(startAwaitingDisplay: Bool) -> Bool {
        !startAwaitingDisplay
    }

    /// Runs `body` with a start's hold on the carrier stream (see
    /// `wakeMayRebuildCarrier`). The hold is taken by `begin` before the body
    /// starts, so no wake can rebuild the carrier during the body's first
    /// probe either, and `end` runs on every exit: a return, a throw from the
    /// wait, a cancellation. A hold that outlived the start blocked every
    /// later wake rebuild for the life of the sender.
    static func whileAwaitingDisplay<Result>(
        begin: () async throws -> Void,
        end: () -> Void,
        body: () async throws -> Result
    ) async throws -> Result {
        defer { end() }
        try await begin()
        return try await body()
    }

    /// What a Window start does when its readiness wait was cancelled.
    enum CancelledWaitDecision: Equatable {
        /// The sender was stopped: nothing is left to start.
        case endQuietly
        /// The session generation was superseded (a transport switch, a
        /// reconnect): follow the session to its next admitted connection and
        /// start for that one, as startup does before capture.
        case follow
        /// The session kept changing: fail the start so the sender stops
        /// instead of running with no workspace engine.
        case fail
    }

    /// Superseded waits a start follows before it fails.
    static let maxFollows = 2

    /// `follows` is how many superseded waits this start already followed.
    static func afterCancelledWait(stopped: Bool, follows: Int) -> CancelledWaitDecision {
        if stopped { return .endQuietly }
        return follows < maxFollows ? .follow : .fail
    }

    /// The first value `probe` yields. A value already there is returned at
    /// once, with no wake and no pause. Otherwise `wake` runs exactly once
    /// and `probe` is retried after each `pause`, at most `polls` times; nil
    /// when it never yields one. Throws `CancellationError` as soon as
    /// `stillWanted` turns false (session ended, sender stopped), so a wait
    /// never outlives the session it was started for.
    static func firstAvailable<Value>(
        polls: Int,
        wake: () -> Void,
        probe: () async -> Value?,
        pause: () async throws -> Void,
        stillWanted: () -> Bool
    ) async throws -> Value? {
        guard stillWanted() else { throw CancellationError() }
        if let value = await probe() { return value }
        wake()
        for _ in 0..<max(polls, 0) {
            try await pause()
            guard stillWanted() else { throw CancellationError() }
            if let value = await probe() { return value }
        }
        return nil
    }
}

/// The intent an admitted connection's session declared, recorded when that
/// connection was admitted (#255). Keyed by the generation, so an intent from
/// one connection can never be read for another.
struct AdmittedSessionIntent: Equatable, Sendable {
    let generation: UInt64
    let intent: SessionInvitationIntent
}

/// Who may wake a sleeping Mac at the start of a session (#255, #260): only a
/// session the user explicitly asked for. A start that finds no display (the
/// Mac sleeps, a dark wake keeps the network up) wakes it for such a session
/// and for no other. An automatic connect or an unsolicited Mac-side redial
/// stays admitted, reports asleep (`macDisplaySleep`) and waits; the user's
/// explicit `promoteInteractiveWake` (Wake Mac, Wake & Connect) is a separate
/// request and is not decided here.
///
/// Pure: the caller passes state the Mac already trusts. Nothing here reads a
/// UI label or Bonjour metadata, and a missing record is never a yes.
enum StartWakePolicy {
    /// True only for the admitted connection `admittedGeneration`, when the
    /// intent recorded at its admission is `.manual` (a Mac-side Connect, or
    /// the receiver's own Connect or Wake & Connect). Not admitted, no record,
    /// or a record for another generation (an earlier connection's manual
    /// intent) all mean no wake.
    static func mayWake(admittedGeneration: UInt64, sessionIsAdmitted: Bool,
                        recorded: AdmittedSessionIntent?) -> Bool {
        guard sessionIsAdmitted, let recorded, recorded.generation == admittedGeneration else { return false }
        return recorded.intent == .manual
    }

    /// Whether a start that found no display keeps waiting once the bounded
    /// readiness grace has run out. A start allowed to wake asked once and
    /// gives up as before. One that may not wake keeps waiting while the
    /// Mac's displays sleep, so the user's Wake Mac or macOS waking by itself
    /// completes it; it gives up on an awake Mac with no display as before.
    static func keepsWaitingAfterGrace(mayWake: Bool, displaysAsleep: Bool) -> Bool {
        !mayWake && displaysAsleep
    }
}
