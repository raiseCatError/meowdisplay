import SwiftUI

/// The Automatic Remote Access switch (PROTOCOL.md 6.17), on unless turned off. Each app has its
/// own; turning it off forgets the addresses paired devices reported, and the next connection
/// tells them to forget this one's.
struct AutomaticRemoteAccessToggle: View {
    let role: RolePreferences
    /// "devices" on the Mac, "Macs" on a receiver.
    let peers: Peers

    enum Peers { case devices, macs }

    @State private var enabled: Bool

    init(role: RolePreferences, peers: Peers) {
        self.role = role
        self.peers = peers
        _enabled = State(initialValue: AutomaticRemoteAccessPreference.isEnabled(role))
    }

    var body: some View {
        Toggle(isOn: Binding(get: { enabled }, set: { newValue in
            enabled = newValue
            AutomaticRemoteAccessPreference.set(newValue, role)
        })) {
            switch peers {
            case .devices: Text("Share Tailscale Addresses with Paired Devices")
            case .macs: Text("Share Tailscale Addresses with Paired Macs")
            }
        }
        Text("After a connection, this device and the other one tell each other their Tailscale addresses, so Remote Access can reach it later without typing one. Only addresses are shared. They never grant trust: every connection still needs the existing secure pairing. Turning this off forgets the addresses others shared.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}
