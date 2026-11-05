import AppKit

/// Where the Mac's request panels appear (pairing, input control, display
/// request, Files): in front of the person at this Mac, on whichever Space
/// and display they're using, without ever taking the keyboard. This is
/// placement only. Who may answer a request is `ConsentInputPolicy`.
enum SecurityPanelPlacement {
    /// On every Space, including beside a full-screen app where macOS allows
    /// it, so a request is never left on a Space the owner isn't looking at.
    static let collectionBehavior: NSWindow.CollectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

    /// A request panel. It is non-activating, so it never takes focus by
    /// appearing. It floats at modal-panel level and stays up while
    /// MeowDisplay isn't the active app. The coordinator owns it, so closing
    /// it doesn't release it.
    static func makePanel(title: String, contentRect: NSRect) -> NSPanel {
        let panel = NSPanel(contentRect: contentRect, styleMask: [.titled, .closable, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.title = title
        panel.isFloatingPanel = true
        panel.level = .modalPanel
        // A security decision must stay visible even if the user clicks
        // elsewhere. It may only close through an explicit answer, the close
        // button (a rejection) or the model's own timeout, never by losing focus.
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = collectionBehavior
        return panel
    }

    /// The display a request opens on: the one under the pointer, so it
    /// appears where the owner is working. A display MeowDisplay is streaming
    /// to a device as a virtual display (`avoiding`) is never chosen while
    /// another exists: the request is for the person at this Mac, not
    /// whoever is looking at the device. Otherwise falls back to the first
    /// display, the one with the menu bar.
    static func displayIndex(screens: [(id: CGDirectDisplayID?, frame: CGRect)], pointer: CGPoint,
                             avoiding: Set<CGDirectDisplayID>) -> Int? {
        let allowed = screens.indices.filter { index in
            screens[index].id.map { !avoiding.contains($0) } ?? true
        }
        if let underPointer = allowed.first(where: { screens[$0].frame.contains(pointer) }) {
            return underPointer
        }
        return allowed.first ?? screens.indices.first
    }

    /// Centred across and a little above the middle (where
    /// `NSWindow.center()` puts a window), kept inside the visible area. A
    /// panel too big to fit keeps its title bar and left edge on screen.
    static func origin(for size: CGSize, in visible: CGRect) -> CGPoint {
        let x = visible.midX - size.width / 2
        let y = visible.minY + (visible.height - size.height) * 2 / 3
        return CGPoint(x: max(visible.minX, min(x, visible.maxX - size.width)).rounded(),
                       y: min(visible.maxY - size.height, max(y, visible.minY)).rounded())
    }

    /// Whether to move a panel before showing it. A panel already up on the
    /// chosen display stays where it is, so a repeated request never moves
    /// its buttons under the owner's cursor.
    static func shouldMove(isVisible: Bool, currentDisplay: Int?, chosenDisplay: Int?) -> Bool {
        guard isVisible else { return chosenDisplay != nil }
        guard let chosenDisplay else { return false }
        return currentDisplay != chosenDisplay
    }

    /// Brings `panel` in front of the owner without activating MeowDisplay
    /// or making the panel key.
    @MainActor
    static func show(_ panel: NSPanel, avoiding: Set<CGDirectDisplayID>) {
        let screens = NSScreen.screens
        let chosen = displayIndex(
            screens: screens.map { (id: $0.requestPanelDisplayID, frame: $0.frame) },
            pointer: NSEvent.mouseLocation, avoiding: avoiding)
        let current = panel.isVisible ? panel.screen.flatMap { screens.firstIndex(of: $0) } : nil
        if shouldMove(isVisible: panel.isVisible, currentDisplay: current, chosenDisplay: chosen),
           let chosen {
            panel.setFrameOrigin(origin(for: panel.frame.size, in: screens[chosen].visibleFrame))
        }
        panel.orderFrontRegardless()
    }
}

private extension NSScreen {
    var requestPanelDisplayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}
