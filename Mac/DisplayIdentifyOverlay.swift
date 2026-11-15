import AppKit

/// Identify Displays: a large label on every Mac screen for a few seconds, so the displays in
/// the receiver's overview can be matched with the screens on the desk. Click-through, never
/// key, never activates MeowDisplay, and gone by itself.
@MainActor
enum DisplayIdentifyOverlay {
    private static var panels: [NSPanel] = []
    private static var generation = 0

    /// `labels`: display id -> text (`DisplayActionPolicy.identifyLabel`). Screens without a
    /// label (not in the receiver's listing) show nothing.
    static func show(_ labels: [UInt32: String], duration: Double) {
        hide()
        generation += 1
        let mine = generation
        for screen in NSScreen.screens {
            guard let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value,
                  let text = labels[id] else { continue }
            panels.append(panel(text, on: screen))
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
            MainActor.assumeIsolated { if generation == mine { hide() } }
        }
    }

    static func hide() {
        panels.forEach { $0.orderOut(nil) }
        panels.removeAll()
    }

    private static func panel(_ text: String, on screen: NSScreen) -> NSPanel {
        let size = NSSize(width: min(520, screen.frame.width * 0.6), height: 150)
        let origin = NSPoint(x: screen.frame.midX - size.width / 2, y: screen.frame.midY - size.height / 2)
        let panel = NSPanel(contentRect: NSRect(origin: origin, size: size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isReleasedWhenClosed = false

        let background = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        background.material = .hudWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 22
        background.layer?.masksToBounds = true

        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 44, weight: .bold)
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        label.frame = NSRect(x: 16, y: (size.height - 56) / 2, width: size.width - 32, height: 56)
        background.addSubview(label)
        panel.contentView = background
        panel.orderFrontRegardless()
        return panel
    }
}
