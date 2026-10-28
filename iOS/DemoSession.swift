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

    /// The demo only starts from the home screen. While a real session's
    /// surface is up, entering would leave a hidden demo that appears once
    /// the session ends.
    static func canEnterDemo(realSurfaceShown: Bool) -> Bool { !realSurfaceShown }
}

/// How the home screen offers Demo Mode. Decided by whether any Mac is
/// paired right now (trusted pins), not by whether one ever connected:
/// forgetting the last paired Mac brings the prominent entry back.
enum ExploreDemoPresentation: Equatable {
    /// No paired Mac: a button inside the Macs card, so the demo is on
    /// screen without scrolling in every layout.
    case prominent
    /// At least one paired Mac: just the Try the Demo link in the footer,
    /// so it doesn't compete with the Macs.
    case compact

    static func resolve(pairedMacCount: Int) -> ExploreDemoPresentation {
        pairedMacCount > 0 ? .compact : .prominent
    }

    /// Whether the entry sits in the Macs card rather than the footer links.
    var leadsConnectionSetup: Bool { self == .prominent }
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
    /// Under the RFC 2606 reserved `.example` TLD, so it can never be a real
    /// host. Shown only; nothing resolves or dials it.
    static let remoteHost = "review-mac.example"
    static let remotePort = 7300
    /// Separate defaults domain for the demo's control preferences.
    static let controlDefaultsSuite = "com.raisecaterror.meowdisplay.demo"

    /// Where shared Settings pages keep their `@AppStorage` values: the
    /// real `.standard` domain, or the demo domain (wiped on entry and exit)
    /// so Demo Mode never reads or writes a real preference.
    static func preferenceDefaults(demoActive: Bool) -> UserDefaults {
        guard demoActive else { return .standard }
        return UserDefaults(suiteName: controlDefaultsSuite) ?? UserDefaults()
    }

    /// Drops everything Demo Mode saved.
    static func discardPreferences() {
        UserDefaults(suiteName: controlDefaultsSuite)?.removePersistentDomain(forName: controlDefaultsSuite)
    }

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
    /// Extend Shape, demo-local. Uses the real `ExtendDisplayShapePreference`.
    @Published var extendShape = ExtendDisplayShapePreference.standard {
        didSet { if extendShape != oldValue { log("Demo Extend shape set to \(extendShape.shape.title)") } }
    }
    @Published private(set) var events: [Event] = []
    /// The interactive sample desktop. Its own object, so touches and
    /// pointer movement never re-render Settings.
    let workspace = DemoWorkspace()
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

    // Every "send" lands on the sample desktop or becomes a preview of what
    // a real session would send. Nothing leaves the device.

    func sendKeyboardPress(usage: Int, modifiers: [String]) {
        guard inputAllowed else { return workspace.show(.inputOff) }
        workspace.key(usage: usage, modifiers: modifiers)
    }

    func sendKeyboardDown(usage: Int, modifiers: [String]) {
        sendKeyboardPress(usage: usage, modifiers: modifiers)
    }

    func sendKeyboardUp(usage: Int, modifiers: [String]) {}

    func sendModifier(_ modifier: ControlModifier, down: Bool) {
        if down, inputAllowed { workspace.show(.modifierHeld(modifier)) }
    }

    func sendGesture(name: String) {
        guard inputAllowed else { return workspace.show(.inputOff) }
        workspace.gesture(name: name)
    }

    func typeText(_ text: String) {
        guard inputAllowed else { return workspace.show(.inputOff) }
        workspace.type(text)
    }

    static let symbols: [String: String] = [
        "control": "⌃", "option": "⌥", "shift": "⇧", "command": "⌘",
    ]

    private static let keyNames: [Int: String] = [
        40: "Return", 41: "Esc", 42: "Delete", 43: "Tab", 44: "Space",
        45: "-", 46: "=", 47: "[", 48: "]",
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

/// The interactive sample desktop: the desktop, pointer and local view, plus
/// the latest feedback for the screen's chip. In memory only.
@MainActor
final class DemoWorkspace: ObservableObject {
    @Published var interaction = DemoInteraction(
        desktop: DemoDesktop(mode: .extend, size: DemoDesktop.size(forAspect: ExtendDisplayShape.defaultAutomaticAspect)))
    @Published private(set) var feedback: DemoFeedback?
    @Published private(set) var feedbackGeneration = 0

    func show(_ feedback: DemoFeedback) {
        self.feedback = feedback
        feedbackGeneration &+= 1
    }

    func key(usage: Int, modifiers: [String]) {
        show(interaction.desktop.key(usage: usage, modifiers: modifiers)
             ?? .macShortcut(usage: usage, modifiers: modifiers))
    }

    func gesture(name: String) {
        if name == ReceiverGesture.showDesktop.rawValue {
            show(interaction.desktop.toggleShowDesktop())
        } else {
            show(.macGesture(name))
        }
    }

    func type(_ text: String) {
        show(interaction.desktop.type(text) ? .local(String(localized: "Typed in Notes")) : .macTyping)
    }

    /// The keyboard opened: typing has somewhere visible to go.
    func focusNotesForTyping() {
        guard interaction.desktop.window(.notes) != nil else { return }
        interaction.desktop.raise(.notes)
    }
}
