import SwiftUI

/// The session's control state and the one existing way to ask for control (the same request as
/// Settings ▸ Input), handed down to every place that says an action needs control.
struct InlineControlRequest: Sendable {
    var state: SessionInputWireState
    var request: @MainActor @Sendable () -> Void
}

private struct InlineControlRequestKey: EnvironmentKey {
    static let defaultValue: InlineControlRequest? = nil
}

extension EnvironmentValues {
    var controlRequest: InlineControlRequest? {
        get { self[InlineControlRequestKey.self] }
        set { self[InlineControlRequestKey.self] = newValue }
    }
}

/// Where actions that need control are hidden: says so, with Request Control in place.
/// The caller shows it only while this device can't control the Mac.
struct MoreActionsNeedControl: View {
    var detail: String?

    var body: some View {
        VStack(spacing: 6) {
            Text(detail ?? String(localized: "Request Control for more actions."))
                .font(.caption).foregroundStyle(.white.opacity(0.75)).multilineTextAlignment(.center)
            RequestControlInline(compact: true)
        }
        .frame(maxWidth: .infinity)
    }
}

/// "Control required · Request Control" in place: asks the Mac, shows Awaiting Approval, then
/// the answer. Never repeats the action that needed control; the person does that.
struct RequestControlInline: View {
    @Environment(\.controlRequest) private var control
    var compact = false

    var body: some View {
        if let control, control.state != .allowed {
            HStack(spacing: 8) {
                switch control.state {
                case .requesting:
                    ProgressView().controlSize(.small)
                    Text("Awaiting approval on the Mac…").font(.caption)
                case .requestsDisabled:
                    Image(systemName: "lock").accessibilityHidden(true)
                    Text("This Mac doesn't take control requests from this device.").font(.caption)
                case .notAllowed:
                    Text("Not allowed.").font(.caption)
                    button(String(localized: "Ask Again"), control)
                default:
                    if !compact { Text("Control required").font(.caption) }
                    button(String(localized: "Request Control"), control)
                }
            }
            .foregroundStyle(.white.opacity(0.9))
            .accessibilityElement(children: .contain)
        }
    }

    private func button(_ title: String, _ control: InlineControlRequest) -> some View {
        Button(title, action: control.request)
            .font(.caption.weight(.semibold))
            .buttonStyle(.borderedProminent)
            .controlSize(.mini)
            .tint(meowAccent)
            .accessibilityHint("Asks the Mac to allow control from this device")
    }
}

extension InlineControlRequest {
    /// The label for a control-gated button while control is missing.
    var gatedLabel: String {
        switch state {
        case .requesting: return String(localized: "Awaiting Approval")
        case .requestsDisabled: return String(localized: "Needs Control")
        default: return String(localized: "Request Control")
        }
    }
}
