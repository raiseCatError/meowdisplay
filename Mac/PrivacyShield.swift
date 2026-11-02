import AppKit
import LocalAuthentication
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
///
/// OLED care: the cover is black (an OLED panel's pixels are off). Its message and Unlock button
/// move every minute, dim after a minute with no one at the Mac and go dark after five; any touch
/// of the Mac's own input brings them back (PrivacyShieldPolicy.coverLook / coverCenter).
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
    /// Where the message sits (`coverStep`) and how bright it is, on every cover.
    private var coverStep = 0
    private var coverLook: PrivacyShieldPolicy.CoverLook = .bright
    /// When the cover last appeared (the message moves on from there).
    private var coverSince = ProcessInfo.processInfo.systemUptime
    /// Where the Unlock button is going (it may still be gliding there).
    private var revealTarget: NSRect?
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
        let reveal = NSHostingView(rootView: RevealButton { [weak self] in self?.revealTapped() })
        reveal.sizingOptions = []   // the panel's size is fixed; SwiftUI never resizes it
        revealPanel.contentView = reveal
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

    /// The settings as they stand while the cover is up (PrivacyShieldPolicy.latched); nil while
    /// it isn't, when the stored settings are read as they are.
    private var latch: (remote: Bool, local: Bool)?
    private var remoteOn: Bool { latch?.remote ?? PrivacyShieldPolicy.isOn(remote: true) }
    private var localOn: Bool { latch?.local ?? PrivacyShieldPolicy.isOn(remote: false) }

    /// Settings changed (turned on or off, relock time). `ownerConfirmed`: MeowDisplay's own
    /// Settings confirmed it with Touch ID or the password at this Mac (needed to turn one off
    /// while the cover is up).
    func settingsChanged(ownerConfirmed: Bool = false) {
        if let current = latch {
            latch = PrivacyShieldPolicy.latched(current, stored: (PrivacyShieldPolicy.isOn(remote: true), PrivacyShieldPolicy.isOn(remote: false)),
                                                ownerConfirmed: ownerConfirmed)
        }
        update()
    }

    private var wantsCover: Bool {
        PrivacyShieldPolicy.shouldCover(remoteOn: remoteOn, localOn: localOn,
                                        sessions: Array(connected.values), revealed: revealed,
                                        physicalIdle: ProcessInfo.processInfo.systemUptime - lastPhysicalInput, relockAfter: relockAfter,
                                        held: held)
    }

    func update() {
        if revealed, ProcessInfo.processInfo.systemUptime - lastPhysicalInput >= relockAfter { revealed = false }
        if wantsCover { if !unlocking { rebuild() } } else { hide() }
        let anyOn = PrivacyShieldPolicy.shouldCover(remoteOn: remoteOn, localOn: localOn,
                                                    sessions: Array(connected.values), revealed: false, physicalIdle: 0, relockAfter: 1,
                                                    held: held)
        if anyOn { startWatching() } else { stopWatching() }
    }

    // MARK: Cover

    private func hide() {
        guard showing || !shields.isEmpty else { return }
        showing = false
        latch = nil
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
        if !showing {
            Log.info("privacy shield: covering this Mac's screens")
            latch = (PrivacyShieldPolicy.isOn(remote: true), PrivacyShieldPolicy.isOn(remote: false))
            coverSince = ProcessInfo.processInfo.systemUptime
            coverStep = 0
            coverLook = .bright
        }
        showing = true
        refreshAppearance()
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
                for (id, w) in self.shields {
                    guard let s = screens[id] else { continue }
                    w.setFrame(s.frame, display: true)
                    (w.contentView as? PrivacyShieldCoverView)?.show(step: self.coverStep, look: self.coverLook, animate: false)
                    w.orderFrontRegardless()
                }
                self.placeRevealButton(animate: false)
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

    /// The Unlock button under the message on the main covered display; gone while the cover is dark.
    private func placeRevealButton(animate: Bool) {
        guard showing, !unlocking else { return }
        guard coverLook != .dark else { revealPanel.orderOut(nil); return }
        let screens = NSScreen.screens.filter { s in s.displayID.map { shields[$0] != nil } ?? false }
        guard let s = screens.first(where: { $0 == NSScreen.main }) ?? screens.first else { return }
        let c = PrivacyShieldPolicy.coverCenter(step: coverStep, screen: s.frame.size)
        let size = revealPanel.frame.size
        let frame = NSRect(x: s.frame.minX + c.x - size.width / 2,
                           y: s.frame.maxY - c.y - PrivacyShieldPolicy.coverButtonDrop - size.height / 2,
                           width: size.width, height: size.height)
        revealPanel.alphaValue = coverLook == .dim ? 0.4 : 1
        if frame != revealTarget || !revealPanel.isVisible {
            if animate && revealPanel.isVisible {
                // Glides with the message (not blocking the main thread).
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 1.5
                    revealPanel.animator().setFrame(frame, display: true)
                }
            } else {
                revealPanel.setFrame(frame, display: true)
            }
            revealTarget = frame
        }
        revealPanel.orderFrontRegardless()
    }

    /// Moves the message every minute and dims it with no one at the Mac (OLED care).
    private func refreshAppearance() {
        guard showing else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let step = max(0, Int((now - coverSince) / PrivacyShieldPolicy.coverMoveEvery))
        let look = PrivacyShieldPolicy.coverLook(idle: now - max(coverSince, lastPhysicalInput))
        guard step != coverStep || look != coverLook else { return }
        if look != coverLook { Log.info("privacy shield: message \(look)") }
        if step != coverStep { Log.info("privacy shield: message moved (spot \(step))") }
        coverStep = step
        coverLook = look
        for w in shields.values { (w.contentView as? PrivacyShieldCoverView)?.show(step: step, look: look, animate: true) }
        placeRevealButton(animate: true)
    }

    /// Someone touched this Mac's own input: a dimmed or dark message comes back at once.
    fileprivate func physicalInputArrived() {
        guard showing, coverLook != .bright else { return }
        refreshAppearance()
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
        // Plain AppKit, not a SwiftUI root: a hosting view as the content of a full-screen window
        // over the camera notch looped on safe-area and window-size updates until AppKit threw
        // (crash 2026-10-30 18:38, ad9be49). The message is a fixed-size subview AppKit places.
        w.contentView = PrivacyShieldCoverView()
        return w
    }

    /// True when the ids changed.
    @discardableResult
    private func publishIDs() -> Bool {
        let windows: [NSWindow] = pool + [revealPanel, noticePanel]
        let changed = PrivacyShieldWindows.replace(with: windows.map { CGWindowID($0.windowNumber) }.filter { $0 > 0 })
        if changed { ShareableContent.invalidate() }   // captures must list the new windows to leave them out
        return changed
    }

    /// A small notice on the Mac when a device connects: whether the cover is on. Devices don't see it.
    private func showNotice(on: Bool) {
        // Fixed size, centred label: letting SwiftUI size this panel made its height flip between
        // 33 and 34 pt and loop until AppKit threw (crash 2026-10-30 18:38:42, "more Update
        // Constraints in Window passes than there are views", <NSPanel> 155x33).
        let host = NSHostingView(rootView: Label(on ? "Privacy Shield is on" : "Privacy Shield is off",
                                                 systemImage: on ? "eye.slash.fill" : "eye")
            .font(.callout.weight(.semibold)).padding(.horizontal, 14).padding(.vertical, 9)
            .background(.regularMaterial, in: Capsule())
            .frame(maxWidth: .infinity, maxHeight: .infinity))
        host.sizingOptions = []
        noticePanel.contentView = host
        noticePanel.setContentSize(NSSize(width: 320, height: 40))
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
                Log.info("privacy shield: removed at this Mac (owner confirmed)")
                hide()
            } else {
                shields.values.forEach { $0.level = Self.topLevel }
            }
            update()
        }
    }

    /// Installed by SenderController: every session lets go of its device's held input.
    static var releaseRemoteInput: (@MainActor () -> Void)?

    /// macOS asks for this Mac's login password (MeowDisplay only learns yes or no). Meanwhile no
    /// remote input reaches the Mac and devices don't see the prompt (`refresh` updates captures).
    static func askForLoginPassword(refresh: @escaping @MainActor () -> Void) async -> Bool {
        // Let go of anything a device holds first (its releases still pass while unlocking).
        releaseRemoteInput?()
        PrivacyShieldWindows.isUnlocking = true
        refresh()
        // The prompt appears a moment later: leave it out of the captures as soon as it's listed.
        for delay in [0.4, 1.2, 2.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { MainActor.assumeIsolated { if PrivacyShieldWindows.isUnlocking { refresh() } } }
        }
        let method = PrivacyShieldPolicy.unlockMethod(
            touchIDAllowed: UserDefaults.standard.object(forKey: PrivacyShieldPolicy.touchIDKey) as? Bool ?? true,
            touchIDAvailable: touchIDAvailable())
        let ok: Bool
        switch method {
        case .touchIDOrPassword: ok = await authenticateWithTouchIDOrPassword()
        case .password: ok = await Task.detached(priority: .userInitiated) { authenticateSessionUser() }.value
        }
        Log.info("privacy shield: owner check by \(method == .touchIDOrPassword ? "Touch ID or password" : "login password"): \(ok ? "confirmed" : "not confirmed")")
        PrivacyShieldWindows.isUnlocking = false
        refresh()
        return ok
    }

    /// A Touch ID sensor with an enrolled finger that can be used now (not with the lid closed).
    static func touchIDAvailable() -> Bool {
        let context = LAContext()
        return context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) && context.biometryType == .touchID
    }

    /// This Mac has a Touch ID sensor at all (for showing the setting), enrolled or not.
    static func hasTouchIDSensor() -> Bool {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        return context.biometryType == .touchID
    }

    /// macOS's own sheet: a finger on this Mac's Touch ID, or "Use Password…". MeowDisplay only
    /// learns yes or no.
    private static func authenticateWithTouchIDOrPassword() async -> Bool {
        let context = LAContext()
        context.localizedFallbackTitle = String(localized: "Use Password…")
        do {
            return try await context.evaluatePolicy(.deviceOwnerAuthentication,
                                                    localizedReason: String(localized: "remove the Privacy Shield cover"))
        } catch {
            return false
        }
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
                let shield = Unmanaged<PrivacyShield>.fromOpaque(info).takeUnretainedValue()
                shield.lastPhysicalInput = ProcessInfo.processInfo.systemUptime
                // The tap runs on the main run loop.
                MainActor.assumeIsolated { shield.physicalInputArrived() }
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

/// A cover's content: black (an OLED panel's pixels are off) with the message in a fixed-size
/// subview that AppKit moves and dims. SwiftUI only draws the message's text: it can't size the
/// window or react to the camera notch's safe area.
final class PrivacyShieldCoverView: NSView {
    private let message: NSHostingView<PrivacyShieldMessage>
    private var step = 0
    private var look: PrivacyShieldPolicy.CoverLook = .bright

    override var isFlipped: Bool { true }   // top-left origin, like PrivacyShieldPolicy.coverCenter

    init() {
        message = NSHostingView(rootView: PrivacyShieldMessage())
        message.sizingOptions = []
        message.safeAreaRegions = []
        message.frame = NSRect(origin: .zero, size: PrivacyShieldPolicy.coverMessageSize)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        addSubview(message)
    }

    required init?(coder: NSCoder) { nil }

    /// Places and dims the message for this cover's size.
    func show(step: Int, look: PrivacyShieldPolicy.CoverLook, animate: Bool) {
        self.step = step
        self.look = look
        let c = PrivacyShieldPolicy.coverCenter(step: step, screen: bounds.size)
        let size = message.frame.size
        let origin = NSPoint(x: c.x - size.width / 2, y: c.y - PrivacyShieldPolicy.coverMessageLift - size.height / 2)
        let alpha: CGFloat = look == .bright ? 1 : look == .dim ? 0.4 : 0
        if animate {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 1.5
                message.animator().setFrameOrigin(origin)
                message.animator().alphaValue = alpha
            }
        } else {
            message.setFrameOrigin(origin)
            message.alphaValue = alpha
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        show(step: step, look: look, animate: false)
    }
}

/// The cover's message (drawn only; its size is fixed by `PrivacyShieldCoverView`).
struct PrivacyShieldMessage: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "eye.slash").font(.system(size: 34, weight: .regular)).foregroundStyle(.white.opacity(0.55))
            Text("This Mac is in use from another device").font(.title3.weight(.semibold)).foregroundStyle(.white.opacity(0.75))
            Text("Privacy Shield · Click Unlock, then type this Mac's login password").font(.callout).foregroundStyle(.white.opacity(0.45))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
    @AppStorage(PrivacyShieldPolicy.touchIDKey) private var touchID = true
    @State private var hasTouchID = PrivacyShield.hasTouchIDSensor()
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
            if hasTouchID {
                Toggle("Remove With Touch ID", isOn: $touchID)
                    .disabled(!remoteOn && !localOn)
                    .help("Touch ID on this Mac, or its login password, removes the cover. Off: only the login password.")
            }
            if authFailed { Text("Not turned off: the owner wasn't confirmed at this Mac.").font(.caption).foregroundStyle(.secondary) }
        } header: {
            Text("Privacy Shield")
        } footer: {
            Text("While a device is connected, this Mac's own screens are covered in black; the device still sees and controls everything. Remote means Tailscale and other routed addresses; local means Wi-Fi, peer-to-peer, USB and hotspot. Someone at the Mac can remove it with Touch ID (when this Mac has it and it's allowed above) or this Mac's login password, typed on its own keyboard; it covers again after the time above without use at the Mac. It doesn't stop typing or clicking at the Mac, and some system alerts can appear above it. Its message moves every minute and fades when no one is at the Mac, so OLED screens don't burn in.")
        }
        .confirmationDialog(confirmingOff == true ? "Turn off the Privacy Shield for remote connections?" : "Turn off the Privacy Shield for local connections?",
                            isPresented: Binding(get: { confirmingOff != nil }, set: { if !$0 { confirmingOff = nil } })) {
            Button("Turn Off", role: .destructive) { if let r = confirmingOff { turnOff(remote: r) }; confirmingOff = nil }
            Button("Cancel", role: .cancel) { confirmingOff = nil }
        } message: {
            Text(PrivacyShield.shared.isCovering
                 ? "If that turns the cover off now, macOS asks for Touch ID or this Mac's login password, at this Mac."
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
            if ok { apply(off: remote, ownerConfirmed: true); PrivacyShield.shared.unlockedLocally() }
        }
    }

    private func apply(off remote: Bool, ownerConfirmed: Bool = false) {
        if remote { remoteOn = false } else { localOn = false }
        PrivacyShield.shared.settingsChanged(ownerConfirmed: ownerConfirmed)
    }
}
