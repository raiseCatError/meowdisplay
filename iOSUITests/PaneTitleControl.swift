import XCTest

extension XCUIApplication {
    /// Taller than any pane title; the title sits in the pane's top strip.
    static let paneTitleMaxHeight: CGFloat = 60

    /// The frame of a Window-view pane title whose label matches `label`, only when that title is
    /// its own control: title-sized and at the top of its pane (of `pane` when given).
    ///
    /// Holding a pane's title opens the pane's menu. In a live session the rest of the pane is the
    /// Mac picture, where a hold reaches the Mac window under it. XCUITest presses an element's
    /// middle, so a title that reported the whole pane's frame would be pressed on the Mac picture.
    @MainActor
    func paneTitleFrame(_ label: NSPredicate, in pane: XCUIElement? = nil) -> CGRect? {
        let panes = pane.map { [$0.frame] }
            ?? descendants(matching: .any).matching(identifier: "workspacePane").allElementsBoundByIndex.map(\.frame)
        let named = NSCompoundPredicate(andPredicateWithSubpredicates: [label, NSPredicate(format: "identifier != 'workspacePane'")])
        let frames = descendants(matching: .any).matching(named).allElementsBoundByIndex.map(\.frame)
        return frames.first { f in
            let middle = CGPoint(x: f.midX, y: f.midY)
            guard f.height > 0, f.height < Self.paneTitleMaxHeight,
                  let pane = panes.first(where: { $0.contains(middle) }) else { return false }
            return f.width < pane.width * 0.75 && f.minY - pane.minY < Self.paneTitleMaxHeight
        }
    }

    /// Holds a pane's title long enough to open its menu, at the middle of the frame
    /// `paneTitleFrame` checked. Throws `XCTSkip`, pressing nothing, when there's no such title.
    @MainActor
    func holdPaneTitle(_ label: NSPredicate, in pane: XCUIElement? = nil) throws {
        guard let f = paneTitleFrame(label, in: pane) else {
            throw XCTSkip("no title-sized pane title matching \(label.predicateFormat); not holding the pane")
        }
        coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: f.midX, dy: f.midY)).press(forDuration: 0.7)
    }
}

extension NSPredicate {
    /// A pane title with exactly this label (the shown tab; a hidden tab reads "<title>, tab").
    static func paneTitle(_ title: String) -> NSPredicate { NSPredicate(format: "label == %@", title) }
}
