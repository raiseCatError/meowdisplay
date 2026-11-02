import AppKit
import SwiftUI

/// The pairing-code confirmation for the Mac Receiver: the shared
/// `StreamReceiver` pairing responder/initiator waits on its
/// `PairingPromptModel` for an explicit Codes Match / Cancel, so something
/// on this Mac must present it. Mirrors Mac Sender's
/// `SecurityPresentationCoordinator.presentPairing` — a real, independently
/// alive floating panel driven only by the model, never a sheet on a
/// Settings page that may not exist — with only the macOS 12 SwiftUI
/// differences. Trust is decided entirely by the model; this only shows it.
@MainActor
enum ReceiverPairingPanel {
    private static var panel: NSPanel?
    // NSWindow does not retain its delegate.
    private static var panelDelegate: PanelDelegate?

    static func present(prompt: PairingPromptModel) {
        guard let pending = prompt.pending else { return }
        Log.info("uiDebug: pairing presentation requested peerID=\(pending.peerID)")
        NSApp.activate(ignoringOtherApps: true)

        let panel: NSPanel
        if let existing = self.panel {
            panel = existing
        } else {
            panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 380, height: 240),
                styleMask: [.titled, .closable, .nonactivatingPanel],
                backing: .buffered, defer: false)
            panel.title = String(localized: "Pairing Request")
            panel.isFloatingPanel = true
            panel.level = .modalPanel
            // A security decision stays visible until it is answered or times out.
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            self.panel = panel
        }
        // Closing the panel with its close button rejects the pending
        // confirmation; our own `orderOut` below does not reach the delegate.
        let delegate = PanelDelegate(prompt: prompt)
        panelDelegate = delegate
        panel.delegate = delegate
        panel.contentView = NSHostingView(rootView: ReceiverPairingPanelView(prompt: prompt) {
            Log.info("uiDebug: pairing panel closed reason=resolved")
            panel.orderOut(nil)
        })
        panel.center()
        panel.makeKeyAndOrderFront(nil)
    }

    @MainActor
    private final class PanelDelegate: NSObject, NSWindowDelegate {
        private weak var prompt: PairingPromptModel?

        init(prompt: PairingPromptModel) {
            self.prompt = prompt
        }

        func windowWillClose(_ notification: Notification) {
            Log.info("uiDebug: pairing panel closed reason=windowClosed")
            prompt?.windowClosedByUser()
        }
    }
}

/// Observes the live `PairingPromptModel`, so it always shows the current
/// request and closes the moment the attempt ends — by user action here, a
/// duplicate-request rejection, or the model's timeout.
private struct ReceiverPairingPanelView: View {
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
                    VStack(spacing: 2) {
                        Text(PairingCopy.sasTitle).font(.subheadline.weight(.semibold))
                        Text(PairingCopy.sasHelper).font(.caption).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    HStack {
                        Button("Cancel", role: .cancel) { prompt.decide(accept: false) }
                        Button(pending.classification == .newPeer ? "Codes Match" : "Re-pair") {
                            prompt.decide(accept: true)
                        }
                        .keyboardShortcut(.defaultAction)
                        .disabled(prompt.isAuthenticating)
                    }
                }
                .padding(24)
            } else if let confirmed = prompt.confirmedLocally {
                VStack(spacing: 12) {
                    ProgressView()
                    Text(PairingCopy.waitingTitle).font(.headline)
                    Text(PairingCopy.waitingHelper(
                        otherDevice: PairingCopy.otherDevice(localIsMac: true, peerName: confirmed.peerName)))
                        .font(.subheadline).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    if !prompt.isCommitting {
                        Button("Cancel", role: .cancel) { prompt.cancelWaiting() }
                    }
                }
                .padding(24)
            } else {
                Color.clear.frame(width: 1, height: 1)
            }
        }
        .frame(minWidth: 360)
        // Stays open while waiting for the other device; closes only once
        // the attempt has neither a pending code nor a local confirmation.
        // The single-value onChange: the two-value form is macOS 14.
        .onChange(of: prompt.pending == nil && prompt.confirmedLocally == nil) { ended in
            if ended { onResolved() }
        }
    }
}
