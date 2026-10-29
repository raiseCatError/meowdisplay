import AppKit
import CoreImage
@preconcurrency import ScreenCaptureKit
import UniformTypeIdentifiers

// Browsing for one receiver session, in EVERY display mode: Stage Peek, search
// and Launchpad open over Mirror and Extend without switching to Window mode,
// so the Mac must list windows, displays and apps (and send stills) there too.
// Read-only, except `launch`, which needs the session's input grant. The Window
// mode engine shares this service's identity ledger, so a window keeps one
// `gen` across modes and a tile picked in Mirror is accepted in Window mode.

/// What the thumbnail scheduler should do with one request, given the cache.
enum ThumbnailPlan: Equatable {
    case sendCached
    case capture
}

/// Pure scheduling rules (tested): merge requests in the receiver's priority
/// order, answer fresh stills from the cache, never starve windows late in the list.
struct ThumbnailScheduler: Equatable {
    struct Cached: Equatable { var generation: UInt64; var at: TimeInterval; var width: Int }
    /// A still younger than this is answered from the cache.
    static let freshFor: TimeInterval = 4
    static let maxPending = 64

    private(set) var pending: [UInt32] = []
    private(set) var cache: [UInt32: Cached] = [:]

    /// The receiver's latest request comes first (it is what is on screen now);
    /// older pending ids keep their place behind it.
    mutating func enqueue(_ ids: [UInt32], generations: [UInt32: UInt64], width: Int, now: TimeInterval) -> [UInt32] {
        var cachedNow: [UInt32] = []
        var front: [UInt32] = []
        for id in ids where !front.contains(id) {
            if let c = cache[id], c.generation == generations[id], now - c.at < Self.freshFor, c.width >= width {
                cachedNow.append(id)
            } else {
                front.append(id)
            }
        }
        pending = Array((front + pending.filter { !front.contains($0) }).prefix(Self.maxPending))
        return cachedNow
    }

    mutating func next() -> UInt32? { pending.isEmpty ? nil : pending.removeFirst() }

    mutating func stored(_ id: UInt32, generation: UInt64, width: Int, at now: TimeInterval) {
        cache[id] = Cached(generation: generation, at: now, width: width)
        if cache.count > 160, let oldest = cache.min(by: { $0.value.at < $1.value.at })?.key { cache[oldest] = nil }
    }

    mutating func forget(_ id: UInt32) { cache[id] = nil; pending.removeAll { $0 == id } }
}

/// One Mac display a tile (or Stage Peek's Displays row) can show.
struct DisplayCatalogEntry: Equatable, Sendable {
    var displayID: UInt32
    var name: String
    var frame: CGRect
    var isMain: Bool
    var isVirtual: Bool

    var wire: [String: Any] {
        ["id": Int(displayID), "name": String(name.prefix(80)), "w": Int(frame.width.rounded()), "h": Int(frame.height.rounded()),
         "main": isMain, "virtual": isVirtual]
    }
}

/// SCWindow and pixel buffers are immutable snapshots: safe to hand to a capture task.
private struct StillJob: @unchecked Sendable { let live: CVPixelBuffer?; let window: SCWindow }

final class WindowBrowserService: @unchecked Sendable {
    let hostID: String
    private let queue = DispatchQueue(label: "meow.workspace.browser", qos: .userInitiated)
    private let ledgerLock = NSLock()
    private var ledger = WindowIdentityLedger()
    private var snapshot: WindowCatalogSnapshot?
    private var displays: [DisplayCatalogEntry] = []
    private var scDisplays: [UInt32: SCDisplay] = [:]
    private var refreshInFlight = false
    private var refreshQueuedCatalog: Bool?
    private var lastCatalogRequestAt: TimeInterval = 0
    private var active = true
    private var stopped = false
    private var scheduler = ThumbnailScheduler()
    private var stills: [UInt32: Data] = [:]
    private var captureWidth: [UInt32: Int] = [:]
    private var inFlight = 0
    private static let maxConcurrentStills = 2
    private var lastAppRevisionSent: Int?
    private var iconsSent = Set<String>()

    /// A message for the receiver (the sender gates it on admission).
    var sendMessage: (([String: Any]) -> Void)?
    /// Every new listing, for the Window-mode engine (on this service's queue).
    var onSnapshot: ((WindowCatalogSnapshot) -> Void)?
    /// The latest WHOLE-window frame a tile streams, if any: a free, exact still.
    var liveFrame: ((UInt32) -> CVPixelBuffer?)?
    /// Integration tests only.
    var includeOwnProcessForTesting = false

    init(hostID: String) { self.hostID = hostID }

    /// Paused, Video Off or not admitted: no listings or stills leave the Mac.
    func setActive(_ value: Bool) { queue.async { [self] in active = value } }

    func stop() {
        queue.async { [self] in
            stopped = true; active = false
            sendMessage = nil; onSnapshot = nil; liveFrame = nil
            stills.removeAll()
        }
    }

    /// Window identity check for the engine (any queue).
    func knows(windowID: UInt32, generation: UInt64) -> Bool {
        ledgerLock.withLock { ledger.knows(windowID: windowID, generation: generation) }
    }

    func scDisplay(_ id: UInt32) -> SCDisplay? { queue.sync { scDisplays[id] } }
    func displayEntry(_ id: UInt32) -> DisplayCatalogEntry? { queue.sync { displays.first { $0.displayID == id } } }
    /// Listed displays' global bounds (a tile may show one of these, nothing else).
    func displayFrames() -> [UInt32: CGRect] {
        queue.sync { Dictionary(displays.map { ($0.displayID, $0.frame) }, uniquingKeysWith: { a, _ in a }) }
    }

    // MARK: Messages (admitted session only; MacSender gates)

    func handle(type: String, message obj: [String: Any], inputGranted: Bool) {
        queue.async { [self] in
            guard active, !stopped else { return }
            switch type {
            case WireMessage.windowCatalogRequest:
                let now = ProcessInfo.processInfo.systemUptime
                guard now - lastCatalogRequestAt >= 0.5 else { return }
                lastCatalogRequestAt = now
                refresh(sendCatalog: true)
            case WireMessage.windowThumbnailRequest:
                let ids = (obj["ids"] as? [Int] ?? []).compactMap { UInt32(exactly: $0) }
                let width = min(max(obj["max"] as? Int ?? 240, 64), 640)
                requestStills(Array(ids.prefix(48)), width: width)
                if let bundles = obj["icons"] as? [String] {
                    let fresh = bundles.prefix(48).filter { iconsSent.insert($0).inserted }   // each icon once per session
                    if !fresh.isEmpty { sendIcons(Array(fresh)) }
                }
                if let ds = obj["displays"] as? [Int] { sendDisplayStills(ds.compactMap { UInt32(exactly: $0) }.prefix(8), width: width) }
            case WireMessage.appCatalogRequest:
                let rev = obj["rev"] as? Int
                AppCatalog.shared.current { [weak self] apps, revision in
                    self?.queue.async { self?.sendAppCatalog(apps, revision: revision, receiverHas: rev) }
                }
            case WireMessage.appLaunch:
                // Changing the Mac needs control. Opens without activating: no focus steal.
                guard inputGranted, let bundle = obj["bundle"] as? String else { return }
                AppCatalog.shared.launch(bundle) { [weak self] ok in
                    self?.queue.async {
                        self?.sendMessage?(["type": WireMessage.appLaunchResult, "bundle": bundle, "ok": ok])
                        self?.queue.asyncAfter(deadline: .now() + 0.8) { self?.refresh(sendCatalog: true) }
                    }
                }
            default:
                break
            }
        }
    }

    // MARK: Listing

    /// Builds a listing (one at a time) and hands it to the engine; sends it when asked.
    func refresh(sendCatalog: Bool) {
        queue.async { [self] in
            guard !stopped else { return }
            guard !refreshInFlight else { refreshQueuedCatalog = (refreshQueuedCatalog ?? false) || sendCatalog; return }
            refreshInFlight = true
            let ledgerIn = ledgerLock.withLock { ledger }
            let includeOwn = includeOwnProcessForTesting
            Task { [weak self] in
                let built = try? await WindowCatalogBuilder.build(ledger: ledgerIn, includeOwnProcess: includeOwn)
                let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
                self?.queue.async {
                    guard let self else { return }
                    self.refreshInFlight = false
                    if let queued = self.refreshQueuedCatalog { self.refreshQueuedCatalog = nil; self.refresh(sendCatalog: queued) }
                    if let content { self.updateDisplays(content.displays) }
                    guard let (snap, ledgerOut) = built else {
                        Log.info("workspace: window listing failed (Screen Recording permission or ScreenCaptureKit)")
                        if sendCatalog, self.active {
                            self.sendMessage?(["type": WireMessage.windowCatalog, "windows": [], "apps": [], "error": "unavailable"])
                        }
                        return
                    }
                    self.ledgerLock.withLock { self.ledger = ledgerOut }
                    self.snapshot = snap
                    self.onSnapshot?(snap)
                    if sendCatalog, self.active { self.sendCatalogMessage(snap) }
                }
            }
        }
    }

    private func updateDisplays(_ list: [SCDisplay]) {
        let main = CGMainDisplayID()
        scDisplays = Dictionary(list.map { ($0.displayID, $0) }, uniquingKeysWith: { a, _ in a })
        displays = list.map { d in
            let screen = NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == d.displayID }
            let isVirtual = CGDisplayIsBuiltin(d.displayID) == 0 && CGDisplayVendorNumber(d.displayID) == 0x1234   // CGVirtualDisplay default vendor
                || (screen?.localizedName.contains("MeowDisplay") ?? false)
            return DisplayCatalogEntry(displayID: d.displayID, name: screen?.localizedName ?? "Display \(d.displayID)",
                                       frame: CGDisplayBounds(d.displayID), isMain: d.displayID == main, isVirtual: isVirtual)
        }.sorted { ($0.isMain ? 0 : 1, $0.displayID) < ($1.isMain ? 0 : 1, $1.displayID) }
    }

    private func sendCatalogMessage(_ snap: WindowCatalogSnapshot) {
        sendMessage?([
            "type": WireMessage.windowCatalog,
            "host": hostID,
            "windows": snap.windows.prefix(120).map(\.wire),
            "apps": snap.apps.prefix(60).map(\.wire),
            "displays": displays.prefix(8).map(\.wire),
        ])
        Log.info("workspace: catalog sent enumerated=\(snap.windows.count) displays=\(displays.count) apps=\(snap.apps.count)")
    }

    private func sendAppCatalog(_ apps: [AppCatalog.Entry], revision: Int, receiverHas: Int?) {
        guard active else { return }
        if receiverHas == revision {
            sendMessage?(["type": WireMessage.appCatalog, "rev": revision, "same": true])
            return
        }
        let running = Dictionary((snapshot?.apps ?? []).map { ($0.bundleID, $0) }, uniquingKeysWith: { a, _ in a })
        let windowCounts = Dictionary(grouping: snapshot?.windows ?? [], by: \.bundleID).mapValues(\.count)
        var list = apps.map { a -> [String: Any] in
            var m: [String: Any] = ["bundle": a.bundleID, "name": String(a.name.prefix(80))]
            if running[a.bundleID] != nil { m["running"] = true }
            if let n = windowCounts[a.bundleID] { m["windows"] = n }
            if let used = a.lastUsed { m["used"] = Int(used.timeIntervalSince1970) }
            return m
        }
        // Running apps that aren't installed in an app folder (a dev build, a helper) still belong in the list.
        let known = Set(apps.map(\.bundleID))
        for r in snapshot?.apps ?? [] where !known.contains(r.bundleID) {
            list.append(["bundle": r.bundleID, "name": String(r.name.prefix(80)), "running": true, "windows": windowCounts[r.bundleID] ?? 0])
        }
        sendMessage?(["type": WireMessage.appCatalog, "rev": revision, "apps": Array(list.prefix(AppCatalog.wireLimit))])
        lastAppRevisionSent = revision
    }

    // MARK: Stills

    private func requestStills(_ ids: [UInt32], width: Int) {
        guard let snap = snapshot else { return }
        let gens = Dictionary(snap.windows.map { ($0.windowID, $0.generation) }, uniquingKeysWith: { a, _ in a })
        let known = ids.filter { gens[$0] != nil }
        let now = ProcessInfo.processInfo.systemUptime
        for id in scheduler.enqueue(known, generations: gens, width: width, now: now) {
            if let jpeg = stills[id], let gen = gens[id] {
                sendMessage?(["type": WireMessage.windowThumbnail, "id": Int(id), "gen": Int(gen), "jpeg": jpeg.base64EncodedString()])
            }
        }
        for id in known { captureWidth[id] = width }
        pump()
    }

    private func pump() {
        while active, !stopped, inFlight < Self.maxConcurrentStills, let id = scheduler.next() {
            guard let snap = snapshot, active, let entry = snap.windows.first(where: { $0.windowID == id }),
                  let window = snap.scWindows[id] else { scheduler.forget(id); continue }
            inFlight += 1
            let width = captureWidth[id] ?? 320
            let job = StillJob(live: liveFrame?(id), window: window)
            Task { [weak self] in
                let image: CGImage?
                let window = job.window
                if let live = job.live { image = Self.downscale(live, width: width) } else {
                    let cfg = SCStreamConfiguration()
                    let aspect = window.frame.height / max(window.frame.width, 1)
                    cfg.width = width
                    cfg.height = max(Int(Double(width) * aspect) & ~1, 2)
                    cfg.showsCursor = false
                    if #available(macOS 14.2, *) { cfg.ignoreShadowsSingleWindow = true }
                    do {
                        image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: window),
                                                                           configuration: cfg)
                    } catch {
                        Log.info("workspace: still failed window=\(id) app=\(entry.bundleID) state=\(entry.availability.rawValue) code=\((error as NSError).code)")
                        image = nil
                    }
                }
                let jpeg = image.flatMap { Self.jpeg($0, quality: 0.62) }
                self?.queue.async {
                    guard let self else { return }
                    self.inFlight -= 1
                    var msg: [String: Any] = ["type": WireMessage.windowThumbnail, "id": Int(id), "gen": Int(entry.generation)]
                    if let jpeg {
                        self.stills[id] = jpeg
                        self.scheduler.stored(id, generation: entry.generation, width: width, at: ProcessInfo.processInfo.systemUptime)
                        msg["jpeg"] = jpeg.base64EncodedString()
                    } else if let old = self.stills[id] {
                        msg["jpeg"] = old.base64EncodedString()   // the last real still, marked as such
                        msg["stale"] = true
                    } else {
                        msg["unavailable"] = true
                        msg["reason"] = entry.availability == .offscreen ? "offscreen" : "failed"
                    }
                    if self.stills.count > 160, let drop = self.stills.keys.first(where: { self.scheduler.cache[$0] == nil }) { self.stills[drop] = nil }
                    if self.active { self.sendMessage?(msg) }
                    self.pump()
                }
            }
        }
    }

    private var displayStillsBusy = false
    private var lastDisplayStillsAt: TimeInterval = 0

    /// One display batch at a time, at most every 2 s (a display still is a full-screen capture).
    private func sendDisplayStills(_ ids: ArraySlice<UInt32>, width: Int) {
        let now = ProcessInfo.processInfo.systemUptime
        guard !displayStillsBusy, now - lastDisplayStillsAt >= 2 else { return }
        let wanted = ids.compactMap { scDisplays[$0] }
        guard !wanted.isEmpty else { return }
        displayStillsBusy = true
        lastDisplayStillsAt = now
        Task { [weak self] in
            defer { self?.queue.async { self?.displayStillsBusy = false } }
            for d in wanted {
                guard let self, await self.isActive() else { return }
                let cfg = SCStreamConfiguration()
                cfg.width = width
                cfg.height = max(Int(Double(width) * Double(d.height) / Double(max(d.width, 1))) & ~1, 2)
                cfg.showsCursor = false
                // MeowDisplay's own windows (prompts, privacy cover) never appear in a still.
                let own = (try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true))?
                    .applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier } ?? []
                let filter = SCContentFilter(display: d, excludingApplications: own, exceptingWindows: [])
                guard let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg),
                      let jpeg = Self.jpeg(image, quality: 0.6) else { continue }
                self.queue.async { [weak self] in
                    guard let self, self.active else { return }
                    self.sendMessage?(["type": WireMessage.displayThumbnail, "id": Int(d.displayID), "jpeg": jpeg.base64EncodedString()])
                }
            }
        }
    }

    private func isActive() async -> Bool {
        await withCheckedContinuation { c in queue.async { [self] in c.resume(returning: active && !stopped) } }
    }

    private func sendIcons(_ bundles: [String]) {
        DispatchQueue.main.async { [weak self] in
            for bundle in bundles {
                guard AppCatalog.shared.isKnown(bundle) || NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first != nil,
                      let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) else { continue }
                guard let png = Self.png(NSWorkspace.shared.icon(forFile: url.path), side: 96) else { continue }
                let msg: [String: Any] = ["type": WireMessage.appIcon, "bundle": bundle, "png": png.base64EncodedString()]
                self?.queue.async { if self?.active == true { self?.sendMessage?(msg) } }
            }
        }
    }

    private static let ciContext = CIContext(options: [.cacheIntermediates: false])

    static func downscale(_ buffer: CVPixelBuffer, width: Int) -> CGImage? {
        let image = CIImage(cvPixelBuffer: buffer)
        let s = CGFloat(width) / max(image.extent.width, 1)
        let scaled = image.transformed(by: CGAffineTransform(scaleX: s, y: s))
        return ciContext.createCGImage(scaled, from: scaled.extent.integral)
    }

    static func jpeg(_ image: CGImage, quality: Double) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }

    static func png(_ image: NSImage, side: Int) -> Data? {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }
}

// MARK: - Installed apps (one per Mac, shared by every session)

/// Every launchable app the Mac can find, from Spotlight's own index
/// (NSMetadataQuery, live-updated on installs and removals) with a folder scan
/// as fallback when Spotlight is off. Deduplicated by bundle id; Finder first.
final class AppCatalog: @unchecked Sendable {
    static let shared = AppCatalog()
    static let wireLimit = 900
    static let finderBundle = "com.apple.finder"

    struct Entry: Equatable, Sendable {
        var bundleID: String
        var name: String
        var path: String
        var lastUsed: Date?
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var revision = 0
    private var ready = false
    private var waiters: [([Entry], Int) -> Void] = []
    private var query: NSMetadataQuery?
    private var observers: [NSObjectProtocol] = []

    static var searchFolders: [URL] {
        let fm = FileManager.default
        var dirs = ["/Applications", "/System/Applications", "/System/Applications/Utilities", "/Applications/Utilities"]
            .map { URL(fileURLWithPath: $0) }
        dirs.append(fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications"))
        return dirs
    }

    /// Sorted list (Finder first, then by name) and its revision. Starts the query on first use.
    func current(_ completion: @escaping ([Entry], Int) -> Void) {
        let snapshot: ([Entry], Int)? = lock.withLock {
            if ready { return (Self.sorted(Array(entries.values)), revision) }
            waiters.append(completion)
            return nil
        }
        if let snapshot { completion(snapshot.0, snapshot.1) } else { start() }
    }

    func isKnown(_ bundle: String) -> Bool { lock.withLock { entries[bundle] != nil } }

    static func sorted(_ list: [Entry]) -> [Entry] {
        list.sorted { a, b in
            if (a.bundleID == finderBundle) != (b.bundleID == finderBundle) { return a.bundleID == finderBundle }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    /// Merge rule (tested): one entry per bundle id; /Applications beats other folders; never MeowDisplay itself.
    static func merge(_ found: [Entry], ownBundle: String?) -> [String: Entry] {
        var out: [String: Entry] = [:]
        func rank(_ p: String) -> Int { p.hasPrefix("/Applications/") ? 0 : p.hasPrefix("/System/") ? 1 : 2 }
        for e in found where !e.bundleID.isEmpty && e.bundleID != ownBundle && !e.path.contains(".app/") {
            if let old = out[e.bundleID] {
                if rank(e.path) < rank(old.path) { out[e.bundleID] = Entry(bundleID: e.bundleID, name: e.name, path: e.path, lastUsed: e.lastUsed ?? old.lastUsed) }
                else if old.lastUsed == nil, let used = e.lastUsed { out[e.bundleID]?.lastUsed = used }
            } else {
                out[e.bundleID] = e
            }
        }
        return out
    }

    private func start() {
        DispatchQueue.main.async { [self] in
            guard query == nil else { return }
            let q = NSMetadataQuery()
            q.predicate = NSPredicate(format: "kMDItemContentType == 'com.apple.application-bundle'")
            q.searchScopes = Self.searchFolders
            q.notificationBatchingInterval = 2
            let center = NotificationCenter.default
            observers.append(center.addObserver(forName: .NSMetadataQueryDidFinishGathering, object: q, queue: .main) { [weak self] _ in self?.collect() })
            observers.append(center.addObserver(forName: .NSMetadataQueryDidUpdate, object: q, queue: .main) { [weak self] _ in self?.collect() })
            query = q
            if !q.start() { DispatchQueue.global(qos: .utility).async { self.publish(Self.scanFolders()) } }
            // Spotlight off or slow: never leave the receiver waiting.
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 4) { [weak self] in
                guard let self, !self.lock.withLock({ self.ready }) else { return }
                self.publish(Self.scanFolders())
            }
        }
    }

    private func collect() {
        guard let q = query else { return }
        q.disableUpdates()
        var found: [Entry] = []
        for i in 0..<q.resultCount {
            guard let item = q.result(at: i) as? NSMetadataItem, let path = item.value(forAttribute: NSMetadataItemPathKey) as? String,
                  let bundle = Bundle(path: path), let id = bundle.bundleIdentifier else { continue }
            let name = (item.value(forAttribute: NSMetadataItemDisplayNameKey) as? String).map { $0.hasSuffix(".app") ? String($0.dropLast(4)) : $0 }
                ?? URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
            found.append(Entry(bundleID: id, name: name, path: path, lastUsed: item.value(forAttribute: "kMDItemLastUsedDate") as? Date))
        }
        q.enableUpdates()
        found.append(Self.finderEntry)
        DispatchQueue.global(qos: .utility).async { [self] in publish(found.count > 1 ? found : Self.scanFolders()) }
    }

    static var finderEntry: Entry { Entry(bundleID: finderBundle, name: "Finder", path: "/System/Library/CoreServices/Finder.app", lastUsed: nil) }

    static func scanFolders() -> [Entry] {
        var found = [finderEntry]
        for dir in searchFolders {
            for url in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] where url.pathExtension == "app" {
                guard let b = Bundle(url: url), let id = b.bundleIdentifier else { continue }
                let name = (b.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                    ?? (b.object(forInfoDictionaryKey: "CFBundleName") as? String) ?? url.deletingPathExtension().lastPathComponent
                found.append(Entry(bundleID: id, name: name, path: url.path, lastUsed: nil))
            }
        }
        return found
    }

    private func publish(_ found: [Entry]) {
        let merged = Self.merge(found, ownBundle: Bundle.main.bundleIdentifier)
        let (list, rev, toCall): ([Entry], Int, [([Entry], Int) -> Void]) = lock.withLock {
            if merged != entries || !ready { entries = merged; revision += 1 }
            ready = true
            let w = waiters; waiters = []
            return (Self.sorted(Array(entries.values)), revision, w)
        }
        for w in toCall { w(list, rev) }
    }

    /// Opens an app the Mac listed, WITHOUT activating it (no focus steal). Already
    /// running: a reopen, which makes most apps show a window.
    func launch(_ bundle: String, completion: @escaping @Sendable (Bool) -> Void) {
        let path: String? = lock.withLock { entries[bundle]?.path }
        DispatchQueue.main.async {
            let runningApp = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first
            guard let url = path.map(URL.init(fileURLWithPath:)) ?? (runningApp != nil ? NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) : nil) else {
                completion(false); return
            }
            let config = NSWorkspace.OpenConfiguration()
            config.activates = false
            config.addsToRecentItems = false
            NSWorkspace.shared.openApplication(at: url, configuration: config) { app, error in
                if let error { Log.info("workspace: launch \(bundle) failed \(error.localizedDescription)") }
                completion(app != nil && error == nil)
            }
        }
    }
}
