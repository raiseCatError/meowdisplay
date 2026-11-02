import AppKit
import SwiftUI

/// Mac Receiver surface for session invitations (pv 21): a Mac's invitation
/// awaiting approval here, or this Mac's own Connect request waiting for the
/// sending Mac's user. A standalone panel, like `ReceiverPairingPanel`, so it
/// is visible whether or not Settings is open.
@MainActor
enum ReceiverSessionInvitationPanel {
    private static var panel: NSPanel?
    private static var panelDelegate: PanelDelegate?

    static func update(receiver: StreamReceiver) {
        guard receiver.pendingSessionApproval != nil || receiver.awaitingSenderApprovalName != nil else {
            panel?.orderOut(nil)
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        let panel: NSPanel
        if let existing = self.panel {
            panel = existing
        } else {
            panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 380, height: 1),
                styleMask: [.titled, .closable, .nonactivatingPanel],
                backing: .buffered, defer: false)
            panel.title = String(localized: "Display Request")
            panel.isFloatingPanel = true
            panel.level = .modalPanel
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            self.panel = panel
        }
        let delegate = PanelDelegate(receiver: receiver)
        panelDelegate = delegate
        panel.delegate = delegate
        let hostingView = NSHostingView(rootView: PanelContent(receiver: receiver))
        panel.contentView = hostingView
        panel.setContentSize(hostingView.fittingSize)
        if !panel.isVisible { panel.center() }
        panel.makeKeyAndOrderFront(nil)
    }

    /// Closing the panel: Reject for This Session, or Cancel while waiting.
    @MainActor
    private final class PanelDelegate: NSObject, NSWindowDelegate {
        private weak var receiver: StreamReceiver?

        init(receiver: StreamReceiver) {
            self.receiver = receiver
        }

        func windowWillClose(_ notification: Notification) {
            guard let receiver else { return }
            if let pending = receiver.pendingSessionApproval {
                receiver.respondToSessionInvitation(id: pending.id, decision: .rejectForSession)
            } else if receiver.awaitingSenderApprovalName != nil {
                receiver.cancelOutgoingSessionRequest()
            }
        }
    }

    private struct PanelContent: View {
        @ObservedObject var receiver: StreamReceiver

        var body: some View {
            Group {
                if let pending = receiver.pendingSessionApproval {
                    VStack(spacing: 20) {
                        VStack(spacing: 6) {
                            Text(pending.receiverPromptTitle)
                                .font(.headline)
                                .fixedSize(horizontal: false, vertical: true)
                                .multilineTextAlignment(.center)
                            Text(pending.receiverPromptMessage)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        HStack(spacing: 8) {
                            Button("Allow") { receiver.respondToSessionInvitation(id: pending.id, decision: .allow) }
                                .keyboardShortcut(.defaultAction)
                            Button("Allow Permanently") {
                                receiver.respondToSessionInvitation(id: pending.id, decision: .allowPermanently)
                            }
                        }
                        Divider()
                        HStack(spacing: 8) {
                            Button("Reject for This Session") {
                                receiver.respondToSessionInvitation(id: pending.id, decision: .rejectForSession)
                            }
                            .keyboardShortcut(.cancelAction)
                            Button("Reject Permanently") {
                                receiver.respondToSessionInvitation(id: pending.id, decision: .rejectPermanently)
                            }
                            .foregroundStyle(.red)
                        }
                    }
                    .padding(24)
                    .frame(width: 360)
                } else if let name = receiver.awaitingSenderApprovalName {
                    SessionInvitationWaitingCard(peerName: name) {
                        receiver.cancelOutgoingSessionRequest()
                    }
                    .frame(width: 360)
                } else {
                    Color.clear.frame(width: 1, height: 1)
                }
            }
        }
    }
}
