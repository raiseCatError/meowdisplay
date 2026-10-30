import AppKit
import Security
import SwiftUI

/// Privacy Shield: while a device is connected, the Mac's own screens show a black cover instead of
/// what the device sees. The device's picture is unchanged: MeowDisplay leaves the cover out of its
/// captures. On by default for remote connections (Tailscale), off by default for local ones (Wi-Fi,
/// peer-to-peer, USB, hotspot); each setting stays as the owner leaves it.
///
/// What it can and can't do (macOS gives no stronger guarantee):
/// - It covers windows, the menu bar and the Dock at the highest window level apps may use. Some
///   system UI (the login window, some alerts) can appear above it.
/// - Clicks and keys pass through it, so remote control keeps working; someone at the Mac could
///   still type or click without seeing.
/// - Revealing needs an administrator's password (macOS asks; MeowDisplay never sees it) and a
///   click from this Mac's own mouse or trackpad: remote clicks are ignored.
@MainActor
final class PrivacyShield {
    static let shared = PrivacyShield()

    /// The cover's windows changed: captures of the Mac's screens must leave them out again.
    var onWindowsChanged: (() -> Void)?
    /// Connected sessions: true = remote.
    private var connected: [String: Bool] = [:]
    private var shields: [CGDirectDisplayID: NSWindow] = [:]
    private var revealPanel: NSPanel?
    private var revealed = false
    private var authorizing = false
    private nonisolated(unsafe) var lastPhysicalInput = ProcessInfo.processInfo.systemUptime
    private var tap: CFMachPort?
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []

    var isCovering: Bool { !shields.isEmpty }
    var relockAfter: TimeInterval {
        let m = UserDefaults.standard.integer(forKey: PrivacyShieldPolicy.relockMinutesKey)
        return TimeInterval(PrivacyShieldPolicy.relockChoices.contains(m) ? m : PrivacyShieldPolicy.defaultRelockMinutes) * 60
    }

    private init() {
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                                object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuild() }
        })
    }

    /// A device finished connecting (its welcome was sent).
    func connected(_ sessionID: String, remote: Bool) {
        connected[sessionID] = remote
        update()
        PrivacyShieldNotice.show(on: PrivacyShieldPolicy.isOn(remote: remote))
    }

    /// The sessions that still exist (others ended).
    func retain(sessionIDs: Set<String>) {
        guard !Set(connected.keys).isSubset(of: sessionIDs) else { return }
        connected = connected.filter { sessionIDs.contains($0.key) }
        if connected.isEmpty { revealed = false }
        update()
    }

    /// Settings changed (turned on or off, relock time).
    func settingsChanged() { update() }

    private var wantsCover: Bool {
        PrivacyShieldPolicy.shouldCover(remoteOn: PrivacyShieldPolicy.isOn(remote: true), localOn: PrivacyShieldPolicy.isOn(remote: false),
                                        sessions: Array(connected.values), revealed: revealed,
                                        physicalIdle: ProcessInfo.processInfo.systemUptime - lastPhysicalInput, relockAfter: relockAfter)
    }

    func update() {
        let idle = ProcessInfo.processInfo.systemUptime - lastPhysicalInput
        if revealed, idle >= relockAfter { revealed = false }
        let cover = wantsCover
        if cover, !authorizing { show() } else if !cover { hide() }
        let needsWatch = PrivacyShieldPolicy.shouldCover(remoteOn: PrivacyShieldPolicy.isOn(remote: true), localOn: PrivacyShieldPolicy.isOn(remote: false),
                                                         sessions: Array(connected.values), revealed: false, physicalIdle: 0, relockAfter: 1)
        if needsWatch { startWatching() } else { stopWatching() }
    }

    // MARK: Cover

    private func show() {
        if shields.isEmpty { Log.info("privacy shield: covering this Mac's screens") }
        rebuild()
    }

    private func hide() {
        guard !shields.isEmpty || revealPanel != nil else { return }
        shields.values.forEach { $0.orderOut(nil) }
        shields = [:]
        revealPanel?.orderOut(nil)
        revealPanel = nil
        publishIDs()
        Log.info("privacy shield: screens shown")
    }

    /// One cover per physical display, rebuilt when displays come and go.
    private func rebuild() {
        guard wantsCover, !authorizing else { return }
        let screens = Dictionary(NSScreen.screens.compactMap { s in s.displayID.map { ($0, s) } }, uniquingKeysWith: { a, _ in a })
        let wanted = Set(PrivacyShieldPolicy.coveredDisplays(Array(screens.keys), virtual: VirtualDisplayRegistry.shared.displayIDs))
        for (id, w) in shields where !wanted.contains(id) { w.orderOut(nil); shields[id] = nil }
        for id in wanted {
            guard let screen = screens[id] else { continue }
            let w = shields[id] ?? Self.makeShield()
            w.setFrame(screen.frame, display: true)
            w.orderFrontRegardless()
            shields[id] = w
        }
        let main = NSScreen.main.flatMap { $0.displayID }.flatMap { shields[$0] != nil ? $0 : nil } ?? shields.keys.first
        if let main, let screen = screens[main] { placeRevealPanel(on: screen) }
        publishIDs()
    }

    private static func makeShield() -> NSWindow {
        let w = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        w.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        w.backgroundColor = .black
        // Not opaque to the window server: windows below aren't treated as hidden, so apps keep
        // drawing and the device's picture stays live. It still draws fully black.
        w.isOpaque = false
        w.hasShadow = false
        w.ignoresMouseEvents = true   // remote clicks reach the windows below
        w.isReleasedWhenClosed = false
        w.sharingType = .none
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        w.contentView = NSHostingView(rootView: PrivacyShieldCover())
        return w
    }

    private func placeRevealPanel(on screen: NSScreen) {
        let panel = revealPanel ?? {
            let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 220, height: 44), styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
            p.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()) + 1)
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = false
            p.becomesKeyOnlyIfNeeded = true   // never key: remote keys can't press it
            p.sharingType = .none
            p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
            p.contentView = NSHostingView(rootView: RevealButton { [weak self] in self?.revealTapped() })
            return p
        }()
        panel.setFrameOrigin(NSPoint(x: screen.frame.midX - 110, y: screen.frame.midY - 120))
        panel.orderFrontRegardless()
        revealPanel = panel
    }

    private func publishIDs() {
        let new = (Array(shields.values) + [revealPanel].compactMap { $0 }).map { CGWindowID($0.windowNumber) }.filter { $0 > 0 }
        if PrivacyShieldWindows.replace(with: new) { onWindowsChanged?() }
    }

    // MARK: Reveal (local only, administrator)

    private func revealTapped() {
        // Only this Mac's own mouse or trackpad: a click MeowDisplay injected for a device carries its pid.
        guard let event = NSApp.currentEvent?.cgEvent,
              PrivacyShieldPolicy.isPhysical(sourcePID: event.getIntegerValueField(.eventSourceUnixProcessID)) else {
            Log.info("privacy shield: ignored a reveal click that didn't come from this Mac's own input")
            return
        }
        authorizing = true
        // macOS's own administrator prompt must be visible to the person at the Mac.
        shields.values.forEach { $0.level = .normal; $0.orderBack(nil) }
        revealPanel?.orderOut(nil)
        Task.detached(priority: .userInitiated) {
            let ok = Self.authenticateAdministrator()
            await MainActor.run {
                self.authorizing = false
                if ok {
                    self.revealed = true
                    self.lastPhysicalInput = ProcessInfo.processInfo.systemUptime
                    Log.info("privacy shield: revealed by an administrator at the Mac")
                    self.hide()
                } else {
                    self.shields.values.forEach { $0.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel())) }
                    self.rebuild()
                }
                self.update()
            }
        }
    }

    /// macOS asks for an administrator's name and password; MeowDisplay only learns yes or no.
    nonisolated static func authenticateAdministrator() -> Bool {
        var ref: AuthorizationRef?
        guard AuthorizationCreate(nil, nil, [], &ref) == errAuthorizationSuccess, let ref else { return false }
        defer { AuthorizationFree(ref, [.destroyRights]) }
        return kAuthorizationRuleAuthenticateAsAdmin.withCString { name -> Bool in
            var item = AuthorizationItem(name: name, valueLength: 0, value: nil, flags: 0)
            return withUnsafeMutablePointer(to: &item) { p -> Bool in
                var rights = AuthorizationRights(count: 1, items: p)
                return AuthorizationCopyRights(ref, &rights, nil, [.interactionAllowed, .extendRights, .destroyRights], nil) == errAuthorizationSuccess
            }
        }
    }

    // MARK: Physical input (timestamps only, never contents)

    private func startWatching() {
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.update() } }
        }
        guard tap == nil else { return }
        let mask: CGEventMask = [CGEventType.keyDown, .leftMouseDown, .rightMouseDown, .mouseMoved, .scrollWheel, .otherMouseDown]
            .reduce(0) { $0 | (1 << CGEventMask($1.rawValue)) }
        let me = Unmanaged.passUnretained(self).toOpaque()
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .listenOnly, eventsOfInterest: mask,
                                callback: { _, _, event, info in
            if let info, PrivacyShieldPolicy.isPhysical(sourcePID: event.getIntegerValueField(.eventSourceUnixProcessID)) {
                Unmanaged<PrivacyShield>.fromOpaque(info).takeUnretainedValue().lastPhysicalInput = ProcessInfo.processInfo.systemUptime
            }
            return Unmanaged.passUnretained(event)
        }, userInfo: me)
        if let tap {
            CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
        } else {
            // Without the tap a reveal still ends: it times out as if the Mac were idle.
            Log.info("privacy shield: can't watch for physical input; a reveal ends after the relock time")
        }
    }

    private func stopWatching() {
        timer?.invalidate(); timer = nil
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        tap = nil
    }
}

private extension NSScreen {
    var displayID: CGDirectDisplayID? { (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value }
}

private struct PrivacyShieldCover: View {
    var body: some View {
        ZStack {
            Color.black
            VStack(spacing: 10) {
                Image(systemName: "eye.slash").font(.system(size: 34, weight: .regular)).foregroundStyle(.white.opacity(0.55))
                Text("This Mac is in use from another device").font(.title3.weight(.semibold)).foregroundStyle(.white.opacity(0.75))
                Text("Privacy Shield").font(.callout).foregroundStyle(.white.opacity(0.45))
            }
        }
        .ignoresSafeArea()
    }
}

private struct RevealButton: View {
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Text("Reveal This Mac…").font(.callout.weight(.medium)).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .padding(4)
    }
}

/// A small notice on the Mac when a device connects: whether the Privacy Shield is on.
@MainActor
enum PrivacyShieldNotice {
    private static var panel: NSPanel?
    private static var hideWork: DispatchWorkItem?

    static func show(on: Bool) {
        let p = panel ?? {
            let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 40), styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
            p.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()) + 2)
            p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = true; p.ignoresMouseEvents = true
            p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
            return p
        }()
        p.contentView = NSHostingView(rootView: Label(on ? "Privacy Shield is on" : "Privacy Shield is off",
                                                      systemImage: on ? "eye.slash.fill" : "eye")
            .font(.callout.weight(.semibold)).padding(.horizontal, 14).padding(.vertical, 9)
            .background(.regularMaterial, in: Capsule()))
        if let screen = NSScreen.main {
            p.setFrameOrigin(NSPoint(x: screen.frame.midX - 150, y: screen.visibleFrame.maxY - 56))
        }
        p.orderFrontRegardless()
        panel = p
        hideWork?.cancel()
        let work = DispatchWorkItem { MainActor.assumeIsolated { panel?.orderOut(nil) } }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }
}

/// Settings ▸ System ▸ Privacy Shield: remote connections on by default, local ones off.
struct PrivacyShieldSettingsSection: View {
    @AppStorage(PrivacyShieldPolicy.remoteKey) private var remoteOn = true
    @AppStorage(PrivacyShieldPolicy.localKey) private var localOn = false
    @AppStorage(PrivacyShieldPolicy.relockMinutesKey) private var relockMinutes = PrivacyShieldPolicy.defaultRelockMinutes
    @State private var confirmingOff: Bool?   // true = remote, false = local
    @State private var authFailed = false

    var body: some View {
        Section {
            Toggle("Remote Connections", isOn: binding(remote: true))
            Toggle("Local Connections", isOn: binding(remote: false))
            Picker("Cover Again After", selection: $relockMinutes) {
                ForEach(PrivacyShieldPolicy.relockChoices, id: \.self) { Text("\($0) min without use at this Mac").tag($0) }
            }
            .disabled(!remoteOn && !localOn)
            .onChange(of: relockMinutes) { PrivacyShield.shared.settingsChanged() }
            if authFailed { Text("Not turned off: administrator authentication didn't succeed.").font(.caption).foregroundStyle(.secondary) }
        } header: {
            Text("Privacy Shield")
        } footer: {
            Text("While a device is connected, this Mac's own screens are covered in black; the device still sees and controls everything. Remote means Tailscale and other routed addresses; local means Wi-Fi, peer-to-peer, USB and hotspot. Someone at the Mac can reveal it with an administrator's password; it covers again after the time above without use at the Mac. It doesn't stop typing or clicking at the Mac, and some system alerts can appear above it.")
        }
        .confirmationDialog(confirmingOff == true ? "Turn off the Privacy Shield for remote connections?" : "Turn off the Privacy Shield for local connections?",
                            isPresented: Binding(get: { confirmingOff != nil }, set: { if !$0 { confirmingOff = nil } })) {
            Button("Turn Off", role: .destructive) { if let r = confirmingOff { turnOff(remote: r) }; confirmingOff = nil }
            Button("Cancel", role: .cancel) { confirmingOff = nil }
        } message: {
            Text(PrivacyShield.shared.isCovering
                 ? "If that turns the cover off now, macOS asks for an administrator's password."
                 : "This Mac's screens will show what those devices do.")
        }
    }

    private func binding(remote: Bool) -> Binding<Bool> {
        Binding(get: { remote ? remoteOn : localOn }, set: { on in
            if on {
                if remote { remoteOn = true } else { localOn = true }
                PrivacyShield.shared.settingsChanged()
            } else { confirmingOff = remote }
        })
    }

    private func turnOff(remote: Bool) {
        guard PrivacyShield.shared.isCovering else { apply(off: remote); return }
        Task { @MainActor in
            let ok = await Task.detached { PrivacyShield.authenticateAdministrator() }.value
            authFailed = !ok
            if ok { apply(off: remote) }
        }
    }

    private func apply(off remote: Bool) {
        if remote { remoteOn = false } else { localOn = false }
        PrivacyShield.shared.settingsChanged()
    }
}
