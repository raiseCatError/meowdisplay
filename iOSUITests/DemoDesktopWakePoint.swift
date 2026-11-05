import XCTest

extension XCUIApplication {
    /// A point on the Demo desktop's top strip (the sample menu bar) for a
    /// touch that only wakes faded controls.
    ///
    /// The middle of that strip is the usual spot, but Demo Mode's Show
    /// Window View button sits over it; a touch there switches to Window
    /// view and the desktop goes away. When the button covers the middle,
    /// the touch moves along the strip to halfway between the desktop's
    /// leading edge and the button. The whole strip is the sample menu bar,
    /// so the touch means the same thing to the demo either way.
    @MainActor
    func demoDesktopWakePoint() -> XCUICoordinate {
        let desktop = descendants(matching: .any)["Sample Mac desktop"].firstMatch
        let dy: CGFloat = 0.02
        var dx: CGFloat = 0.5
        let toggle = buttons["demoWindowViewToggle"].firstMatch
        if toggle.exists {
            let area = desktop.frame
            let point = CGPoint(x: area.midX, y: area.minY + area.height * dy)
            let button = toggle.frame
            if area.width > 0, button.insetBy(dx: -4, dy: -4).contains(point) {
                dx = ((area.minX + button.minX) / 2 - area.minX) / area.width
            }
        }
        return desktop.coordinate(withNormalizedOffset: CGVector(dx: dx, dy: dy))
    }
}
