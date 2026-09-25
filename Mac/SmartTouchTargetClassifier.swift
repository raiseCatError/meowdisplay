import ApplicationServices
import CoreGraphics
import Foundation

/// Smart Touch (Experimental): decides whether the Accessibility element
/// under a touch-down point is a standard window's title bar / empty
/// toolbar space, or sits inside a standard scrollable container.
///
/// Conservative by design — anything short of a clear match answers "not
/// scrollable", and the receiver keeps ordinary Direct Touch. For title
/// bars a missed window drag (Direct Touch) is always preferred over a
/// touch meant for a button moving the window.
enum SmartTouchTargetClassifier {
    enum Decision: Equatable {
        case scrollable(container: String)
        case windowDrag
        case notScrollable(reason: String)
    }

    /// Containers that own wheel scrolling for everything inside them.
    /// AppKit lists, tables, outlines, collection and text views all sit
    /// inside an `AXScrollArea`; `AXWebArea` covers browser engines that
    /// expose the document root without a separate scroll area.
    static let scrollContainerRoles: Set<String> = [
        kAXScrollAreaRole as String,
        "AXWebArea",
    ]

    /// Elements that interpret a drag themselves. Hitting one of these
    /// before any scroll container means the finger is on a control, not
    /// on scrollable content.
    static let dragOwningRoles: Set<String> = [
        kAXSliderRole as String,
        kAXScrollBarRole as String,
        kAXValueIndicatorRole as String,
        kAXSplitterRole as String,
        kAXIncrementorRole as String,
        kAXColorWellRole as String,
        kAXLevelIndicatorRole as String,
    ]

    /// Where the ancestor walk stops: nothing above a window can be the
    /// touched content's scroll container.
    static let boundaryRoles: Set<String> = [
        kAXWindowRole as String,
        kAXApplicationRole as String,
        kAXSheetRole as String,
        kAXDrawerRole as String,
    ]

    /// Ancestor depth cap. Real scroll containers sit within a handful of
    /// levels of the hit element; the cap bounds the AX IPC cost of an
    /// unusually deep or cyclic tree.
    static let maxAncestorDepth = 12

    /// Pure classification over the hit element's role chain, leaf first.
    static func classify(roles: [String]) -> Decision {
        guard !roles.isEmpty else { return .notScrollable(reason: "noElement") }
        for role in roles.prefix(maxAncestorDepth + 1) {
            if dragOwningRoles.contains(role) { return .notScrollable(reason: "control:\(role)") }
            if scrollContainerRoles.contains(role) { return .scrollable(container: role) }
            if boundaryRoles.contains(role) { return .notScrollable(reason: "noScrollContainer") }
        }
        return .notScrollable(reason: "depthLimit")
    }

    /// How a role chain could be a window's drag region, before the live
    /// geometry checks. Leaf-first chains that end at the window.
    enum TitleBarCandidate: Equatable {
        /// Empty toolbar space (the chain passes through `AXToolbar`):
        /// draggable wherever the toolbar is.
        case toolbar
        /// The bare title bar, its title text or a plain group or scroll
        /// area showing through it: draggable only inside the title bar
        /// band (see `isInTitleBar`).
        case titleBand
        case rejected(reason: String)
    }

    /// Plain containers a title bar hit may pass through on its way up to
    /// the window. Modern unified toolbars nest items in groups; split
    /// views run underneath full-height sidebars.
    static let titleBarContainerRoles: Set<String> = [
        kAXToolbarRole as String,
        kAXGroupRole as String,
        kAXSplitGroupRole as String,
    ]

    /// Extra roles accepted only as the hit element itself: the window
    /// title, or a scroll area running underneath a transparent title bar
    /// with no content under the finger.
    static let titleBarLeafRoles: Set<String> = [
        kAXStaticTextRole as String,
        kAXScrollAreaRole as String,
    ]

    /// Allow-list, not deny-list: every role between the hit and its
    /// window must be a plain container (or the title text / bare scroll
    /// area as the hit itself). Buttons — traffic lights included — text
    /// and search fields, segmented controls, pop-ups, sliders, scroll
    /// bars, images, links, rows and anything unfamiliar reject the whole
    /// chain, so the touch stays Direct Touch.
    static func titleBarCandidate(roles: [String]) -> TitleBarCandidate {
        guard let last = roles.last else { return .rejected(reason: "noElement") }
        guard last == kAXWindowRole as String else { return .rejected(reason: "notInWindow:\(last)") }
        for (index, role) in roles.dropLast().enumerated() {
            if titleBarContainerRoles.contains(role) { continue }
            if index == 0, titleBarLeafRoles.contains(role) { continue }
            return .rejected(reason: "role:\(role)")
        }
        return roles.contains(kAXToolbarRole as String) ? .toolbar : .titleBand
    }

    /// Whether the ancestor walk can still end in a title bar candidate —
    /// once it can't, it may stop at the first scroll container as before.
    static func canBeTitleBar(role: String, isLeaf: Bool) -> Bool {
        titleBarContainerRoles.contains(role) || role == kAXWindowRole as String
            || (isLeaf && titleBarLeafRoles.contains(role))
    }

    /// Title bar band from the window's close button: the traffic lights
    /// sit vertically centered in the title bar (or unified toolbar), so
    /// the band reaches twice the button's center offset from the window
    /// top. Consulted for every `.titleBand` candidate.
    static func isInTitleBar(pointY: CGFloat, windowTop: CGFloat, closeButtonMidY: CGFloat) -> Bool {
        let bandHeight = 2 * (closeButtonMidY - windowTop)
        guard bandHeight > 0, bandHeight <= maxTitleBarHeight else { return false }
        return pointY >= windowTop && pointY <= windowTop + bandHeight
    }

    /// Tallest title bar + unified toolbar the band check accepts.
    static let maxTitleBarHeight: CGFloat = 96

    /// Off the network/input queues: AX calls are synchronous IPC into the
    /// target app. One lookup per Smart Touch touch-down, never per move.
    static let queue = DispatchQueue(label: "smartTouch.classifier", qos: .userInteractive)

    /// Upper bound on any single AX message, so an unresponsive target app
    /// degrades to "not scrollable" instead of stalling the reply.
    static let messagingTimeout: Float = 0.05

    /// Live lookup at a global CG point (top-left origin — the same space
    /// Accessibility uses). Never prompts for permission: without it this
    /// answers "not scrollable", and the receiver falls back to Direct Touch.
    ///
    /// The title bar is checked first: on current macOS, content scroll
    /// views and full-height sidebars run underneath a transparent title
    /// bar, and a touch there must move the window, not scroll.
    static func classify(at point: CGPoint) -> Decision {
        guard AXIsProcessTrusted() else { return .notScrollable(reason: "accessibilityUnavailable") }
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, messagingTimeout)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &hit) == .success,
              let element = hit else {
            return .notScrollable(reason: "noElement")
        }
        let chain = ancestorChain(from: element)
        let roles = chain.map(\.role)
        let candidate = titleBarCandidate(roles: roles)
        let titleBarRejection: String?
        switch candidate {
        case .rejected(let reason):
            titleBarRejection = reason
        case .toolbar, .titleBand:
            titleBarRejection = windowDragRejection(window: chain[chain.count - 1].element, point: point,
                                                    needsTitleBand: candidate == .titleBand)
        }
        let decision: Decision = titleBarRejection == nil ? .windowDrag : classify(roles: roles)
        #if DEBUG
        // Roles and reasons only — never titles, values or other content.
        let titleBar = titleBarRejection.map { "rejected(\($0))" } ?? "accepted"
        Log.info("smartTouch: classify roles=\(roles.joined(separator: ">")) titleBar=\(titleBar) decision=\(decision)")
        #endif
        return decision
    }

    /// Live half of the window-drag check, `nil` when it passes: a
    /// standard, movable, non-full-screen window, and — unless the hit is
    /// toolbar space — a point inside the title bar band.
    private static func windowDragRejection(window: AXUIElement, point: CGPoint, needsTitleBand: Bool) -> String? {
        guard copyAttribute(window, kAXSubroleAttribute) as? String == kAXStandardWindowSubrole as String else {
            return "notStandardWindow"
        }
        if copyAttribute(window, "AXFullScreen") as? Bool == true { return "fullScreen" }
        var movable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(window, kAXPositionAttribute as CFString, &movable) == .success,
              movable.boolValue else { return "notMovable" }
        guard let windowPosition = pointValue(copyAttribute(window, kAXPositionAttribute)) else {
            return "noWindowPosition"
        }
        guard needsTitleBand else { return nil }
        guard let closeValue = copyAttribute(window, kAXCloseButtonAttribute),
              CFGetTypeID(closeValue) == AXUIElementGetTypeID() else { return "noCloseButton" }
        let closeButton = closeValue as! AXUIElement
        AXUIElementSetMessagingTimeout(closeButton, messagingTimeout)
        guard let closePosition = pointValue(copyAttribute(closeButton, kAXPositionAttribute)),
              let closeSize = sizeValue(copyAttribute(closeButton, kAXSizeAttribute)) else {
            return "noCloseButtonFrame"
        }
        return isInTitleBar(pointY: point.y, windowTop: windowPosition.y,
                            closeButtonMidY: closePosition.y + closeSize.height / 2) ? nil : "outsideTitleBar"
    }

    private static func pointValue(_ value: CFTypeRef?) -> CGPoint? {
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(value as! AXValue, .cgPoint, &point) ? point : nil
    }

    private static func sizeValue(_ value: CFTypeRef?) -> CGSize? {
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var size = CGSize.zero
        return AXValueGetValue(value as! AXValue, .cgSize, &size) ? size : nil
    }

    /// The hit element and its ancestors, leaf first, up to the first
    /// boundary (normally the window). Stops early at a scroll container or
    /// drag-owning control once the chain can no longer be a title bar, so
    /// ordinary content costs no more lookups than a scroll check needs.
    private static func ancestorChain(from leaf: AXUIElement) -> [(element: AXUIElement, role: String)] {
        var chain: [(element: AXUIElement, role: String)] = []
        var titleBarPossible = true
        var current: AXUIElement? = leaf
        while let element = current, chain.count <= maxAncestorDepth {
            AXUIElementSetMessagingTimeout(element, messagingTimeout)
            guard let role = copyAttribute(element, kAXRoleAttribute) as? String else { break }
            chain.append((element, role))
            if boundaryRoles.contains(role) { break }
            titleBarPossible = titleBarPossible && canBeTitleBar(role: role, isLeaf: chain.count == 1)
            if !titleBarPossible, scrollContainerRoles.contains(role) || dragOwningRoles.contains(role) { break }
            current = copyAttribute(element, kAXParentAttribute).flatMap { value in
                CFGetTypeID(value) == AXUIElementGetTypeID() ? (value as! AXUIElement) : nil
            }
        }
        return chain
    }

    private static func copyAttribute(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }
}
