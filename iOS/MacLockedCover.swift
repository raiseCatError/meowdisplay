import SwiftUI

/// Shown, opaque, over everything while the Mac's screen is locked or switched to another user
/// (`macLockState`). Nothing of the Mac is behind it: the Mac sends no picture, sound, window
/// names or stills meanwhile, and this device dropped what it had. It says where unlocking
/// happens; MeowDisplay never asks for or carries the Mac's password. It stays up through every step
/// of Show Lock Screen until the Mac's lock screen is playing here (`MacLockedCoverPolicy`).
struct MacLockedCover: View {
    let notice: MacLockNotice
    let macName: String
    var lockFlow = LockScreenFlow()
    /// Local actions that never need control of the Mac (#255): the cover takes every touch, so
    /// they have to be on it. Nil hides one.
    var onSettings: (() -> Void)?
    var onBackToHome: (() -> Void)?
    var onShowLockScreen: () -> Void = {}
    var onHideLockScreen: () -> Void = {}
    var onCancelLockScreen: () -> Void = {}
    let onDisconnect: () -> Void

    /// The Mac offers its own lock screen to this device (or is waiting on a step toward it).
    private var offersLockScreen: Bool {
        guard notice.state == .locked, notice.remoteUnlock else { return false }
        switch notice.lockScreen {
        case .available, .needsControl, .needsFullDesktop: return true
        case .active, .unavailable: return false
        }
    }

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
            if offersLockScreen || lockFlow.isWaiting || notice.showsMacLockScreen {
                return String(localized: "Unlock it at the Mac, or show its lock screen here.")
            }
            return String(localized: "Unlock it at the Mac to continue.")
        }
    }

    @ViewBuilder private var lockScreenControls: some View {
        VStack(spacing: 8) {
            if lockFlow.isWaiting {
                status(waitingText)
                // A way out that isn't Disconnect: stop waiting and keep the session (#255).
                Button("Cancel", action: onCancelLockScreen)
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("macLockedCancelLockScreen")
            } else if notice.showsMacLockScreen, lockFlow.isShowing {
                // The Mac said `active`; the picture isn't playing yet.
                status(String(localized: "Waiting for the lock screen picture…"))
                Button("Cancel", action: onHideLockScreen)
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("macLockedHideLockScreen")
            } else if offersLockScreen {
                Button(action: onShowLockScreen) {
                    Label("Show Lock Screen", systemImage: "lock.open.fill")
                        .frame(minWidth: 180)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .accessibilityIdentifier("macLockedShowLockScreen")
                if let offerText = MacLockedCoverPolicy.offerText(notice) {
                    Text(offerText).font(.callout).foregroundStyle(.white.opacity(0.8)).multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("macLockedLockScreenOffer")
                }
                Text("Type your Mac password on its own lock screen. MeowDisplay passes the keys to macOS and doesn’t check, log or keep them.")
                    .font(.footnote).foregroundStyle(.white.opacity(0.6)).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !lockFlow.isWaiting {
                if case .failed(let message) = lockFlow.phase {
                    Text(message).font(.callout).foregroundStyle(.orange).multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("macLockedLockScreenStatus")
                } else if !offersLockScreen, !notice.showsMacLockScreen, let reason = MacLockedCoverPolicy.offerText(notice) {
                    // Not offered: why, in plain words.
                    Text(reason).font(.callout).foregroundStyle(.white.opacity(0.75)).multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("macLockedLockScreenOffer")
                }
            }
        }
        .padding(.top, 4)
    }

    private func status(_ text: String) -> some View {
        HStack(spacing: 8) {
            ProgressView().tint(.white)
            Text(text).font(.callout).foregroundStyle(.white.opacity(0.85))
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("macLockedLockScreenStatus")
    }

    private var lockFlowFailed: Bool {
        if case .failed = lockFlow.phase { return true }
        return false
    }

    private var waitingText: String {
        switch lockFlow.phase {
        case .waitingForControl: return String(localized: "Asking for control…")
        case .waitingForFullDesktop: return String(localized: "Switching to Full Desktop…")
        default: return String(localized: "Showing the lock screen…")
        }
    }

    private var content: some View {
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
            if notice.state == .locked || lockFlow.isWaiting || lockFlowFailed { lockScreenControls }
            HStack(spacing: 10) {
                if let onBackToHome {
                    Button(action: onBackToHome) { Label("Back to Home", systemImage: "house") }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("macLockedBackToHome")
                }
                if let onSettings {
                    Button(action: onSettings) { Label("Settings", systemImage: "gearshape") }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("macLockedSettings")
                }
            }
            .tint(.white)
            .padding(.top, 6)
            Button("Disconnect", role: .destructive, action: onDisconnect)
                .buttonStyle(.bordered)
                .accessibilityIdentifier("macLockedDisconnect")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .frame(maxWidth: 460)
        .accessibilityElement(children: .contain)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            // A phone in landscape (compact height) or large text: the same content, scrolling.
            ViewThatFits(in: .vertical) {
                content
                ScrollView { content.frame(maxWidth: .infinity) }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {}   // takes every touch: nothing reaches the views behind
        .accessibilityAddTraits(.isModal)
        .accessibilityIdentifier("macLockedCover")
    }
}
