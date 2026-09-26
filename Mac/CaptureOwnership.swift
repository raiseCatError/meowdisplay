import Foundation

/// Proof that one capture start holds the capture slot, handed out by
/// `CaptureOwnership.reserveStart()`. Only the owner mints these.
struct CaptureStartTicket: Equatable, Sendable {
    fileprivate let id: UInt64
}

/// The one owner of a Mac Sender pipeline's capture stream and of the
/// capture start/stop lifecycle. `MacSender` keeps exactly one of these,
/// confined to its `queue`; every read and write of the stream, of
/// `stopped`, and every start, stop and rebuild goes through it there. A
/// capture start suspends several times (ScreenCaptureKit and the audio
/// encoder are async), so it holds a ticket across those suspensions and
/// commits only if nothing replaced it meanwhile:
///
/// * one start at a time: a newer start supersedes one still suspended (the
///   newer one carries the current session, geometry and media wants), and
///   the superseded start can no longer install or commit its stream;
/// * `stop()` and every rebuild (`releaseStream()`: Video Off, reconfigure,
///   resume, wake recovery, a stale Extend display) invalidate an in-flight
///   start, which then discards the stream it started instead of
///   installing or keeping it;
/// * after `stop()` nothing can be started or installed until `resume()`.
///
/// Generic over the stream type so the rules are testable without
/// ScreenCaptureKit.
struct CaptureOwnership<Stream: AnyObject> {
    enum StartRefusal: Error, Equatable {
        /// The pipeline was stopped.
        case stopped
        /// A capture stream is already live.
        case streamActive
    }

    struct Reservation {
        let ticket: CaptureStartTicket
        /// The stream a superseded start had installed, which the caller
        /// must stop.
        let superseded: Stream?
    }

    private(set) var stopped = false
    /// The stream frame callbacks accept: the live one, or the one an
    /// in-flight start installed just before starting it.
    private(set) var stream: Stream?
    private var inFlight: UInt64?
    private var nextTicket: UInt64 = 0

    init() {}

    var isStartInFlight: Bool { inFlight != nil }

    /// The committed, running stream — not one a start is still bringing up.
    var liveStream: Stream? { inFlight == nil ? stream : nil }

    func isCurrent(_ ticket: CaptureStartTicket) -> Bool {
        !stopped && inFlight == ticket.id
    }

    /// `beginStart()`: the pipeline may capture again.
    mutating func resume() {
        stopped = false
    }

    /// Takes the one capture-start slot, superseding a start still in
    /// flight. Refused while stopped or while a committed stream is live.
    mutating func reserveStart() -> Result<Reservation, StartRefusal> {
        if stopped { return .failure(.stopped) }
        if liveStream != nil { return .failure(.streamActive) }
        let superseded = stream
        stream = nil
        nextTicket &+= 1
        inFlight = nextTicket
        return .success(Reservation(ticket: CaptureStartTicket(id: nextTicket), superseded: superseded))
    }

    /// The start created its stream and is about to start it; frames from it
    /// are accepted from now on. Refused once the ticket was invalidated.
    mutating func install(_ newStream: Stream, for ticket: CaptureStartTicket) -> Bool {
        guard isCurrent(ticket), stream == nil else { return false }
        stream = newStream
        return true
    }

    /// The stream started and every other check passed: it becomes the live
    /// stream. Refused if a stop or rebuild invalidated the ticket meanwhile.
    mutating func commit(_ ticket: CaptureStartTicket) -> Bool {
        guard isCurrent(ticket), stream != nil else { return false }
        inFlight = nil
        return true
    }

    /// The start failed or was refused after reserving. Returns whether it
    /// still held the slot — if not, a stop or rebuild already took over the
    /// stream and the capture bookkeeping — and the stream it had installed,
    /// which is no longer current.
    mutating func abandon(_ ticket: CaptureStartTicket) -> (wasCurrent: Bool, installed: Stream?) {
        guard inFlight == ticket.id else { return (false, nil) }
        inFlight = nil
        let installed = stream
        stream = nil
        return (true, installed)
    }

    /// Stops the pipeline: no start may commit or begin after this. Returns
    /// the stream to stop, live or mid-start.
    mutating func stop() -> Stream? {
        stopped = true
        inFlight = nil
        let released = stream
        stream = nil
        return released
    }

    /// Tears the stream down for a rebuild or Video Off, and invalidates a
    /// start still in flight. Returns the stream to stop.
    mutating func releaseStream() -> Stream? {
        inFlight = nil
        let released = stream
        stream = nil
        return released
    }

    /// Releases `candidate` only if it is still the current stream (a late
    /// callback for a replaced stream changes nothing). Returns whether it
    /// was.
    @discardableResult
    mutating func release(_ candidate: Stream) -> Bool {
        guard stream === candidate else { return false }
        inFlight = nil
        stream = nil
        return true
    }
}

/// A flag one queue owns and alone writes, with a lock-guarded copy other
/// threads may read (`MacSender.stopped`).
final class QueueOwnedFlag {
    private let lock = NSLock()
    private var value = false

    func get() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set(_ newValue: Bool) {
        lock.lock()
        value = newValue
        lock.unlock()
    }
}
