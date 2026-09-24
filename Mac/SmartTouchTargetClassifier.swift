import ApplicationServices
import CoreGraphics
import Foundation

/// Smart Touch (Experimental): decides whether the Accessibility element
/// under a touch-down point sits inside a standard scrollable container.
///
/// Conservative by design — anything short of a clear scroll container
/// answers "not scrollable", and the receiver keeps ordinary Direct Touch.
enum SmartTouchTargetClassifier {
    enum Decision: Equatable {
        case scrollable(container: String)
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
        return classify(roles: roleChain(from: element))
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
