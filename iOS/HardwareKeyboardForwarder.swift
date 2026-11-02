import GameController
import UIKit

/// HID-B: a physical keyboard controls the Mac without the on-screen
/// Keyboard button. GameController reports raw key down/up with HID usages
/// (GCKeyCode's raw value is the keyboard-page usage), so every key and
/// modifier reaches the Mac and the Mac's own layout decides the character,
/// like the Mac Receiver. While MeowDisplay's text field is up (the on-screen
/// Keyboard), typing goes through the iOS text system instead, so composed
/// and international input still works. iPadOS keeps its own reserved
/// shortcuts (Globe, ⌘Tab, ⌘Space): they never arrive here.
@MainActor
final class HardwareKeyboardForwarder {
    /// The connected session's receiver.
    var receiver: () -> StreamReceiver? = { nil }
    /// True while keys should go to the Mac: input allowed, the on-screen
    /// keyboard closed, the app in front.
    var isActive: () -> Bool = { false }

    private var held: Set<Int> = []
    private var modifiers: Set<ControlModifier> = []
    private var connectObserver: NSObjectProtocol?

    init() {
        connectObserver = NotificationCenter.default.addObserver(forName: .GCKeyboardDidConnect, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.attach() }
        }
        attach()
    }

    private func attach() {
        GCKeyboard.coalesced?.keyboardInput?.keyChangedHandler = { [weak self] _, _, keyCode, pressed in
            let usage = Int(keyCode.rawValue)
            Task { @MainActor in self?.key(usage, pressed: pressed) }
        }
    }

    static func modifier(forUsage usage: Int) -> ControlModifier? {
        switch usage {
        case 224, 228: return .control
        case 225, 229: return .shift
        case 226, 230: return .option
        case 227, 231: return .command
        default: return nil
        }
    }

    func key(_ usage: Int, pressed: Bool) {
        guard let receiver = receiver() else { return }
        if let modifier = Self.modifier(forUsage: usage) {
            if pressed, isActive(), modifiers.insert(modifier).inserted {
                receiver.sendModifier(modifier, down: true)
            } else if !pressed, modifiers.remove(modifier) != nil {
                receiver.sendModifier(modifier, down: false)
            }
            return
        }
        // Caps Lock and the Globe/Fn key stay local.
        guard usage != 57, usage < 224 || usage > 231 else { return }
        let names = modifiers.map(\.rawValue)
        if pressed {
            guard isActive(), held.insert(usage).inserted else { return }
            receiver.sendKeyboardDown(usage: usage, modifiers: names)
        } else if held.remove(usage) != nil {
            // A release always goes through, even after input turned off.
            receiver.sendKeyboardUp(usage: usage, modifiers: names)
        }
    }

    /// Focus or control lost, the app backgrounded, the session ended.
    func releaseAll() {
        guard let receiver = receiver() else { held.removeAll(); modifiers.removeAll(); return }
        for usage in held { receiver.sendKeyboardUp(usage: usage, modifiers: []) }
        for modifier in modifiers { receiver.sendModifier(modifier, down: false) }
        held.removeAll()
        modifiers.removeAll()
    }
}
