import UIKit

/// Applies `ScreenAwakePolicy` with iOS's idle timer, only when the answer changes (never on
/// every view update), and looks again when a reconnect grace runs out.
@MainActor
final class ScreenAwakeController {
    static let shared = ScreenAwakeController()

    private var inputs: ScreenAwakePolicy.Inputs?
    private var lastStreamingAt: TimeInterval?
    private var recheck: DispatchWorkItem?
    private var applied: Bool?

    func update(_ new: ScreenAwakePolicy.Inputs) {
        inputs = new
        evaluate()
    }

    private func evaluate() {
        guard let inputs else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if inputs.streaming, inputs.watching, inputs.foreground { lastStreamingAt = now }
        let d = ScreenAwakePolicy.decide(inputs, sinceStreaming: lastStreamingAt.map { now - $0 })
        recheck?.cancel()
        recheck = nil
        if let after = d.recheckIn {
            let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.evaluate() } }
            recheck = work
            DispatchQueue.main.asyncAfter(deadline: .now() + after + 0.1, execute: work)
        }
        guard d.awake != applied else { return }
        applied = d.awake
        UIApplication.shared.isIdleTimerDisabled = d.awake
        Log.info("screenAwake: " + (d.awake ? (inputs.streaming ? "kept awake while streaming" : "kept awake for a reconnect")
                                            : "Auto-Lock as usual"))
    }
}
