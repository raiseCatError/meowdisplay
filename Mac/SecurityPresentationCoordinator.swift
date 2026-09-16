import AppKit
import SwiftUI

/// Single, stable owner for every security-relevant confirmation (pairing
/// SAS, Forget Device). Neither surface is a `.sheet`/`.confirmationDialog`
/// attached to a Settings page view — those are transient (a MenuBarExtra
/// popover that only exists while open, or a MacSettingsWindow that may not
/// have been created yet), so a modifier hung off one can silently own a
/// pending confirmation with nothing on screen. These are real,
/// independently-alive AppKit objects instead, driven directly by the model
/// (`PairingPromptModel`) or the controller call site (`requestForget`),
/// never by whichever settings view instance happens to exist.
@MainActor
enum SecurityPresentationCoordinator {
    // MARK: - Pairing (SAS confirmation)

    private static var pairingPanel: NSPanel?
    // Held here, not just as `panel.delegate`, since NSWindow does not
    // retain its delegate — letting this drop would silently stop the
    // window-close-as-rejection wiring below.
    private static var pairingPanelDelegate: PairingPanelWindowDelegate?

    static func presentPairing(prompt: PairingPromptModel) {
        guard let pending = prompt.pending else { return }
        Log.info("uiDebug: pairing presentation requested peerID=\(pending.peerID)")
        NSApp.activate(ignoringOtherApps: true)

        let panel: NSPanel
        if let existing = pairingPanel {
            panel = existing
        } else {
            panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 380, height: 240),
                styleMask: [.titled, .closable, .nonactivatingPanel],
                backing: .buffered, defer: false)
            panel.title = "Pairing Request"
            panel.isFloatingPanel = true
            panel.level = .modalPanel
            // A security decision must stay visible even if the user clicks
            // elsewhere — it may only close through explicit accept/reject
            // or the model's own timeout, never by losing focus.
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            pairingPanel = panel
            Log.info("uiDebug: pairing panel created id=\(ObjectIdentifier(panel))")
        }
        // The traffic-light close button is an explicit rejection of
        // whatever confirmation is pending when it's clicked — never a
        // no-op that leaves an invisible `pending` behind to reject the
        // next Pair attempt as a duplicate. Our own `orderOut` (below, once
        // the model resolves) does not trigger this delegate call, only an
        // actual `close()` from the window controls does, so a user close
        // and a programmatic dismiss can never be confused for each other.
        let delegate = PairingPanelWindowDelegate(prompt: prompt)
        pairingPanelDelegate = delegate
        panel.delegate = delegate
        panel.contentView = NSHostingView(rootView: PairingPanelView(prompt: prompt, onResolved: {
            Log.info("uiDebug: pairing panel closed reason=resolved")
            panel.orderOut(nil)
        }))
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        Log.info("uiDebug: pairing panel orderedFront visible=\(panel.isVisible) keyWindow=\(panel.isKeyWindow)")
    }

    // MARK: - Forget Device

    // Guards against a double-presentation if requestForget is somehow
    // invoked twice for overlapping confirmations (e.g. two rows racing).
    private static var forgetAlertActive = false

    static func presentForget(_ request: ForgetConfirmation, controller: SenderController) {
        Log.info("uiDebug: forget presentation requested peerID=\(request.peerID)")
        guard !forgetAlertActive else {
            Log.info("uiDebug: forget presentation skipped reason=alreadyPresenting")
            return
        }
        forgetAlertActive = true
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = "Forget \(request.name)?"
        alert.informativeText = "This removes trust, connection hints, and wake metadata for this device. It must be re-paired to connect again."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Forget Device")
        alert.addButton(withTitle: "Cancel")
        Log.info("uiDebug: forget panel visible=true")
        // NSAlert.runModal is synchronous and does not require Dock
        // presence — it works in accessory (menu-bar-only) apps exactly
        // like it does in regular ones, unlike a SwiftUI sheet/dialog
        // attached to a MenuBarExtra popover.
        let response = alert.runModal()
        forgetAlertActive = false
        if response == .alertFirstButtonReturn {
            controller.confirmForget(request)
        } else {
            controller.cancelForget(request)
        }
    }
}

/// Treats the user closing the pairing panel via its window controls as an
/// explicit rejection of the pending confirmation (see the invariant in
/// `SecurityPresentationCoordinator.presentPairing`).
@MainActor
private final class PairingPanelWindowDelegate: NSObject, NSWindowDelegate {
    private weak var prompt: PairingPromptModel?

    init(prompt: PairingPromptModel) {
        self.prompt = prompt
    }

    func windowWillClose(_ notification: Notification) {
        Log.info("uiDebug: pairing panel closed reason=windowClosed")
        prompt?.windowClosedByUser()
    }
}

/// The pairing panel's content. Observes the shared `PairingPromptModel`
/// directly rather than receiving a snapshot, so it always reflects the
/// live pending confirmation and disappears the instant it resolves —
/// whether by user action here, a duplicate-request rejection, or timeout.
private struct PairingPanelView: View {
    @ObservedObject var prompt: PairingPromptModel
    let onResolved: () -> Void

    var body: some View {
        Group {
            if let pending = prompt.pending {
                VStack(spacing: 16) {
                    switch pending.classification {
                    case .newPeer:
                        Text("Pair with \(pending.peerName)?").font(.headline)
                    case .rePairSameKey:
                        Text("\(pending.peerName) is already paired with this Mac.")
                            .font(.headline)
                        Text("The device is requesting to pair again.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    case .identityChanged:
                        Text("This device's cryptographic identity has changed.")
                            .font(.headline)
                        Text("Re-pair only if you trust \(pending.peerName) — its saved key no longer matches.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    Text(pending.sas).font(.system(.title, design: .monospaced)).bold()
                    Text("Confirm only if this code matches on both devices.")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("Cancel", role: .cancel) { prompt.decide(accept: false) }
                        Button(pending.classification == .newPeer ? "Codes Match" : "Re-pair") {
                            prompt.decide(accept: true)
                        }
                        .keyboardShortcut(.defaultAction)
                    }
                }
                .padding(24)
            } else {
                Color.clear.frame(width: 1, height: 1)
            }
        }
        .frame(minWidth: 360)
        .onChange(of: prompt.pending) { _, newValue in
            if newValue == nil { onResolved() }
        }
    }
}
