import AppKit
import ApplicationServices

/// One menu level, as the receiver draws it (PROTOCOL.md 6.13).
struct AppMenuItem: Equatable {
    /// Index among the AX children at this level (separators included), so a path is direct.
    var index: Int
    var title: String
    var enabled = true
    var checked = false
    var separator = false
    var hasSubmenu = false
    /// "⌘S", "⇧⌘Z"…
    var shortcut: String?

    var wire: [String: Any] {
        if separator { return ["i": index, "sep": true] }
        var m: [String: Any] = ["i": index, "t": title]
        if !enabled { m["on"] = false }
        if checked { m["mark"] = true }
        if hasSubmenu { m["sub"] = true }
        if let shortcut { m["key"] = shortcut }
        return m
    }
}

/// The menus of the app a pane shows, read through Accessibility one level at a time (the
/// real menu bar only shows the frontmost app). Never the Apple menu: its items (Restart,
/// Shut Down, Log Out, System Settings) are the system's, not the app's.
enum AppMenuReader {
    static let maxTopLevel = 24
    static let maxItems = 120
    static let maxDepth = 4

    /// Where an item lives: [menu bar index, item index, submenu item index…], checked
    /// against the titles the receiver saw so a menu that changed meanwhile is never pressed.
    static func isValidPath(_ path: [Int], titles: [String]) -> Bool {
        !path.isEmpty && path.count <= maxDepth && path.count == titles.count && path[0] >= 1 && path.allSatisfy { $0 >= 0 && $0 < 500 }
    }

    /// The items at `path` ([] = the menu bar's own titles, without the Apple menu).
    static func items(pid: Int32, path: [Int]) -> (app: String, items: [AppMenuItem])? {
        guard AXIsProcessTrusted(), path.count < maxDepth, path.first.map({ $0 >= 1 }) ?? true else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        guard let bar = element(app, kAXMenuBarAttribute) else { return nil }
        let name = NSRunningApplication(processIdentifier: pid)?.localizedName ?? ""
        if path.isEmpty {
            let tops = children(bar)
            let items = tops.enumerated().dropFirst().prefix(maxTopLevel).compactMap { i, e -> AppMenuItem? in
                let title = string(e, kAXTitleAttribute) ?? ""
                return title.isEmpty ? nil : AppMenuItem(index: i, title: title, enabled: bool(e, kAXEnabledAttribute) ?? true, hasSubmenu: true)
            }
            return (name, items)
        }
        guard let menu = menuElement(bar, path: path) else { return nil }
        let items = children(menu).enumerated().prefix(maxItems).map { i, e in item(e, index: i) }
        return (name, items)
    }

    /// Presses the item at `path` if every title on the way still matches.
    static func press(pid: Int32, path: [Int], titles: [String]) -> Bool {
        guard AXIsProcessTrusted(), isValidPath(path, titles: titles), path.count >= 2 else { return false }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        guard let bar = element(app, kAXMenuBarAttribute) else { return false }
        var current = bar
        for (depth, index) in path.enumerated() {
            let level = depth == 0 ? children(bar) : (children(current).first.map(children) ?? [])
            guard index < level.count else { return false }
            let next = level[index]
            guard (string(next, kAXTitleAttribute) ?? "") == titles[depth] else { return false }
            current = next
        }
        guard bool(current, kAXEnabledAttribute) ?? true, children(current).isEmpty else { return false }
        return AXUIElementPerformAction(current, kAXPressAction as CFString) == .success
    }

    // MARK: AX

    /// The menu (AXMenu) under the item at `path`.
    private static func menuElement(_ bar: AXUIElement, path: [Int]) -> AXUIElement? {
        var level = children(bar)
        var menu: AXUIElement?
        for index in path {
            guard index < level.count, let m = children(level[index]).first else { return nil }
            menu = m
            level = children(m)
        }
        return menu
    }

    private static func item(_ e: AXUIElement, index: Int) -> AppMenuItem {
        let names = [kAXTitleAttribute, kAXEnabledAttribute, "AXMenuItemCmdChar", "AXMenuItemCmdModifiers", "AXMenuItemMarkChar", kAXChildrenAttribute] as CFArray
        var values: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(e, names, AXCopyMultipleAttributeOptions(rawValue: 0), &values) == .success,
              let list = values as? [Any], list.count == 6 else {
            return AppMenuItem(index: index, title: "", separator: true)
        }
        let title = (list[0] as? String) ?? ""
        let hasSubmenu = !((list[5] as? [AXUIElement]) ?? []).isEmpty
        if title.isEmpty && !hasSubmenu { return AppMenuItem(index: index, title: "", separator: true) }
        return AppMenuItem(index: index, title: String(title.prefix(120)), enabled: (list[1] as? Bool) ?? true,
                           checked: !((list[4] as? String) ?? "").isEmpty, hasSubmenu: hasSubmenu,
                           shortcut: shortcut(char: list[2] as? String, modifiers: (list[3] as? NSNumber)?.intValue ?? 0))
    }

    /// AXMenuItemCmdModifiers: 1 Shift, 2 Option, 4 Control, 8 no Command.
    static func shortcut(char: String?, modifiers: Int) -> String? {
        guard let char, !char.isEmpty, char.count <= 3 else { return nil }
        var s = ""
        if modifiers & 4 != 0 { s += "⌃" }
        if modifiers & 2 != 0 { s += "⌥" }
        if modifiers & 1 != 0 { s += "⇧" }
        if modifiers & 8 == 0 { s += "⌘" }
        return s + char.uppercased()
    }

    private static func element(_ e: AXUIElement, _ attribute: String) -> AXUIElement? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, attribute as CFString, &v) == .success, let v,
              CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)   // swiftlint:disable:this force_cast
    }

    private static func children(_ e: AXUIElement) -> [AXUIElement] {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, kAXChildrenAttribute as CFString, &v) == .success else { return [] }
        return (v as? [AXUIElement]) ?? []
    }

    private static func string(_ e: AXUIElement, _ attribute: String) -> String? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, attribute as CFString, &v) == .success else { return nil }
        return v as? String
    }

    private static func bool(_ e: AXUIElement, _ attribute: String) -> Bool? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, attribute as CFString, &v) == .success else { return nil }
        return v as? Bool
    }
}
