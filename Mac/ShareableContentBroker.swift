import CoreGraphics
import ScreenCaptureKit

/// The app's one source of ScreenCaptureKit shareable content: every session and the Privacy
/// Shield share one request in flight to macOS's capture service, and reuse recent answers until
/// a display or the shield's windows change (`CoalescingFetch` explains why).
enum ShareableContent {
    struct Box: @unchecked Sendable { let content: SCShareableContent }
    typealias Freshness = CoalescingFetch<Box>.Freshness
    typealias TimedOut = CoalescingFetch<Box>.TimedOut

    static let broker: CoalescingFetch<Box> = {
        // Any display change (added, removed, moved, mode) makes cached displays stale.
        CGDisplayRegisterReconfigurationCallback({ _, _, _ in ShareableContent.invalidate() }, nil)
        return CoalescingFetch<Box>(onSlowFetch: { took in
            Log.info("captureService: shareable content took \(milliseconds(took)) ms — macOS's capture service "
                + "(replayd) is answering slowly, usually because another app is sending it many requests")
        }) {
            // The widest list (desktop and off-screen windows too) serves every caller.
            Box(content: try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false))
        }
    }()

    static func content(_ freshness: Freshness = .cachedWithin(.seconds(2)),
                        timeout: Duration? = nil) async throws -> SCShareableContent {
        try await broker.value(freshness, timeout: timeout).value.content
    }

    static func invalidate() { broker.invalidate() }

    static func milliseconds(_ d: Duration) -> Int {
        Int(d.components.seconds * 1000 + d.components.attoseconds / 1_000_000_000_000_000)
    }
}

/// Monotonic timings for one capture start, tagged with a short id so the lines of sessions
/// starting at the same time (an iPhone and a Moto) can be told apart in the log.
final class StartTrace: @unchecked Sendable {
    let id: String
    let mode: String
    private let began = ContinuousClock.now
    private let lock = NSLock()
    private var last: ContinuousClock.Instant
    private var once: Set<String> = []

    init(mode: String, generation: UInt64) {
        id = String(format: "%04x", UInt16.random(in: 0...UInt16.max))
        self.mode = mode
        last = began
        Log.info("startTrace id=\(id) mode=\(mode) stage=admitted generation=\(generation) t=0")
    }

    func mark(_ stage: String, _ detail: String = "") {
        let now = ContinuousClock.now
        let step = lock.withLock { () -> Duration in defer { last = now }; return now - last }
        Log.info("startTrace id=\(id) mode=\(mode) stage=\(stage) t=\(ShareableContent.milliseconds(now - began)) "
            + "dt=\(ShareableContent.milliseconds(step))\(detail.isEmpty ? "" : " " + detail)")
    }

    /// Marks a stage only the first time (first frame captured, first frame sent).
    func markOnce(_ stage: String) {
        guard lock.withLock({ once.insert(stage).inserted }) else { return }
        mark(stage)
    }
}
