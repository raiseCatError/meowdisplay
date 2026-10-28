import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

// Caret-following Zoom While Typing, Mac side (PROTOCOL.md 6.11).
//
// While a receiver has control of this Mac AND reports its on-screen keyboard
// open, the focused text caret's rectangle is read through Accessibility and
// sent to that receiver, normalized to the display (or Window-mode canvas)
// it is streaming. Only a rectangle is ever read or sent: never the text,
// its length, the field's name or value. Everything fails quietly — no
// Accessibility permission, no focused text field, an app that exposes no
// caret (terminals, many Electron and game apps) — and the receiver then
// falls back to the last touch. The AX reading sits behind
// `FocusedCaretProviding` so the rest is testable with a fake.

/// What one Accessibility read found.
enum FocusedCaretReading: Equatable, Sendable {
    /// The caret's rectangle in global screen coordinates (points, top-left
    /// origin — the space `CGDisplayBounds` and the window frames use).
    case caret(CGRect)
    /// Permission missing, no focused element, a secure field, or no caret.
    case unavailable
}

protocol FocusedCaretProviding: AnyObject, Sendable {
    /// One read of the system's focused text caret. May block on another
    /// process, so it is only called off the network and main queues.
    func readFocusedCaret() -> FocusedCaretReading
}

/// Display-relative normalization of a global caret rectangle.
enum TextCaretNormalizer {
    /// Wider than this is not a caret (an app returned a whole line or field).
    static let maxCaretHeight: CGFloat = 400
    static let maxCaretWidth: CGFloat = 4

    /// `caret` in global points -> normalized to `display` (top-left origin,
    /// the space of `touch.x/y`), or `nil` when the caret's centre is not on
    /// that display (the receiver is not looking at it) or the rectangle is
    /// not a plausible caret.
    static func normalized(_ caret: CGRect, in display: CGRect) -> CGRect? {
        guard display.width > 0, display.height > 0, display.width.isFinite, display.height.isFinite,
              let caret = plausible(caret),
              display.contains(CGPoint(x: caret.midX, y: caret.midY)) else { return nil }
        return CGRect(x: (caret.minX - display.minX) / display.width,
                      y: (caret.minY - display.minY) / display.height,
                      width: caret.width / display.width,
                      height: caret.height / display.height)
    }

    /// Whether an app's answer can be a caret or a character: finite, with a
    /// height, and no taller than a caret can be.
    static func isPlausible(_ rect: CGRect) -> Bool {
        !rect.isNull && !rect.isInfinite
            && rect.origin.x.isFinite && rect.origin.y.isFinite && rect.width.isFinite && rect.height.isFinite
            && rect.height > 0 && rect.height <= maxCaretHeight && rect.width >= 0
    }

    /// The rectangle clamped to a caret's shape, or `nil` for non-finite,
    /// empty or oversized rectangles.
    static func plausible(_ rect: CGRect) -> CGRect? {
        guard isPlausible(rect) else { return nil }
        return CGRect(x: rect.minX, y: rect.minY, width: min(rect.width, maxCaretWidth), height: rect.height)
    }
}

/// How to turn a text selection into a caret rectangle when all an app
/// offers is bounds-for-range: the zero-length range first, then the
/// character after the caret (its leading edge — right even at the start of a
/// wrapped line), then the one before it (its trailing edge — the end of the
/// text).
enum CaretRectStrategy {
    static func caretRect(location: Int, length: Int, bounds: (_ location: Int, _ length: Int) -> CGRect?) -> CGRect? {
        guard location >= 0, length >= 0 else { return nil }
        // A selection's insertion point is its end.
        let caret = location + length
        if let rect = bounds(caret, 0).flatMap(TextCaretNormalizer.plausible) { return rect }
        // A character's own box: only its near edge matters, not its width.
        if let next = bounds(caret, 1), TextCaretNormalizer.isPlausible(next) {
            return CGRect(x: next.minX, y: next.minY, width: 0, height: next.height)
        }
        if caret > 0, let previous = bounds(caret - 1, 1), TextCaretNormalizer.isPlausible(previous) {
            return CGRect(x: previous.maxX, y: previous.minY, width: 0, height: previous.height)
        }
        return nil
    }
}

/// When to read. At most 10 reads a second ever; one soon after the Mac
/// injects a key (the caret has just moved); a steady 10 Hz for a second
/// after typing; a slow poll otherwise, which still notices a click into
/// another field.
struct TextCaretSchedule: Equatable {
    static let activeInterval: TimeInterval = 0.1
    static let idleInterval: TimeInterval = 0.3
    static let activeWindow: TimeInterval = 1.0
    static let inputDelay: TimeInterval = 0.05

    private(set) var lastReadAt: TimeInterval?
    private var lastInputAt: TimeInterval?
    private var inputDueAt: TimeInterval?

    mutating func reset() { self = TextCaretSchedule() }

    /// The Mac just injected a key event.
    mutating func noteInput(now: TimeInterval) {
        lastInputAt = now
        // Coalesce a burst of keys into the one read already due.
        if let due = inputDueAt, due > now { return }
        inputDueAt = max(now + Self.inputDelay, (lastReadAt ?? -.infinity) + Self.activeInterval)
    }

    /// Whether a read is due at `now`; recording it when so.
    mutating func shouldRead(now: TimeInterval) -> Bool {
        guard let last = lastReadAt else {
            lastReadAt = now
            return true
        }
        guard now - last >= Self.activeInterval else { return false }
        if let due = inputDueAt, now >= due {
            inputDueAt = nil
            lastReadAt = now
            return true
        }
        let typing = lastInputAt.map { now - $0 < Self.activeWindow } ?? false
        if now - last >= (typing ? Self.activeInterval : Self.idleInterval) {
            lastReadAt = now
            return true
        }
        return false
    }
}

/// Drives the reads for one receiver session and reports changes.
///
/// Everything but the Accessibility read itself runs on `ownerQueue` (the
/// sender's serial queue): `isPermitted`, `normalize` and `send` are called
/// there. The read runs on `readQueue`, one at a time, never blocking the
/// owner; a slow target app costs a skipped sample, not a stalled sender.
final class TextCaretFollower: @unchecked Sendable {
    /// A change smaller than this (in normalized units) is not worth a message.
    static let positionTolerance: CGFloat = 0.0005
    static let sizeTolerance: CGFloat = 0.001

    private let provider: FocusedCaretProviding
    private let readQueue: DispatchQueue
    private let ownerQueue: DispatchQueue
    private let clock: () -> TimeInterval
    private let tickInterval: TimeInterval?
    private let isPermitted: () -> Bool
    private let normalize: (CGRect) -> CGRect?
    private let send: (CGRect?) -> Void

    // Owner-queue state.
    private var keyboardOpen = false
    private var timer: DispatchSourceTimer?
    private var schedule = TextCaretSchedule()
    private var readInFlight = false
    private var generation = 0
    /// What the receiver was last told: outer `nil` = nothing yet.
    private var lastSent: CGRect??

    /// - Parameters:
    ///   - tickInterval: how often to check whether a read is due while the
    ///     keyboard is open; `nil` runs no timer (tests call `tick()`).
    init(provider: FocusedCaretProviding,
         readQueue: DispatchQueue,
         ownerQueue: DispatchQueue,
         clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         tickInterval: TimeInterval? = 0.04,
         isPermitted: @escaping () -> Bool,
         normalize: @escaping (CGRect) -> CGRect?,
         send: @escaping (CGRect?) -> Void) {
        self.provider = provider
        self.readQueue = readQueue
        self.ownerQueue = ownerQueue
        self.clock = clock
        self.tickInterval = tickInterval
        self.isPermitted = isPermitted
        self.normalize = normalize
        self.send = send
    }

    deinit { timer?.cancel() }

    var isFollowing: Bool { keyboardOpen }

    // MARK: Owner-queue API

    /// The receiver reported its on-screen keyboard open or closed.
    func setKeyboardOpen(_ open: Bool) {
        guard open != keyboardOpen else { return }
        if open {
            keyboardOpen = true
            schedule.reset()
            lastSent = .some(nil)       // a receiver starts with no caret
            startTimer()
        } else {
            stop()
        }
    }

    /// The Mac injected a keyboard event for this receiver: read soon.
    func noteInput() {
        guard keyboardOpen else { return }
        schedule.noteInput(now: clock())
    }

    /// The connection ended or the sender stopped: nothing is sent.
    func stop() {
        keyboardOpen = false
        timer?.cancel()
        timer = nil
        generation &+= 1
        readInFlight = false
        lastSent = nil
        schedule.reset()
    }

    /// One scheduling step: reads when one is due.
    func tick() {
        guard keyboardOpen else { return }
        guard isPermitted() else {
            // Control was revoked while the keyboard stayed open: tell the
            // receiver once, then stay quiet until it is back.
            report(nil)
            return
        }
        guard !readInFlight, schedule.shouldRead(now: clock()) else { return }
        readInFlight = true
        let generation = self.generation
        let provider = self.provider
        readQueue.async { [weak self] in
            guard let self else { return }
            let reading = provider.readFocusedCaret()
            self.ownerQueue.async { self.finishRead(reading, generation: generation) }
        }
    }

    // MARK: Private

    private func startTimer() {
        timer?.cancel()
        timer = nil
        guard let tickInterval else { return }
        let timer = DispatchSource.makeTimerSource(queue: ownerQueue)
        timer.schedule(deadline: .now() + tickInterval, repeating: tickInterval, leeway: .milliseconds(10))
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
    }

    private func finishRead(_ reading: FocusedCaretReading, generation: Int) {
        guard generation == self.generation else { return }
        readInFlight = false
        guard keyboardOpen, isPermitted() else { return }
        let rect: CGRect?
        if case .caret(let global) = reading { rect = normalize(global) } else { rect = nil }
        report(rect)
    }

    /// Sends `rect` unless the receiver already has (about) that.
    private func report(_ rect: CGRect?) {
        if let last = lastSent, Self.same(last, rect) { return }
        lastSent = .some(rect)
        send(rect)
    }

    private static func same(_ a: CGRect?, _ b: CGRect?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case let (a?, b?):
            return abs(a.minX - b.minX) <= positionTolerance && abs(a.minY - b.minY) <= positionTolerance
                && abs(a.width - b.width) <= sizeTolerance && abs(a.height - b.height) <= sizeTolerance
        default: return false
        }
    }
}

/// The live Accessibility reader: the system-wide focused element, its
/// selected-text range, and that range's on-screen bounds.
///
/// Never prompts for permission and never reads text: only the range
/// (two integers) and a rectangle are requested. Each call carries a short
/// messaging timeout so an unresponsive target app yields "no caret" instead
/// of a stall. Password fields are skipped. Apps that do not expose a caret —
/// Terminal-style apps that draw their own text, Chromium and Electron apps
/// until their accessibility tree is switched on, games — answer
/// `.unavailable`.
final class AXFocusedCaretProvider: FocusedCaretProviding, @unchecked Sendable {
    static let messagingTimeout: Float = 0.05
    private static let secureSubrole = "AXSecureTextField"

    func readFocusedCaret() -> FocusedCaretReading {
        guard AXIsProcessTrusted() else { return .unavailable }
        guard let element = focusedElement() else { return .unavailable }
        AXUIElementSetMessagingTimeout(element, Self.messagingTimeout)
        if Self.copy(element, kAXSubroleAttribute) as? String == Self.secureSubrole { return .unavailable }
        guard let range = Self.selectedRange(of: element) else { return .unavailable }
        let rect = CaretRectStrategy.caretRect(location: range.location, length: range.length) { location, length in
            Self.bounds(of: element, location: location, length: length)
        }
        return rect.map(FocusedCaretReading.caret) ?? .unavailable
    }

    /// The focused element: system-wide first, then the frontmost app's own
    /// (some apps answer only to their own application element).
    private func focusedElement() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, Self.messagingTimeout)
        if let element = Self.element(Self.copy(system, kAXFocusedUIElementAttribute)) { return element }
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, Self.messagingTimeout)
        return Self.element(Self.copy(app, kAXFocusedUIElementAttribute))
    }

    private static func copy(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }

    private static func element(_ value: CFTypeRef?) -> AXUIElement? {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func selectedRange(of element: AXUIElement) -> CFRange? {
        guard let value = copy(element, kAXSelectedTextRangeAttribute),
              CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = value as! AXValue
        var range = CFRange()
        guard AXValueGetType(axValue) == .cfRange, AXValueGetValue(axValue, .cfRange, &range) else { return nil }
        return range
    }

    private static func bounds(of element: AXUIElement, location: Int, length: Int) -> CGRect? {
        var range = CFRange(location: location, length: length)
        guard let rangeValue = AXValueCreate(.cfRange, &range) else { return nil }
        var result: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element, kAXBoundsForRangeParameterizedAttribute as CFString, rangeValue, &result) == .success,
              let result, CFGetTypeID(result) == AXValueGetTypeID() else { return nil }
        let axValue = result as! AXValue
        var rect = CGRect.zero
        guard AXValueGetType(axValue) == .cgRect, AXValueGetValue(axValue, .cgRect, &rect) else { return nil }
        return rect
    }
}
