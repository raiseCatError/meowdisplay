import SwiftUI

/// Settings → Availability, directly below Keep Mac Available. Shows the real
/// OS value (read through `pmset -g`), and who turned it on. See CLOSED_LID.md.
struct ClosedLidAvailabilityRow: View {
    @ObservedObject var controller: SenderController

    private var state: ClosedLidState { controller.closedLidState }

    private var binding: Binding<Bool> {
        Binding(get: { state.preventsSleep },
                set: { controller.setClosedLidAvailability($0) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Circle()
                    .fill(dotColor)
                    .frame(width: 8, height: 8)
                    .accessibilityHidden(true)
                Toggle("Stay Awake with Lid Closed", isOn: binding)
                    .disabled(state == .onExternally || state == .unknown || state == .authorizing)
                    .accessibilityValue(accessibilityStatus)
            }
            status
            notice
        }
        .onAppear { controller.refreshClosedLidState() }
    }

    private var dotColor: Color {
        switch state {
        case .onByMEOW: .green
        case .onExternally: .blue
        case .authorizing, .unknown: .orange
        case .off: Color.secondary.opacity(0.5)
        }
    }

    private var accessibilityStatus: String {
        switch state {
        case .off: "Off, normal sleep"
        case .onByMEOW: "On, turned on by MEOW"
        case .onExternally: "On, set outside MEOW"
        case .authorizing: "Waiting for administrator approval"
        case .unknown: "Sleep setting unavailable"
        }
    }

    @ViewBuilder private var status: some View {
        switch state {
        case .off:
            caption("Turns off all sleep on this Mac, so a MacBook keeps running with its lid closed and no external display. Asks for an administrator password each time it changes.")
        case .authorizing:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                caption("Waiting for administrator approval…")
            }
        case .onByMEOW:
            caption("Turned on by MEOW. This Mac won't sleep at all — not with the lid closed, and not from Apple menu → Sleep — until you turn this off. Keep it on power and ventilated, and don't put it in a bag while it's on.")
        case .onExternally:
            caption("Sleep is already turned off on this Mac by something other than MEOW — another app (such as Amphetamine's Power Protect) or an administrator using pmset. MEOW didn't change it and won't turn it back on.")
        case .unknown:
            HStack(spacing: 8) {
                caption("Can't read this Mac's sleep setting, so MEOW won't change it.")
                Button("Check Again") { controller.refreshClosedLidState() }
                    .controlSize(.small)
            }
        }
    }

    @ViewBuilder private var notice: some View {
        switch controller.closedLidNotice {
        case nil:
            EmptyView()
        case .authorizationCancelled:
            warning("Nothing changed: the administrator request was cancelled.")
        case .writeFailed(let message):
            warning("macOS didn't change the sleep setting: \(message)")
        case .readFailed:
            warning("Couldn't confirm this Mac's sleep setting, so MEOW isn't treating it as its own.")
        case .notApplied:
            warning("macOS accepted the request but the sleep setting didn't change.")
        case .restoredOutsideMEOW:
            warning("Sleep is back on. It was changed outside MEOW, or reset by a restart.")
        case .alreadyOnExternally:
            warning("Sleep was already off, set outside MEOW. MEOW left it as it was.")
        case .confirmRestoreWithUtilities(let names):
            VStack(alignment: .leading, spacing: 4) {
                warning("\(names.joined(separator: ", ")) is running. This setting is shared by every app, so turning sleep back on may also undo sleep prevention that \(names.count == 1 ? "it" : "they") set.")
                HStack {
                    Button("Turn Sleep Back On Anyway") {
                        controller.setClosedLidAvailability(false, confirmedDespiteUtilities: true)
                    }
                    Button("Keep Sleep Off") { controller.dismissClosedLidNotice() }
                }
                .controlSize(.small)
            }
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    private func warning(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
    }
}
