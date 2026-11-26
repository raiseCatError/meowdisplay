import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass

/// Quiet feedback on the Trackpad (owner's QA of 9000083): while a finger moves, a short smooth
/// line follows it, one colour, fading from the finger back; a tap gets a brief soft press under
/// it. Nothing marks a touch that only starts. Drawing only: the touches come from a watcher that
/// never recognizes, delays or cancels anything, so the pointer engine sees every touch exactly
/// as before.
@MainActor final class TrackpadTouchTrail: ObservableObject {
    struct Sample {
        let point: CGPoint
        let time: TimeInterval
        let stroke: Int
    }

    struct Tap {
        let point: CGPoint
        let time: TimeInterval
    }

    /// How much of a moving finger's path shows, in seconds.
    static let tailSpan: TimeInterval = 0.1
    /// How long the line takes to fade once the finger stops or lifts.
    static let fadeOut: TimeInterval = 0.16
    /// How long a tap's press shows.
    static let tapDuration: TimeInterval = 0.24
    /// A tap: this short, and moving no further than `tapSlop` points.
    static let tapMaximumDuration: TimeInterval = 0.3
    static let tapSlop: CGFloat = 10
    private static let maximumSamples = 120

    @Published private(set) var samples: [Sample] = []
    @Published private(set) var taps: [Tap] = []
    /// Where touches count, in global coordinates (the Trackpad's own areas).
    var regions: [CGRect] = []

    private struct Stroke {
        let id: Int
        let start: CGPoint
        let began: TimeInterval
        var travelled: CGFloat = 0
    }

    private var strokes: [ObjectIdentifier: Stroke] = [:]
    private var nextStroke = 0
    private var expiry: Task<Void, Never>?

    var isActive: Bool { !samples.isEmpty || !taps.isEmpty }

    func began(_ touch: ObjectIdentifier, at point: CGPoint, time: TimeInterval) {
        guard regions.contains(where: { $0.contains(point) }) else { return }
        nextStroke += 1
        strokes[touch] = Stroke(id: nextStroke, start: point, began: time)
        append(Sample(point: point, time: time, stroke: nextStroke))
    }

    func moved(_ touch: ObjectIdentifier, to point: CGPoint, time: TimeInterval) {
        guard var stroke = strokes[touch] else { return }
        stroke.travelled = max(stroke.travelled, hypot(point.x - stroke.start.x, point.y - stroke.start.y))
        strokes[touch] = stroke
        append(Sample(point: point, time: time, stroke: stroke.id))
    }

    func ended(_ touch: ObjectIdentifier, at point: CGPoint, time: TimeInterval, cancelled: Bool) {
        guard let stroke = strokes.removeValue(forKey: touch) else { return }
        if !cancelled, time - stroke.began <= Self.tapMaximumDuration, stroke.travelled <= Self.tapSlop {
            taps.append(Tap(point: stroke.start, time: time))
            samples.removeAll { $0.stroke == stroke.id }   // a tap shows only its press
            scheduleExpiry()
        }
    }

    private func append(_ sample: Sample) {
        let horizon = Self.tailSpan + Self.fadeOut
        samples.removeAll { sample.time - $0.time > horizon }
        samples.append(sample)
        if samples.count > Self.maximumSamples { samples.removeFirst(samples.count - Self.maximumSamples) }
        scheduleExpiry()
    }

    private func scheduleExpiry() {
        expiry?.cancel()
        let wait = max(Self.tailSpan + Self.fadeOut, Self.tapDuration)
        expiry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled else { return }
            self?.samples.removeAll()
            self?.taps.removeAll()
        }
    }
}

/// Draws a `TrackpadTouchTrail` (global coordinates) in a view whose global origin is `origin`.
struct TrackpadTouchTrailView: View {
    @ObservedObject var trail: TrackpadTouchTrail
    let origin: CGPoint

    /// One colour for the line and the press.
    private static let tint = Color.white
    private static let lineOpacity = 0.2
    private static let pressOpacity = 0.16

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 120, paused: !trail.isActive)) { timeline in
            Canvas { context, _ in
                let now = timeline.date.timeIntervalSinceReferenceDate
                for (_, samples) in Dictionary(grouping: trail.samples, by: \.stroke) {
                    drawLine(samples, now: now, in: &context)
                }
                for tap in trail.taps { drawPress(tap, now: now, in: &context) }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func local(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x - origin.x, y: p.y - origin.y) }

    /// One smooth stroke through the finger's last `tailSpan`, drawn once (no overlapping caps),
    /// transparent at its tail and fading out together once the finger stops.
    private func drawLine(_ samples: [TrackpadTouchTrail.Sample], now: TimeInterval, in context: inout GraphicsContext) {
        guard let newest = samples.last else { return }
        let points = samples.filter { newest.time - $0.time <= TrackpadTouchTrail.tailSpan }.map { local($0.point) }
        guard points.count >= 2, let head = points.last, let tail = points.first,
              hypot(head.x - tail.x, head.y - tail.y) >= 2 else { return }
        let fade = min(max(1 - (now - newest.time) / TrackpadTouchTrail.fadeOut, 0), 1)
        guard fade > 0 else { return }
        var path = Path()
        path.move(to: points[0])
        // Through the midpoints, with each sample as the control point: no corners.
        for i in 1..<points.count - 1 {
            let mid = CGPoint(x: (points[i].x + points[i + 1].x) / 2, y: (points[i].y + points[i + 1].y) / 2)
            path.addQuadCurve(to: mid, control: points[i])
        }
        path.addLine(to: head)
        context.drawLayer { layer in
            layer.opacity = fade
            layer.addFilter(.blur(radius: 0.8))
            let shading = GraphicsContext.Shading.linearGradient(
                Gradient(colors: [Self.tint.opacity(0), Self.tint.opacity(Self.lineOpacity)]),
                startPoint: tail, endPoint: head)
            layer.stroke(path, with: shading, style: StrokeStyle(lineWidth: 3.5, lineCap: .round, lineJoin: .round))
        }
    }

    /// A tap: a soft disc under the finger that settles outward and fades, like a key giving way.
    private func drawPress(_ tap: TrackpadTouchTrail.Tap, now: TimeInterval, in context: inout GraphicsContext) {
        let t = min(max((now - tap.time) / TrackpadTouchTrail.tapDuration, 0), 1)
        guard t < 1 else { return }
        let eased = 1 - pow(1 - t, 3)
        let r = 14 + 6 * eased
        let alpha = Self.pressOpacity * (1 - eased)
        let center = local(tap.point)
        let disc = Gradient(stops: [.init(color: Self.tint.opacity(alpha), location: 0),
                                    .init(color: Self.tint.opacity(alpha * 0.6), location: 0.55),
                                    .init(color: Self.tint.opacity(0), location: 1)])
        context.fill(Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r)),
                     with: .radialGradient(disc, center: center, startRadius: 0, endRadius: r))
    }
}

/// Feeds a `TrackpadTouchTrail` from every touch in the window, without taking part in any
/// gesture: a recognizer that never recognizes, delays nothing and cancels nothing.
struct TrackpadTouchTrailWatch: UIViewRepresentable {
    let trail: TrackpadTouchTrail

    func makeUIView(context: Context) -> WatchView {
        let v = WatchView()
        v.trail = trail
        v.isUserInteractionEnabled = false
        return v
    }

    func updateUIView(_ v: WatchView, context: Context) { v.trail = trail }

    static func dismantleUIView(_ v: WatchView, coordinator: ()) { v.detach() }

    final class WatchView: UIView {
        weak var trail: TrackpadTouchTrail?
        private var recognizer: Watcher?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            detach()
            guard let window else { return }
            let r = Watcher { [weak self] in self?.trail }
            window.addGestureRecognizer(r)
            recognizer = r
        }

        func detach() {
            if let r = recognizer { r.view?.removeGestureRecognizer(r) }
            recognizer = nil
        }
    }

    final class Watcher: UIGestureRecognizer, UIGestureRecognizerDelegate {
        private let trail: () -> TrackpadTouchTrail?
        private var down = Set<ObjectIdentifier>()

        init(trail: @escaping () -> TrackpadTouchTrail?) {
            self.trail = trail
            super.init(target: nil, action: nil)
            cancelsTouchesInView = false
            delaysTouchesBegan = false
            delaysTouchesEnded = false
            delegate = self
        }

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
            for touch in touches where touch.type == .direct {
                down.insert(ObjectIdentifier(touch))
                trail()?.began(ObjectIdentifier(touch), at: touch.location(in: nil), time: Self.now)
            }
        }

        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
            for touch in touches where down.contains(ObjectIdentifier(touch)) {
                trail()?.moved(ObjectIdentifier(touch), to: touch.location(in: nil), time: Self.now)
            }
        }

        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) { lift(touches, cancelled: false) }
        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { lift(touches, cancelled: true) }

        private func lift(_ touches: Set<UITouch>, cancelled: Bool) {
            for touch in touches where down.remove(ObjectIdentifier(touch)) != nil {
                trail()?.ended(ObjectIdentifier(touch), at: touch.location(in: nil), time: Self.now, cancelled: cancelled)
            }
            if down.isEmpty { state = .failed }   // never recognizes; resets for the next touch
        }

        override func reset() {
            super.reset()
            down.removeAll()
        }

        /// The same clock as `TimelineView`'s dates.
        private static var now: TimeInterval { Date().timeIntervalSinceReferenceDate }

        // Never in anyone's way.
        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
        override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
        override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    }
}
