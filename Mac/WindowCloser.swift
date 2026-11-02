import AppKit
import ApplicationServices

/// Closes one real Mac window the way its own close button does (an Accessibility press) and
/// reports what happened. Never Cmd-Q, never activates the app, never moves the window. A save
/// dialog the app shows is left for the owner to answer on the Mac.
enum WindowCloser {
    private static let queue = DispatchQueue(label: "meow.window.close", qos: .userInitiated)
    /// How long to watch for the window to go (or a dialog to appear) after the press.
    static let checks = 8
    static let checkInterval: TimeInterval = 0.25

    /// `completion` runs on a background queue.
    static func close(pid: Int32, frame: CGRect, title: String, completion: @escaping @Sendable (WindowCloseResult) -> Void) {
        queue.async {
            guard AXIsProcessTrusted() else { return completion(.accessibility) }
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 0.3)
            guard let before = windows(app) else { return completion(.stale) }
            let matches = before.filter { w in
                guard let f = axFrame(w), framesMatch(f, frame) else { return false }
                return title.isEmpty || string(w, kAXTitleAttribute) == title
            }
            guard matches.count == 1, let window = matches.first else {
                Log.info("workspace: close refused, \(matches.count) matching windows")
                return completion(matches.isEmpty ? .stale : .ambiguous)
            }
            var button: CFTypeRef?
            guard AXUIElementCopyAttributeValue(window, kAXCloseButtonAttribute as CFString, &button) == .success, let button,
                  CFGetTypeID(button) == AXUIElementGetTypeID() else { return completion(.noButton) }
            // swiftlint:disable:next force_cast
            guard AXUIElementPerformAction(button as! AXUIElement, kAXPressAction as CFString) == .success else {
                return completion(.stillOpen)
            }
            settle(app: app, window: window, before: before, check: 1, completion: completion)
        }
    }

    private static func settle(app: AXUIElement, window: AXUIElement, before: [AXUIElement], check: Int,
                               completion: @escaping @Sendable (WindowCloseResult) -> Void) {
        queue.asyncAfter(deadline: .now() + checkInterval) {
            var role: CFTypeRef?
            let state = AXUIElementCopyAttributeValue(window, kAXRoleAttribute as CFString, &role)
            let now = windows(app)
            if state == .invalidUIElement || (now.map { list in !list.contains { CFEqual($0, window) } } ?? false) {
                return completion(.closed)
            }
            // The app asked first (unsaved changes): a sheet on the window, or a new dialog window.
            let newDialog = (now ?? []).contains { w in !before.contains { CFEqual($0, w) } && isDialog(w) }
            if hasSheet(window) || newDialog { return completion(.saveDialog) }
            if check >= checks { return completion(.stillOpen) }
            settle(app: app, window: window, before: before, check: check + 1, completion: completion)
        }
    }

    // MARK: Accessibility helpers

    static func framesMatch(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) <= 2 && abs(a.minY - b.minY) <= 2 && abs(a.width - b.width) <= 2 && abs(a.height - b.height) <= 2
    }

    private static func windows(_ app: AXUIElement) -> [AXUIElement]? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success else { return nil }
        return value as? [AXUIElement]
    }

    private static func string(_ e: AXUIElement, _ attribute: String) -> String? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, attribute as CFString, &v) == .success else { return nil }
        return v as? String
    }

    private static func hasSheet(_ window: AXUIElement) -> Bool {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXChildrenAttribute as CFString, &v) == .success,
              let children = v as? [AXUIElement] else { return false }
        return children.contains { string($0, kAXRoleAttribute) == kAXSheetRole }
    }

    private static func isDialog(_ w: AXUIElement) -> Bool {
        let sub = string(w, kAXSubroleAttribute)
        return string(w, kAXRoleAttribute) == kAXSheetRole || sub == kAXDialogSubrole || sub == kAXSystemDialogSubrole
    }

    private static func axFrame(_ element: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?, sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let posRef, let sizeRef else { return nil }
        var pos = CGPoint.zero, size = CGSize.zero
        // swiftlint:disable force_cast
        AXValueGetValue(posRef as! AXValue, .cgPoint, &pos)
        AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)
        // swiftlint:enable force_cast
        return CGRect(origin: pos, size: size)
    }
}
