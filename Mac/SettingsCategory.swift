import Foundation

/// The unified Settings sidebar taxonomy for Mac Sender. Same concept/name
/// used across Mac Receiver and iOS where it applies — see their own
/// category types for the (smaller) sets that make sense there.
enum SettingsCategory: String, CaseIterable, Identifiable {
    case overview, displays, streaming, input, devices, remoteAccess, system
    #if DEBUG
    case developer
    #endif

    var id: String { rawValue }

    var label: String {
        switch self {
        case .overview: return "Overview"
        case .displays: return "Displays"
        case .streaming: return "Streaming"
        case .input: return "Input"
        case .devices: return "Devices"
        case .remoteAccess: return "Remote Access"
        case .system: return "System"
        #if DEBUG
        case .developer: return "Developer"
        #endif
        }
    }

    var systemImage: String {
        switch self {
        case .overview: return "square.dashed"
        case .displays: return "display"
        case .streaming: return "antenna.radiowaves.left.and.right"
        case .input: return "hand.tap"
        case .devices: return "list.bullet.rectangle"
        case .remoteAccess: return "network"
        case .system: return "gearshape"
        #if DEBUG
        case .developer: return "wrench.and.screwdriver"
        #endif
        }
    }
}
