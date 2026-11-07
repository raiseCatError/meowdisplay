import SwiftUI

/// Shown, opaque, over everything while the Mac's screen is locked or switched to another user
/// (`macLockState`). Nothing of the Mac is behind it: the Mac sends no picture, sound, window
/// names or stills meanwhile, and this device dropped what it had. It says where unlocking
/// happens; MeowDisplay never asks for or carries the Mac's password.
struct MacLockedCover: View {
    let notice: MacLockNotice
    let macName: String
    let onDisconnect: () -> Void

    private var name: String { macName.isEmpty ? String(localized: "Your Mac") : macName }

    private var title: String {
        notice.state == .switchedOut ? String(localized: "\(name) is in use by another user")
                                     : String(localized: "\(name) is locked")
    }

    private var detail: String {
        switch notice.state {
        case .switchedOut:
            return String(localized: "Switch back to your account on the Mac to continue.")
        case .unknown:
            return String(localized: "MeowDisplay can’t confirm the Mac is unlocked, so nothing is shown. Unlock it at the Mac to continue.")
        default:
            return String(localized: "Unlock it at the Mac to continue. It can’t be unlocked from this device, and control can be requested once it’s unlocked.")
        }
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 14) {
                Image(systemName: notice.state == .switchedOut ? "person.2.fill" : "lock.fill")
                    .font(.system(size: 40, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
                    .accessibilityHidden(true)
                Text(title).font(.title2.weight(.semibold)).foregroundStyle(.white).multilineTextAlignment(.center)
                Text(detail).font(.body).foregroundStyle(.white.opacity(0.75)).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Your layout comes back when it’s unlocked.")
                    .font(.footnote).foregroundStyle(.white.opacity(0.55)).multilineTextAlignment(.center)
                Button("Disconnect", role: .destructive, action: onDisconnect)
                    .buttonStyle(.bordered)
                    .padding(.top, 6)
                    .accessibilityIdentifier("macLockedDisconnect")
            }
            .padding(.horizontal, 28)
            .frame(maxWidth: 460)
            .accessibilityElement(children: .contain)
        }
        .contentShape(Rectangle())
        .onTapGesture {}   // takes every touch: nothing reaches the views behind
        .accessibilityAddTraits(.isModal)
        .accessibilityIdentifier("macLockedCover")
    }
}
