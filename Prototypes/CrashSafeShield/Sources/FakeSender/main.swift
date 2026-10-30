import AppKit
import ShieldCore

// Stands in for MeowDisplay's main app in the prototype. Covers the screens like the app does,
// and optionally starts the keeper (option B) or relaunches into a covered state from a marker
// (option A). Flags: --log PATH, --deadline S, --session NAME,
// --keeper PATH [--keeper-log PATH --keeper-args "…"], --marker PATH,
// --clean-quit-after S, --hang-keeper-after S.

let log = LineLog(path: argumentValue("--log"), tag: "app")
armHardDeadline(argumentValue("--deadline").flatMap(Double.init) ?? 30, log: log)
let session = argumentValue("--session") ?? "device"
let markerPath = argumentValue("--marker")

@MainActor
final class FakeApp {
    var covers: [NSWindow] = []
    var keeperChannel: FileHandle?
    var keeperNonce: String?

    func start() {
        log("started")
        if let markerPath, FileManager.default.fileExists(atPath: markerPath) {
            // Option A: relaunched after an abnormal exit while covering: cover before anything else.
            cover(reason: "relaunched with the covering marker set")
        }
        if let keeper = argumentValue("--keeper") { startKeeper(path: keeper) }
        cover(reason: "session \(session) started")
        keeperChannel?.write(WireMessage.cover(session: session).line.data(using: .utf8)!)
        if let s = argumentValue("--clean-quit-after").flatMap(Double.init) {
            DispatchQueue.main.asyncAfter(deadline: .now() + s) { MainActor.assumeIsolated { self.cleanQuit() } }
        }
        if let s = argumentValue("--hang-keeper-after").flatMap(Double.init) {
            DispatchQueue.main.asyncAfter(deadline: .now() + s) {
                MainActor.assumeIsolated {
                    log("asking the keeper (test mode) to hang its main thread")
                    self.keeperChannel?.write(WireMessage.testHang(seconds: 8).line.data(using: .utf8)!)
                }
            }
        }
        let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        signal(SIGTERM, SIG_IGN)
        term.setEventHandler { MainActor.assumeIsolated { self.cleanQuit() } }
        term.resume()
        objc_setAssociatedObject(self, "term", term, .OBJC_ASSOCIATION_RETAIN)
    }

    func cover(reason: String) {
        CoverWindows.show(&covers, label: "MeowDisplay shield prototype: app cover")
        if let markerPath { FileManager.default.createFile(atPath: markerPath, contents: Data("covering".utf8)) }
        log("covers shown (\(reason))")
    }

    /// Normal Quit: end the session, hand-shake, exit. The covers go with the process; the
    /// keeper's stay (held) until local unlock.
    func cleanQuit() {
        log("normal quit")
        keeperChannel?.write(WireMessage.sessionEnded(session: session).line.data(using: .utf8)!)
        if let keeperNonce { keeperChannel?.write(WireMessage.cleanQuit(nonce: keeperNonce).line.data(using: .utf8)!) }
        if let markerPath { try? FileManager.default.removeItem(atPath: markerPath) }
        exit(0)
    }

    private func startKeeper(path: String) {
        var pair: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else { log("socketpair failed"); return }
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawn_file_actions_adddup2(&actions, pair[1], 3)
        posix_spawn_file_actions_addclose(&actions, pair[0])
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        // Its own session: a signal to the app's process group doesn't reach the keeper.
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID))
        var args = [path]
        if let l = argumentValue("--keeper-log") { args += ["--log", l] }
        if let extra = argumentValue("--keeper-args") { args += extra.split(separator: " ").map(String.init) }
        let cArgs = args.map { strdup($0) } + [nil]
        var pid: pid_t = 0
        let r = posix_spawn(&pid, path, &actions, &attr, cArgs, environ)
        cArgs.forEach { free($0) }
        close(pair[1])
        guard r == 0 else { log("keeper spawn failed \(r)"); close(pair[0]); return }
        let channel = FileHandle(fileDescriptor: pair[0], closeOnDealloc: true)
        keeperChannel = channel
        // The keeper's hello carries the nonce for the clean-quit handshake.
        var hello = Data()
        while !hello.contains(0x0A) {
            let chunk = channel.availableData
            if chunk.isEmpty { break }
            hello.append(chunk)
        }
        keeperNonce = KeeperHello.parse(String(decoding: hello.prefix { $0 != 0x0A }, as: UTF8.self))?.nonce
        log("keeper pid \(pid) started; hello \(keeperNonce == nil ? "missing" : "received")")
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
MainActor.assumeIsolated {
    let fake = FakeApp()
    fake.start()
    objc_setAssociatedObject(app, "fake", fake, .OBJC_ASSOCIATION_RETAIN)
}
app.run()
