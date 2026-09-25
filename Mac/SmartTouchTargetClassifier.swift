import ApplicationServices
import CoreGraphics
import Foundation

/// Smart Touch (Experimental): decides whether the Accessibility element
/// under a touch-down point sits inside a standard scrollable container,
/// or on a standard window's title bar / empty toolbar space.
///
/// Conservative by design — anything short of a clear match answers "not
/// scrollable", and the receiver keeps ordinary Direct Touch.
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

    /// Whether a role chain that found no scroll container could be a
    /// window's drag region: the window itself (its bare title bar), its
    /// title text, or empty toolbar space — nothing deeper, so any real
    /// control or content view keeps Direct Touch.
    static func isWindowDragCandidate(roles: [String]) -> Bool {
        guard roles.last == kAXWindowRole as String else { return false }
        switch roles.count {
        case 1: return true
        case 2: return roles[0] == kAXToolbarRole as String || roles[0] == kAXStaticTextRole as String
        default: return false
        }
    }

    /// Title bar band from the window's close button: the traffic lights
    /// sit vertically centered in the title bar (or unified toolbar), so
    /// the band reaches twice the button's center offset from the window
    /// top. Only consulted for a bare-window or title-text hit.
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
    static func classify(at point: CGPoint) -> Decision {
        guard AXIsProcessTrusted() else { return .notScrollable(reason: "accessibilityUnavailable") }
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, messagingTimeout)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &hit) == .success,
              let element = hit else {
            return .notScrollable(reason: "noElement")
        }
        let roles = roleChain(from: element)
        let decision = classify(roles: roles)
        guard case .notScrollable = decision, isWindowDragCandidate(roles: roles),
              isWindowDragRegion(leaf: element, leafRole: roles[0], point: point) else { return decision }
        return .windowDrag
    }

    /// Live half of the window-drag check: a standard, movable window, and
    /// — unless the hit is empty toolbar space, which AppKit always lets
    /// drag the window — a point inside the title bar band.
    private static func isWindowDragRegion(leaf: AXUIElement, leafRole: String, point: CGPoint) -> Bool {
        let window: AXUIElement
        if leafRole == kAXWindowRole as String {
            window = leaf
        } else if let parent = copyAttribute(leaf, kAXParentAttribute),
                  CFGetTypeID(parent) == AXUIElementGetTypeID() {
            window = parent as! AXUIElement
        } else {
            return false
        }
        AXUIElementSetMessagingTimeout(window, messagingTimeout)
        guard copyAttribute(window, kAXSubroleAttribute) as? String == kAXStandardWindowSubrole as String,
              let windowPosition = pointValue(copyAttribute(window, kAXPositionAttribute)) else { return false }
        if leafRole == kAXToolbarRole as String { return true }
        guard let closeValue = copyAttribute(window, kAXCloseButtonAttribute),
              CFGetTypeID(closeValue) == AXUIElementGetTypeID() else { return false }
        let closeButton = closeValue as! AXUIElement
        AXUIElementSetMessagingTimeout(closeButton, messagingTimeout)
        guard let closePosition = pointValue(copyAttribute(closeButton, kAXPositionAttribute)),
              let closeSize = sizeValue(copyAttribute(closeButton, kAXSizeAttribute)) else { return false }
        return isInTitleBar(pointY: point.y, windowTop: windowPosition.y,
                            closeButtonMidY: closePosition.y + closeSize.height / 2)
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

    private static func roleChain(from leaf: AXUIElement) -> [String] {
        var roles: [String] = []
        var current: AXUIElement? = leaf
        while let element = current, roles.count <= maxAncestorDepth {
            AXUIElementSetMessagingTimeout(element, messagingTimeout)
            guard let role = copyAttribute(element, kAXRoleAttribute) as? String else { break }
            roles.append(role)
            if scrollContainerRoles.contains(role) || dragOwningRoles.contains(role)
                || boundaryRoles.contains(role) { break }
            current = copyAttribute(element, kAXParentAttribute).flatMap { value in
                CFGetTypeID(value) == AXUIElementGetTypeID() ? (value as! AXUIElement) : nil
            }
        }
        return roles
    }

    private static func copyAttribute(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }
}
