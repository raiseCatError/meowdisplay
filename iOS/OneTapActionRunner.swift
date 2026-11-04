import Foundation

/// Runs a one-tap action over the existing wire in plan order. Single
/// actions go out at once. A sequence's pauses run on the main actor, and
/// each later step goes out only while the session is still the one it
/// started on and input may still reach the Mac:
/// - the receiver still reports the same `RemoteInputTicket`, so the
///   sequence stops for good on Home, Session Actions, a display-mode
///   switch, the app leaving the foreground, Picture in Picture, a pause,
///   a disconnect or a different connection, even if input comes back
///   before the next step;
/// - `inputAllowed` still holds (this device's Allow Input, which follows
///   the Mac's decision).
///
/// Each step's keys are sent down and up together, with no pause between
/// them, so stopping between steps leaves nothing held.
@MainActor
enum OneTapActionRunner {
    /// The returned task runs a sequence with pauses; it's nil when
    /// everything already went out or nothing could.
    @discardableResult
    static func run(_ action: ControlAction, receiver: some ReceiverControlSource,
                    inputAllowed: @escaping @MainActor () -> Bool) -> Task<Void, Never>? {
        let operations = ControlActionPlan.operations(for: action)
        guard !operations.isEmpty, let ticket = receiver.remoteInputTicket, inputAllowed() else { return nil }
        let pauses = operations.contains { if case .pause = $0 { return true } else { return false } }
        guard pauses else {
            operations.forEach { perform($0, receiver: receiver) }
            return nil
        }
        // Checked when the task starts and after every pause, never in the
        // middle of a step, so a chord's downs and ups always go out together.
        let mayContinue = { !Task.isCancelled && receiver.remoteInputTicket == ticket && inputAllowed() }
        return Task { @MainActor in
            guard mayContinue() else { return }
            for operation in operations {
                if case .pause(let milliseconds) = operation {
                    try? await Task.sleep(nanoseconds: UInt64(milliseconds) * 1_000_000)
                    guard mayContinue() else { return }
                    continue
                }
                perform(operation, receiver: receiver)
            }
        }
    }

    private static func perform(_ operation: ControlActionOperation, receiver: some ReceiverControlSource) {
        switch operation {
        case .press(let usage, let modifiers):
            receiver.sendKeyboardPress(usage: usage, modifiers: modifiers)
        case .key(let event):
            switch event.phase {
            case .down: receiver.sendKeyboardDown(usage: event.usage, modifiers: event.modifiers)
            case .up: receiver.sendKeyboardUp(usage: event.usage, modifiers: event.modifiers)
            }
        case .gesture(let name):
            guard ReceiverGesture(rawValue: name) != nil else { return }
            receiver.sendGesture(name: name)
        case .pause:
            break
        }
    }
}
