// Performance Lab (#123): the source fixture window.
//
// Opened only by the Open Fixture Window button in the Performance Lab panel
// (never automatically). Driven by the view's display link: on each refresh
// it asks the workload for a plan and, when the plan changes the picture,
// draws the next frame with its frame-ID strip (PerformanceLabFrameIDCodec)
// across the top and a visible counter. Everything the frame contains comes
// from `PerformanceLabWorkload` (pure, tested); this file only draws it.
//
// Generated content only: no user data, no screenshots. It is an ordinary
// resizable window; the operator moves it onto the streamed display.

import AppKit
import QuartzCore

@MainActor
final class PerformanceLabFixtureWindow: NSObject, PerformanceLabFixtureMeasuring, NSWindowDelegate {
    static let shared = PerformanceLabFixtureWindow()

    private var window: NSWindow?
    private var view: PerformanceLabFixtureView?

    var isOpen: Bool { window?.isVisible == true }
    var workloadID: PerformanceLabWorkloadID? { view?.workload.id }

    /// Opens (or replaces) the fixture with `workload`. User action only.
    func open(_ workload: PerformanceLabWorkloadID) {
        close()
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable],
                         backing: .buffered, defer: false)
        w.title = "Performance Lab Fixture"
        w.isReleasedWhenClosed = false
        w.delegate = self
        let v = PerformanceLabFixtureView(workload: PerformanceLabWorkload.workload(workload))
        w.contentView = v
        w.center()
        w.makeKeyAndOrderFront(nil)
        window = w
        view = v
    }

    func close() {
        view?.stop()
        window?.orderOut(nil)
        window = nil
        view = nil
    }

    func windowWillClose(_ notification: Notification) {
        view?.stop()
        window = nil
        view = nil
    }

    func beginMeasurement() { view?.beginMeasurement() }

    func endMeasurement() -> PerformanceLabFixtureRecord? { view?.endMeasurement() }
}

@MainActor
final class PerformanceLabFixtureView: NSView {
    let workload: PerformanceLabWorkload
    private var link: CADisplayLink?
    private var startSeconds: CFTimeInterval?
    private var current: PerformanceLabFramePlan?
    private var pending: PerformanceLabFramePlan?
    private var pendingAtMs: Double = 0
    private(set) var frameID: UInt32 = 0
    private var lastDrawMs: Double?
    // Measurement while a lab trial runs.
    private var measuring = false
    private var measureStartMs = 0.0
    private var drawn = 0
    private var intervals = DiagnosticsHistogram()
    private lazy var textLines = PerformanceLabWorkload.textLines(count: 400)

    init(workload: PerformanceLabWorkload) {
        self.workload = workload
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil, link == nil {
            let l = displayLink(target: self, selector: #selector(step(_:)))
            l.add(to: .main, forMode: .common)
            link = l
        } else if window == nil {
            stop()
        }
    }

    func stop() {
        link?.invalidate()
        link = nil
    }

    @objc private func step(_ link: CADisplayLink) {
        let now = link.timestamp
        if startSeconds == nil { startSeconds = now }
        let next = workload.plan(atSeconds: now - (startSeconds ?? now))
        let shown = pending ?? current
        guard shown == nil || next.animates || next.segmentOrdinal != shown?.segmentOrdinal else { return }
        pending = next
        pendingAtMs = now * 1000
        needsDisplay = true
    }

    func beginMeasurement() {
        measuring = true
        measureStartMs = CACurrentMediaTime() * 1000
        drawn = 0
        intervals = DiagnosticsHistogram()
    }

    func endMeasurement() -> PerformanceLabFixtureRecord? {
        guard measuring else { return nil }
        measuring = false
        return PerformanceLabFixtureRecord(
            workloadSignature: workload.signature,
            seconds: (CACurrentMediaTime() * 1000 - measureStartMs) / 1000,
            drawnFrames: drawn,
            drawInterval: PerformanceLabHistogramRecord(id: "fixture.draw_interval_ms", merging: [intervals]))
    }

    override func draw(_ dirtyRect: NSRect) {
        // A new frame only when the plan changed the picture: same ID, same pixels otherwise.
        if let next = pending {
            pending = nil
            current = next
            frameID = (frameID + 1) % PerformanceLabFrameIDCodec.counterModulus
            if measuring {
                if let last = lastDrawMs { intervals.record(pendingAtMs - last) }
                drawn += 1
            }
            lastDrawMs = pendingAtMs
        }
        guard let plan = current, let cg = NSGraphicsContext.current?.cgContext else { return }
        let b = bounds
        cg.setFillColor(NSColor(white: 0.94, alpha: 1).cgColor)
        cg.fill(b)

        // Frame-ID strip: quiet zones + code modules, full width, 4 modules tall.
        let module = b.width / CGFloat(PerformanceLabFrameIDCodec.stripModules)
        let stripHeight = min(module * CGFloat(PerformanceLabFrameIDCodec.stripHeightModules), b.height / 4)
        cg.setFillColor(NSColor.white.cgColor)
        cg.fill(CGRect(x: 0, y: 0, width: b.width, height: stripHeight))
        cg.setFillColor(NSColor.black.cgColor)
        let modules = PerformanceLabFrameIDCodec.modules(counter: frameID, segment: UInt8(plan.segmentOrdinal % 16))
        for (k, dark) in modules.enumerated() where dark {
            let x = CGFloat(k + PerformanceLabFrameIDCodec.quietModules) * module
            cg.fill(CGRect(x: x.rounded(.down), y: 0, width: (x + module).rounded(.down) - x.rounded(.down), height: stripHeight))
        }

        let content = CGRect(x: 0, y: stripHeight + 44, width: b.width, height: max(0, b.height - stripHeight - 44))
        let header = "frame \(String(format: "%07u", frameID))   segment \(plan.segmentOrdinal) (\(plan.kind.rawValue))   \(workload.signature)"
        draw(header, at: CGPoint(x: 12, y: stripHeight + 8), size: 22, color: .black)

        switch plan.kind {
        case .counter:
            let barWidth = max(8, b.width / 60)
            let x = CGFloat(frameID % 120) / 120 * (b.width - barWidth)
            cg.setFillColor(NSColor.systemBlue.cgColor)
            cg.fill(CGRect(x: x, y: content.minY, width: barWidth, height: content.height))
            let size = min(content.height / 3, 220)
            draw(String(format: "%07u", frameID), at: CGPoint(x: content.midX - size * 2.1, y: content.midY - size / 2), size: size, color: .black)
        case .highMotion:
            let cols = 16, rows = 9
            let cw = content.width / CGFloat(cols), ch = content.height / CGFloat(rows)
            for r in 0..<rows {
                for c in 0..<cols {
                    let idx = PerformanceLabWorkload.motionCell(frameID: frameID, cell: r * cols + c, palette: Self.palette.count)
                    cg.setFillColor(Self.palette[idx].cgColor)
                    cg.fill(CGRect(x: content.minX + CGFloat(c) * cw, y: content.minY + CGFloat(r) * ch, width: cw + 1, height: ch + 1))
                }
            }
        case .scrollingText:
            drawText(in: content, offset: plan.scrollOffsetPoints)
        case .cursorTarget, .still:
            drawText(in: content, offset: 0)
            if plan.kind == .cursorTarget {
                let p = CGPoint(x: content.minX + plan.targetX * content.width, y: content.minY + plan.targetY * content.height)
                cg.setFillColor(NSColor.systemRed.cgColor)
                cg.fillEllipse(in: CGRect(x: p.x - 12, y: p.y - 12, width: 24, height: 24))
                cg.setStrokeColor(NSColor.black.cgColor)
                cg.setLineWidth(2)
                cg.strokeLineSegments(between: [CGPoint(x: p.x - 20, y: p.y), CGPoint(x: p.x + 20, y: p.y),
                                                CGPoint(x: p.x, y: p.y - 20), CGPoint(x: p.x, y: p.y + 20)])
            }
        }
    }

    private static let palette: [NSColor] = [
        .black, .white, .systemRed, .systemGreen, .systemBlue, .systemYellow, .systemPurple, .systemOrange,
    ]

    private static let lineHeight: CGFloat = 15

    private func drawText(in rect: CGRect, offset: Double) {
        guard rect.height > 0 else { return }
        let total = CGFloat(textLines.count) * Self.lineHeight
        let shift = CGFloat(offset).truncatingRemainder(dividingBy: total)
        let first = Int(shift / Self.lineHeight)
        let visible = Int(rect.height / Self.lineHeight) + 2
        for i in 0..<visible {
            let index = (first + i) % textLines.count
            let y = rect.minY + CGFloat(first + i) * Self.lineHeight - shift
            guard y < rect.maxY else { break }
            draw(textLines[index], at: CGPoint(x: 12, y: y), size: 11, color: .black)
        }
    }

    private func draw(_ string: String, at point: CGPoint, size: CGFloat, color: NSColor) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: size, weight: .regular),
            .foregroundColor: color,
        ]
        (string as NSString).draw(at: point, withAttributes: attributes)
    }
}
