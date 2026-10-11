import Combine
import CoreGraphics
import Foundation

/// What the receiver controls need from a session: the state they react to
/// and the input they send. `StreamReceiver` is the real implementation;
/// `DemoSession` is the sample one, which never reaches a network.
@MainActor
protocol ReceiverControlSource: ObservableObject {
    var macProtocolVersion: Int { get }
    var controlSessionPhase: ReceiverSessionPhase { get }
    var displayState: DisplayState { get }
    var videoEnabled: Bool { get }
    var inputResetGeneration: Int { get }
    var controlResetGeneration: Int { get }
    func sendKeyboardPress(usage: Int, modifiers: [String])
    func sendKeyboardDown(usage: Int, modifiers: [String])
    func sendKeyboardUp(usage: Int, modifiers: [String])
    func sendModifier(_ modifier: ControlModifier, down: Bool)
    func sendGesture(name: String)
}

extension ReceiverControlSource {
    func sendKeyboardPress(usage: Int) { sendKeyboardPress(usage: usage, modifiers: []) }
}

/// Which screen the root shows. A real session always wins over the demo,
/// so a Mac connecting while the demo is open ends it.
enum ReceiverPresentationRoute: Equatable {
    case idle
    case demo
    case receiver

    static func resolve(demoActive: Bool, realSurfaceShown: Bool) -> ReceiverPresentationRoute {
        if realSurfaceShown { return .receiver }
        return demoActive ? .demo : .idle
    }
}

/// How a Settings category is presented in Demo Mode: the real page with
/// demo-local stores, or a demo page in place of one that needs a real Mac.
enum DemoSettingsPresentation: Equatable {
    case shared
    case demo

    static func presentation(for category: MobileSettingsCategory) -> DemoSettingsPresentation? {
        switch category {
        case .input, .gestures, .controls, .about: return .shared
        case .general, .display, .audio, .connections, .pairedMacs,
             .remoteAccess, .permissions, .diagnostics: return .demo
        case .developer: return nil
        }
    }
}

/// Demo Mode's whole session: a sample Mac, its sample stream and the local
/// state the reviewer can change. Everything lives in memory and dies with
/// the instance. It holds no `StreamReceiver`, opens no connection, and
/// never touches `TrustStore`, `RemoteEndpointStore`, the connection log or
/// `UserDefaults.standard`.
@MainActor
final class DemoSession: ObservableObject {
    static let macName = "Review Mac"
    /// Never a real paired peer ID (those are SPKI hashes).
    static let peerID = "demo.review-mac"
    /// RFC 2606 reserved domain, so it can never resolve to a real host.
    static let remoteHost = "review-mac.example.ts.net"
    static let remotePort = 7300
    /// Separate defaults domain for the demo's control preferences.
    static let controlDefaultsSuite = "com.raisecaterror.meowdisplay.demo"

    struct Event: Identifiable, Equatable {
        let id: Int
        let secondsIntoSession: Int
        let message: String
    }

    let videoSize: CGSize
    let codec: StreamCodec = .hevc
    let fps = 60
    let latencyMs = 18
    let throughputMbps = 42.0

    @Published var displayMode: ReceiverDisplayMode = .extend { didSet { if displayMode != oldValue { log("Demo display mode set to \(displayMode.title)") } } }
    @Published private(set) var videoEnabled = true
    @Published var audioEnabled = true { didSet { if audioEnabled != oldValue { log(audioEnabled ? "Demo audio on" : "Demo audio off") } } }
    @Published private(set) var inputState: SessionInputWireState = .allowed
    @Published var streamingProfile: StreamingProfile = .performance
    @Published var deviceName: String
    @Published var autoReconnect = true
    @Published var showPerformanceOverlay = false
    @Published var remoteAccessEnabled = true
    @Published var requestInputAutomatically = false
    @Published private(set) var events: [Event] = []
    /// The last control the reviewer used, shown as local feedback only.
    @Published private(set) var lastAction: String?
    @Published private(set) var actionGeneration = 0
    private var clock = 0

    init(videoSize: CGSize = CGSize(width: 2732, height: 2048), deviceName: String = "Sample iPad") {
        self.videoSize = videoSize
        self.deviceName = deviceName
        log("Demo session started (sample data, no network)")
        log("Sample peer \(Self.macName) shown as paired")
        log("Sample \(codec == .hevc ? "HEVC" : "H.264") stream selected")
        log("Sample video \(Int(videoSize.width))×\(Int(videoSize.height)) @ \(fps) fps")
        log("Demo audio enabled")
        log("Demo input allowed")
    }

    var inputAllowed: Bool { inputState == .allowed }

    /// Demo Allow Input. Local only: no Mac is asked and nothing is sent.
    func setInputAllowed(_ allowed: Bool) {
        let state: SessionInputWireState = allowed ? .allowed : .off
        guard state != inputState else { return }
        inputState = state
        log(allowed ? "Demo input allowed" : "Demo input turned off")
    }

    func setVideoEnabled(_ enabled: Bool) {
        guard enabled != videoEnabled else { return }
        videoEnabled = enabled
        log(enabled ? "Demo video on" : "Demo video off")
    }

    /// Records a control the reviewer used, in place of sending it.
    func noteAction(_ description: String) {
        lastAction = description
        actionGeneration &+= 1
    }

    /// Adds a line to the in-memory demo diagnostics.
    func log(_ message: String) {
        events.append(Event(id: events.count, secondsIntoSession: clock, message: message))
        clock += 1
    }
}

extension DemoSession: ReceiverControlSource {
    var macProtocolVersion: Int { WireProtocol.version }
    var controlSessionPhase: ReceiverSessionPhase { .connected }
    var displayState: DisplayState { .running }
    var inputResetGeneration: Int { 0 }
    var controlResetGeneration: Int { 0 }

    func sendKeyboardPress(usage: Int, modifiers: [String]) {
        noteAction(Self.describe(usage: usage, modifiers: modifiers))
    }

    func sendKeyboardDown(usage: Int, modifiers: [String]) {
        noteAction(Self.describe(usage: usage, modifiers: modifiers))
    }

    func sendKeyboardUp(usage: Int, modifiers: [String]) {}

    func sendModifier(_ modifier: ControlModifier, down: Bool) {
        if down { noteAction(modifier.rawValue.capitalized) }
    }

    func sendGesture(name: String) {
        noteAction(name)
    }

    func noteTyped(_ text: String) {
        noteAction(String(localized: "Typed “\(text)”"))
    }

    private static let symbols: [String: String] = [
        "control": "⌃", "option": "⌥", "shift": "⇧", "command": "⌘",
    ]

    private static let keyNames: [Int: String] = [
        40: "Return", 41: "Esc", 42: "Delete", 43: "Tab", 44: "Space",
        79: "→", 80: "←", 81: "↓", 82: "↑",
    ]

    /// A readable key name for the local feedback chip (⌘C, ⌥⌘D, Esc).
    static func describe(usage: Int, modifiers: [String]) -> String {
        let prefix = ["control", "option", "shift", "command"]
            .filter(modifiers.contains).compactMap { symbols[$0] }.joined()
        let key: String
        if let name = keyNames[usage] {
            key = name
        } else if (4...29).contains(usage), let scalar = UnicodeScalar(UInt32(usage - 4) + 65) {
            key = String(Character(scalar))
        } else if (30...38).contains(usage) {
            key = String(usage - 29)
        } else if usage == 39 {
            key = "0"
        } else {
            key = String(localized: "Key")
        }
        return prefix + key
    }
}
