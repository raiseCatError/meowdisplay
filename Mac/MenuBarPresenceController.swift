import AppKit
import SwiftUI
import Combine

/// Owns the single `NSStatusItem` for MeowDisplay's menu-bar presence.
///
/// Root cause of the bug this replaces: the menu-bar icon was previously a
/// SwiftUI `MenuBarExtra(isInserted:)` scene, whose insertion is supposed to
/// track a binding read from `SenderController.presentation`. In practice
/// toggling that binding after launch does not reliably insert/remove the
/// status item — the extra's lifecycle is owned by SwiftUI's scene graph,
/// not by this controller, so there is no deterministic point where "the
/// setting changed" is guaranteed to translate into "the item now exists".
/// Driving a single, explicitly-owned `NSStatusItem` here instead means the
/// item is created/removed at exactly the moments this controller decides,
/// nothing else can leave it half-updated, and only one instance can ever
/// exist (`statusItem` is the sole owner — `apply` always tears down any
/// existing item before deciding whether to create a fresh one).
@MainActor
final class MenuBarPresenceController: NSObject {
    static let shared = MenuBarPresenceController()

    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var observation: AnyCancellable?
    private weak var observedController: SenderController?

    /// Idempotent: safe to call on every presentation change (live switch)
    /// and once at cold launch. Never creates a second status item — if one
    /// already exists and menu-bar presence is still wanted, it's left
    /// alone (only its icon/content may refresh via the state observation).
    func apply(_ presentation: AppPresentation, controller: SenderController) {
        if presentation.showsMenuBarIcon {
            observeIfNeeded(controller: controller)
            if statusItem == nil {
                createStatusItem(controller: controller)
            } else {
                refreshIcon(controller: controller)
            }
        } else {
            tearDown()
        }
    }

    private func createStatusItem(controller: SenderController) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.target = self
        item.button?.action = #selector(togglePopover(_:))
        statusItem = item
        refreshIcon(controller: controller)
    }

    private func tearDown() {
        popover?.performClose(nil)
        popover = nil
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
        }
        statusItem = nil
        observation = nil
        observedController = nil
    }

    private func observeIfNeeded(controller: SenderController) {
        guard observedController !== controller else { return }
        observedController = controller
        observation = controller.objectWillChange.sink { [weak self, weak controller] _ in
            guard let self, let controller else { return }
            // objectWillChange fires before the value updates — hop one
            // runloop turn so the icon reflects the new state.
            DispatchQueue.main.async { self.refreshIcon(controller: controller) }
        }
    }

    private func refreshIcon(controller: SenderController) {
        // A distinct, monochrome/template status icon — never the full-color
        // app logo — per the menu-bar status-item convention. Template mode
        // lets AppKit render it correctly in both light and dark menu bars.
        let name = controller.hasActiveDisplay ? "rectangle.on.rectangle.fill" : "rectangle.on.rectangle"
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "MeowDisplay")
        image?.isTemplate = true
        statusItem?.button?.image = image
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem?.button else { return }
        if let popover, popover.isShown {
            popover.performClose(sender)
            return
        }
        let controller = observedController ?? SenderController.shared
        let hosting = NSHostingController(rootView: MenuBarQuickView(controller: controller))
        let popover = self.popover ?? NSPopover()
        popover.behavior = .transient
        popover.contentViewController = hosting
        self.popover = popover
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        NSApp.activate(ignoringOtherApps: true)
    }
}
