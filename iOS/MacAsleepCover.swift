import SwiftUI

/// Shown, opaque, over the session while the Mac's displays are asleep (`macDisplaySleep`, #255).
/// The session is still connected, but the Mac has nothing to capture and this device dropped
/// the last picture. It never wakes the Mac by itself: Wake Mac sends one authenticated wake
/// request (the same one Wake & Connect uses) and waits a bounded time for the Mac to report its
/// displays awake. The locked cover and the picture take over from there.
struct MacAsleepCoverOverlay: ViewModifier {
    @ObservedObject var receiver: StreamReceiver
    let macName: String
    @State private var request = MacWakeRequest()

    private var name: String { macName.isEmpty ? String(localized: "Your Mac") : macName }

    private func wake() {
        guard let id = request.begin() else { return }
        receiver.requestPromoteInteractiveWake()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(MacWakeRequest.timeout * 1_000_000_000))
            request.timedOut(id)
        }
    }

    private var cover: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 14) {
                Image(systemName: "moon.zzz.fill")
                    .font(.system(size: 40, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
                    .accessibilityHidden(true)
                Text("\(name) is asleep").font(.title2.weight(.semibold)).foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                Text("You’re still connected. Wake it to continue where you left off.")
                    .font(.body).foregroundStyle(.white.opacity(0.75)).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                if request.phase == .waiting {
                    HStack(spacing: 8) {
                        ProgressView().tint(.white)
                        Text("Waking…").font(.callout).foregroundStyle(.white.opacity(0.85))
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("macAsleepStatus")
                } else {
                    Button(action: wake) {
                        Label(request.phase == .failed ? "Try Again" : "Wake Mac", systemImage: "power")
                            .frame(minWidth: 180)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .accessibilityIdentifier("macAsleepWake")
                    if request.phase == .failed {
                        Text("The Mac didn’t wake. Try again, or wake it at the Mac.")
                            .font(.callout).foregroundStyle(.orange).multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("macAsleepStatus")
                    }
                }
                Button("Disconnect", role: .destructive) { receiver.disconnect() }
                    .buttonStyle(.bordered)
                    .padding(.top, 6)
                    .accessibilityIdentifier("macAsleepDisconnect")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .frame(maxWidth: 460)
            .accessibilityElement(children: .contain)
        }
        .contentShape(Rectangle())
        .onTapGesture {}   // takes every touch: nothing reaches the views behind
        .accessibilityAddTraits(.isModal)
        .accessibilityIdentifier("macAsleepCover")
    }

    func body(content: Content) -> some View {
        content
            .overlay {
                if receiver.macDisplayAsleep { cover.transition(.opacity) }
            }
            .animation(.easeOut(duration: 0.15), value: receiver.macDisplayAsleep)
            .onChange(of: receiver.macDisplayAsleep) { asleep in request.displayReported(asleep: asleep) }
    }
}
