import CoreGraphics
import Foundation

// Display arrangement editing from a receiver (PROTOCOL.md 6.10, Display arrangement).
//
// The order of a request is fixed and every step can only end it, never skip ahead:
//   1. control (the session's input grant) when it arrives, one request at a time Mac-wide;
//   2. the receiver's catalog must still be this Mac's arrangement (`base`), and the result
//      must be valid against the CURRENT displays (`DisplayArrangementEdit.proposal`);
//   3. the Mac's owner answers a prompt ON THE MAC (Don't Allow after 60 s);
//   4. control is asked again, then the origins are applied for this login session only;
//   5. only `displayArrangeKeep` within 15 s makes them permanent; Revert, the timer, losing
//      control and the session ending all put the previous origins back.
// Every OS call goes through `DisplayOriginConfigurator` and the prompt through
// `DisplayArrangementConfirming`, so the tests never touch the real arrangement.

/// How long a configuration lasts (`CGConfigureOption`).
enum DisplayConfigurationScope: Equatable, Sendable {
    /// Until logout; the saved arrangement is untouched.
    case forSession
    /// Saved: macOS uses it from now on.
    case permanently
}

/// The OS seam: what the displays are now, and changing their origins.
protocol DisplayOriginConfigurator: AnyObject {
    /// Every active display now (mirror members included) with its `CGDisplayBounds` frame,
    /// main, mirror and MeowDisplay flags. Names may be empty.
    func currentDisplays() -> [OverviewDisplay]
    /// Applies all `origins` in one configuration transaction. False when macOS reported an
    /// error (the transaction is cancelled; nothing is applied).
    func configure(origins: [UInt32: CGPoint], scope: DisplayConfigurationScope) -> Bool
}

/// The Mac owner's answer to a prompt.
enum DisplayArrangementDecision: Equatable, Sendable {
    case allow
    case deny
    /// Another arrangement prompt is on screen.
    case busy
    /// No prompt could be shown (nothing on this Mac can ask).
    case unavailable
}

/// What the Mac's prompt shows.
struct DisplayArrangementConfirmationRequest: Equatable, Sendable {
    struct Change: Equatable, Sendable {
        let id: UInt32
        let before: CGRect
        let after: CGPoint
    }

    /// Unique per request, so dismissing an old prompt can never close a newer one.
    let token: UInt64
    /// The asking device as this Mac knows it (the prompt prefers the paired session's name).
    let deviceName: String
    /// Moved displays, by id.
    let changes: [Change]
    /// The main display's frame (it stays at 0,0).
    let mainFrame: CGRect
}

/// The prompt seam. `decide` is called at most once, on any thread.
protocol DisplayArrangementConfirming: AnyObject, Sendable {
    func requestConfirmation(_ request: DisplayArrangementConfirmationRequest,
                             decide: @escaping @Sendable (DisplayArrangementDecision) -> Void)
    /// The request ended without an answer (timeout, cancel, session end): its prompt goes.
    func dismissConfirmation(token: UInt64)
}

/// A scheduled timer that can be cancelled.
protocol DisplayArrangementTimer: AnyObject {
    func cancel()
}

/// The clock seam. `work` must run on the service's queue.
protocol DisplayArrangementScheduling: AnyObject {
    func schedule(after seconds: Int, _ work: @escaping @Sendable () -> Void) -> DisplayArrangementTimer
}

/// Only one arrangement change at a time on this Mac, across every session: two pending
/// reverts would otherwise put back each other's arrangements.
final class DisplayArrangementExclusivity: @unchecked Sendable {
    static let shared = DisplayArrangementExclusivity()

    private let lock = NSLock()
    private var holder: ObjectIdentifier?

    func acquire(_ owner: ObjectIdentifier) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard holder == nil || holder == owner else { return false }
        holder = owner
        return true
    }

    func release(_ owner: ObjectIdentifier) {
        lock.lock(); defer { lock.unlock() }
        if holder == owner { holder = nil }
    }
}

/// Runs one session's display arrangement requests. Confined to its owner's queue (MacSender's
/// `queue`): every method, timer and `perform` hop runs there.
final class DisplayArrangementService: @unchecked Sendable {
    private struct Pending {
        let req: Int
        let token: UInt64
        /// The normalized changed origins: what is configured.
        let changes: [UInt32: CGPoint]
        /// Every drawn display's origin before (restored on revert).
        let previous: [UInt32: CGPoint]
        /// Every drawn display's origin once applied (verified after each step).
        let expected: [UInt32: CGPoint]
        /// Asked again, side-effect free, right before anything is configured.
        let controlStillAllowed: () -> Bool
        var timer: DisplayArrangementTimer?
    }

    private enum Phase {
        case idle
        case confirming(Pending)
        case applied(Pending)
    }

    /// Sends one message to this session's receiver (the owner drops it once not admitted).
    var sendMessage: ([String: Any]) -> Void = { _ in }

    private let configurator: DisplayOriginConfigurator
    private let confirmer: DisplayArrangementConfirming
    private let scheduler: DisplayArrangementScheduling
    private let exclusivity: DisplayArrangementExclusivity
    private let deviceName: String
    /// Hops a prompt answer back onto the owner's queue.
    private let perform: @Sendable (@escaping @Sendable () -> Void) -> Void
    private let makeToken: () -> UInt64
    private var phase = Phase.idle

    init(configurator: DisplayOriginConfigurator, confirmer: DisplayArrangementConfirming,
         scheduler: DisplayArrangementScheduling, exclusivity: DisplayArrangementExclusivity = .shared,
         deviceName: String, perform: @escaping @Sendable (@escaping @Sendable () -> Void) -> Void,
         makeToken: @escaping () -> UInt64 = { UInt64.random(in: 1...UInt64.max) }) {
        self.configurator = configurator
        self.confirmer = confirmer
        self.scheduler = scheduler
        self.exclusivity = exclusivity
        self.deviceName = deviceName
        self.perform = perform
        self.makeToken = makeToken
    }

    /// True while a request waits for the Mac's owner or for Keep.
    var isBusy: Bool {
        if case .idle = phase { return false }
        return true
    }

    /// One `displayArrangeRequest`, `displayArrangeKeep` or `displayArrangeRevert` from an admitted
    /// session. `inputGranted`: the session's control gate as the message arrived;
    /// `controlStillAllowed`: the same, asked again (side-effect free) right before applying.
    func handle(type: String, message: [String: Any], inputGranted: Bool,
                controlStillAllowed: @escaping () -> Bool) {
        switch type {
        case WireMessage.displayArrangeRequest:
            handleRequest(message, inputGranted: inputGranted, controlStillAllowed: controlStillAllowed)
        case WireMessage.displayArrangeKeep:
            guard let req = message["req"] as? Int else { return }
            keep(req: req, controlAllowed: inputGranted && controlStillAllowed())
        case WireMessage.displayArrangeRevert:
            guard let req = message["req"] as? Int else { return }
            revertRequested(req: req)
        default:
            break
        }
    }

    /// The session ended or its connection changed: a prompt goes (Don't Allow), an applied
    /// arrangement is put back. Nothing is sent: the receiver that asked is gone.
    func sessionEnded() {
        switch phase {
        case .idle:
            return
        case .confirming(let pending):
            pending.timer?.cancel()
            confirmer.dismissConfirmation(token: pending.token)
            Log.info("display arrange: request \(pending.req) withdrawn (session ended)")
        case .applied(let pending):
            pending.timer?.cancel()
            let restored = restore(pending.previous, scope: .forSession)
            Log.info("display arrange: request \(pending.req) reverted (session ended), restored=\(restored)")
        }
        phase = .idle
        exclusivity.release(ObjectIdentifier(self))
    }

    // MARK: Steps

    private func handleRequest(_ message: [String: Any], inputGranted: Bool, controlStillAllowed: @escaping () -> Bool) {
        guard let request = DisplayArrangeRequestMessage.parse(message) else {
            if let req = message["req"] as? Int { send(req, .denied, reason: DisplayArrangeReason.malformed) }
            return
        }
        guard inputGranted else { return send(request.req, .denied, reason: DisplayArrangeReason.control) }
        guard case .idle = phase, exclusivity.acquire(ObjectIdentifier(self)) else {
            return send(request.req, .denied, reason: DisplayArrangeReason.busy)
        }

        let edit = DisplayArrangementEdit(displays: configurator.currentDisplays())
        guard Self.baseMatches(request.base, edit.original) else {
            return finish(request.req, .denied, reason: DisplayArrangeReason.stale)
        }
        let changes: [UInt32: CGPoint]
        switch edit.proposal(applying: request.origins) {
        case .failure(let problem):
            return finish(request.req, .denied, reason: problem.wireReason)
        case .success(let accepted):
            changes = accepted
        }

        let previous = Self.origins(of: edit.original)
        var expected = edit.normalizedOrigins
        for (id, origin) in changes { expected[id] = origin }
        let token = makeToken()
        var pending = Pending(req: request.req, token: token, changes: changes, previous: previous,
                              expected: expected, controlStillAllowed: controlStillAllowed, timer: nil)
        pending.timer = scheduler.schedule(after: DisplayArrangeWire.confirmSeconds) { [weak self] in
            self?.confirmationTimedOut(token: token)
        }
        phase = .confirming(pending)
        send(request.req, .awaitingMacConfirm)
        Log.info("display arrange: request \(request.req) asks the Mac's owner (\(changes.count) display(s))")

        var mainFrame = CGRect.zero
        if let main = edit.original.first(where: { $0.isMain }) { mainFrame = CGRect(origin: .zero, size: main.frame.size) }
        var described: [DisplayArrangementConfirmationRequest.Change] = []
        for id in changes.keys.sorted() {
            guard let before = edit.original.first(where: { $0.id == id })?.frame, let after = changes[id] else { continue }
            described.append(DisplayArrangementConfirmationRequest.Change(id: id, before: before, after: after))
        }
        let confirmation = DisplayArrangementConfirmationRequest(token: token, deviceName: deviceName,
                                                                 changes: described, mainFrame: mainFrame)
        let perform = self.perform
        confirmer.requestConfirmation(confirmation) { [weak self] decision in
            guard let service = self else { return }
            perform { service.confirmationAnswered(token: token, decision: decision) }
        }
    }

    private func confirmationTimedOut(token: UInt64) {
        guard case .confirming(let pending) = phase, pending.token == token else { return }
        confirmer.dismissConfirmation(token: token)
        finish(pending.req, .denied, reason: DisplayArrangeReason.timeout)
    }

    private func confirmationAnswered(token: UInt64, decision: DisplayArrangementDecision) {
        guard case .confirming(var pending) = phase, pending.token == token else { return }
        pending.timer?.cancel()
        pending.timer = nil
        switch decision {
        case .deny: return finish(pending.req, .denied, reason: DisplayArrangeReason.declined)
        case .busy: return finish(pending.req, .denied, reason: DisplayArrangeReason.busy)
        case .unavailable: return finish(pending.req, .denied, reason: DisplayArrangeReason.unavailable)
        case .allow: break
        }
        // Control may have ended while the owner read the prompt.
        guard pending.controlStillAllowed() else {
            return finish(pending.req, .denied, reason: DisplayArrangeReason.control)
        }
        // Nothing may have changed while the prompt was up: the owner approved THIS arrangement.
        guard currentOrigins() == pending.previous else {
            return finish(pending.req, .denied, reason: DisplayArrangeReason.stale)
        }
        guard configurator.configure(origins: pending.changes, scope: .forSession) else {
            let restored = restore(pending.previous, scope: .forSession)
            Log.info("display arrange: request \(pending.req) not applied (configuration error), restored=\(restored)")
            return finish(pending.req, .failed, reason: DisplayArrangeReason.configurationError)
        }
        guard currentOrigins() == pending.expected else {
            // macOS moved something else (it snaps displays it can't place): never leave that.
            let restored = restore(pending.previous, scope: .forSession)
            Log.info("display arrange: request \(pending.req) not applied as asked, restored=\(restored)")
            return finish(pending.req, .failed, reason: DisplayArrangeReason.notApplied)
        }
        pending.timer = scheduler.schedule(after: DisplayArrangeWire.revertSeconds) { [weak self] in
            self?.keepTimedOut(token: token)
        }
        phase = .applied(pending)
        send(pending.req, .applied, revertIn: DisplayArrangeWire.revertSeconds)
        Log.info("display arrange: request \(pending.req) applied for this session; reverting in \(DisplayArrangeWire.revertSeconds) s unless kept")
    }

    private func keepTimedOut(token: UInt64) {
        guard case .applied(let pending) = phase, pending.token == token else { return }
        revert(pending, reason: DisplayArrangeReason.timeout)
    }

    private func keep(req: Int, controlAllowed: Bool) {
        guard case .applied(var pending) = phase, pending.req == req else { return }
        pending.timer?.cancel()
        pending.timer = nil
        guard controlAllowed else { return revert(pending, reason: DisplayArrangeReason.control) }
        guard currentOrigins() == pending.expected else {
            return revert(pending, reason: DisplayArrangeReason.displaysChanged)
        }
        guard configurator.configure(origins: pending.changes, scope: .permanently),
              currentOrigins() == pending.expected else {
            // The saved arrangement may have been written: put the previous one back there too.
            let restored = restore(pending.previous, scope: .permanently)
            Log.info("display arrange: request \(pending.req) not kept (macOS didn't save it), restored=\(restored)")
            return finish(pending.req, .failed, reason: DisplayArrangeReason.notApplied)
        }
        Log.info("display arrange: request \(pending.req) kept")
        finish(pending.req, .kept)
    }

    private func revertRequested(req: Int) {
        switch phase {
        case .confirming(let pending) where pending.req == req:
            // Withdrawn before the owner answered: nothing was changed.
            pending.timer?.cancel()
            confirmer.dismissConfirmation(token: pending.token)
            finish(req, .denied, reason: DisplayArrangeReason.requested)
        case .applied(let pending) where pending.req == req:
            revert(pending, reason: DisplayArrangeReason.requested)
        default:
            break
        }
    }

    private func revert(_ pending: Pending, reason: String) {
        pending.timer?.cancel()
        if restore(pending.previous, scope: .forSession) {
            Log.info("display arrange: request \(pending.req) reverted (\(reason))")
            finish(pending.req, .reverted, reason: reason)
        } else {
            Log.info("display arrange: request \(pending.req) revert (\(reason)) not applied as asked")
            finish(pending.req, .failed, reason: DisplayArrangeReason.notApplied)
        }
    }

    // MARK: Helpers

    /// Puts `previous` back for every display still present whose origin differs, then checks it.
    private func restore(_ previous: [UInt32: CGPoint], scope: DisplayConfigurationScope) -> Bool {
        let now = currentOrigins()
        let moved = previous.filter { entry in now[entry.key] != nil && now[entry.key] != entry.value }
        if !moved.isEmpty, !configurator.configure(origins: moved, scope: scope) { return false }
        let after = currentOrigins()
        return previous.allSatisfy { entry in after[entry.key] == nil || after[entry.key] == entry.value }
    }

    /// Every drawn display's origin now, read again from the OS.
    private func currentOrigins() -> [UInt32: CGPoint] {
        Self.origins(of: DisplayArrangementEdit(displays: configurator.currentDisplays()).original)
    }

    private static func origins(of displays: [ArrangementDisplay]) -> [UInt32: CGPoint] {
        var out: [UInt32: CGPoint] = [:]
        for display in displays {
            out[display.id] = CGPoint(x: display.frame.minX.rounded(), y: display.frame.minY.rounded())
        }
        return out
    }

    /// The receiver edited exactly this Mac's current drawn displays (same ids, same frames).
    static func baseMatches(_ base: [DisplayArrangeRequestMessage.BaseDisplay], _ current: [ArrangementDisplay]) -> Bool {
        guard base.count == current.count else { return false }
        for display in current {
            guard let edited = base.first(where: { $0.id == display.id }),
                  rounded(edited.frame) == rounded(display.frame) else { return false }
        }
        return true
    }

    private static func rounded(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minX.rounded(), y: rect.minY.rounded(), width: rect.width.rounded(), height: rect.height.rounded())
    }

    private func send(_ req: Int, _ state: DisplayArrangeState, reason: String? = nil, revertIn: Int? = nil) {
        sendMessage(DisplayArrangeStateMessage(req: req, state: state, reason: reason, revertIn: revertIn).wire)
    }

    /// Reports a final state and frees the service (and the Mac-wide slot).
    private func finish(_ req: Int, _ state: DisplayArrangeState, reason: String? = nil) {
        phase = .idle
        exclusivity.release(ObjectIdentifier(self))
        send(req, state, reason: reason)
    }
}

// MARK: - Prompt text

/// The prompt's short before/after description, from the Mac's own display data (never the
/// receiver's names), relative to the main display.
enum DisplayArrangementSummary {
    /// At most `limit` lines, then one "and N more" line.
    static func lines(for request: DisplayArrangementConfirmationRequest, limit: Int = 4,
                      name: (UInt32) -> String) -> [String] {
        var out: [String] = []
        for change in request.changes.prefix(limit) {
            let after = CGRect(origin: change.after, size: change.before.size)
            let from = place(change.before, relativeTo: request.mainFrame)
            let to = place(after, relativeTo: request.mainFrame)
            out.append(String(localized: "\(name(change.id)): \(from) → \(to)"))
        }
        let more = request.changes.count - limit
        if more > 0 { out.append(String(localized: "and \(more) more")) }
        return out
    }

    /// "left of the main display (−1920, 0)" and so on, by the larger centre offset.
    static func place(_ rect: CGRect, relativeTo main: CGRect) -> String {
        let dx = rect.midX - main.midX
        let dy = rect.midY - main.midY
        let side: String
        if abs(dx) >= abs(dy) {
            side = dx < 0 ? String(localized: "left of the main display") : String(localized: "right of the main display")
        } else {
            side = dy < 0 ? String(localized: "above the main display") : String(localized: "below the main display")
        }
        return "\(side) (\(Int(rect.minX.rounded())), \(Int(rect.minY.rounded())))"
    }
}

// MARK: - Live seams

/// Quartz Display Services, public API only (as Mac/VirtualDisplay.swift uses it). Never
/// System Settings.
final class LiveDisplayOriginConfigurator: DisplayOriginConfigurator {
    /// This session's own virtual displays.
    private let ownDisplayIDs: () -> Set<UInt32>

    init(ownDisplayIDs: @escaping () -> Set<UInt32>) {
        self.ownDisplayIDs = ownDisplayIDs
    }

    func currentDisplays() -> [OverviewDisplay] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        let main = CGMainDisplayID()
        let meow = VirtualDisplayRegistry.shared.displayIDs
        let own = ownDisplayIDs()
        return ids.prefix(Int(count)).map { id in
            let mirror = CGDisplayMirrorsDisplay(id)
            return OverviewDisplay(id: id, frame: CGDisplayBounds(id), isMain: id == main,
                                   isMeow: meow.contains(id), isOwn: own.contains(id),
                                   mirrorOf: mirror == kCGNullDirectDisplay ? nil : mirror)
        }
    }

    func configure(origins: [UInt32: CGPoint], scope: DisplayConfigurationScope) -> Bool {
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let config else { return false }
        for id in origins.keys.sorted() {
            // Origins were validated as whole points within ±32768, so these conversions are exact.
            guard let origin = origins[id], DisplayArrangementEdit.isValidOrigin(origin),
                  CGConfigureDisplayOrigin(config, id, Int32(origin.x), Int32(origin.y)) == .success else {
                CGCancelDisplayConfiguration(config)
                return false
            }
        }
        let result = CGCompleteDisplayConfiguration(config, scope == .permanently ? .permanently : .forSession)
        if result != .success { Log.info("display arrange: configuration failed (result \(result.rawValue))") }
        return result == .success
    }
}

/// Timers on the owner's queue.
final class QueueDisplayArrangementScheduler: DisplayArrangementScheduling {
    private let queue: DispatchQueue

    init(queue: DispatchQueue) {
        self.queue = queue
    }

    func schedule(after seconds: Int, _ work: @escaping @Sendable () -> Void) -> DisplayArrangementTimer {
        let item = DispatchWorkItem(block: work)
        queue.asyncAfter(deadline: .now() + .seconds(seconds), execute: item)
        return WorkItemTimer(item: item)
    }

    private final class WorkItemTimer: DisplayArrangementTimer {
        let item: DispatchWorkItem
        init(item: DispatchWorkItem) { self.item = item }
        func cancel() { item.cancel() }
    }
}

/// The prompt through closures (MacSender hands it to its controller, which owns the panel).
final class ClosureDisplayArrangementConfirmer: DisplayArrangementConfirming, @unchecked Sendable {
    private let present: @Sendable (DisplayArrangementConfirmationRequest, @escaping @Sendable (DisplayArrangementDecision) -> Void) -> Void
    private let dismiss: @Sendable (UInt64) -> Void

    init(present: @escaping @Sendable (DisplayArrangementConfirmationRequest, @escaping @Sendable (DisplayArrangementDecision) -> Void) -> Void,
         dismiss: @escaping @Sendable (UInt64) -> Void) {
        self.present = present
        self.dismiss = dismiss
    }

    func requestConfirmation(_ request: DisplayArrangementConfirmationRequest,
                             decide: @escaping @Sendable (DisplayArrangementDecision) -> Void) {
        present(request, decide)
    }

    func dismissConfirmation(token: UInt64) { dismiss(token) }
}
