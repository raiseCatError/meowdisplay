import Foundation

/// Requests shared by every caller (at most two out, usually one), with recent answers reused.
///
/// Built for ScreenCaptureKit's shareable content: macOS's capture service (replayd) answers
/// every app's requests in turn, so while another app floods it (AltTab 10.x screenshot bursts
/// on macOS 26/27, alt-tab-macos#5861) each request can wait tens of seconds. Sending several
/// requests of our own per session start, and one per device, only lengthens that wait. Here a
/// caller joins the request already in flight when its answer is new enough, and gives up after
/// its own timeout or when cancelled, without abandoning the request for the others.
final class CoalescingFetch<Value: Sendable>: @unchecked Sendable {
    enum Freshness: Sendable {
        /// An answer from a request started after the last `invalidate()` and at most this old.
        case cachedWithin(Duration)
        /// An answer from a request started after this call, or at most `sameMoment` before it
        /// (something just changed that the caller must see, such as a password prompt
        /// appearing; callers reacting to the same change share one request).
        case startedAfterNow
    }

    struct TimedOut: Error, Equatable {
        let after: Duration
    }

    struct Answer: Sendable {
        let value: Value
        /// How long the request behind this answer took.
        let fetchDuration: Duration
        /// True when this caller's call started the request or waited for it, false for a
        /// reused answer.
        let waited: Bool
    }

    private struct Waiter {
        let needs: UInt64
        let continuation: CheckedContinuation<Answer, Error>
        var timer: Task<Void, Never>?
    }

    private let lock = NSLock()
    private let fetch: @Sendable () async throws -> Value
    private let onSlowFetch: (@Sendable (Duration) -> Void)?
    private let slowFetch: Duration
    /// The number the next request gets.
    private var nextSequence: UInt64 = 1
    /// Requests numbered below this started before the last `invalidate()`.
    private var validFrom: UInt64 = 1
    /// Requests out now. A second goes out only when the one out started too early for a caller
    /// (before a display appeared): waiting for it would put the fresh request at the back of
    /// replayd's queue, behind everything other apps sent meanwhile.
    private var inFlight: Set<UInt64> = []
    static var maxInFlight: Int { 2 }
    static var sameMoment: Duration { .milliseconds(50) }
    private var lastStart: (sequence: UInt64, at: ContinuousClock.Instant)?
    private var cached: (value: Value, sequence: UInt64, at: ContinuousClock.Instant, took: Duration)?
    private var waiters: [UInt64: Waiter] = [:]
    private var nextWaiter: UInt64 = 0
    /// Requests actually sent (for tests and logs).
    private(set) var requestsSent = 0

    init(slowFetch: Duration = .seconds(2), onSlowFetch: (@Sendable (Duration) -> Void)? = nil,
         fetch: @escaping @Sendable () async throws -> Value) {
        self.fetch = fetch
        self.slowFetch = slowFetch
        self.onSlowFetch = onSlowFetch
    }

    /// Displays or the windows that matter changed: answers from requests started before now are
    /// no longer reused.
    func invalidate() {
        lock.withLock {
            validFrom = nextSequence
            cached = nil
        }
    }

    var sentCount: Int { lock.withLock { requestsSent } }

    func value(_ freshness: Freshness, timeout: Duration? = nil) async throws -> Answer {
        let needs: UInt64
        switch lookup(freshness, now: .now) {
        case .reuse(let answer): return answer
        case .wait(let sequence): needs = sequence
        }
        try Task.checkCancellation()
        let id = lock.withLock { nextWaiter += 1; return nextWaiter }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Answer, Error>) in
                lock.lock()
                var waiter = Waiter(needs: needs, continuation: continuation)
                if let timeout {
                    waiter.timer = Task { [weak self] in
                        try? await Task.sleep(for: timeout)
                        guard !Task.isCancelled else { return }
                        self?.finish(waiter: id, with: .failure(TimedOut(after: timeout)))
                    }
                }
                waiters[id] = waiter
                let start = startIfNeededLocked()
                lock.unlock()
                start?()
                // Cancelled before the waiter was registered: `onCancel` found nothing to end.
                if Task.isCancelled { finish(waiter: id, with: .failure(CancellationError())) }
            }
        } onCancel: {
            finish(waiter: id, with: .failure(CancellationError()))
        }
    }

    private enum Lookup { case reuse(Answer), wait(UInt64) }

    private func lookup(_ freshness: Freshness, now: ContinuousClock.Instant) -> Lookup {
        lock.withLock {
            switch freshness {
            case .cachedWithin(let maxAge):
                if let cached, cached.sequence >= validFrom, now - cached.at <= maxAge {
                    return .reuse(Answer(value: cached.value, fetchDuration: cached.took, waited: false))
                }
                return .wait(validFrom)
            case .startedAfterNow:
                if let lastStart, inFlight.contains(lastStart.sequence), now - lastStart.at <= Self.sameMoment {
                    return .wait(lastStart.sequence)
                }
                return .wait(nextSequence)
            }
        }
    }

    /// Ends one caller's wait early (timeout or cancellation); the request carries on for the rest.
    private func finish(waiter id: UInt64, with result: Result<Answer, Error>) {
        let waiter = lock.withLock { waiters.removeValue(forKey: id) }
        waiter?.timer?.cancel()
        waiter?.continuation.resume(with: result)
    }

    /// Lock held. Starts a request when a caller needs a newer answer than any request out can
    /// give, within `maxInFlight`.
    private func startIfNeededLocked() -> (() -> Void)? {
        let newestOut = inFlight.max() ?? 0
        guard inFlight.count < Self.maxInFlight, waiters.values.contains(where: { $0.needs > newestOut }) else { return nil }
        let sequence = nextSequence
        nextSequence += 1
        inFlight.insert(sequence)
        lastStart = (sequence, .now)
        requestsSent += 1
        return { [self] in
            Task {
                let began = ContinuousClock.now
                let result: Result<Value, Error>
                do { result = .success(try await fetch()) } catch { result = .failure(error) }
                completed(sequence: sequence, result: result, took: ContinuousClock.now - began)
            }
        }
    }

    private func completed(sequence: UInt64, result: Result<Value, Error>, took: Duration) {
        if took >= slowFetch { onSlowFetch?(took) }
        lock.lock()
        inFlight.remove(sequence)
        if case .success(let value) = result, sequence >= validFrom, sequence > (cached?.sequence ?? 0) {
            cached = (value, sequence, ContinuousClock.now, took)
        }
        let served = waiters.filter { $0.value.needs <= sequence }
        served.keys.forEach { waiters[$0] = nil }
        let start = startIfNeededLocked()
        lock.unlock()
        for waiter in served.values {
            waiter.timer?.cancel()
            waiter.continuation.resume(with: result.map { Answer(value: $0, fetchDuration: took, waited: true) })
        }
        start?()
    }
}
