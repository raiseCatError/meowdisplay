import SwiftUI
import UIKit

/// A gallery card's touch handling, done the UIKit way so it shares each touch with the
/// gallery's scroll view instead of claiming it:
/// - a vertical drag scrolls the gallery, even when it starts on a card (with momentum);
/// - a stationary tap selects (never the tap that stops a moving gallery);
/// - press and hold lifts the card: move to drag it onto a pane, or lift in place for its menu;
/// - a deliberate horizontal swipe reveals (or hides) Close Window.
/// Whichever gesture UIKit recognizes first wins and the others fail, so scrolling never selects.
struct StagePeekCardGestures: UIViewRepresentable {
    var onTap: () -> Void
    /// The hold completed (the card lifts). Window coordinates.
    var onHold: (CGPoint) -> Void = { _ in }
    /// The held finger moved (window coordinates).
    var onHoldMove: (CGPoint) -> Void = { _ in }
    /// The held finger lifted: `moved` says whether it travelled (a drag) or stayed (the menu).
    var onHoldEnd: (_ at: CGPoint, _ moved: Bool) -> Void = { _, _ in }
    var onHoldCancel: () -> Void = {}
    /// Horizontal swipes, when the card has a swipe action.
    var swipeEnabled = false
    var onSwipe: (_ dx: CGFloat) -> Void = { _ in }
    var onSwipeEnd: (_ dx: CGFloat, _ velocity: CGFloat) -> Void = { _, _ in }

    static let holdDuration: TimeInterval = 0.35
    static let holdSlop: CGFloat = 10

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UIView {
        let view = TouchView()
        view.backgroundColor = .clear
        view.isAccessibilityElement = false
        view.accessibilityElementsHidden = true   // the SwiftUI card carries labels and actions
        let c = context.coordinator
        let tap = UITapGestureRecognizer(target: c, action: #selector(Coordinator.tap(_:)))
        let hold = UILongPressGestureRecognizer(target: c, action: #selector(Coordinator.hold(_:)))
        hold.minimumPressDuration = Self.holdDuration
        hold.allowableMovement = Self.holdSlop
        let pan = UIPanGestureRecognizer(target: c, action: #selector(Coordinator.pan(_:)))
        for g in [tap, hold, pan] as [UIGestureRecognizer] {
            g.delegate = c
            view.addGestureRecognizer(g)
        }
        c.pan = pan
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) { context.coordinator.parent = self }

    final class TouchView: UIView {}

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: StagePeekCardGestures
        weak var pan: UIPanGestureRecognizer?
        private var holdStart: CGPoint = .zero
        private var holdMoved = false
        /// The touch landed while the gallery was still moving: it only stops the gallery.
        private var landedWhileScrolling = false
        private weak var currentTouch: UITouch?
        private var holdIgnored = false

        init(_ parent: StagePeekCardGestures) { self.parent = parent }

        private func scrollView(of view: UIView?) -> UIScrollView? {
            var v = view?.superview
            while let s = v { if let scroll = s as? UIScrollView, scroll.isScrollEnabled { return scroll }; v = s.superview }
            return nil
        }

        @objc func tap(_ g: UITapGestureRecognizer) {
            guard g.state == .ended, !landedWhileScrolling else { return }
            parent.onTap()
        }

        @objc func hold(_ g: UILongPressGestureRecognizer) {
            let p = g.location(in: nil)
            switch g.state {
            case .began:
                holdIgnored = landedWhileScrolling
                guard !holdIgnored else { return }
                holdStart = p
                holdMoved = false
                parent.onHold(p)
            case .changed:
                guard !holdIgnored else { return }
                if hypot(p.x - holdStart.x, p.y - holdStart.y) > Self.moveSlop { holdMoved = true }
                parent.onHoldMove(p)
            case .ended:
                guard !holdIgnored else { return }
                parent.onHoldEnd(p, holdMoved)
            case .cancelled, .failed:
                guard !holdIgnored else { return }
                parent.onHoldCancel()
            default:
                break
            }
        }

        static let moveSlop: CGFloat = 12

        @objc func pan(_ g: UIPanGestureRecognizer) {
            let dx = g.translation(in: g.view).x
            switch g.state {
            case .began, .changed: parent.onSwipe(dx)
            case .ended: parent.onSwipeEnd(dx, g.velocity(in: g.view).x)
            case .cancelled, .failed: parent.onSwipeEnd(0, 0)
            default: break
            }
        }

        // MARK: Arbitration

        func gestureRecognizer(_ g: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            // Once per touch, before any recognizer acts on it.
            if touch !== currentTouch {
                currentTouch = touch
                let scroll = scrollView(of: g.view)
                landedWhileScrolling = scroll.map { $0.isDecelerating || $0.isDragging } ?? false
            }
            return true
        }

        func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
            guard g === pan, let pan else { return true }
            // Only a deliberate sideways swipe; anything more vertical is the gallery's scroll.
            guard parent.swipeEnabled else { return false }
            let v = pan.velocity(in: pan.view), t = pan.translation(in: pan.view)
            let x = abs(v.x) + abs(t.x) * 10, y = abs(v.y) + abs(t.y) * 10
            return x > y * 1.6
        }

        /// The gallery's scroll waits for the sideways swipe to decide (it fails at once for
        /// a vertical drag), so a sideways swipe never also scrolls.
        func gestureRecognizer(_ g: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
            g === pan && parent.swipeEnabled && other.view is UIScrollView && other === (other.view as? UIScrollView)?.panGestureRecognizer
        }
    }
}
