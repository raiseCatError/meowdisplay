import SwiftUI
import UIKit

// The receiver's local calculator: a floating window that can be moved by
// its title bar and resized freely from its corner. Three views:
// - Basic: a coloured keypad, the expression as typed with a live answer
//   under it, and a history of what was calculated (tap a line to reuse
//   its answer; hold it to copy).
// - Scientific (Expand): adds ( ) sin cos tan ln log √ x² xʸ π e and more.
// - Notes (the keyboard button): a Soulver / Math Notes style sheet. Type
//   (or write with Apple Pencil, which Scribble turns into text) a sum or a
//   plain-English question on a line, and its answer appears under it with
//   a shimmer. Lines can name values ("rent = 1200") that later lines use.
// Everything runs on this device; nothing here can reach the Mac.

// MARK: - Model

/// While a calculator notes line is being edited, a hardware keyboard types
/// into it instead of controlling the Mac (`HardwareKeyboardForwarder`).
@MainActor
enum LocalCalculatorTextFocus {
    static var isEditing = false
}

/// The receiver's local calculator for this app session: what is being
/// typed, the history, the notes, its mode and where its window sits.
/// Memory only: it survives the panel closing, Home, reconnects and
/// Settings, and is gone when the app quits. Owned by
/// `ReceiverControlStore`, so the demo has its own.
@MainActor
final class LocalCalculatorModel: ObservableObject {
    enum Mode: Hashable {
        case basic
        case scientific
        case notes
    }

    typealias Key = CalculatorKeypad.Key
    typealias HistoryEntry = CalculatorKeypad.HistoryEntry

    @Published private(set) var isOpen = false
    @Published var mode: Mode = .basic
    @Published private(set) var keypad = CalculatorKeypad()
    @Published var inverse = false
    /// The notes sheet's text, one calculation or question per line.
    @Published var notesText = ""
    /// Whether the notes take the keyboard (the rail's button and Close let it go).
    @Published var notesEditing = false
    /// Each view's window frame once moved or resized, in the layer's space: the keypads keep
    /// their proportions, the notes are freeform, so each keeps its own.
    @Published var windowFrames: [Mode: CGRect] = [:]
    var windowFrame: CGRect? {
        get { windowFrames[mode] }
        set { windowFrames[mode] = newValue }
    }
    /// Bumped by each Copy Result, for the button's brief confirmation.
    @Published private(set) var copyCount = 0
    /// Flicked to an edge: out of sight but for a strip, everything kept. The
    /// strip, the calculator button or VoiceOver bring it back.
    @Published var stash: LocalCalculatorStash?

    var input: String { keypad.input }
    var showsAnswer: Bool { keypad.showsAnswer }
    var answeredExpression: String { keypad.answeredExpression }
    var failed: Bool { keypad.failed }
    var history: [HistoryEntry] { keypad.history }
    var preview: Decimal? { keypad.preview }
    var currentValue: Decimal? { keypad.currentValue }
    var angle: CalculatorAngleUnit {
        get { keypad.angle }
        set { keypad.angle = newValue }
    }

    /// The calculator button: brings a stashed window back, else opens or closes it.
    func toggle() {
        if isOpen, stash != nil {
            stash = nil
        } else {
            isOpen.toggle()
        }
    }

    func close() {
        isOpen = false
        notesEditing = false
        stash = nil
    }

    /// Out of sight at `stash`'s edge; the keyboard goes, nothing else changes.
    func stash(at stash: LocalCalculatorStash) {
        notesEditing = false
        self.stash = stash
    }

    func press(_ key: Key) { keypad.press(key) }
    func use(_ value: Decimal) { keypad.use(value) }
    func clearHistory() { keypad.clearHistory() }
    func removeHistory(_ id: HistoryEntry.ID) { keypad.removeHistory(id) }

    static func symbol(_ operation: LocalCalculator.Operation) -> String { CalculatorKeypad.symbol(operation) }

    // MARK: Copy

    /// Writes the result to this device's pasteboard, like any other copy
    /// in the app. Unified Clipboard isn't called or changed: if the person
    /// allowed it, it notices this copy later through its own change
    /// detection (`ClipboardModel.checkLocal`), exactly as it would a copy
    /// made in another app. False while there is no value.
    @discardableResult
    func copyResult(locale: Locale = .current, to pasteboard: UIPasteboard = .general) -> Bool {
        guard let value = currentValue else { return false }
        return copy(value, locale: locale, to: pasteboard)
    }

    @discardableResult
    func copy(_ value: Decimal, locale: Locale = .current, to pasteboard: UIPasteboard = .general) -> Bool {
        pasteboard.string = LocalCalculatorFormat.copyText(value, locale: locale)
        copyCount &+= 1
        return true
    }

    // MARK: Notes

    /// The last evaluation, so a keystroke redoes only the lines from the edit down.
    private var notesEvaluation: CalculatorSheet.Evaluation?

    var noteResults: [CalculatorLineResult] {
        let evaluation = CalculatorSheet.evaluate(lines: notesText.components(separatedBy: "\n"), angle: angle,
                                                  smart: CalculatorSmartContext(), reusing: notesEvaluation)
        notesEvaluation = evaluation
        return evaluation.results
    }

    func clearNotes() {
        notesText = ""
    }

    /// What a notes line's answer copies: the number when there is one, else its text.
    @discardableResult
    func copy(_ result: CalculatorLineResult, locale: Locale = .current) -> Bool {
        if let value = result.value { return copy(value, locale: locale) }
        guard let text = result.text else { return false }
        UIPasteboard.general.string = text
        copyCount &+= 1
        return true
    }
}

/// The open panel's frame, so the surface (Stage Peek, the Video Off grid)
/// treats it as occupied like any other control.
struct LocalCalculatorFramesPreference: PreferenceKey {
    static let defaultValue: [CGRect] = []
    static func reduce(value: inout [CGRect], nextValue: () -> [CGRect]) {
        value += nextValue()
    }
}

/// A stashed panel's strip (where it takes touches), reported apart from the
/// panel: the workspace keeps clear of it, but the arrow keys don't move for
/// it; the strip keeps off them instead (`LocalCalculatorLayer.stashObstacles`).
struct LocalCalculatorStashFramesPreference: PreferenceKey {
    static let defaultValue: [CGRect] = []
    static func reduce(value: inout [CGRect], nextValue: () -> [CGRect]) {
        value += nextValue()
    }
}

// MARK: - Window geometry

enum LocalCalculatorWindowGeometry {
    static func minimumSize(_ mode: LocalCalculatorModel.Mode) -> CGSize {
        switch mode {
        case .basic: return CGSize(width: 200, height: 280)
        case .scientific: return CGSize(width: 330, height: 280)
        case .notes: return CGSize(width: 240, height: 200)
        }
    }

    /// The size a mode opens at when the window hasn't been resized, from
    /// the fitted basic keypad.
    static func preferredSize(_ mode: LocalCalculatorModel.Mode, basic: CGSize) -> CGSize {
        switch mode {
        case .basic: return CGSize(width: basic.width, height: basic.height + 64)
        case .scientific: return CGSize(width: basic.width * 1.75, height: basic.height + 64)
        case .notes: return CGSize(width: max(basic.width * 1.3, 320), height: basic.height + 64)
        }
    }

    /// The keypads resize only proportionally (their round keys would stretch otherwise):
    /// `frame`'s top-left kept, its width setting the size at `aspect` (width / height),
    /// within `minimum` and `bounds`.
    static func proportional(_ frame: CGRect, aspect: CGFloat, minimum: CGSize, bounds: CGRect) -> CGRect {
        guard aspect > 0, aspect.isFinite, !bounds.isNull, !bounds.isEmpty else {
            return clamped(frame, minimum: minimum, bounds: bounds)
        }
        let smallest = max(minimum.width, minimum.height * aspect)
        let largest = min(bounds.width, bounds.height * aspect)
        let width = min(max(frame.width, smallest), largest)
        return clamped(CGRect(x: frame.minX, y: frame.minY, width: width, height: width / aspect),
                       minimum: .zero, bounds: bounds)
    }

    /// `frame` kept inside `bounds`: no smaller than `minimum` (unless the
    /// bounds are), no larger than the bounds, and moved back inside.
    static func clamped(_ frame: CGRect, minimum: CGSize, bounds: CGRect) -> CGRect {
        guard !bounds.isNull, !bounds.isEmpty else { return frame }
        let width = min(max(frame.width, min(minimum.width, bounds.width)), bounds.width)
        let height = min(max(frame.height, min(minimum.height, bounds.height)), bounds.height)
        let x = min(max(frame.minX, bounds.minX), bounds.maxX - width)
        let y = min(max(frame.minY, bounds.minY), bounds.maxY - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }
}

// MARK: - Layer

/// The entry button and, while open, the floating calculator window, in the
/// control overlay's coordinates. Only the button and the window take
/// touches; the rest of the layer passes them through to the Mac untouched,
/// so there is no tap-catcher and nothing outside dismisses it: Close, the
/// button again, or VoiceOver's escape gesture do.
struct LocalCalculatorLayer<Chip: View>: View {
    @ObservedObject var model: LocalCalculatorModel
    let containerSize: CGSize
    /// nil while the button isn't shown (an open panel then sits in the
    /// top-left of `panelBounds`).
    let buttonFrame: CGRect?
    var buttonFaceDiameter: CGFloat?
    /// A Strip caption under the button, when Control Hints are on.
    var buttonHint: String?
    /// The safe area the window must stay inside.
    let panelBounds: CGRect
    /// Where a window dragged past `panelBounds` is cut, as a float is cut at the picture's
    /// edge: nil cuts it at `panelBounds`.
    var dragClip: CGRect?
    /// Other controls and reserved regions the window keeps off when it can.
    var obstacles: [CGRect] = []
    /// Everything a stashed window's strip keeps off: `obstacles` and the controls placed
    /// after the calculator (an open palette, the arrow keys, a floating gear).
    var stashObstacles: [CGRect] = []
    /// Auto-hide fades the button with the other controls, but never while
    /// its panel is open, and never the panel.
    var autoHiding = false
    let haptics: ReceiverHaptics
    @ViewBuilder let chip: (_ selected: Bool) -> Chip

    @ScaledMetric(relativeTo: .body) private var preferredKey: CGFloat = 54
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var keyboard = LocalCalculatorKeyboardObserver()
    @State private var layerOrigin: CGPoint = .zero
    /// The window's frame when a move began, and when a resize began (each its own).
    @State private var moveStart: CGRect?
    @State private var resizeStart: CGRect?
    /// Where the window is while its title bar is dragged: it may hang past
    /// the left or right edge then (`LocalCalculatorStashGeometry.dragged`).
    @State private var dragFrame: CGRect?
    /// Counts title-bar drags, so a queued cancellation only ends the drag it belongs to.
    @State private var moveGeneration = 0
    /// A touch on a stashed window's strip: what it is doing (nil: a tap so far) and how far it
    /// has moved. Kept as state so its end can act on it; `stashHeld` clears it if the system
    /// cancels the touch (no end).
    @State private var stashTouch: StripTouchState?
    @GestureState private var stashHeld = false
    /// Counts strip touches: each has its own, so a queued cancellation only clears its own.
    @State private var stashTouchCount = 0

    private struct StripTouchState {
        var id: Int
        var start: CGPoint
        var kind: LocalCalculatorStashGeometry.StripTouch?
        var translation: CGSize
        /// Where the strip was drawn when the touch began: a slide moves it from there, whatever
        /// opens or moves meanwhile.
        var origin: LocalCalculatorStash
    }
    @Environment(\.colorSchemeContrast) private var contrast

    /// The bounds above the on-screen keyboard while notes are typed.
    private var usableBounds: CGRect {
        guard let keyboardTop = keyboard.top else { return panelBounds }
        let top = keyboardTop - layerOrigin.y - LocalCalculatorPlacement.margin
        guard top < panelBounds.maxY else { return panelBounds }
        var bounds = panelBounds
        bounds.size.height = max(120, top - bounds.minY)
        return bounds
    }

    var body: some View {
        let bounds = usableBounds
        let metrics = LocalCalculatorPanelMetrics.fitting(panelBounds.size, preferredKey: preferredKey)
        let anchor = buttonFrame ?? CGRect(x: panelBounds.minX, y: panelBounds.minY, width: 0, height: 0)
        let panel: CGRect? = model.isOpen ? windowFrame(metrics: metrics, anchor: anchor, bounds: bounds) : nil
        let buttonVisible = !autoHiding || model.isOpen
        ZStack(alignment: .topLeading) {
            // Faded by Auto-hide (closed): gone, as the trays and the Arrow Keys button are, so
            // VoiceOver and Voice Control can't reach an invisible button either.
            if let buttonFrame, buttonVisible {
                let press = {
                    if model.isOpen, model.stash != nil, let panel {
                        restore(panel, bounds: bounds)
                    } else {
                        model.toggle()
                    }
                    haptics.play(.selection)
                }
                LocalCalculatorEntryButton(open: model.isOpen, diameter: buttonFaceDiameter ?? buttonFrame.width,
                                           hitDiameter: buttonFrame.width, hint: buttonHint, chip: chip, action: press)
                .position(x: buttonFrame.midX,
                          y: buttonFrame.minY + (buttonFrame.height + (buttonHint == nil ? 0 : PadControlMetrics.hintHeight + 2)) / 2)
                .transition(.opacity)
            }
            if let panel {
                // While its strip is slid along the edge, it waits where the finger has taken it.
                let waiting = model.stash.map {
                    LocalCalculatorStashGeometry.waiting(size: panel.size, stash: sliding($0, size: panel.size, bounds: bounds), bounds: bounds,
                                                         obstacles: obstacles + stashObstacles)
                }
                let shown = waiting.map { peeked($0.window) } ?? dragFrame ?? panel
                LocalCalculatorPanel(model: model, haptics: haptics,
                                     onMove: { move(by: $0, from: panel, bounds: bounds) },
                                     onMoveEnd: { endMove(velocity: $0, from: panel, bounds: bounds) },
                                     onResize: { resize(by: $0, from: panel, bounds: bounds, metrics: metrics) },
                                     onResizeEnd: { resizeStart = nil },
                                     // A drag the system cancelled (no end): let go where it is.
                                     // Checked a turn later, so a normal end (with its velocity) goes first.
                                     onMoveCancel: {
                                         let generation = moveGeneration
                                         DispatchQueue.main.async {
                                             guard generation == moveGeneration, dragFrame != nil else { return }
                                             endMove(velocity: .zero, from: panel, bounds: bounds)
                                         }
                                     },
                                     onStash: { stashAtNearestEdge(panel, bounds: bounds) })
                    .frame(width: shown.width, height: shown.height)
                    // Stashed: only the strip (and a peek while pulled) shows, inside the bounds.
                    // Dragged past the screen's edge: only the part inside it (what it reports, below).
                    .clipShape(LocalCalculatorStashClip(visible: waiting.map { visibleStrip(of: shown, waiting: $0.strip, window: $0.window) }
                                                            ?? visibleWhileDragged(shown, bounds: bounds)))
                    // A clip only changes what is drawn: the part cut off takes no touches either.
                    .contentShape(LocalCalculatorStashClip(visible: waiting.map { visibleStrip(of: shown, waiting: $0.strip, window: $0.window) }
                                                               ?? visibleWhileDragged(shown, bounds: bounds)))
                    .position(x: shown.midX, y: shown.midY)
                    // Reduce Motion: stashing and bringing it back only fade, never slide.
                    .transaction { if reduceMotion { $0.animation = nil } }
                    // Stashed, the window itself isn't drawn: its strip's card stands for it (no live
                    // pixels around the card's corners); it fades back in as it comes out.
                    .opacity(waiting == nil ? 1 : 0)
                    .allowsHitTesting(waiting == nil)
                    .accessibilityHidden(waiting != nil)
                    .transition(reduceMotion
                                ? .opacity
                                : .scale(scale: 0.92, anchor: Self.unitPoint(of: anchor, in: panel))
                                    .combined(with: .opacity))
                // Only where a finger can take it: with no clear place, nothing is drawn over the
                // controls there and the calculator button brings it back (`anchorStashed`).
                if let waiting, let stash = model.stash, let touch = waiting.touch {
                    stashHandle(strip: waiting.strip, touch: touch, stash: stash, bounds: bounds,
                                restore: { restore(panel, bounds: bounds) },
                                settle: { slideEnded(panel, to: $0, bounds: bounds) },
                                step: { direction in
                                    LocalCalculatorStashGeometry.stepped(stash, size: panel.size, direction: direction,
                                                                         step: max(waiting.strip.height, 60), bounds: bounds,
                                                                         obstacles: obstacles + stashObstacles)
                                        .map { slideEnded(panel, to: $0, bounds: bounds) }
                                })
                }
            }
        }
        .frame(width: containerSize.width, height: containerSize.height, alignment: .topLeading)
        .background(GeometryReader { proxy in
            Color.clear
                .onAppear { layerOrigin = proxy.frame(in: .global).origin }
                .onChange(of: proxy.frame(in: .global).origin) { layerOrigin = $0 }
        })
        .animation(reduceMotion ? .easeOut(duration: 0.12) : .snappy(duration: 0.22), value: model.isOpen)
        .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: model.mode)
        .animation(.easeOut(duration: 0.2), value: keyboard.top)
        .animation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.38, dampingFraction: 0.86),
                   value: model.stash)
        // Where it is drawn: while dragged, its live frame (the part inside the bounds, as drawn),
        // so the arrow keys and the workspace keep clear of where it is, not where it was.
        .preference(key: LocalCalculatorFramesPreference.self, value: occupied(panel: panel, bounds: bounds))
        .preference(key: LocalCalculatorStashFramesPreference.self, value: stashOccupied(panel: panel, bounds: bounds))
        // Stashed through a rotation (or a keyboard change): it keeps coming back flush with
        // its edge in the bounds it has now, wherever it is brought back from.
        .onChange(of: usableBounds) { anchorStashed(in: $0) }
        // Closed (or stashed) mid-gesture: the panel that would end the gesture is gone or
        // hidden, so nothing of it carries into the next open.
        .onChange(of: model.isOpen) { open in if !open { clearGestures() } }
        .onChange(of: model.stash) { stash in
            if stash != nil { clearGestures() }
            stashTouch = nil   // moved or brought back by something else: that touch is over
        }
        // A strip touch the system cancelled (no end): let go of it, checked a turn later so a
        // normal end goes first; a newer touch is never cleared by it.
        .onChange(of: stashHeld) { held in
            guard !held, let id = stashTouch?.id else { return }
            DispatchQueue.main.async { if stashTouch?.id == id { stashTouch = nil } }
        }
        // Controls opened or moved onto its strip: it moves to where it can still be tapped.
        .onChange(of: obstacles + stashObstacles) { _ in anchorStashed(in: usableBounds) }
        .onChange(of: buttonFrame) { _ in anchorStashed(in: usableBounds) }
        .onAppear { anchorStashed(in: usableBounds) }
    }

    /// What the open window takes from the screen: while dragged, only its part inside the
    /// drag clip (nothing when none is); else its frame. Stashed, its strip does instead.
    private func occupied(panel: CGRect?, bounds: CGRect) -> [CGRect] {
        guard model.stash == nil else { return [] }
        if let dragFrame {
            return LocalCalculatorStashGeometry.onScreen(dragFrame, bounds: dragClipping(bounds)).map { [$0] } ?? []
        }
        return panel.map { [$0] } ?? []
    }

    /// The part of the window (in its own coordinates) that shows while it isn't stashed: all
    /// of it, but while dragged only what is inside the drag clip.
    private func visibleWhileDragged(_ shown: CGRect, bounds: CGRect) -> CGRect {
        guard dragFrame != nil else { return CGRect(origin: .zero, size: shown.size) }
        guard let part = LocalCalculatorStashGeometry.onScreen(shown, bounds: dragClipping(bounds)) else { return .zero }
        return part.offsetBy(dx: -shown.minX, dy: -shown.minY)
    }

    /// Where a dragged window is cut: `dragClip`, but never below the on-screen keyboard's top
    /// (one raised mid-drag included); the bounds without a `dragClip`.
    private func dragClipping(_ bounds: CGRect) -> CGRect {
        guard var clip = dragClip else { return bounds }
        if let keyboardTop = keyboard.top {
            clip.size.height = max(0, min(clip.maxY, keyboardTop - layerOrigin.y) - clip.minY)
        }
        return clip
    }

    private func clearGestures() {
        moveStart = nil
        resizeStart = nil
        dragFrame = nil
        moveGeneration &+= 1
    }

    /// While stashed, where it comes back: flush with its edge in `bounds`, placed by the size
    /// it is drawn at there (a keypad keeps its proportions, so it may shrink). Only the place
    /// is kept: the chosen size stays, so rotating back gives it back. Whatever brings it back
    /// (its strip, the button, VoiceOver) then finds it in place.
    private func anchorStashed(in bounds: CGRect) {
        guard var stash = model.stash, let frame = model.windowFrame else { return }
        let metrics = LocalCalculatorPanelMetrics.fitting(panelBounds.size, preferredKey: preferredKey)
        let fitted = settled(frame, metrics: metrics, bounds: bounds)
        // Its strip covered (a rotation, or controls that opened there): the other side edge if
        // that has a clear place, so every stashed window stays reachable by a finger, moved
        // there at once rather than across the screen. With neither, the calculator button
        // brings it back; without a button it comes back now, never out of reach.
        let usable = LocalCalculatorStashGeometry.usable(stash, size: fitted.size, bounds: bounds,
                                                         obstacles: obstacles + stashObstacles)
        if usable == nil, buttonFrame == nil {
            model.windowFrame = LocalCalculatorStashGeometry.keepingSize(
                frame.size, at: LocalCalculatorStashGeometry.restored(fitted, stash: stash, bounds: bounds,
                                                                      obstacles: obstacles + stashObstacles))
            model.stash = nil
            return
        }
        var moveAtOnce = Transaction()
        moveAtOnce.disablesAnimations = true
        withTransaction(moveAtOnce) {
            if let usable, usable != stash {
                stash = usable
                model.stash = usable
            }
            model.windowFrame = LocalCalculatorStashGeometry.keepingSize(
                frame.size, at: LocalCalculatorStashGeometry.restored(fitted, stash: stash, bounds: bounds,
                                                                      obstacles: obstacles + stashObstacles))
        }
    }

    /// What a stashed window takes from the screen: its strip, where it takes touches.
    private func stashOccupied(panel: CGRect?, bounds: CGRect) -> [CGRect] {
        guard let panel, let stash = model.stash else { return [] }
        // Where it is drawn: while slid, its live place, so the workspace gives way to it there.
        let waiting = LocalCalculatorStashGeometry.waiting(size: panel.size, stash: sliding(stash, size: panel.size, bounds: bounds),
                                                           bounds: bounds, obstacles: obstacles + stashObstacles)
        // Nothing is drawn without a touch target, so nothing is reserved either.
        return waiting.touch.map { [$0] } ?? []
    }

    /// How far the window shows past its strip: a little while a touch rests on the strip (a
    /// peek, as a tucked float's), following the finger while it pulls; none while it slides.
    private var stashPeek: CGFloat {
        guard let touch = stashTouch, let edge = model.stash?.edge else { return 0 }
        switch touch.kind {
        case nil: return 6
        case .pull:
            let inward = edge == .left ? touch.translation.width : -touch.translation.width
            return min(max(inward - LocalCalculatorStashGeometry.decideDistance, 0), LocalCalculatorStashGeometry.maximumPeek)
        case .slide, .away: return 0
        }
    }

    /// `stash` moved along its edge by a strip being slid there.
    private func sliding(_ stash: LocalCalculatorStash, size: CGSize, bounds: CGRect) -> LocalCalculatorStash {
        guard let touch = stashTouch, touch.kind == .slide, touch.origin.edge == stash.edge else { return stash }
        return LocalCalculatorStashGeometry.slid(touch.origin, along: touch.translation.height, bounds: bounds)
    }

    /// The waiting window moved in by the peek or pull on its strip.
    private func peeked(_ window: CGRect) -> CGRect {
        guard let edge = model.stash?.edge else { return window }
        return window.offsetBy(dx: edge == .left ? stashPeek : -stashPeek, dy: 0)
    }

    /// The part of the window (in its own coordinates) that shows: its strip and any peek.
    private func visibleStrip(of shown: CGRect, waiting strip: CGRect, window: CGRect) -> CGRect {
        guard let edge = model.stash?.edge else { return CGRect(origin: .zero, size: shown.size) }
        let width = min(shown.width, strip.width + stashPeek)
        return CGRect(x: edge == .left ? shown.width - width : 0, y: strip.minY - window.minY,
                      width: width, height: strip.height)
    }

    /// A strip slid along its edge and let go: it waits there (where it was drawn, past any
    /// controls it stepped over), and comes back at that height.
    private func slideEnded(_ panel: CGRect, to slid: LocalCalculatorStash, bounds: CGRect) {
        guard let stash = model.stash, slid.edge == stash.edge else { return }
        let strip = LocalCalculatorStashGeometry.waiting(size: panel.size, stash: slid, bounds: bounds,
                                                         obstacles: obstacles + stashObstacles).strip
        let settled = LocalCalculatorStashGeometry.settled(slid, strip: strip, bounds: bounds)
        model.windowFrame = LocalCalculatorStashGeometry.keepingSize(
            model.windowFrame?.size, at: LocalCalculatorStashGeometry.restored(panel, stash: settled, bounds: bounds,
                                                                               obstacles: obstacles + stashObstacles))
        model.stash = settled
    }

    /// The stashed window's strip, drawn as a tucked float's: a clean dark card along the edge
    /// (never a slice cut through the keys, the text or a scroll indicator) with a grip, and the
    /// calculator's sign when there is room. A tap brings the window back, as does a pull
    /// inward; a slide along the edge moves the strip there (owner QA, round 5). Without a clear
    /// `touch` area the strip only shows, and the calculator button brings it back. Left and
    /// right edges only, so the card always stands along its edge.
    private func stashHandle(strip: CGRect, touch: CGRect, stash: LocalCalculatorStash, bounds: CGRect,
                             restore: @escaping () -> Void, settle: @escaping (LocalCalculatorStash) -> Void,
                             step: @escaping (CGFloat) -> Void) -> some View {
        let area = touch
        let inward: (CGSize) -> CGFloat = { stash.edge == .left ? $0.width : -$0.width }
        let peek = stashPeek
        let lit = stashTouch != nil
        let highContrast = contrast == .increased
        let gripLength = min(36, max(strip.height * 0.3, 16))
        // The card covers all that shows of the window, growing inward with a peek or a pull
        // (never a slice of the live keys or text), inside the strip's touch area.
        let card = CGRect(x: stash.edge == .left ? strip.minX : strip.minX - peek, y: strip.minY,
                          width: strip.width + peek, height: strip.height).offsetBy(dx: -area.minX, dy: -area.minY)
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color(red: 0.07, green: 0.07, blue: 0.08))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(Color.white.opacity(highContrast ? 0.75 : 0.35), lineWidth: 1))
                .frame(width: card.width, height: card.height)
                .position(x: card.midX, y: card.midY)
            Capsule()
                .fill(Color.white.opacity(lit ? 0.95 : 0.5))
                .overlay(Capsule().strokeBorder(Color.black.opacity(0.35), lineWidth: 0.5))
                .frame(width: 4, height: gripLength)
                .position(x: card.midX, y: card.midY)
            if card.height >= gripLength + 40 {
                Image(systemName: LocalCalculatorPanel.symbolName)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Color.white.opacity(0.7))
                    .position(x: card.midX, y: card.midY - gripLength / 2 - 12)
            }
        }
        .frame(width: area.width, height: area.height, alignment: .topLeading)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .updating($stashHeld) { _, held, _ in held = true }
            .onChanged { value in
                var t: StripTouchState
                if let current = stashTouch, current.start == value.startLocation {
                    t = current
                } else {
                    // A new touch (any earlier one was cancelled): its own identity and decision.
                    stashTouchCount &+= 1
                    t = StripTouchState(id: stashTouchCount, start: value.startLocation, kind: nil, translation: .zero,
                                        origin: LocalCalculatorStashGeometry.settled(stash, strip: strip, bounds: bounds))
                }
                t.translation = value.translation
                if t.kind == nil { t.kind = LocalCalculatorStashGeometry.stripTouch(value.translation, edge: stash.edge) }
                stashTouch = t
            }
            .onEnded { value in
                // A touch that was let go of meanwhile (the window moved edge, came back, or the
                // system cancelled it) does nothing when it ends.
                guard let current = stashTouch, current.start == value.startLocation else { return }
                switch current.kind ?? LocalCalculatorStashGeometry.stripTouch(value.translation, edge: stash.edge) {
                case nil:
                    stashTouch = nil
                    restore()   // a tap
                    haptics.play(.selection)
                case .pull:
                    stashTouch = nil
                    if LocalCalculatorStashGeometry.pullRestores(inward: inward(value.translation),
                                                                 projected: inward(value.predictedEndTranslation),
                                                                 travel: LocalCalculatorStashGeometry.decideDistance) {
                        restore()
                        haptics.play(.selection)
                    }
                case .slide:
                    // Let go where it was drawn: the touch ends with its new place set at once.
                    var atOnce = Transaction()
                    atOnce.disablesAnimations = true
                    withTransaction(atOnce) {
                        settle(LocalCalculatorStashGeometry.slid(current.origin, along: value.translation.height, bounds: bounds))
                        stashTouch = nil
                    }
                case .away:
                    stashTouch = nil   // pushed back into its edge: it stays
                }
            })
        .position(x: area.midX, y: area.midY)
        // It moves along its edge at once (controls opening over it, a rotation, a slide let
        // go), never animating across a control.
        .animation(nil, value: strip)
        .transition(.opacity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Calculator", comment: "The local calculator's control and panel."))
        .accessibilityValue(stash.edge == .left
                            ? Text("At the left edge", comment: "Local calculator: stashed at the left edge.")
                            : Text("At the right edge", comment: "Local calculator: stashed at the right edge."))
        .accessibilityHint(Text("Brings the calculator back.", comment: "Local calculator: hint on a stashed window's strip."))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { restore() }
        // The slide, for VoiceOver and Switch Control: a step along the edge, past controls.
        .accessibilityAction(named: Text("Move Up", comment: "Local calculator: moves a stashed window's strip up its edge.")) {
            step(-1)
        }
        .accessibilityAction(named: Text("Move Down", comment: "Local calculator: moves a stashed window's strip down its edge.")) {
            step(1)
        }
        .accessibilityIdentifier("calculatorStashStrip")
    }

    private func aspect(metrics: LocalCalculatorPanelMetrics) -> CGFloat? {
        guard model.mode != .notes else { return nil }
        let preferred = LocalCalculatorWindowGeometry.preferredSize(model.mode, basic: metrics.size)
        return preferred.height > 0 ? preferred.width / preferred.height : nil
    }

    private func settled(_ frame: CGRect, metrics: LocalCalculatorPanelMetrics, bounds: CGRect) -> CGRect {
        let minimum = LocalCalculatorWindowGeometry.minimumSize(model.mode)
        if let aspect = aspect(metrics: metrics) {
            return LocalCalculatorWindowGeometry.proportional(frame, aspect: aspect, minimum: minimum, bounds: bounds)
        }
        return LocalCalculatorWindowGeometry.clamped(frame, minimum: minimum, bounds: bounds)
    }

    private func windowFrame(metrics: LocalCalculatorPanelMetrics, anchor: CGRect, bounds: CGRect) -> CGRect {
        if let frame = model.windowFrame { return settled(frame, metrics: metrics, bounds: bounds) }
        let preferred = LocalCalculatorWindowGeometry.preferredSize(model.mode, basic: metrics.size)
        // Another view was moved: this one opens where that one is.
        if let other = model.windowFrames.values.first {
            return settled(CGRect(origin: other.origin, size: preferred), metrics: metrics, bounds: bounds)
        }
        let size = CGSize(width: min(preferred.width, bounds.width), height: min(preferred.height, bounds.height))
        let placed = LocalCalculatorPlacement.panelFrame(button: anchor, size: size, bounds: bounds, obstacles: obstacles)
        return settled(placed, metrics: metrics, bounds: bounds)
    }

    private func move(by translation: CGSize, from current: CGRect, bounds: CGRect) {
        let start = moveStart ?? current
        if moveStart == nil {
            moveStart = current
            moveGeneration &+= 1
        }
        let moved = start.offsetBy(dx: translation.width, dy: translation.height)
        dragFrame = LocalCalculatorStashGeometry.dragged(moved, bounds: bounds)
    }

    /// Let go: flicked (or pulled more than halfway) past the left or right
    /// edge, it is stashed there, as a floating window tucks; else it stays,
    /// moved back inside.
    private func endMove(velocity: CGVector, from current: CGRect, bounds: CGRect) {
        defer {
            moveStart = nil
            dragFrame = nil
        }
        guard let frame = dragFrame else { return }
        if let flicked = LocalCalculatorStashGeometry.release(frame, velocity: velocity, bounds: bounds),
           let stash = LocalCalculatorStashGeometry.usable(flicked, size: frame.size, bounds: bounds,
                                                           obstacles: obstacles + stashObstacles) {
            model.windowFrame = LocalCalculatorStashGeometry.keepingSize(
                model.windowFrame?.size, at: LocalCalculatorStashGeometry.restored(frame, stash: stash, bounds: bounds,
                                                                                   obstacles: obstacles + stashObstacles))
            // The keyboard guard clears when the notes actually let go (`textViewDidEndEditing`).
            model.stash(at: stash)
            haptics.play(.selection)
        } else {
            model.windowFrame = LocalCalculatorWindowGeometry.clamped(frame, minimum: .zero, bounds: bounds)
        }
    }

    /// VoiceOver's Move to Edge: the nearer of the left and right edges.
    private func stashAtNearestEdge(_ panel: CGRect, bounds: CGRect) {
        guard bounds.height > 0 else { return }
        let edge: WorkspaceEdge = panel.midX < bounds.midX ? .left : .right
        let offset = Double((panel.midY - bounds.minY) / bounds.height)
        guard let stash = LocalCalculatorStashGeometry.usable(LocalCalculatorStash(edge: edge, offset: offset),
                                                              size: panel.size, bounds: bounds,
                                                              obstacles: obstacles + stashObstacles) else { return }
        model.windowFrame = LocalCalculatorStashGeometry.keepingSize(
            model.windowFrame?.size, at: LocalCalculatorStashGeometry.restored(panel, stash: stash, bounds: bounds,
                                                                               obstacles: obstacles + stashObstacles))
        model.stash(at: stash)
    }

    /// Brings a stashed window back (its strip, the calculator button, VoiceOver): fitted to
    /// the bounds it has now, flush with its edge at the height its strip shows, the strip
    /// placed against everything it keeps off now.
    private func restore(_ panel: CGRect, bounds: CGRect) {
        guard let stash = model.stash else { return }
        model.windowFrame = LocalCalculatorStashGeometry.keepingSize(
            model.windowFrame?.size, at: LocalCalculatorStashGeometry.restored(panel, stash: stash, bounds: bounds,
                                                                               obstacles: obstacles + stashObstacles))
        model.stash = nil
    }

    private func resize(by translation: CGSize, from current: CGRect, bounds: CGRect, metrics: LocalCalculatorPanelMetrics) {
        let start = resizeStart ?? current
        if resizeStart == nil { resizeStart = current }
        let minimum = LocalCalculatorWindowGeometry.minimumSize(model.mode)
        let room = CGRect(x: start.minX, y: start.minY, width: bounds.maxX - start.minX, height: bounds.maxY - start.minY)
        if let aspect = aspect(metrics: metrics) {
            // Proportional: whichever way the corner moves further sets the size.
            let grow = max(translation.width / max(start.width, 1), translation.height / max(start.height, 1))
            let frame = CGRect(x: start.minX, y: start.minY, width: start.width * (1 + grow), height: start.height)
            model.windowFrame = LocalCalculatorWindowGeometry.proportional(frame, aspect: aspect, minimum: minimum, bounds: room)
            return
        }
        let width = min(max(minimum.width, start.width + translation.width), room.width)
        let height = min(max(minimum.height, start.height + translation.height), room.height)
        model.windowFrame = CGRect(x: start.minX, y: start.minY, width: width, height: height)
    }

    /// The button's center relative to the panel, so it grows out of it.
    private static func unitPoint(of anchor: CGRect, in panel: CGRect) -> UnitPoint {
        guard panel.width > 0, panel.height > 0 else { return .topLeading }
        return UnitPoint(x: min(max((anchor.midX - panel.minX) / panel.width, 0), 1),
                         y: min(max((anchor.midY - panel.minY) / panel.height, 0), 1))
    }
}

/// The bottom-right corner of a rect cut along its diagonal: points whose
/// distances to the right and bottom edges add up to at most `leg`.
struct LocalCalculatorCornerWedge: Shape {
    var leg: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.maxX, y: rect.maxY - leg))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - leg, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

/// A stashed window shows only this rect of itself (animatable, so it slides
/// in and out with the window).
struct LocalCalculatorStashClip: Shape {
    var visible: CGRect

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>> {
        get { AnimatablePair(AnimatablePair(visible.minX, visible.minY), AnimatablePair(visible.width, visible.height)) }
        set { visible = CGRect(x: newValue.first.first, y: newValue.first.second,
                               width: newValue.second.first, height: newValue.second.second) }
    }

    func path(in rect: CGRect) -> Path { Path(visible) }
}

/// The on-screen keyboard's top edge in screen coordinates while it shows.
@MainActor
final class LocalCalculatorKeyboardObserver: ObservableObject {
    @Published private(set) var top: CGFloat?
    nonisolated(unsafe) private var observers: [NSObjectProtocol] = []

    init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UIResponder.keyboardWillChangeFrameNotification, object: nil,
                                            queue: .main) { [weak self] note in
            let frame = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue
            MainActor.assumeIsolated { self?.update(frame) }
        })
        observers.append(center.addObserver(forName: UIResponder.keyboardWillHideNotification, object: nil,
                                            queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.top = nil }
        })
    }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    private func update(_ frame: CGRect?) {
        guard let frame, frame.height > 0, let screen = UIScreen.mainScreenBounds, frame.minY < screen.maxY - 1 else {
            top = nil
            return
        }
        // A floating or undocked keyboard doesn't push the window up.
        top = frame.maxY >= screen.maxY - 1 ? frame.minY : nil
    }
}

private extension UIScreen {
    @MainActor static var mainScreenBounds: CGRect? {
        (UIApplication.shared.connectedScenes.first { $0 is UIWindowScene } as? UIWindowScene)?.screen.bounds
    }
}

// MARK: - Entry button

/// The calculator's control: a chip like its neighbours, drawn selected
/// while the panel is open. A tap opens or closes the panel.
struct LocalCalculatorEntryButton<Chip: View>: View {
    let open: Bool
    let diameter: CGFloat
    var hitDiameter: CGFloat?
    var hint: String?
    @ViewBuilder let chip: (_ selected: Bool) -> Chip
    let action: () -> Void

    var body: some View {
        VStack(spacing: 2) {
            // A real button at its own size carries the one accessibility element, so its frame
            // (VoiceOver's outline, where a UI test taps) is the face's. Made around the stack,
            // hosted iPhone Duo reported the whole screen as the element's frame.
            Button(action: action) {
                Image(systemName: LocalCalculatorPanel.symbolName)
                    .font(.system(size: (diameter * 0.4).rounded(), weight: .semibold))
                    .foregroundStyle(open ? Color.black : Color.white)
                    .frame(width: diameter, height: diameter)
                    .background(chip(open))
                    .frame(width: hitDiameter ?? diameter, height: hitDiameter ?? diameter)
                    .contentShape(Circle())
            }
            .buttonStyle(LocalCalculatorEntryButtonStyle())
            .accessibilityLabel(Text("Calculator", comment: "The local calculator's control and panel."))
            .accessibilityValue(open ? Text("Open", comment: "The local calculator's panel is showing.") : Text(""))
            .accessibilityHint(LocalCalculatorPanel.deviceOnlyHint)
            .accessibilityInputLabels([Text("Calculator", comment: "The local calculator's control and panel.")])
            if let hint {
                // The caption only shows what the button is; the button says it already.
                Text(hint)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(width: diameter + PadControlMetrics.hintWidthAllowance, height: PadControlMetrics.hintHeight)
                    .accessibilityHidden(true)
            }
        }
    }
}

/// The calculator button as it always looked: no dimming or highlight while pressed.
private struct LocalCalculatorEntryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { configuration.label }
}


// MARK: - Palette

enum LocalCalculatorPalette {
    static let digit = Color(white: 0.2)
    static let function = Color(red: 0.29, green: 0.33, blue: 0.42)
    static let clear = Color(red: 0.86, green: 0.3, blue: 0.32)
    static let operation = Color(red: 1.0, green: 0.6, blue: 0.14)
    static let equals = Color(red: 0.16, green: 0.74, blue: 0.5)
    static let scientific = Color(red: 0.35, green: 0.3, blue: 0.62)
    /// Answers, as Math Notes colours them.
    static let answer = Color(red: 1.0, green: 0.78, blue: 0.3)
    static let answerGlow = Color(red: 1.0, green: 0.95, blue: 0.75)
}

// MARK: - Panel

/// The calculator window: a title bar (move it by dragging), the current
/// view and a resize grip in the corner. Every touch inside it stays here.
struct LocalCalculatorPanel: View {
    static let symbolName = "plus.forwardslash.minus"

    @ObservedObject var model: LocalCalculatorModel
    let haptics: ReceiverHaptics
    var onMove: (CGSize) -> Void = { _ in }
    /// The title bar let go, with its velocity (points per second).
    var onMoveEnd: (CGVector) -> Void = { _ in }
    var onResize: (CGSize) -> Void = { _ in }
    var onResizeEnd: () -> Void = {}
    /// The title bar's drag ended without an end (cancelled by the system).
    var onMoveCancel: () -> Void = {}
    /// Stash at the nearer side edge (VoiceOver's Move to Edge).
    var onStash: () -> Void = {}

    @Environment(\.locale) private var locale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showsCopied = false
    /// Gesture state resets even when a drag is cancelled, unlike `onEnded`.
    @GestureState private var moving = false
    @GestureState private var resizing = false

    static var deviceOnlyHint: Text {
        UIDevice.current.userInterfaceIdiom == .pad
            ? Text("Works on this iPad only. Nothing is sent to your Mac.",
                   comment: "Accessibility hint for the local calculator.")
            : Text("Works on this iPhone only. Nothing is sent to your Mac.",
                   comment: "Accessibility hint for the local calculator.")
    }

    private static let cornerRadius: CGFloat = 22
    private static let gap: CGFloat = 6

    var body: some View {
        VStack(spacing: Self.gap) {
            titleBar
            switch model.mode {
            case .basic, .scientific:
                LocalCalculatorKeypadView(model: model, haptics: haptics)
            case .notes:
                LocalCalculatorNotesView(model: model, haptics: haptics)
            }
        }
        .padding(8)
        .background(panelBackground)
        .overlay(alignment: .bottomTrailing) { resizeGrip }
        // Gaps between keys belong to the panel too: nothing falls through.
        .contentShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Calculator", comment: "The local calculator's control and panel."))
        .accessibilityAction(.escape) { close() }
        .accessibilityAction(named: Text("Move to Edge", comment: "Local calculator: stashes the window at the nearer side edge.")) {
            onStash()
        }
        .onChange(of: model.copyCount) { _ in flashCopied() }
        // After an end these do nothing; after a cancel they let go cleanly.
        .onChange(of: moving) { if !$0 { onMoveCancel() } }
        .onChange(of: resizing) { if !$0 { onResizeEnd() } }
    }

    private var panelBackground: some View {
        RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
            .fill(.ultraThinMaterial)
            // One flat dark tint, like the workspace's other floating chrome (owner QA, round 5:
            // no gradient).
            .overlay(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                .fill(Color(white: 0.06, opacity: 0.88)))
            .overlay(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                .strokeBorder(Color.white.opacity(0.14), lineWidth: 0.75))
            .shadow(color: .black.opacity(0.35), radius: 14, y: 4)
    }

    // MARK: Title bar

    private var titleBar: some View {
        HStack(spacing: 6) {
            headerButton("xmark", label: Text("Close Calculator", comment: "Closes the local calculator's panel."),
                         action: close)
            // The middle of the bar moves the window.
            HStack(spacing: 4) {
                Capsule().fill(Color.white.opacity(0.28)).frame(width: 28, height: 4)
            }
            .frame(maxWidth: .infinity, minHeight: 32)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 2, coordinateSpace: .global)
                .updating($moving) { _, moving, _ in moving = true }
                .onChanged { onMove($0.translation) }
                .onEnded { onMoveEnd(Self.velocity(of: $0)) })
            .accessibilityHidden(true)
            headerButton(model.mode == .notes ? "keyboard.fill" : "keyboard",
                         label: model.mode == .notes
                            ? Text("Keypad", comment: "Local calculator: back to the keypad from notes.")
                            : Text("Type or Write", comment: "Local calculator: opens notes to type or handwrite calculations."),
                         selected: model.mode == .notes) {
                model.mode = model.mode == .notes ? .basic : .notes
                haptics.play(.selection)
            }
            if model.mode != .notes {
                headerButton(model.mode == .scientific ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                             label: model.mode == .scientific
                                ? Text("Basic", comment: "Local calculator: back to the basic keypad.")
                                : Text("Scientific", comment: "Local calculator: expands to the scientific keypad."),
                             selected: model.mode == .scientific) {
                    model.mode = model.mode == .scientific ? .basic : .scientific
                    haptics.play(.selection)
                }
            }
            // Notes copy an answer by tapping it; this copies the keypad's result.
            if model.mode != .notes {
            Button(action: copy) {
                Image(systemName: showsCopied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(showsCopied ? LocalCalculatorPalette.equals : .white.opacity(model.currentValue == nil ? 0.35 : 0.95))
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(Color.white.opacity(0.12)))
                    .frame(minWidth: 36, minHeight: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(model.currentValue == nil)
            .accessibilityLabel(Text("Copy Result", comment: "Local calculator: copies the result to this device's clipboard."))
            .accessibilityHint(Text("Copies the number to this device's clipboard.",
                                    comment: "Accessibility hint for the local calculator's Copy Result button."))
            }
        }
    }

    private func headerButton(_ symbol: String, label: Text, selected: Bool = false,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(selected ? Color.black : Color.white.opacity(0.92))
                .frame(width: 32, height: 32)
                .background(Circle().fill(selected ? LocalCalculatorPalette.answer : Color.white.opacity(0.12)))
                .frame(minWidth: 36, minHeight: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var resizeGrip: some View {
        Image(systemName: "arrow.up.left.and.arrow.down.right")
            .font(.system(size: 10, weight: .bold))
            .rotationEffect(.degrees(90))
            .foregroundStyle(.white.opacity(0.5))
            .frame(width: 30, height: 30, alignment: .bottomTrailing)
            .padding(4)
            // Only the corner outside the round bottom-right key (=): a square here
            // took the middle of that key, so taps on = resized instead (round 4).
            .contentShape(LocalCalculatorCornerWedge(leg: 32))
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .updating($resizing) { _, resizing, _ in resizing = true }
                .onChanged { onResize($0.translation) }
                .onEnded { _ in onResizeEnd() })
            .accessibilityHidden(true)
    }

    /// A drag's release velocity in points per second. Before iOS 17, from
    /// its predicted end: UIKit's normal deceleration carries a release about
    /// half its speed in points.
    static func velocity(of value: DragGesture.Value) -> CGVector {
        if #available(iOS 17.0, *) { return CGVector(dx: value.velocity.width, dy: value.velocity.height) }
        return CGVector(dx: (value.predictedEndTranslation.width - value.translation.width) * 2,
                        dy: (value.predictedEndTranslation.height - value.translation.height) * 2)
    }

    // MARK: Actions

    private func copy() {
        guard model.copyResult(locale: locale) else { return }
        haptics.play(.confirmation)
        if UIAccessibility.isVoiceOverRunning {
            UIAccessibility.post(notification: .announcement,
                                 argument: String(localized: "Copied", comment: "Local calculator: copies the result to this device's clipboard."))
        }
    }

    private func close() {
        // The keyboard guard (`LocalCalculatorTextFocus`) clears when the notes editor actually
        // lets go (it resigns as `notesEditing` turns off, or as it leaves), not before: while the
        // panel animates out the editor may still hold the keyboard.
        model.close()
        haptics.play(.selection)
    }

    private func flashCopied() {
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) { showsCopied = true }
        let count = model.copyCount
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            guard model.copyCount == count else { return }
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { showsCopied = false }
        }
    }

    /// The display as VoiceOver reads it: scientific values in words.
    static func spoken(_ display: LocalCalculatorDisplay) -> String {
        switch display {
        case .plain(let text): return text
        case .scientific(let mantissa, let exponent):
            return String(localized: "\(mantissa) times ten to the power of \(exponent)",
                          comment: "Local calculator: a number in scientific notation, read aloud.")
        case .error:
            return String(localized: "Error", comment: "Local calculator display after a division by zero or an overflow.")
        }
    }
}

// MARK: - Keypad view

private struct LocalCalculatorKeypadView: View {
    @ObservedObject var model: LocalCalculatorModel
    let haptics: ReceiverHaptics

    @Environment(\.locale) private var locale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// History over the keypad, for a window too short to show it above.
    @State private var historyShown = false

    private static let gap: CGFloat = 6

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            // The keypad takes what it needs; history and the display share
            // the rest.
            let keyRows: CGFloat = 5
            let keyHeight = min(72, max(30, (size.height * 0.62 - Self.gap * (keyRows - 1)) / keyRows))
            let keypadHeight = keyHeight * keyRows + Self.gap * (keyRows - 1)
            let displayHeight = min(96, max(56, size.height - keypadHeight - Self.gap))
            let historyHeight = max(0, size.height - keypadHeight - displayHeight - Self.gap * 2)
            let compact = historyHeight < 24
            VStack(spacing: Self.gap) {
                if !compact {
                    historyList.frame(height: historyHeight)
                }
                display.frame(height: displayHeight)
                    .overlay(alignment: .topLeading) {
                        if compact, !model.history.isEmpty { historyButton }
                    }
                keypad(keyHeight: keyHeight, width: size.width).frame(height: keypadHeight)
            }
            .frame(width: size.width, height: size.height, alignment: .bottom)
            .overlay {
                if compact, historyShown {
                    VStack(spacing: 6) {
                        HStack {
                            Text("History", comment: "Local calculator: heading of the history shown over the keypad.")
                                .font(.subheadline.weight(.semibold)).foregroundStyle(.white.opacity(0.9))
                            Spacer()
                            Button { historyShown = false } label: {
                                Image(systemName: "xmark").font(.system(size: 12, weight: .bold))
                                    .frame(width: 30, height: 30).background(Circle().fill(Color.white.opacity(0.12)))
                            }
                            .buttonStyle(.plain).foregroundStyle(.white)
                            .accessibilityLabel(Text("Close History", comment: "Local calculator: closes the history."))
                        }
                        historyList
                    }
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.black.opacity(0.92)))
                    .transition(.opacity)
                }
            }
            .onChange(of: compact) { if !$0 { historyShown = false } }
            .onChange(of: model.keypad.input) { _ in historyShown = false }
        }
    }

    // MARK: History

    private var historyButton: some View {
        Button { historyShown = true; haptics.play(.selection) } label: {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 28, height: 28)
                .background(Circle().fill(Color.white.opacity(0.12)))
                .frame(minWidth: 36, minHeight: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("History", comment: "Local calculator: shows past calculations in a short window."))
    }

    private var historyList: some View {
        ScrollViewReader { reader in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .trailing, spacing: 6) {
                    ForEach(model.history) { entry in
                        historyRow(entry).id(entry.id)
                    }
                }
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .defaultScrollAnchorBottom()
            .onChange(of: model.history.count) { _ in
                if let last = model.history.last { withAnimation { reader.scrollTo(last.id, anchor: .bottom) } }
            }
            .overlay {
                if model.history.isEmpty {
                    Text("History appears here", comment: "Local calculator: empty history placeholder.")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.3))
                }
            }
        }
        .mask(LinearGradient(colors: [.clear, .black, .black], startPoint: .top, endPoint: .init(x: 0.5, y: 0.25)))
    }

    private func historyRow(_ entry: LocalCalculatorModel.HistoryEntry) -> some View {
        let answer = LocalCalculatorFormat.display(entry.value, locale: locale)
        return Button {
            model.use(entry.value)
            haptics.play(.selection)
        } label: {
            HStack(spacing: 6) {
                Text(verbatim: entry.expression)
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
                    .truncationMode(.head)
                Text(verbatim: "= " + answer.text)
                    .foregroundStyle(LocalCalculatorPalette.answer.opacity(0.9))
                    .lineLimit(1)
                    .layoutPriority(1)
            }
            .font(.system(size: 14, weight: .regular).monospacedDigit())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                model.copy(entry.value, locale: locale)
            } label: {
                Label(String(localized: "Copy Answer", comment: "Local calculator history: copies an answer."),
                      systemImage: "doc.on.doc")
            }
            Button {
                UIPasteboard.general.string = entry.expression + " = " + LocalCalculatorFormat.copyText(entry.value, locale: locale)
            } label: {
                Label(String(localized: "Copy Calculation", comment: "Local calculator history: copies the sum and its answer."),
                      systemImage: "text.badge.plus")
            }
            Button(role: .destructive) {
                model.removeHistory(entry.id)
            } label: {
                Label(String(localized: "Delete", comment: "Local calculator history: removes one line."), systemImage: "trash")
            }
            Button(role: .destructive) {
                model.clearHistory()
            } label: {
                Label(String(localized: "Clear History", comment: "Local calculator: removes every history line."),
                      systemImage: "clear")
            }
        }
        .accessibilityLabel(Text(verbatim: entry.expression + " = " + LocalCalculatorPanel.spoken(answer)))
        .accessibilityHint(Text("Uses this answer.", comment: "Local calculator history row hint."))
    }

    // MARK: Display

    private var resultDisplay: LocalCalculatorDisplay {
        if model.failed { return .error }
        guard let value = model.currentValue else { return .error }
        return LocalCalculatorFormat.display(value, locale: locale)
    }

    private var display: some View {
        let big: String
        let small: String
        var smallIsAnswer = false
        if model.failed {
            big = String(localized: "Error", comment: "Local calculator display after a division by zero or an overflow.")
            small = model.keypad.displayInput(locale: locale)
        } else if model.showsAnswer {
            big = resultDisplay.text
            small = model.answeredExpression + " ="
        } else {
            big = model.input.isEmpty ? LocalCalculatorFormat.display(0, locale: locale).text : model.keypad.displayInput(locale: locale)
            if let preview = model.preview {
                small = "= " + LocalCalculatorFormat.display(preview, locale: locale).text
                smallIsAnswer = true
            } else {
                small = ""
            }
        }
        return VStack(alignment: .trailing, spacing: 2) {
            Text(verbatim: small)
                .font(.system(size: 16, weight: .medium).monospacedDigit())
                .foregroundStyle(smallIsAnswer ? LocalCalculatorPalette.answer.opacity(0.75) : .white.opacity(0.5))
                .lineLimit(1)
                .truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .trailing)
            Text(verbatim: big)
                .font(.system(size: 40, weight: model.showsAnswer ? .regular : .light).monospacedDigit())
                .foregroundStyle(model.showsAnswer ? LocalCalculatorPalette.answer : Color.white)
                .lineLimit(1)
                .minimumScaleFactor(0.35)
                .truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .modifier(LocalCalculatorShimmer(trigger: model.showsAnswer ? model.history.last?.id : nil))
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .contentShape(Rectangle())
        // A sideways swipe deletes the last character, as in Calculator.
        .gesture(DragGesture(minimumDistance: 16).onEnded { value in
            let dx = value.translation.width
            if abs(dx) > 28, abs(dx) > abs(value.translation.height) * 1.5 { press(.delete) }
        })
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Result", comment: "Local calculator display, read with its number."))
        .accessibilityValue(Text(verbatim: model.showsAnswer || model.input.isEmpty || model.failed
                                    ? LocalCalculatorPanel.spoken(resultDisplay)
                                    : model.keypad.displayInput(locale: locale) + (model.preview.map { ", = " + LocalCalculatorFormat.display($0, locale: locale).text } ?? "")))
        .accessibilityAddTraits(.updatesFrequently)
        .accessibilityAction(named: Text("Delete", comment: "Local calculator: deletes the last digit typed.")) {
            press(.delete)
        }
        .accessibilityAction(named: Text("Copy Result", comment: "Local calculator: copies the result to this device's clipboard.")) {
            model.copyResult(locale: locale)
        }
    }

    // MARK: Keys

    private enum KeyID: Hashable {
        case clear, sign, percent, delete, point, equals
        case digit(Int)
        case operation(LocalCalculator.Operation)
        case open, close, angle, inverse
        case sin, cos, tan, ln, log, sqrt, square, power, cbrt, reciprocal, factorial, abs, pi, e, answer
    }

    private static let basicRows: [[KeyID]] = [
        [.clear, .sign, .percent, .operation(.divide)],
        [.digit(7), .digit(8), .digit(9), .operation(.multiply)],
        [.digit(4), .digit(5), .digit(6), .operation(.subtract)],
        [.digit(1), .digit(2), .digit(3), .operation(.add)],
        [.delete, .digit(0), .point, .equals],
    ]

    private static let scientificRows: [[KeyID]] = [
        [.open, .close, .inverse, .angle],
        [.sin, .cos, .tan, .pi],
        [.ln, .log, .sqrt, .e],
        [.square, .power, .cbrt, .reciprocal],
        [.factorial, .abs, .answer, .percent],
    ]

    private func keypad(keyHeight: CGFloat, width: CGFloat) -> some View {
        let scientific = model.mode == .scientific
        let columns: CGFloat = scientific ? 8 : 4
        let keyWidth = max(24, (width - Self.gap * (columns - 1)) / columns)
        return HStack(spacing: Self.gap) {
            if scientific {
                grid(Self.scientificRows, keyWidth: keyWidth, keyHeight: keyHeight)
            }
            grid(Self.basicRows, keyWidth: keyWidth, keyHeight: keyHeight)
        }
    }

    private func grid(_ rows: [[KeyID]], keyWidth: CGFloat, keyHeight: CGFloat) -> some View {
        Grid(horizontalSpacing: Self.gap, verticalSpacing: Self.gap) {
            ForEach(rows.indices, id: \.self) { row in
                GridRow {
                    ForEach(rows[row], id: \.self) { id in keyButton(id, width: keyWidth, height: keyHeight) }
                }
            }
        }
    }

    private func role(_ id: KeyID) -> LocalCalculatorKeyRole {
        switch id {
        case .digit, .point: return .digit
        case .clear: return .clear
        case .sign, .percent, .delete: return .function
        case .operation: return .operation
        case .equals: return .equals
        default: return .scientific
        }
    }

    private func key(for id: KeyID) -> LocalCalculatorModel.Key? {
        switch id {
        case .clear: return .clear
        case .sign: return .toggleSign
        case .percent: return .percent
        case .delete: return .delete
        case .point: return .decimalPoint
        case .equals: return .equals
        case .digit(let digit): return .digit(digit)
        case .operation(let operation): return .operation(operation)
        case .open: return .open
        case .close: return .close
        case .angle, .inverse: return nil
        case .sin: return .function(model.inverse ? "asin" : "sin")
        case .cos: return .function(model.inverse ? "acos" : "cos")
        case .tan: return .function(model.inverse ? "atan" : "tan")
        case .ln: return .function(model.inverse ? "exp" : "ln")
        case .log: return model.inverse ? .constant("10^") : .function("log")
        case .sqrt: return .function("sqrt")
        case .square: return .square
        case .power: return .power
        case .cbrt: return .function("cbrt")
        case .reciprocal: return .reciprocal
        case .factorial: return .factorial
        case .abs: return .function("abs")
        case .pi: return .constant("π")
        case .e: return .constant("e")
        case .answer: return .answer
        }
    }

    private func keyButton(_ id: KeyID, width: CGFloat, height: CGFloat) -> some View {
        let selected: Bool = {
            switch id {
            case .inverse: return model.inverse
            case .operation(let operation):
                return !model.showsAnswer
                    && model.input.trimmingCharacters(in: .whitespaces).hasSuffix(LocalCalculatorModel.symbol(operation))
            default: return false
            }
        }()
        let glyph = min(26, max(13, min(width, height) * 0.42))
        return Button {
            switch id {
            case .angle:
                model.angle = model.angle == .degrees ? .radians : .degrees
            case .inverse:
                model.inverse.toggle()
            default:
                if let key = key(for: id) { press(key) }
            }
            haptics.play(.selection)
        } label: {
            keyLabel(id, glyph: glyph)
                .frame(width: min(width, height), height: min(width, height))
                .contentShape(Circle())
        }
        .buttonStyle(LocalCalculatorKeyStyle(role: role(id), selected: selected))
        .frame(width: width, height: height)
        .accessibilityLabel(accessibilityLabel(id))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder
    private func keyLabel(_ id: KeyID, glyph: CGFloat) -> some View {
        let small = glyph * 0.72
        switch id {
        case .clear: Text(verbatim: "AC").font(.system(size: glyph * 0.8, weight: .semibold))
        case .sign: Image(systemName: "plus.forwardslash.minus").font(.system(size: glyph * 0.8, weight: .medium))
        case .percent: Image(systemName: "percent").font(.system(size: glyph * 0.8, weight: .medium))
        case .delete: Image(systemName: "delete.left").font(.system(size: glyph * 0.8, weight: .medium))
        case .equals: Image(systemName: "equal").font(.system(size: glyph, weight: .bold))
        case .point: Text(verbatim: locale.decimalSeparator ?? ".").font(.system(size: glyph * 1.1))
        case .digit(let digit): Text(verbatim: Self.digit(digit, locale)).font(.system(size: glyph * 1.05))
        case .operation(let operation):
            Image(systemName: Self.symbol(operation)).font(.system(size: glyph * 0.95, weight: .bold))
        case .open: Text(verbatim: "(").font(.system(size: glyph))
        case .close: Text(verbatim: ")").font(.system(size: glyph))
        case .angle: Text(verbatim: model.angle == .degrees ? "Deg" : "Rad").font(.system(size: small, weight: .semibold))
        case .inverse: Text(verbatim: "Inv").font(.system(size: small, weight: .semibold))
        case .sin: Text(verbatim: model.inverse ? "sin⁻¹" : "sin").font(.system(size: small, weight: .medium))
        case .cos: Text(verbatim: model.inverse ? "cos⁻¹" : "cos").font(.system(size: small, weight: .medium))
        case .tan: Text(verbatim: model.inverse ? "tan⁻¹" : "tan").font(.system(size: small, weight: .medium))
        case .ln: Text(verbatim: model.inverse ? "eˣ" : "ln").font(.system(size: small, weight: .medium))
        case .log: Text(verbatim: model.inverse ? "10ˣ" : "log").font(.system(size: small, weight: .medium))
        case .sqrt: Text(verbatim: "√x").font(.system(size: small, weight: .medium))
        case .square: Text(verbatim: "x²").font(.system(size: small, weight: .medium))
        case .power: Text(verbatim: "xʸ").font(.system(size: small, weight: .medium))
        case .cbrt: Text(verbatim: "∛x").font(.system(size: small, weight: .medium))
        case .reciprocal: Text(verbatim: "1/x").font(.system(size: small, weight: .medium))
        case .factorial: Text(verbatim: "x!").font(.system(size: small, weight: .medium))
        case .abs: Text(verbatim: "|x|").font(.system(size: small, weight: .medium))
        case .pi: Text(verbatim: "π").font(.system(size: glyph * 0.9))
        case .e: Text(verbatim: "e").font(.system(size: glyph * 0.9))
        case .answer: Text(verbatim: "Ans").font(.system(size: small, weight: .semibold))
        }
    }

    private func accessibilityLabel(_ id: KeyID) -> Text {
        switch id {
        case .clear: return Text("All Clear", comment: "Local calculator key: clears the whole calculation.")
        case .sign: return Text("Plus or Minus", comment: "Local calculator key: changes the sign.")
        case .percent: return Text("Percent", comment: "Local calculator key.")
        case .delete: return Text("Delete", comment: "Local calculator: deletes the last digit typed.")
        case .point: return Text("Decimal Point", comment: "Local calculator key.")
        case .equals: return Text("Equals", comment: "Local calculator key.")
        case .digit(let digit): return Text(verbatim: Self.digit(digit, locale))
        case .operation(.add): return Text("Plus", comment: "Local calculator key: addition.")
        case .operation(.subtract): return Text("Minus", comment: "Local calculator key: subtraction.")
        case .operation(.multiply): return Text("Multiply", comment: "Local calculator key.")
        case .operation(.divide): return Text("Divide", comment: "Local calculator key.")
        case .open: return Text("Open Parenthesis", comment: "Local calculator key.")
        case .close: return Text("Close Parenthesis", comment: "Local calculator key.")
        case .angle:
            return model.angle == .degrees
                ? Text("Degrees", comment: "Local calculator: angles in degrees; tap for radians.")
                : Text("Radians", comment: "Local calculator: angles in radians; tap for degrees.")
        case .inverse: return Text("Inverse Functions", comment: "Local calculator key: switches to inverse functions.")
        case .sin: return model.inverse ? Text(verbatim: "arcsine") : Text(verbatim: "sine")
        case .cos: return model.inverse ? Text(verbatim: "arccosine") : Text(verbatim: "cosine")
        case .tan: return model.inverse ? Text(verbatim: "arctangent") : Text(verbatim: "tangent")
        case .ln: return model.inverse ? Text("e to the power of x", comment: "Local calculator key.")
                                       : Text("Natural Logarithm", comment: "Local calculator key.")
        case .log: return model.inverse ? Text("10 to the power of x", comment: "Local calculator key.")
                                        : Text("Logarithm", comment: "Local calculator key.")
        case .sqrt: return Text("Square Root", comment: "Local calculator key.")
        case .square: return Text("Squared", comment: "Local calculator key.")
        case .power: return Text("To the Power of", comment: "Local calculator key.")
        case .cbrt: return Text("Cube Root", comment: "Local calculator key.")
        case .reciprocal: return Text("Reciprocal", comment: "Local calculator key.")
        case .factorial: return Text("Factorial", comment: "Local calculator key.")
        case .abs: return Text("Absolute Value", comment: "Local calculator key.")
        case .pi: return Text(verbatim: "pi")
        case .e: return Text(verbatim: "e")
        case .answer: return Text("Last Answer", comment: "Local calculator key.")
        }
    }

    private static func symbol(_ operation: LocalCalculator.Operation) -> String {
        switch operation {
        case .add: return "plus"
        case .subtract: return "minus"
        case .multiply: return "multiply"
        case .divide: return "divide"
        }
    }

    /// The region's own digits, matching the display.
    private static func digit(_ digit: Int, _ locale: Locale) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        return formatter.string(from: NSNumber(value: digit)) ?? String(digit)
    }

    private func press(_ key: LocalCalculatorModel.Key) {
        model.press(key)
        if key == .equals, UIAccessibility.isVoiceOverRunning {
            UIAccessibility.post(notification: .announcement, argument: LocalCalculatorPanel.spoken(resultDisplay))
        }
    }
}

// MARK: - Notes view

/// Soulver / Math Notes: one text view, one calculation or question per line,
/// typed or handwritten (Scribble turns Apple Pencil writing into text). Each
/// line's answer sits beside it in colour and shimmers when it appears; tap
/// one to copy it. A rail above the keyboard holds the maths symbols and the
/// button that puts the keyboard away.
private struct LocalCalculatorNotesView: View {
    @ObservedObject var model: LocalCalculatorModel
    let haptics: ReceiverHaptics
    @Environment(\.locale) private var locale

    var body: some View {
        let results = model.noteResults
        VStack(spacing: 6) {
            LocalCalculatorNotesEditor(
                text: $model.notesText,
                editing: $model.notesEditing,
                answers: results.map { answer($0) },
                onCopy: { index in
                    guard index < results.count, model.copy(results[index], locale: locale) else { return }
                    haptics.play(.confirmation)
                })
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.05)))
            HStack(spacing: 8) {
                Text("Try: 20% of 150 · 5 km in miles · 3pm PST in London · 5 hours from now · x = 4, then 2x + 1",
                     comment: "Local calculator notes: examples of what can be typed.")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.4))
                    .lineLimit(2)
                    .minimumScaleFactor(0.75)
                Spacer(minLength: 0)
                Button {
                    model.angle = model.angle == .degrees ? .radians : .degrees
                } label: {
                    Text(verbatim: model.angle == .degrees ? "Deg" : "Rad")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Capsule().fill(LocalCalculatorPalette.scientific))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(model.angle == .degrees
                                    ? Text("Degrees", comment: "Local calculator: angles in degrees; tap for radians.")
                                    : Text("Radians", comment: "Local calculator: angles in radians; tap for degrees."))
                Button {
                    model.clearNotes()
                    haptics.play(.selection)
                } label: {
                    Image(systemName: "trash")
                        .font(.caption.weight(.semibold))
                        .padding(6)
                        .background(Circle().fill(Color.white.opacity(0.12)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Clear Notes", comment: "Local calculator: clears every notes line."))
            }
            .padding(.horizontal, 4)
        }
        // Not while stashed: a remount (a rotation) must not raise the keyboard for a hidden window.
        .onAppear { if model.stash == nil { model.notesEditing = true } }
        .onDisappear { model.notesEditing = false }
    }

    /// What a line's answer shows: its text answer, or its number.
    private func answer(_ result: CalculatorLineResult) -> String? {
        if let text = result.text { return text }
        return result.value.map { LocalCalculatorFormat.display($0, locale: locale).text }
    }
}

/// The notes' text view with its answer column, placeholder and symbol rail.
private struct LocalCalculatorNotesEditor: UIViewRepresentable {
    @Binding var text: String
    @Binding var editing: Bool
    /// One per line; nil where a line has no answer.
    let answers: [String?]
    let onCopy: (Int) -> Void

    func makeUIView(context: Context) -> NotesEditorView {
        let view = NotesEditorView()
        view.textView.delegate = context.coordinator
        view.onCopy = onCopy
        view.onDismissKeyboard = { [weak view] in view?.textView.resignFirstResponder() }
        return view
    }

    func updateUIView(_ view: NotesEditorView, context: Context) {
        context.coordinator.parent = self
        view.onCopy = onCopy
        if view.textView.text != text { view.textView.text = text }
        view.update(answers: answers)
        if editing, !view.textView.isFirstResponder, view.window != nil {
            let wanted = _editing
            // Only if still wanted when it runs (stashing may have let go meanwhile).
            DispatchQueue.main.async {
                guard wanted.wrappedValue, view.window != nil else { return }
                view.textView.becomeFirstResponder()
            }
        } else if !editing, view.textView.isFirstResponder {
            let wanted = _editing
            // Only if still unwanted when it runs (focus may have come back meanwhile).
            DispatchQueue.main.async {
                guard !wanted.wrappedValue else { return }
                view.textView.resignFirstResponder()
            }
        }
    }

    static func dismantleUIView(_ view: NotesEditorView, coordinator: Coordinator) {
        // Only the editor that holds the keyboard gives up the guard, once it has let go.
        guard view.textView.isFirstResponder else { return }
        view.textView.resignFirstResponder()
        LocalCalculatorTextFocus.isEditing = false
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: LocalCalculatorNotesEditor

        init(parent: LocalCalculatorNotesEditor) { self.parent = parent }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
            (textView.superview as? NotesEditorView)?.layoutAnswers()
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            LocalCalculatorTextFocus.isEditing = true
            if !parent.editing { parent.editing = true }
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            LocalCalculatorTextFocus.isEditing = false
            if parent.editing { parent.editing = false }
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            (scrollView.superview as? NotesEditorView)?.layoutAnswers()
        }
    }
}

/// UIKit side of the notes: the text view, the answer labels beside each
/// line, the placeholder and the keyboard's symbol rail.
final class NotesEditorView: UIView {
    let textView = UITextView(usingTextLayoutManager: false)
    var onCopy: ((Int) -> Void)?
    var onDismissKeyboard: (() -> Void)?

    private let placeholder = UILabel()
    private var labels: [UILabel] = []
    private var answers: [String?] = []
    private static let answerFont = UIFont.monospacedDigitSystemFont(ofSize: 18, weight: .semibold)
    private static let inset: CGFloat = 10

    override init(frame: CGRect) {
        super.init(frame: frame)
        // Answers sit beside the scrolling text, not in it: keep them inside the editor.
        clipsToBounds = true
        textView.backgroundColor = .clear
        textView.font = UIFont.monospacedDigitSystemFont(ofSize: 18, weight: .regular)
        textView.textColor = .white
        textView.tintColor = UIColor(LocalCalculatorPalette.answer)
        textView.keyboardAppearance = .dark
        textView.autocorrectionType = .no
        textView.autocapitalizationType = .none
        textView.spellCheckingType = .no
        textView.smartDashesType = .no
        textView.smartQuotesType = .no
        textView.smartInsertDeleteType = .no
        textView.alwaysBounceVertical = true
        textView.keyboardDismissMode = .interactive
        textView.textContainerInset = UIEdgeInsets(top: Self.inset, left: 6, bottom: Self.inset, right: Self.inset)
        textView.inputAccessoryView = makeRail()
        addSubview(textView)
        placeholder.text = String(localized: "Type or write a sum or a question, one per line",
                                  comment: "Local calculator notes: placeholder while the notes are empty.")
        placeholder.font = UIFont.systemFont(ofSize: 16)
        placeholder.textColor = UIColor.white.withAlphaComponent(0.28)
        placeholder.numberOfLines = 0
        placeholder.isUserInteractionEnabled = false
        addSubview(placeholder)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unsupported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        textView.frame = bounds
        let inset = textView.textContainerInset
        placeholder.frame = CGRect(x: inset.left + 5, y: inset.top, width: max(0, bounds.width - inset.left - 16), height: 44)
        placeholder.sizeToFit()
        layoutAnswers()
    }

    func update(answers: [String?]) {
        let previous = self.answers
        self.answers = answers
        placeholder.isHidden = !textView.text.isEmpty
        while labels.count < answers.count {
            let label = UILabel()
            label.font = Self.answerFont
            label.textColor = UIColor(LocalCalculatorPalette.answer)
            label.textAlignment = .right
            // A long answer (a date with a time) shrinks to fit a narrow sheet; VoiceOver reads it whole.
            label.adjustsFontSizeToFitWidth = true
            label.minimumScaleFactor = 0.55
            label.isUserInteractionEnabled = true
            label.tag = labels.count
            label.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapAnswer(_:))))
            label.accessibilityTraits = .button
            label.accessibilityHint = String(localized: "Copies this answer.", comment: "Local calculator notes: an answer's hint.")
            addSubview(label)
            labels.append(label)
        }
        for (i, label) in labels.enumerated() {
            let text = i < answers.count ? answers[i] : nil
            label.text = text
            label.isHidden = text == nil
            label.accessibilityLabel = text.map { "= " + $0 }
            if let text, (i < previous.count ? previous[i] : nil) != text { shimmer(label) }
        }
        // The answers' column: as wide as the widest answer, at most 45% of the sheet.
        let widest = answers.compactMap { $0 }.map { ($0 as NSString).size(withAttributes: [.font: Self.answerFont]).width }.max() ?? 0
        let column = widest > 0 ? min(widest + 18, bounds.width * 0.45) : Self.inset
        if abs(textView.textContainerInset.right - column) > 0.5 {
            textView.textContainerInset.right = column
        }
        layoutAnswers()
    }

    /// Each answer beside the last line fragment of its line.
    func layoutAnswers() {
        let manager = textView.layoutManager
        let container = textView.textContainer
        manager.ensureLayout(for: container)
        let text = (textView.text ?? "") as NSString
        let inset = textView.textContainerInset
        let column = max(0, inset.right - 8)
        var location = 0
        let lines = (textView.text ?? "").components(separatedBy: "\n")
        for (i, line) in lines.enumerated() {
            let length = (line as NSString).length
            defer { location += length + 1 }
            guard i < labels.count, !labels[i].isHidden, length > 0, location + length <= text.length else {
                if i < labels.count { labels[i].frame = .zero }
                continue
            }
            let glyphs = manager.glyphRange(forCharacterRange: NSRange(location: location, length: length), actualCharacterRange: nil)
            guard glyphs.length > 0 else { continue }
            let fragment = manager.lineFragmentRect(forGlyphAt: NSMaxRange(glyphs) - 1, effectiveRange: nil)
            let y = fragment.minY + inset.top - textView.contentOffset.y
            labels[i].frame = CGRect(x: bounds.width - column - 8, y: y, width: column, height: max(fragment.height, 24))
        }
        for i in lines.count..<max(lines.count, labels.count) { labels[i].frame = .zero }
    }

    @objc private func tapAnswer(_ recognizer: UITapGestureRecognizer) {
        guard let label = recognizer.view as? UILabel else { return }
        onCopy?(label.tag)
        UIView.animate(withDuration: 0.12, animations: { label.alpha = 0.4 }) { _ in
            UIView.animate(withDuration: 0.2) { label.alpha = 1 }
        }
    }

    /// A bright band sweeping across a new answer once, as Math Notes does.
    private func shimmer(_ label: UILabel) {
        guard !UIAccessibility.isReduceMotionEnabled else { return }
        let mask = CAGradientLayer()
        mask.frame = CGRect(x: 0, y: 0, width: max(label.bounds.width, 200), height: max(label.bounds.height, 30))
        mask.startPoint = CGPoint(x: 0, y: 0.5)
        mask.endPoint = CGPoint(x: 1, y: 0.5)
        mask.colors = [UIColor(white: 0, alpha: 0.35).cgColor, UIColor.black.cgColor, UIColor(white: 0, alpha: 0.35).cgColor]
        mask.locations = [-1, -0.5, 0]
        label.layer.mask = mask
        let animation = CABasicAnimation(keyPath: "locations")
        animation.fromValue = [-1, -0.5, 0]
        animation.toValue = [1, 1.5, 2]
        animation.duration = 0.9
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak label] in label?.layer.mask = nil }
        mask.add(animation, forKey: "shimmer")
        mask.locations = [1, 1.5, 2]
        CATransaction.commit()
    }

    // MARK: Symbol rail

    private static let symbols = ["+", "−", "×", "÷", "=", "(", ")", "^", "%", "x", ".", "√"]

    private func makeRail() -> UIView {
        let rail = UIInputView(frame: CGRect(x: 0, y: 0, width: 320, height: 46), inputViewStyle: .keyboard)
        rail.allowsSelfSizing = true
        let scroll = UIScrollView()
        scroll.showsHorizontalScrollIndicator = false
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.spacing = 6
        for symbol in Self.symbols {
            var config = UIButton.Configuration.filled()
            config.title = symbol
            config.baseBackgroundColor = UIColor.white.withAlphaComponent(0.16)
            config.baseForegroundColor = .white
            config.cornerStyle = .capsule
            config.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 14, bottom: 6, trailing: 14)
            config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
                var a = attributes
                a.font = UIFont.systemFont(ofSize: 19, weight: .medium)
                return a
            }
            let button = UIButton(configuration: config, primaryAction: UIAction { [weak self] _ in
                self?.insert(symbol)
            })
            button.accessibilityLabel = Self.spokenSymbol(symbol)
            stack.addArrangedSubview(button)
        }
        var doneConfig = UIButton.Configuration.filled()
        doneConfig.image = UIImage(systemName: "keyboard.chevron.compact.down")
        doneConfig.baseBackgroundColor = UIColor(LocalCalculatorPalette.answer)
        doneConfig.baseForegroundColor = .black
        doneConfig.cornerStyle = .capsule
        let done = UIButton(configuration: doneConfig, primaryAction: UIAction { [weak self] _ in
            self?.onDismissKeyboard?()
        })
        done.accessibilityLabel = String(localized: "Hide Keyboard", comment: "Local calculator notes: puts the keyboard away.")
        scroll.addSubview(stack)
        rail.addSubview(scroll)
        rail.addSubview(done)
        for v in [scroll, stack, done] as [UIView] { v.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            done.trailingAnchor.constraint(equalTo: rail.safeAreaLayoutGuide.trailingAnchor, constant: -8),
            done.centerYAnchor.constraint(equalTo: rail.centerYAnchor),
            done.widthAnchor.constraint(equalToConstant: 52),
            scroll.leadingAnchor.constraint(equalTo: rail.safeAreaLayoutGuide.leadingAnchor, constant: 8),
            scroll.trailingAnchor.constraint(equalTo: done.leadingAnchor, constant: -8),
            scroll.topAnchor.constraint(equalTo: rail.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: rail.bottomAnchor),
            rail.heightAnchor.constraint(equalToConstant: 46),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: scroll.frameLayoutGuide.centerYAnchor),
            stack.heightAnchor.constraint(equalToConstant: 36),
        ])
        return rail
    }

    private func insert(_ symbol: String) {
        if !textView.isFirstResponder { textView.becomeFirstResponder() }
        let text: String
        switch symbol {
        case "+", "−", "×", "÷", "=": text = " \(symbol) "
        case "√": text = "√("
        // The locale's decimal mark, which the notes read as one (a comma in de_DE or fr_FR).
        case ".": text = Locale.current.decimalSeparator ?? "."
        default: text = symbol
        }
        textView.insertText(text)
        UISelectionFeedbackGenerator().selectionChanged()
    }

    private static func spokenSymbol(_ symbol: String) -> String {
        switch symbol {
        case "+": return String(localized: "Plus", comment: "Local calculator key: addition.")
        case "−": return String(localized: "Minus", comment: "Local calculator key: subtraction.")
        case "×": return String(localized: "Multiply", comment: "Local calculator key.")
        case "÷": return String(localized: "Divide", comment: "Local calculator key.")
        case "=": return String(localized: "Equals", comment: "Local calculator key.")
        case "(": return String(localized: "Open Parenthesis", comment: "Local calculator key.")
        case ")": return String(localized: "Close Parenthesis", comment: "Local calculator key.")
        case "^": return String(localized: "To the Power of", comment: "Local calculator key.")
        case "%": return String(localized: "Percent", comment: "Local calculator key.")
        case "√": return String(localized: "Square Root", comment: "Local calculator key.")
        case ".": return String(localized: "Decimal Point", comment: "Local calculator key.")
        default: return symbol
        }
    }
}

// MARK: - Shimmer

/// A bright band that sweeps across an answer once when it appears or
/// changes, as Math Notes does. Nothing moves with Reduce Motion.
private struct LocalCalculatorShimmer<Trigger: Equatable>: ViewModifier {
    let trigger: Trigger
    @State private var phase: CGFloat = 1.4
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .overlay {
                GeometryReader { proxy in
                    LinearGradient(colors: [.clear, LocalCalculatorPalette.answerGlow.opacity(0.95), .clear],
                                   startPoint: .leading, endPoint: .trailing)
                        .frame(width: max(40, proxy.size.width * 0.45))
                        .offset(x: phase * proxy.size.width)
                        .blendMode(.sourceAtop)
                }
                .mask(content)
                .allowsHitTesting(false)
            }
            .onChange(of: trigger) { _ in run() }
            .onAppear { run() }
    }

    private func run() {
        guard !reduceMotion else { return }
        phase = -0.5
        withAnimation(.easeInOut(duration: 0.9)) { phase = 1.4 }
    }
}

// MARK: - Key style

private enum LocalCalculatorKeyRole {
    case digit, function, clear, operation, equals, scientific

    var fill: Color {
        switch self {
        case .digit: return LocalCalculatorPalette.digit
        case .function: return LocalCalculatorPalette.function
        case .clear: return LocalCalculatorPalette.clear
        case .operation: return LocalCalculatorPalette.operation
        case .equals: return LocalCalculatorPalette.equals
        case .scientific: return LocalCalculatorPalette.scientific
        }
    }
}

/// Coloured keys: dark digits, slate functions, a red AC, orange operators
/// (white while they wait for the next number), a green =, and violet
/// scientific keys.
private struct LocalCalculatorKeyStyle: ButtonStyle {
    let role: LocalCalculatorKeyRole
    let selected: Bool

    func makeBody(configuration: Configuration) -> some View {
        let shape = Circle()
        configuration.label
            .foregroundStyle(selected ? role.fill : Color.white)
            .background(shape.fill(selected ? Color.white : role.fill))
            .overlay(shape.fill(Color.white.opacity(configuration.isPressed ? 0.22 : 0)))
            .overlay(shape.strokeBorder(Color.white.opacity(0.08), lineWidth: 0.75))
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}

private extension View {
    @ViewBuilder
    func defaultScrollAnchorBottom() -> some View {
        if #available(iOS 17.0, *) {
            self.defaultScrollAnchor(.bottom)
        } else {
            self
        }
    }
}
