import AppKit
import Security
import ShieldCore

// The supervised cover controller (option B). Started by the app with one end of a private
// socket pair as fd 3. It never uncovers on the app's word; see KeeperPolicy.
//
// Prototype flags: --log PATH, --deadline S (hard exit, default 30), --test-mode (allows
// testHang and --test-autorelease S, which stands in for the owner's password), --no-lock
// (log the lock instead of locking the owner's Mac).

let log = LineLog(path: argumentValue("--log"), tag: "keeper")
let testMode = argumentFlag("--test-mode")
let autorelease = testMode ? argumentValue("--test-autorelease").flatMap(Double.init) : nil
let performLock = !argumentFlag("--no-lock")
armHardDeadline(argumentValue("--deadline").flatMap(Double.init) ?? 30, log: log)

/// Main-thread heartbeat for the watchdog thread.
final class Beat: @unchecked Sendable {
    private let lock = NSLock()
    private var last = Date()
    private var covering = false
    func tick(covering c: Bool) { lock.lock(); last = Date(); covering = c; lock.unlock() }
    func read() -> (age: TimeInterval, covering: Bool) { lock.lock(); defer { lock.unlock() }; return (Date().timeIntervalSince(last), covering) }
}

@MainActor
final class Keeper {
    private var policy = KeeperPolicy(nonce: UUID().uuidString)
    private var covers: [NSWindow] = []
    private let channel = FileHandle(fileDescriptor: 3, closeOnDealloc: true)
    private var buffer = Data()
    private var parentExit: DispatchSourceProcess?
    private let beat = Beat()
    private var unlockPanel: NSPanel?

    func start() {
        log("started; parent pid \(getppid()); test mode \(testMode)")
        channel.write(KeeperHello(nonce: policy.nonce).line.data(using: .utf8)!)
        channel.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if data.isEmpty {
                        handle.readabilityHandler = nil
                        self?.apply(.peerGone, why: "channel closed")
                    } else {
                        self?.receive(data)
                    }
                }
            }
        }
        let source = DispatchSource.makeProcessSource(identifier: getppid(), eventMask: .exit, queue: .main)
        source.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.apply(.peerGone, why: "parent process exited") } }
        source.resume()
        parentExit = source
        // Displays added, removed or rearranged while covering: re-cover every screen at once.
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.policy.isCovering else { return }
                CoverWindows.show(&self.covers, label: "MeowDisplay shield prototype: keeper cover")
                log("screens changed: re-covered \(NSScreen.screens.count) screen(s)")
            }
        }
        Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { guard let self else { return }; self.beat.tick(covering: self.policy.isCovering) }
        }
        let beat = self.beat
        Thread.detachNewThread {
            while true {
                Thread.sleep(forTimeInterval: 0.25)
                let state = beat.read()
                guard state.age > 3 else { continue }
                // The main thread is stuck: decide from the last known state, act from here.
                var stalled = KeeperPolicy(nonce: "")
                if state.covering { _ = stalled.handle(.peer(.cover(session: "watchdog"))) }
                for action in stalled.handle(.mainThreadStalled) {
                    switch action {
                    case .log(let s): log("watchdog: \(s) (main thread silent \(String(format: "%.1f", state.age)) s)")
                    case .lockScreen: lockScreen()
                    case .exitProcess: exit(0)
                    default: break
                    }
                }
            }
        }
    }

    private func receive(_ data: Data) {
        buffer.append(data)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = String(decoding: buffer[buffer.startIndex..<nl], as: UTF8.self)
            buffer.removeSubrange(buffer.startIndex...nl)
            let message = WireMessage.parse(line)
            if case .testHang(let seconds) = message, testMode {
                log("TEST: blocking the main thread for \(seconds) s")
                Thread.sleep(forTimeInterval: seconds)
                continue
            }
            apply(.peer(message), why: "message \(line)")
        }
    }

    private func apply(_ event: KeeperEvent, why: String) {
        let actions = policy.handle(event)
        if !actions.isEmpty { log("event: \(why)") }
        for action in actions { perform(action) }
        beat.tick(covering: policy.isCovering)
    }

    private func perform(_ action: KeeperAction) {
        switch action {
        case .showCovers:
            CoverWindows.show(&covers, label: "MeowDisplay shield prototype: keeper cover")
            showUnlockPanel()
            log("covers shown on \(NSScreen.screens.count) screen(s)")
            if let autorelease {
                DispatchQueue.main.asyncAfter(deadline: .now() + autorelease) { [weak self] in
                    MainActor.assumeIsolated {
                        log("TEST autorelease (stands in for this Mac's own click plus the login password)")
                        self?.apply(.localUnlock(physical: true, authenticated: true), why: "test autorelease")
                    }
                }
            }
        case .hideCovers:
            CoverWindows.hide(covers)
            unlockPanel?.orderOut(nil)
            log("covers hidden")
        case .lockScreen:
            lockScreen()
        case .notifyPeerUnlocked:
            channel.write("{\"unlocked\":true}\n".data(using: .utf8)!)
        case .exitProcess:
            log("exiting")
            exit(0)
        case .log(let s):
            log(s)
        }
    }

    // MARK: Unlock: this Mac's own click, then the login password

    private func showUnlockPanel() {
        let panel = unlockPanel ?? {
            let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 220, height: 44), styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
            p.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()) + 1)
            p.sharingType = .none
            p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
            let button = NSButton(title: "Unlock (login password)", target: nil, action: nil)
            button.frame = NSRect(x: 10, y: 8, width: 200, height: 28)
            button.target = self
            button.action = #selector(unlockTapped)
            p.contentView?.addSubview(button)
            unlockPanel = p
            return p
        }()
        if let screen = NSScreen.main { panel.setFrameOrigin(NSPoint(x: screen.frame.midX - 110, y: screen.frame.minY + 60)) }
        panel.orderFrontRegardless()
    }

    @objc private func unlockTapped() {
        var physical = false
        if let e = NSApp.currentEvent?.cgEvent { physical = e.getIntegerValueField(.eventSourceUnixProcessID) == 0 }
        guard physical else { apply(.localUnlock(physical: false, authenticated: false), why: "unlock click"); return }
        covers.forEach { $0.level = .screenSaver }   // the password prompt must be visible at the Mac
        DispatchQueue.global().async {
            let ok = Self.authenticateSessionUser()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.covers.forEach { $0.level = CoverWindows.shieldingLevel }
                    self.apply(.localUnlock(physical: true, authenticated: ok), why: "unlock with password")
                }
            }
        }
    }

    nonisolated static func authenticateSessionUser() -> Bool {
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
}

/// Ctrl-Cmd-Q, the same public route the app uses. Needs this process to be allowed to post
/// events (Accessibility); without it nothing happens, which the log records.
func lockScreen() {
    guard performLock else { log("lockScreen requested (test run: not performed)"); return }
    guard CGPreflightPostEventAccess() else { log("lockScreen requested but this process may not post events: NOT locked"); return }
    let source = CGEventSource(stateID: .hidSystemState)
    for down in [true, false] {
        let e = CGEvent(keyboardEventSource: source, virtualKey: 12, keyDown: down)
        e?.flags = [.maskCommand, .maskControl]
        e?.post(tap: .cghidEventTap)
    }
    log("lockScreen posted")
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
MainActor.assumeIsolated {
    let keeper = Keeper()
    keeper.start()
    objc_setAssociatedObject(app, "keeper", keeper, .OBJC_ASSOCIATION_RETAIN)
}
app.run()
