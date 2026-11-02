// MeowDisplay Receiver: the standalone "this Mac is a display" app (issues
// #82/#17). It is a separate bundle from the sender on purpose: the sender
// needs macOS 14 for its capture/virtual-display stack, while receiving only
// needs the decoder and a window, so this target keeps a much lower
// deployment floor and old Macs can serve as screens (issue #241).
//
// The receiver starts at launch and stays up for the app's lifetime; the
// Settings window (ReceiverSettingsWindow) only shows and changes it. The
// video window itself is managed by ReceiverController.

import AppKit
import SwiftUI
import Sparkle

// Plain AppKit lifecycle rather than a SwiftUI `App`: a `WindowGroup` sizes
// its window itself and hands out File > New; the Settings window here is
// one AppKit split-view window built like the sender's.
@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static func main() {
        let app = NSApplication.shared
        // NSApplication.delegate is weak, and ARC may free a local after its
        // last use — an optimized build could drop the delegate before the
        // launch callbacks ever fire. run() never returns, so this pins it
        // for the app's lifetime.
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }

    let updater = SPUStandardUpdaterController(
        startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = makeMainMenu()
        ReceiverController.shared.onNeedsAttention = { [weak self] in
            self?.showSettings()
        }
        ReceiverController.shared.start()
        showSettings()
    }

    // Reopening (Dock click) with Settings closed brings it back; the
    // receiver itself never stopped.
    func applicationShouldHandleReopen(_ sender: NSApplication,
                                       hasVisibleWindows: Bool) -> Bool {
        showSettings()
        return false
    }

    // Closing Settings is not quitting: a spare Mac sits there as a display
    // with nothing but the video window (or nothing at all) on screen.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    // Quitting while being a display: tell the sender we're closing (it ends
    // the session instead of retrying a dead peer) before the process goes.
    // stop() calls back once the message is out or a second has passed.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard ReceiverController.shared.active else { return .terminateNow }
        ReceiverController.shared.stop {
            DispatchQueue.main.async { NSApp.reply(toApplicationShouldTerminate: true) }
        }
        return .terminateLater
    }

    @objc private func showSettings() {
        // AppKit delegate callbacks and the onNeedsAttention hook run on the main thread.
        let controller = MainActor.assumeIsolated { ReceiverController.shared }
        ReceiverSettingsWindow.show(controller: controller, updater: updater)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// The minimum a windowed app needs: an app menu with Settings and Quit,
    /// Edit for the text fields' copy/paste and undo, and a Window menu for
    /// Close/Minimize.
    private func makeMainMenu() -> NSMenu {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: String(localized: "About MeowDisplay Receiver"),
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                        keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: String(localized: "Settings…"),
                        action: #selector(showSettings), keyEquivalent: ",").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: String(localized: "Check for Updates…"),
                        action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)),
                        keyEquivalent: "").target = updater
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: String(localized: "Hide MeowDisplay Receiver"),
                        action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: String(localized: "Quit MeowDisplay Receiver"),
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: String(localized: "Edit"))
        edit.addItem(withTitle: String(localized: "Undo"), action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: String(localized: "Redo"), action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: String(localized: "Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: String(localized: "Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: String(localized: "Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: String(localized: "Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let window = NSMenu(title: String(localized: "Window"))
        window.addItem(withTitle: String(localized: "Close"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        window.addItem(withTitle: String(localized: "Minimize"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: String(localized: "Zoom", comment: "Window menu: toggle the window between its standard and user size."), action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowItem.submenu = window
        main.addItem(windowItem)
        NSApp.windowsMenu = window

        return main
    }
}
