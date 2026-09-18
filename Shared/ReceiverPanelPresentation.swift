import Foundation

/// Pure presentation decisions for the MacReceiver control panel. The shared
/// `StreamReceiver` stays the only state machine and the sender the only
/// authority — these only decide what the panel shows and enables from the
/// receiver's already-published state, so they are unit-testable without AppKit.

/// Display Mode picker: shows the pending request while one is in flight,
/// otherwise the Mac-confirmed mode — never an optimistic guess.
struct DisplayModePickerState: Equatable {
    let selection: ReceiverDisplayMode
    let isEnabled: Bool
    let isSwitching: Bool
    /// Extend needs video on (same rule `StreamReceiver.requestDisplayMode` enforces).
    let extendDisabled: Bool

    /// `nil` while the Mac has not confirmed a mode yet (the panel then shows
    /// "Waiting for Mac" instead of a picker).
    init?(confirmed: ReceiverDisplayMode?, pending: ReceiverDisplayMode?,
          connected: Bool, macProtocolVersion: Int, videoEnabled: Bool) {
        guard let confirmed else { return nil }
        selection = pending ?? confirmed
        isSwitching = pending != nil
        isEnabled = connected
            && macProtocolVersion >= WireProtocol.displayModeWireVersion
            && pending == nil
        extendDisabled = !videoEnabled
    }
}

/// Connection controls. Disconnect ends only the live session (pairing/trust
/// stay, the listener stays up); Reconnect is offered only when automatic
/// recovery has given up — the same rule the iOS interruption overlay uses.
struct ReceiverConnectionControls: Equatable {
    let canDisconnect: Bool
    let canReconnect: Bool

    init(session: ReceiverSessionState, connected: Bool) {
        canDisconnect = connected
        canReconnect = session.interruption?.offersManualReconnect ?? false
    }
}

/// Mac-authoritative streaming-state text shared by the panel rows.
enum ReceiverStreamingPresentation {
    /// Codec the Mac is actually sending. The receiver cannot request a codec
    /// (Auto/H.264/HEVC is a sender setting), so this is display-only.
    static func codecLabel(_ codec: StreamCodec) -> String {
        switch codec {
        case .h264: return "H.264"
        case .hevc: return "HEVC"
        }
    }

    /// "Limited to N FPS" note when the Mac's encoder ceiling is below the
    /// profile's request; nil when nothing is limiting.
    static func fpsLimitation(state: MaxFPSStateUpdate?, profileLabel: String) -> String? {
        guard let state, state.encoderSafeFPS < state.requestedFPS else { return nil }
        return "\(profileLabel) requests \(state.requestedFPS) FPS. Limited to \(state.encoderSafeFPS) FPS at this display size."
    }
}
