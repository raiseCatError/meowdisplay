import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass

/// Keeps a drag honest while it lasts (owner, QA 9000024 on iPhone):
/// - Starting a drag puts the search keyboard away, so it doesn't cover the panes, Cancel and
///   Float. Nothing brings it back during the drag; the query stays, one tap away.
/// - A drag ends with its finger. If every finger is up and a drag is still on (the view that
///   carried its gesture went away before it could end), it's cancelled, so no frozen icon,
///   card or Pane/Floating state is left. Also on leaving the foreground and on turning the screen.
struct WorkspaceDragGuard: ViewModifier {
    @ObservedObject var model: WorkspaceModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var touches = 0
    @State private var width: CGFloat = 0
    /// After the last finger lifts, the gesture's own end has this long to arrive.
    static let grace: TimeInterval = 0.35

    func body(content: Content) -> some View {
        content
            .background(TouchWatch { touches = $0 }.allowsHitTesting(false).accessibilityHidden(true))
            .background(GeometryReader { g in
                Color.clear
                    .onAppear { width = g.size.width }
                    .onChange(of: g.size.width) { w in
                        // A keyboard changes only the height; a turn or a resize changes the width.
                        if abs(w - width) > 1, width > 0 { model.abandonDrag(reason: "screen turned") }
                        width = w
                    }
            })
            .onChange(of: model.drag != nil) { dragging in
                if dragging { Self.dismissKeyboard() }
            }
            .onChange(of: touches) { n in
                guard n == 0, model.drag != nil || model.dockingFloat != nil || model.floatGesture != nil else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.grace) {
                    guard touches == 0 else { return }
                    model.abandonDrag(reason: "no finger down")
                }
            }
            .onChange(of: scenePhase) { phase in
                if phase != .active { model.abandonDrag(reason: "left the foreground") }
            }
    }

    static func dismissKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}

/// Counts the fingers (and pointer presses) down anywhere in the window, without taking part in
/// any gesture: a recognizer that never recognizes, delays nothing and cancels nothing.
private struct TouchWatch: UIViewRepresentable {
    let onChange: (Int) -> Void

    func makeUIView(context: Context) -> WatchView {
        let v = WatchView()
        v.onChange = onChange
        v.isUserInteractionEnabled = false
        return v
    }

    func updateUIView(_ v: WatchView, context: Context) { v.onChange = onChange }

    static func dismantleUIView(_ v: WatchView, coordinator: ()) { v.detach() }

    final class WatchView: UIView {
        var onChange: (Int) -> Void = { _ in }
        private var recognizer: Counter?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            detach()
            guard let window else { return }
            let r = Counter { [weak self] n in self?.onChange(n) }
            window.addGestureRecognizer(r)
            recognizer = r
        }

        func detach() {
            if let r = recognizer { r.view?.removeGestureRecognizer(r) }
            recognizer = nil
        }
    }

    final class Counter: UIGestureRecognizer, UIGestureRecognizerDelegate {
        private var down = Set<ObjectIdentifier>()
        private let report: (Int) -> Void

        init(report: @escaping (Int) -> Void) {
            self.report = report
            super.init(target: nil, action: nil)
            cancelsTouchesInView = false
            delaysTouchesBegan = false
            delaysTouchesEnded = false
            delegate = self
        }

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
            touches.forEach { down.insert(ObjectIdentifier($0)) }
            report(down.count)
        }
        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) { lift(touches) }
        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { lift(touches) }

        private func lift(_ touches: Set<UITouch>) {
            touches.forEach { down.remove(ObjectIdentifier($0)) }
            report(down.count)
            if down.isEmpty { state = .failed }   // never recognizes; resets for the next touch
        }

        override func reset() {
            super.reset()
            if !down.isEmpty { down.removeAll(); report(0) }
        }

        // Never in anyone's way.
        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
        override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
        override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    }
}
