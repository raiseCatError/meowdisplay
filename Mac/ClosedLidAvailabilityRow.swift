import SwiftUI

/// Settings → Availability, directly below Keep Mac Available. Shows the real
/// OS value (read through `pmset -g`), and who turned it on. See CLOSED_LID.md.
struct ClosedLidAvailabilityRow: View {
    @ObservedObject var controller: SenderController

    private var state: ClosedLidState { controller.closedLidState }

    /// Never Off while sleep is disabled: during the password prompt it keeps
    /// the value from before the action.
    private var binding: Binding<Bool> {
        Binding(get: { state == .authorizing ? controller.closedLidPreventedSleepBeforeAction : state.preventsSleep },
                set: { controller.setClosedLidAvailability($0) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Circle()
                    .fill(dotColor)
                    .frame(width: 8, height: 8)
                    .accessibilityHidden(true)
                if state == .unknown {
                    // No switch: Off would be a guess.
                    Text("Stay Awake with Lid Closed")
                    Spacer()
                    Text("Unknown").foregroundStyle(.secondary)
                } else {
                    Toggle("Stay Awake with Lid Closed", isOn: binding)
                        .disabled(state == .onExternally || state == .authorizing)
                        .accessibilityValue(accessibilityStatus)
                }
            }
            .accessibilityElement(children: state == .unknown ? .combine : .contain)
            status
            notice
        }
        .onAppear { controller.refreshClosedLidState() }
        .onChange(of: controller.closedLidNotice) { _, notice in
            guard let notice else { return }
            AccessibilityNotification.Announcement(Self.text(for: notice)).post()
        }
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
            VStack(alignment: .leading, spacing: 4) {
                caption("Sleep is turned off on this Mac, and MEOW has no current record of doing it. It may be another app (such as Amphetamine's Power Protect), an administrator using pmset, MEOW before a restart, or the other MEOW build. MEOW leaves it alone.")
                Button("Turn Sleep Back On…") { controller.requestExternalClosedLidRestore() }
                    .controlSize(.small)
            }
        case .unknown:
            HStack(spacing: 8) {
                caption("Can't read this Mac's sleep setting, so MEOW won't change it.")
                Button("Check Again") { controller.refreshClosedLidState() }
                    .controlSize(.small)
            }
        }
    }

    @ViewBuilder private var notice: some View {
        if let notice = controller.closedLidNotice {
            VStack(alignment: .leading, spacing: 4) {
                warning(Self.text(for: notice))
                switch notice {
                case .confirmRestoreWithUtilities:
                    HStack {
                        Button("Turn Sleep Back On Anyway") {
                            controller.setClosedLidAvailability(false, confirmedDespiteUtilities: true)
                        }
                        Button("Keep Sleep Off") { controller.dismissClosedLidNotice() }
                    }
                    .controlSize(.small)
                case .confirmExternalRestore:
                    HStack {
                        Button("Turn Sleep Back On") { controller.confirmExternalClosedLidRestore() }
                        Button("Cancel") { controller.dismissClosedLidNotice() }
                    }
                    .controlSize(.small)
                default:
                    EmptyView()
                }
            }
        }
    }

    static func text(for notice: ClosedLidNotice) -> String {
        switch notice {
        case .authorizationCancelled:
            return "Nothing changed: the administrator request was cancelled."
        case .writeFailed(let message):
            return "macOS didn't change the sleep setting: \(message)"
        case .readFailed:
            return "Couldn't confirm this Mac's sleep setting, so MEOW isn't treating it as its own. If sleep stays off, run “sudo pmset -a disablesleep 0” in Terminal."
        case .notApplied:
            return "macOS accepted the request but the sleep setting didn't change."
        case .restoredOutsideMEOW:
            return "Sleep is back on. It was changed outside MEOW, or reset by a restart."
        case .alreadyOnExternally:
            return "Sleep was already off, set outside MEOW. MEOW left it as it was."
        case .confirmRestoreWithUtilities(let names):
            return "\(names.joined(separator: ", ")) is running. This setting is shared by every app, so turning sleep back on may also undo sleep prevention that \(names.count == 1 ? "it" : "they") set."
        case .confirmExternalRestore:
            return "MEOW didn't turn sleep off, so turning it back on may undo another app's or an administrator's setting. Turn sleep back on anyway?"
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    private func warning(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
    }
}
