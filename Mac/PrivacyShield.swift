import AppKit
import Security
import SwiftUI

/// Privacy Shield: while a device is connected, the Mac's own screens show a black cover instead of
/// what the device sees. On by default for remote connections (Tailscale), off by default for local
/// ones (Wi-Fi, peer-to-peer, USB, hotspot); each setting stays as the owner leaves it.
///
/// Devices never see it: every one of its windows exists, and is left out of MeowDisplay's
/// captures, before it appears on screen (the cover waits for the captures to be updated).
///
/// It never blinks: its windows are made once and kept (hidden, still left out of captures), so
/// mode and layout changes, capture restarts and reconnects don't take it down and put it back.
/// Once it covers, it stays until someone at the Mac unlocks it: a device disconnecting (or
/// switching modes, which reconnects) doesn't uncover the Mac. Quitting MeowDisplay while it
/// covers locks the Mac's screen first.
///
/// What it can and can't do (macOS gives no stronger guarantee):
/// - It covers windows, the menu bar and the Dock at the highest window level apps may use. Some
///   system UI (the login window, some alerts) can appear above it.
/// - Clicks and keys pass through it, so remote control keeps working; someone at the Mac could
///   still type or click without seeing.
/// - Removing it needs a click from this Mac's own mouse or trackpad and this Mac's login password,
///   asked by macOS (MeowDisplay never sees it). While macOS asks, no remote input reaches the Mac,
///   so the password can only come from its own keyboard, and devices don't see the prompt.
@MainActor
final class PrivacyShield {
    static let shared = PrivacyShield()

    /// The cover's windows changed: update the captures, then call the completion (on any queue).
    var onWindowsChanged: ((@escaping () -> Void) -> Void)?

    /// Connected sessions: true = remote.
    private var connected: [String: Bool] = [:]
    /// The cover on each display, taken from `pool`.
    private var shields: [CGDirectDisplayID: NSWindow] = [:]
    /// Every cover window ever made. Never closed: their ids stay left out of the captures, so
    /// showing one again needs no wait.
    private var pool: [NSWindow] = []
    /// A covered device disconnected and no one at the Mac has unlocked since: keep covering.
    private var held = false
    private let revealPanel: NSPanel
    private let noticePanel: NSPanel
    private var noticeHide: DispatchWorkItem?
    private var revealed = false
    private var unlocking = false
    private var showing = false
    private nonisolated(unsafe) var lastPhysicalInput = ProcessInfo.processInfo.systemUptime
    private var tap: CFMachPort?
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private static var topLevel: NSWindow.Level { NSWindow.Level(rawValue: Int(CGShieldingWindowLevel())) }

    var isCovering: Bool { showing }
    /// Covering although no protected device is connected (waiting for an unlock at the Mac).
    var isHeld: Bool { held }
    var relockAfter: TimeInterval {
        let m = UserDefaults.standard.integer(forKey: PrivacyShieldPolicy.relockMinutesKey)
        return TimeInterval(PrivacyShieldPolicy.relockChoices.contains(m) ? m : PrivacyShieldPolicy.defaultRelockMinutes) * 60
    }

    private init() {
        // Made (not shown) now, so their ids are left out of every capture before they ever appear.
        revealPanel = Self.panel(size: NSSize(width: 240, height: 44), level: Self.topLevel + 1, clicks: true)
        noticePanel = Self.panel(size: NSSize(width: 320, height: 40), level: Self.topLevel + 2, clicks: false)
        revealPanel.contentView = NSHostingView(rootView: RevealButton { [weak self] in self?.revealTapped() })
        // Covers for every display now plus spares for displays plugged in later.
        pool = (0..<max(NSScreen.screens.count + 2, 3)).map { _ in Self.makeShield() }
        publishIDs()
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                                object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuild() }
        })
    }

    private static func panel(size: NSSize, level: NSWindow.Level, clicks: Bool) -> NSPanel {
        let p = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.level = level
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = !clicks
        p.ignoresMouseEvents = !clicks
        p.becomesKeyOnlyIfNeeded = true   // never key: remote keys can't press it
        p.sharingType = .none
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        return p
    }

    /// A device finished connecting (its welcome was sent).
    func connected(_ sessionID: String, remote: Bool) {
        connected[sessionID] = remote
        // A reveal covers the sessions that existed then: a new device brings the cover back, so
        // what it's told ("on") is true.
        if revealed { revealed = false; Log.info("privacy shield: a new device connected; covering again") }
        update()
        showNotice(on: PrivacyShieldPolicy.isOn(remote: remote))
    }

    /// The sessions that still exist (others ended).
    func retain(sessionIDs: Set<String>) {
        guard !Set(connected.keys).isSubset(of: sessionIDs) else { return }
        let ended = connected.filter { !sessionIDs.contains($0.key) }
        connected = connected.filter { sessionIDs.contains($0.key) }
        if PrivacyShieldPolicy.holdsAfterDisconnect(showing: showing, endedProtected: ended.values.contains { PrivacyShieldPolicy.isOn(remote: $0) }),
           !held {
            held = true
            Log.info("privacy shield: a covered device disconnected; staying covered until unlocked at this Mac")
        }
        if connected.isEmpty { revealed = false }
        update()
    }

    /// Someone at the Mac confirmed its login password elsewhere (turning the setting off).
    func unlockedLocally() {
        held = false
        update()
    }

    /// Settings changed (turned on or off, relock time).
    func settingsChanged() { update() }

    private var wantsCover: Bool {
        PrivacyShieldPolicy.shouldCover(remoteOn: PrivacyShieldPolicy.isOn(remote: true), localOn: PrivacyShieldPolicy.isOn(remote: false),
                                        sessions: Array(connected.values), revealed: revealed,
                                        physicalIdle: ProcessInfo.processInfo.systemUptime - lastPhysicalInput, relockAfter: relockAfter,
                                        held: held)
    }

    func update() {
        if revealed, ProcessInfo.processInfo.systemUptime - lastPhysicalInput >= relockAfter { revealed = false }
        if wantsCover { if !unlocking { rebuild() } } else { hide() }
        let anyOn = PrivacyShieldPolicy.shouldCover(remoteOn: PrivacyShieldPolicy.isOn(remote: true), localOn: PrivacyShieldPolicy.isOn(remote: false),
                                                    sessions: Array(connected.values), revealed: false, physicalIdle: 0, relockAfter: 1,
                                                    held: held)
        if anyOn { startWatching() } else { stopWatching() }
    }

    // MARK: Cover

    private func hide() {
        guard showing || !shields.isEmpty else { return }
        showing = false
        // Hidden, not closed: the windows (and their left-out ids) are reused next time.
        shields.values.forEach { $0.orderOut(nil) }
        shields = [:]
        revealPanel.orderOut(nil)
        Log.info("privacy shield: screens shown")
    }

    /// One cover per physical display, rebuilt when displays come and go. New cover windows are
    /// left out of the captures first, then shown.
    private func rebuild() {
        guard wantsCover, !unlocking else { return }
        if !showing { Log.info("privacy shield: covering this Mac's screens") }
        showing = true
        let screens = Dictionary(NSScreen.screens.compactMap { s in s.displayID.map { ($0, s) } }, uniquingKeysWith: { a, _ in a })
        let wanted = Set(PrivacyShieldPolicy.coveredDisplays(Array(screens.keys), virtual: VirtualDisplayRegistry.shared.displayIDs))
        for (id, w) in shields where !wanted.contains(id) { w.orderOut(nil); shields[id] = nil }
        var fresh = false
        for id in wanted.sorted() where shields[id] == nil {
            if let spare = pool.first(where: { w in !shields.values.contains { $0 === w } }) {
                shields[id] = spare
            } else {
                // More displays than spares: a new window, shown once the captures leave it out.
                let w = Self.makeShield(); pool.append(w); shields[id] = w; fresh = true
            }
        }
        let present = { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.showing else { return }
                for (id, w) in self.shields { if let s = screens[id] { w.setFrame(s.frame, display: true); w.orderFrontRegardless() } }
                let main = NSScreen.main.flatMap { $0.displayID }.flatMap { self.shields[$0] != nil ? $0 : nil } ?? self.shields.keys.first
                if let main, let s = screens[main] {
                    self.revealPanel.setFrameOrigin(NSPoint(x: s.frame.midX - 120, y: s.frame.midY - 120))
                    self.revealPanel.orderFrontRegardless()
                }
            }
        }
        guard fresh, publishIDs(), let update = onWindowsChanged else { present(); return }
        // Shown once every capture leaves the new windows out. If a capture doesn't answer in 3 s,
        // the screens are covered anyway (people at the Mac come first) and it's logged.
        var done = false
        let finish: () -> Void = { DispatchQueue.main.async { MainActor.assumeIsolated { if !done { done = true; present() } } } }
        update(finish)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            MainActor.assumeIsolated { if !done { Log.info("privacy shield: a capture didn't confirm in 3 s; covering anyway") } }
            finish()
        }
    }

    private static func makeShield() -> NSWindow {
        let w = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        w.level = topLevel
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

    /// True when the ids changed.
    @discardableResult
    private func publishIDs() -> Bool {
        let windows: [NSWindow] = pool + [revealPanel, noticePanel]
        return PrivacyShieldWindows.replace(with: windows.map { CGWindowID($0.windowNumber) }.filter { $0 > 0 })
    }

    /// A small notice on the Mac when a device connects: whether the cover is on. Devices don't see it.
    private func showNotice(on: Bool) {
        noticePanel.contentView = NSHostingView(rootView: Label(on ? "Privacy Shield is on" : "Privacy Shield is off",
                                                                systemImage: on ? "eye.slash.fill" : "eye")
            .font(.callout.weight(.semibold)).padding(.horizontal, 14).padding(.vertical, 9)
            .background(.regularMaterial, in: Capsule()))
        if let screen = NSScreen.main { noticePanel.setFrameOrigin(NSPoint(x: screen.frame.midX - 160, y: screen.visibleFrame.maxY - 56)) }
        noticePanel.orderFrontRegardless()
        noticeHide?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.noticePanel.orderOut(nil) } }
        noticeHide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }

    // MARK: Remove the cover (this Mac's own input and login password)

    private func revealTapped() {
        // Only this Mac's own mouse or trackpad: a click MeowDisplay injected for a device carries its pid.
        guard let event = NSApp.currentEvent?.cgEvent,
              PrivacyShieldPolicy.isPhysical(sourcePID: event.getIntegerValueField(.eventSourceUnixProcessID)) else {
            Log.info("privacy shield: ignored a reveal click that didn't come from this Mac's own input")
            return
        }
        unlocking = true
        revealPanel.orderOut(nil)
        // macOS's prompt must be visible to the person at the Mac, but nothing else: the cover stays
        // above every app window while it's open and goes back to the top after 60 s whatever happens.
        shields.values.forEach { $0.level = .screenSaver }
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.unlocking else { return }
                self.shields.values.forEach { $0.level = Self.topLevel }
            }
        }
        Task {
            let ok = await Self.askForLoginPassword(refresh: { [weak self] in self?.onWindowsChanged?({}) })
            unlocking = false
            if ok {
                revealed = true
                held = false
                lastPhysicalInput = ProcessInfo.processInfo.systemUptime
                Log.info("privacy shield: removed with this Mac's login password")
                hide()
            } else {
                shields.values.forEach { $0.level = Self.topLevel }
            }
            update()
        }
    }

    /// macOS asks for this Mac's login password (MeowDisplay only learns yes or no). Meanwhile no
    /// remote input reaches the Mac and devices don't see the prompt (`refresh` updates captures).
    static func askForLoginPassword(refresh: @escaping @MainActor () -> Void) async -> Bool {
        PrivacyShieldWindows.isUnlocking = true
        refresh()
        // The prompt appears a moment later: leave it out of the captures as soon as it's listed.
        for delay in [0.4, 1.2, 2.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { MainActor.assumeIsolated { if PrivacyShieldWindows.isUnlocking { refresh() } } }
        }
        let ok = await Task.detached(priority: .userInitiated) { authenticateSessionUser() }.value
        PrivacyShieldWindows.isUnlocking = false
        refresh()
        return ok
    }

    nonisolated private static func authenticateSessionUser() -> Bool {
        var ref: AuthorizationRef?
        guard AuthorizationCreate(nil, nil, [], &ref) == errAuthorizationSuccess, let ref else { return false }
        defer { AuthorizationFree(ref, [.destroyRights]) }
        return kAuthorizationRuleAuthenticateAsSessionUser.withCString { name -> Bool in
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
                Text("Privacy Shield · Click Unlock, then type this Mac's login password").font(.callout).foregroundStyle(.white.opacity(0.45))
            }
        }
        .ignoresSafeArea()
    }
}

private struct RevealButton: View {
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Text("Unlock This Mac…").font(.callout.weight(.medium)).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .padding(4)
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
            if authFailed { Text("Not turned off: the login password wasn't confirmed.").font(.caption).foregroundStyle(.secondary) }
        } header: {
            Text("Privacy Shield")
        } footer: {
            Text("While a device is connected, this Mac's own screens are covered in black; the device still sees and controls everything. Remote means Tailscale and other routed addresses; local means Wi-Fi, peer-to-peer, USB and hotspot. Someone at the Mac can remove it with this Mac's login password, typed on its own keyboard; it covers again after the time above without use at the Mac. It doesn't stop typing or clicking at the Mac, and some system alerts can appear above it.")
        }
        .confirmationDialog(confirmingOff == true ? "Turn off the Privacy Shield for remote connections?" : "Turn off the Privacy Shield for local connections?",
                            isPresented: Binding(get: { confirmingOff != nil }, set: { if !$0 { confirmingOff = nil } })) {
            Button("Turn Off", role: .destructive) { if let r = confirmingOff { turnOff(remote: r) }; confirmingOff = nil }
            Button("Cancel", role: .cancel) { confirmingOff = nil }
        } message: {
            Text(PrivacyShield.shared.isCovering
                 ? "If that turns the cover off now, macOS asks for this Mac's login password, typed on its own keyboard."
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
            let ok = await PrivacyShield.askForLoginPassword(refresh: { PrivacyShield.shared.onWindowsChanged?({}) })
            authFailed = !ok
            if ok { apply(off: remote); PrivacyShield.shared.unlockedLocally() }
        }
    }

    private func apply(off remote: Bool) {
        if remote { remoteOn = false } else { localOn = false }
        PrivacyShield.shared.settingsChanged()
    }
}
