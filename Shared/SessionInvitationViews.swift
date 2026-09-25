import SwiftUI

// Receiver-side SwiftUI pieces for session invitations (pv 21), shared by
// the iPhone/iPad Receiver and the Mac Receiver.

/// Per-Mac override of "Automatically Allow Connections".
struct IncomingSessionPolicyPicker: View {
    let peerID: String
    let title: LocalizedStringKey
    @State private var policy: IncomingSessionPeerPolicy?

    init(_ title: LocalizedStringKey = "Connection Requests", peerID: String) {
        self.title = title
        self.peerID = peerID
        _policy = State(initialValue: IncomingSessionPolicyStore.policy(peerID: peerID))
    }

    var body: some View {
        Picker(title, selection: Binding(
            get: { policy },
            set: { newValue in
                policy = newValue
                IncomingSessionPolicyStore.setPolicy(newValue, peerID: peerID)
            })) {
            Text("Default").tag(IncomingSessionPeerPolicy?.none)
            Text("Always Allow").tag(IncomingSessionPeerPolicy?.some(.alwaysAllow))
            Text("Block").tag(IncomingSessionPeerPolicy?.some(.blocked))
        }
    }
}

/// The global incoming-invitation preference, with its explanation.
struct AutomaticallyAllowConnectionsToggle: View {
    @AppStorage(IncomingSessionPolicyStore.automaticallyAllowKey) private var automaticallyAllow = true

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Automatically Allow Connections", isOn: $automaticallyAllow)
            Text("When a paired Mac starts sharing with this device, connect without asking. Blocked Macs are never connected.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// "Waiting for <Mac> to accept…" while this device's own Connect request
/// waits for the Mac's user.
struct SessionInvitationWaitingCard: View {
    let peerName: String
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            ProgressView()
            Text("Waiting for \(peerName) to accept…")
                .font(.callout)
            Spacer(minLength: 8)
            Button("Cancel", action: onCancel)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding()
    }
}

extension PendingSessionApproval {
    /// Title for a Mac's invitation shown on a receiver.
    var receiverPromptTitle: String {
        String(localized: "\(peerName) wants to share its display with this device.")
    }

    /// The Sender-chosen mode, as context only.
    var receiverPromptMessage: String {
        switch mode {
        case .mirror: return String(localized: "It will connect using Mirror.")
        case .extend: return String(localized: "It will connect using Extend.")
        }
    }
}

extension View {
    /// Receiver approval actions for a Mac's invitation: the Sender already
    /// chose Mirror/Extend, so there is no mode choice here.
    func sessionInvitationPrompt(receiver: StreamReceiver) -> some View {
        modifier(SessionInvitationPromptModifier(receiver: receiver))
    }
}

private struct SessionInvitationPromptModifier: ViewModifier {
    @ObservedObject var receiver: StreamReceiver

    func body(content: Content) -> some View {
        content
            .confirmationDialog(
                receiver.pendingSessionApproval?.receiverPromptTitle ?? "",
                // Dismissing without a choice runs the cancel-role button:
                // Reject for This Session.
                isPresented: Binding(get: { receiver.pendingSessionApproval != nil }, set: { _ in }),
                titleVisibility: .visible,
                presenting: receiver.pendingSessionApproval
            ) { pending in
                Button("Allow") { receiver.respondToSessionInvitation(id: pending.id, decision: .allow) }
                Button("Allow Permanently") {
                    receiver.respondToSessionInvitation(id: pending.id, decision: .allowPermanently)
                }
                Button("Reject Permanently", role: .destructive) {
                    receiver.respondToSessionInvitation(id: pending.id, decision: .rejectPermanently)
                }
                Button("Reject for This Session", role: .cancel) {
                    receiver.respondToSessionInvitation(id: pending.id, decision: .rejectForSession)
                }
            } message: { pending in
                Text(pending.receiverPromptMessage)
            }
            .overlay(alignment: .bottom) {
                if let name = receiver.awaitingSenderApprovalName {
                    SessionInvitationWaitingCard(peerName: name) {
                        receiver.cancelOutgoingSessionRequest()
                    }
                }
            }
    }
}
