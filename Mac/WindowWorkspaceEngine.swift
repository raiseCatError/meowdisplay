import AppKit
import ApplicationServices
import CoreImage
import CoreMedia
import Metal
@preconcurrency import ScreenCaptureKit
import UniformTypeIdentifiers

// Window mode for one receiver: native per-window capture
// (`SCContentFilter(desktopIndependentWindow:)`), composited on the GPU into
// one canvas the size of the receiver's panel, encoded by the session's
// existing encoder. No virtual display, and no Mac window is moved, resized
// or put on another Space. See WINDOW_MODE.md for the measurements behind it.

// MARK: - One window's stream

final class WindowTileCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let tileID: String
    let windowID: UInt32
    let assignmentGeneration: UInt64
    private let lock = NSLock()
    private var latest: CVPixelBuffer?
    private var frames = 0
    private var lastFrameAt: TimeInterval = 0
    private var stream: SCStream?
    private var config = SCStreamConfiguration()
    private let outputQueue = DispatchQueue(label: "meow.workspace.tile", qos: .userInteractive)
    var onFrame: (@Sendable () -> Void)?
    var onStop: (@Sendable (Int) -> Void)?

    init(tileID: String, windowID: UInt32, assignmentGeneration: UInt64) {
        self.tileID = tileID
        self.windowID = windowID
        self.assignmentGeneration = assignmentGeneration
    }

    func start(window: SCWindow, size: CGSize, fps: Int, sourceRect: CGRect? = nil) async throws {
        try await start(filter: SCContentFilter(desktopIndependentWindow: window), size: size, fps: fps, sourceRect: sourceRect)
    }

    /// A whole display (Full Desktop in a tile). MeowDisplay's own windows are left out.
    func start(display: SCDisplay, size: CGSize, fps: Int, sourceRect: CGRect? = nil) async throws {
        let own = (try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true))?
            .applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier } ?? []
        try await start(filter: SCContentFilter(display: display, excludingApplications: own, exceptingWindows: []),
                        size: size, fps: fps, sourceRect: sourceRect)
    }

    private func start(filter: SCContentFilter, size: CGSize, fps: Int, sourceRect: CGRect?) async throws {
        config.width = Int(size.width)
        config.height = Int(size.height)
        // Per-tile zoom: capture only the zoomed-in part, at the tile's resolution (sharp).
        config.sourceRect = sourceRect ?? .null
        config.minimumFrameInterval = CMTime(value: 1, timescale: Int32(max(fps, 1)))
        config.showsCursor = false   // the receiver draws one workspace pointer
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.queueDepth = 3
        config.capturesAudio = false
        if #available(macOS 14.2, *) { config.ignoreShadowsSingleWindow = true }
        let s = SCStream(filter: filter, configuration: config, delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: outputQueue)
        lock.withLock { stream = s }
        try await s.startCapture()
    }

    /// Re-size or re-rate without restarting: the window's last frame stays.
    func update(size: CGSize, fps: Int, sourceRect: CGRect? = nil) async {
        guard let s = lock.withLock({ stream }) else { return }
        let newInterval = CMTime(value: 1, timescale: Int32(max(fps, 1)))
        let rect = sourceRect ?? .null
        guard Int(size.width) != config.width || Int(size.height) != config.height || newInterval != config.minimumFrameInterval
              || rect != config.sourceRect else { return }
        config.width = Int(size.width)
        config.height = Int(size.height)
        config.sourceRect = rect
        config.minimumFrameInterval = newInterval
        try? await s.updateConfiguration(config)
    }

    func stop() async {
        let s = lock.withLock { () -> SCStream? in defer { stream = nil; latest = nil }; return stream }
        try? await s?.stopCapture()
    }

    func latestFrame() -> CVPixelBuffer? { lock.withLock { latest } }
    /// Frames arrived recently: the window is being captured (a window on
    /// another Space is, a minimized one isn't), whatever "on screen" says.
    var isDelivering: Bool { lock.withLock { ProcessInfo.processInfo.systemUptime - lastFrameAt < 2 } }
    var hasFrame: Bool { lock.withLock { latest != nil } }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, CMSampleBufferIsValid(sampleBuffer),
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let current = lock.withLock { () -> Bool in
            guard self.stream === stream else { return false }
            latest = pixels
            frames += 1
            lastFrameAt = ProcessInfo.processInfo.systemUptime
            return true
        }
        if current { onFrame?() }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        let code = (error as NSError).code
        let current = lock.withLock { self.stream === stream }
        if current { onStop?(code) }
    }
}

/// What a tile captures: a window, or a whole display (ScreenCaptureKit objects, read-only here).
private struct CaptureSource: @unchecked Sendable { let window: SCWindow?; let display: SCDisplay? }

// MARK: - Compositor

/// Draws tiles into one BGRA canvas. Each tile: its window's latest frame
/// placed by `TileContentTransform` (fit/fill, rotation), clipped to the
/// tile; a quiet placeholder while there is no frame. Nothing from a tile's
/// previous window is ever drawn: frames are looked up by the CURRENT capture.
final class WorkspaceCompositor {
    struct Item {
        var rect: WorkspaceRect
        var transform: TileContentTransform?
        var frame: CVPixelBuffer?
        var sourceSize: CGSize
        var dimmed: Bool
    }

    private let context: CIContext
    private var pool: CVPixelBufferPool?
    private(set) var size: CGSize = .zero
    private let background = CIImage(color: CIColor(red: 0.07, green: 0.07, blue: 0.08))
    private let placeholder = CIImage(color: CIColor(red: 0.13, green: 0.13, blue: 0.15))
    private let dim = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0.45))

    init?() {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        context = CIContext(mtlDevice: device, options: [.cacheIntermediates: false, .name: "MeowDisplay.workspace"])
    }

    func resize(to newSize: CGSize) {
        guard newSize != size, newSize.width >= 2, newSize.height >= 2 else { return }
        size = newSize
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(newSize.width),
            kCVPixelBufferHeightKey as String: Int(newSize.height),
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        var newPool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(nil, [kCVPixelBufferPoolMinimumBufferCountKey as String: 4] as CFDictionary, attrs as CFDictionary, &newPool)
        pool = newPool
    }

    func compose(_ items: [Item]) -> CVPixelBuffer? {
        guard let pool, size.width > 0 else { return nil }
        var out: CVPixelBuffer?
        // Bounded: if the encoder still holds every buffer, skip this tick.
        let auxAttrs = [kCVPixelBufferPoolAllocationThresholdKey as String: 10] as CFDictionary
        guard CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, pool, auxAttrs, &out) == kCVReturnSuccess,
              let buffer = out else { return nil }
        let canvas = CGRect(origin: .zero, size: size)
        var image = background.cropped(to: canvas)
        for item in items {
            let px = item.rect.pixelAligned(in: WorkspaceSize(width: size.width, height: size.height))
            let tileCI = CGRect(x: px.x, y: size.height - px.maxY, width: px.width, height: px.height)
            guard let frame = item.frame, let t = item.transform else {
                image = placeholder.cropped(to: tileCI).composited(over: image)
                continue
            }
            let w = Double(CVPixelBufferGetWidth(frame)), h = Double(CVPixelBufferGetHeight(frame))
            let fw = t.source.width, fh = t.source.height
            // Map three buffer corners (CoreImage: origin bottom-left) through
            // source points (window points, top-left) into the canvas.
            func toCanvas(_ u: Double, _ v: Double) -> CGPoint {
                // The buffer holds only the zoomed-in part: offset into whole-window coordinates.
                let src = WorkspacePoint(x: u / w * fw + t.origin.x, y: (1 - v / h) * fh + t.origin.y)
                let c = t.canvasPoint(fromSource: src)
                return CGPoint(x: c.x, y: size.height - c.y)
            }
            let p0 = toCanvas(0, 0), p1 = toCanvas(w, 0), p2 = toCanvas(0, h)
            let affine = CGAffineTransform(a: (p1.x - p0.x) / w, b: (p1.y - p0.y) / w,
                                           c: (p2.x - p0.x) / h, d: (p2.y - p0.y) / h, tx: p0.x, ty: p0.y)
            var tile = CIImage(cvPixelBuffer: frame).transformed(by: affine).cropped(to: tileCI)
            if item.dimmed { tile = dim.cropped(to: tileCI).composited(over: tile) }
            // Letterbox bars match the canvas background: no gray strips beside a fitted window.
            image = tile.composited(over: background.cropped(to: tileCI)).composited(over: image)
        }
        // Wait for the GPU: `render(_:to:)` on a Metal context returns before
        // the draw lands, and the encoder (or any CPU reader) would then see
        // the previous contents of a recycled pool buffer (found by
        // WindowWorkspaceEngineIntegrationTests).
        let destination = CIRenderDestination(pixelBuffer: buffer)
        destination.colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
        do {
            try context.startTask(toRender: image, from: canvas, to: destination, at: .zero).waitUntilCompleted()
        } catch {
            return nil
        }
        return buffer
    }
}

// MARK: - Engine

/// One receiver's window workspace. Thread model: state lives on `queue`;
/// input mapping (called from the injector on the network queue) reads the
/// targeting model under `inputLock`.
final class WindowWorkspaceEngine: InputTargetMapper, @unchecked Sendable {
    /// All receivers together: window streams this Mac will run at once.
    static let globalCaptureLimit = 16
    private static let budgetLock = NSLock()
    nonisolated(unsafe) private static var globalCaptures = 0

    let hostID: String
    private let queue = DispatchQueue(label: "meow.workspace.engine", qos: .userInteractive)
    private let inputLock = NSRecursiveLock()
    private var targeting = WorkspaceInputTargeting()
    private var canvas: CGSize
    private var streamFPS: Int
    /// Listings, stills and app launches (shared with Mirror/Extend browsing).
    let browser: WindowBrowserService
    private var snapshot: WindowCatalogSnapshot?
    private let liveLock = NSLock()
    private var liveWhole: [UInt32: WindowTileCapture] = [:]
    private var catalog: [UInt32: WindowCatalogEntry] = [:]
    private var assignments: [WorkspaceTileAssignment] = []
    private var captures: [String: WindowTileCapture] = [:]
    private var tileState: [String: String] = [:]
    private var rejected: [String: String] = [:]
    private var nextGeneration: UInt64 = 1
    private let compositor = WorkspaceCompositor()
    private var composeTimer: DispatchSourceTimer?
    private var refreshTimer: DispatchSourceTimer?
    private var dirty = true
    private var lastComposeAt: TimeInterval = 0
    private var running = false
    private var lastStateSent: String = ""
    private var stopped = false
    private var keyboardDecision: WorkspaceKeyboardGate.Decision = .noActiveTile
    private var keyboardCheckedAt: TimeInterval = 0
    private var topmostCache: [UInt32: (at: TimeInterval, rect: CGRect, ok: Bool)] = [:]

    /// A composited frame (engine queue). The sender hops to its own queue.
    var deliverFrame: ((CVPixelBuffer) -> Void)?
    /// A control message for the receiver.
    var sendMessage: (([String: Any]) -> Void)?
    /// Release every held key/button on the Mac (source changed under it).
    var releaseHeldInput: (() -> Void)?

    init(hostID: String, canvas: CGSize, fps: Int, browser: WindowBrowserService) {
        self.hostID = hostID
        self.browser = browser
        self.canvas = canvas
        self.streamFPS = max(fps, 1)
        targeting.canvas = canvas
    }

    // MARK: Lifecycle

    func start() {
        queue.async { [self] in
            guard !running else { return }
            running = true
            compositor?.resize(to: canvas)
            browser.onSnapshot = { [weak self] snap in self?.queue.async { self?.apply(snap) } }
            browser.liveFrame = { [weak self] id in self?.liveWholeFrame(id) }
            startTimers()
            refresh(sendCatalog: false)
        }
    }

    /// A tile streaming this WHOLE window (no zoom): its latest frame is an exact, free still.
    func liveWholeFrame(_ id: UInt32) -> CVPixelBuffer? {
        liveLock.withLock { liveWhole[id] }?.latestFrame()
    }

    private func updateLiveWhole() {
        var map: [UInt32: WindowTileCapture] = [:]
        for a in assignments where a.crop == WorkspaceCrop.full { if let c = captures[a.tileID] { map[a.windowID] = c } }
        liveLock.withLock { liveWhole = map }
    }

    func stop(completion: (@Sendable () -> Void)? = nil) {
        queue.async { [self] in
            running = false
            stopped = true
            deliverFrame = nil
            sendMessage = nil
            releaseHeldInput = nil
            browser.onSnapshot = nil
            browser.liveFrame = nil
            liveLock.withLock { liveWhole = [:] }
            composeTimer?.cancel(); composeTimer = nil
            refreshTimer?.cancel(); refreshTimer = nil
            let all = Array(captures.values)
            captures.removeAll()
            Self.releaseBudget(all.count)
            Task {
                for c in all { await c.stop() }
                completion?()
            }
        }
    }

    /// Paused display or Video Off: every window stream stops (nothing is
    /// captured or composited) but the tiles, their windows and the focus
    /// are kept, so resuming shows the same workspace.
    func setSuspended(_ suspended: Bool) {
        queue.async { [self] in
            guard !stopped else { return }
            if suspended {
                guard running else { return }
                running = false
                composeTimer?.cancel(); composeTimer = nil
                refreshTimer?.cancel(); refreshTimer = nil
                let all = Array(captures.values)
                captures.removeAll()
                Self.releaseBudget(all.count)
                for id in assignments.map(\.tileID) where tileState[id] == "live" { tileState[id] = "waiting" }
                Task { for c in all { await c.stop() } }
            } else {
                guard !running else { return }
                running = true
                dirty = true
                startTimers()
                refresh(sendCatalog: false)
            }
        }
    }

    func update(canvas newCanvas: CGSize, fps: Int) {
        queue.async { [self] in
            canvas = newCanvas
            streamFPS = max(fps, 1)
            compositor?.resize(to: newCanvas)
            inputLock.withLock { targeting.canvas = newCanvas }
            dirty = true
            if running { startTimers() }
            retuneCaptures()
        }
    }

    private func startTimers() {
        composeTimer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        let interval = 1.0 / Double(streamFPS)
        t.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(2))
        t.setEventHandler { [weak self] in self?.composeTick() }
        t.resume()
        composeTimer = t
        if refreshTimer == nil {
            let r = DispatchSource.makeTimerSource(queue: queue)
            r.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(100))
            r.setEventHandler { [weak self] in self?.refresh(sendCatalog: false) }
            r.resume()
            refreshTimer = r
        }
    }

    private func composeTick() {
        guard running, let compositor else { return }
        let now = ProcessInfo.processInfo.systemUptime
        // Static windows produce no frames; resend ~1/s so a lost frame heals.
        guard dirty || now - lastComposeAt >= 1 else { return }
        dirty = false
        lastComposeAt = now
        let targetingNow = inputLock.withLock { targeting }
        let items = assignments.map { a -> WorkspaceCompositor.Item in
            let capture = captures[a.tileID]
            let frame = capture?.assignmentGeneration == a.assignmentGeneration ? capture?.latestFrame() : nil
            let state = tileState[a.tileID]
            return WorkspaceCompositor.Item(rect: a.rect, transform: targetingNow.transform(for: a), frame: frame,
                                            sourceSize: .zero, dimmed: state == "offscreen" || state == "closed")
        }
        if let buffer = compositor.compose(items) { deliverFrame?(buffer) }
    }

    // MARK: Messages from the receiver (admitted session only; MacSender gates)

    func handle(type: String, message obj: [String: Any], inputGranted: Bool) {
        queue.async { [self] in
            // Paused, Video Off or no admitted receiver: no titles, stills or changes.
            guard running, !stopped else { return }
            switch type {
            case WireMessage.workspaceRequest:
                applyWorkspace(obj)
            case WireMessage.workspaceFocus:
                let id = obj["tile"] as? String
                inputLock.withLock { targeting.setActive(id); keyboardCheckedAt = 0 }
                retuneCaptures()
                if inputGranted, let a = inputLock.withLock({ targeting.keyboardTarget }) {
                    activateBounded(a)
                }
                sendState(force: true)
            case WireMessage.windowAction:
                guard inputGranted else { return }   // changing the Mac needs control
                performWindowAction(obj)
            case WireMessage.menuRequest:
                // A pane's app menus: a control feature (reading them alone is of no use, and
                // Open Recent lists file names), so only with this session's input grant.
                guard inputGranted else { return replyMenu(obj, error: "control") }
                readMenu(obj)
            case WireMessage.menuPress:
                guard inputGranted else { return replyMenuPress(obj, ok: false, error: "control") }
                pressMenu(obj)
            default:
                break
            }
        }
    }

    // MARK: Catalog

    /// Assignment generations whose minimized/hidden window was already restored once.
    private var restoreAttempted = Set<UInt64>()

    /// Listings come from the shared browser (one identity ledger for every mode).
    private func refresh(sendCatalog: Bool) {
        guard running || sendCatalog else { return }
        browser.refresh(sendCatalog: sendCatalog)
    }

    private func apply(_ snap: WindowCatalogSnapshot) {
        snapshot = snap
        catalog = Dictionary(snap.windows.map { ($0.windowID, $0) }, uniquingKeysWith: { a, _ in a })
        followApps(snap)
        var frames: [UInt32: CGRect] = [:]
        let previousFrames = inputLock.withLock { targeting.windowFrames }
        let displayFrames = browser.displayFrames()
        for a in assignments {
            if let display = a.displayID {
                // A desktop tile: the display's bounds; gone when the display is unplugged.
                if let f = displayFrames[display] {
                    frames[a.windowID] = f
                    if tileState[a.tileID] == "closed" { setState(a.tileID, captures[a.tileID]?.hasFrame == true ? "live" : "waiting") }
                } else {
                    setState(a.tileID, "closed")
                }
                continue
            }
            guard let entry = catalog[a.windowID], entry.generation == a.windowGeneration else {
                if browser.knows(windowID: a.windowID, generation: a.windowGeneration) {
                    // Skipped by this listing only: keep it as it was.
                    if let f = previousFrames[a.windowID] { frames[a.windowID] = f }
                } else {
                    setState(a.tileID, "closed")
                }
                continue
            }
            let delivering = captures[a.tileID]?.isDelivering == true
            // The frame sizes the tile's picture even off screen. Input to a window
            // that isn't on screen is refused at press/hover time (isTopmost checks
            // the window's own current on-screen bounds).
            frames[a.windowID] = entry.frame
            if entry.availability == .offscreen {
                setState(a.tileID, delivering ? "live" : "offscreen")
                // Chosen on the receiver: bring it back on the Mac without activating its app
                // (ScreenCaptureKit can't capture a minimized window). Once per assignment.
                if !delivering, restoreAttempted.insert(a.assignmentGeneration).inserted {
                    let (pid, frame, title) = (entry.pid, entry.frame, entry.title)
                    DispatchQueue.main.async { Self.restoreQuietly(pid: pid, frame: frame, title: title) }
                    refreshSoon()
                }
            } else if tileState[a.tileID] == "offscreen" || tileState[a.tileID] == "closed" {
                setState(a.tileID, captures[a.tileID]?.hasFrame == true ? "live" : "waiting")
            }
        }
        inputLock.withLock { targeting.windowFrames = frames }
        ensureCaptures()
        sendState()
    }

    /// Tiles that follow an app track its frontmost window (dialogs and new
    /// documents included). Tiles pinned to a window never jump.
    private func followApps(_ snap: WindowCatalogSnapshot) {
        let order = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
        var changed = false
        for (i, a) in assignments.enumerated() where a.follow == .app {
            let front = order.lazy.compactMap { $0[kCGWindowNumber as String] as? UInt32 }
                .first { id in self.catalog[id]?.pid == a.pid }
            guard let front, front != a.windowID, let entry = catalog[front] else { continue }
            assignments[i].windowID = front
            assignments[i].windowGeneration = entry.generation
            assignments[i].assignmentGeneration = nextGeneration
            nextGeneration += 1
            changed = true
        }
        if changed {
            if inputLock.withLock({ targeting.update(assignments: assignments) }) { releaseHeldInput?() }
        }
    }

    // MARK: Workspace

    private func applyWorkspace(_ obj: [String: Any]) {
        let raw = obj["tiles"] as? [[String: Any]] ?? []
        let previous = Dictionary(assignments.map { ($0.tileID, $0) }, uniquingKeysWith: { a, _ in a })
        let displayFrames = browser.displayFrames()
        let result = WorkspaceRequestValidator.validate(tiles: raw, catalog: catalog, hostID: hostID, canvasPixels: canvas,
                                                        previous: previous, nextGeneration: &nextGeneration, displays: displayFrames)
        assignments = result.assignments
        rejected = result.rejected
        for id in Array(tileState.keys) where !assignments.contains(where: { $0.tileID == id }) { tileState[id] = nil }
        // Geometry from the catalog right away, so a new tile draws on the next tick.
        let knownFrames = Dictionary(assignments.compactMap { a in
            a.displayID.map { d in displayFrames[d].map { (a.windowID, $0) } } ?? catalog[a.windowID].map { (a.windowID, $0.frame) }
        }, uniquingKeysWith: { a, _ in a })
        let release = inputLock.withLock { () -> Bool in
            targeting.windowFrames.merge(knownFrames) { _, new in new }
            let r = targeting.update(assignments: assignments)
            if let focus = obj["focus"] as? String { targeting.setActive(focus) }
            return r
        }
        if release { releaseHeldInput?() }
        inputLock.withLock { keyboardCheckedAt = 0 }
        dirty = true
        ensureCaptures()
        retuneCaptures()   // zoom or tile size changed for a running capture
        sendState(force: true)
    }

    private func ensureCaptures() {
        // Stop captures whose tile is gone or now shows another window.
        for (id, capture) in captures {
            let a = assignments.first { $0.tileID == id }
            if a == nil || a?.assignmentGeneration != capture.assignmentGeneration || tileState[id] == "closed" {
                captures[id] = nil
                Self.releaseBudget(1)
                Task { await capture.stop() }
            }
        }
        guard running else { return }
        let active = inputLock.withLock { targeting.keyboardTarget?.tileID }
        for a in assignments where captures[a.tileID] == nil && tileState[a.tileID] != "closed" {
            let source = CaptureSource(window: a.displayID == nil ? snapshot?.scWindows[a.windowID] : nil,
                                       display: a.displayID.flatMap { browser.scDisplay($0) })
            guard source.window != nil || source.display != nil else { setState(a.tileID, "waiting"); continue }
            guard Self.reserveBudget() else { setState(a.tileID, "limit"); continue }
            let capture = WindowTileCapture(tileID: a.tileID, windowID: a.windowID, assignmentGeneration: a.assignmentGeneration)
            capture.onFrame = { [weak self] in
                self?.queue.async {
                    guard let self else { return }
                    self.dirty = true
                    if self.tileState[a.tileID] == "waiting" || self.tileState[a.tileID] == nil { self.setState(a.tileID, "live"); self.sendState() }
                }
            }
            capture.onStop = { [weak self] code in
                self?.queue.async {
                    guard let self, self.captures[a.tileID] === capture else { return }
                    Log.info("workspace: window capture stopped tile=\(a.tileID) code=\(code)")
                    self.captures[a.tileID] = nil
                    Self.releaseBudget(1)
                    // -3815 (no window) / closed: keep the tile, mark it. Other
                    // errors: one restart on the next refresh, never a loop
                    // that touches other tiles.
                    let gone = a.displayID.map { self.browser.displayEntry($0) == nil } ?? (self.catalog[a.windowID] == nil)
                    self.setState(a.tileID, gone ? "closed" : "failed")
                    self.sendState()
                }
            }
            captures[a.tileID] = capture
            setState(a.tileID, "waiting")
            let size = captureSize(for: a)
            let rect = cropRect(for: a)
            let fps = WorkspaceCaptureBudget.fps(isActive: a.tileID == active, tileCount: assignments.count,
                                                 streamFPS: streamFPS, available: true)
            Task { [weak self] in
                do {
                    if let display = source.display {
                        try await capture.start(display: display, size: size, fps: fps, sourceRect: rect)
                    } else if let window = source.window {
                        try await capture.start(window: window, size: size, fps: fps, sourceRect: rect)
                    }
                    // Superseded while starting (stopped, replaced): don't leave it running.
                    let current = await self?.isCurrent(capture) ?? false
                    if !current { await capture.stop() }
                } catch {
                    let code = (error as NSError).code
                    self?.queue.async {
                        guard let self, self.captures[a.tileID] === capture else { return }
                        Log.info("workspace: window capture failed to start tile=\(a.tileID) code=\(code)")
                        self.captures[a.tileID] = nil
                        Self.releaseBudget(1)
                        // -3811: minimized/hidden; retried when it comes back.
                        self.setState(a.tileID, code == -3811 ? "offscreen" : "failed")
                        self.sendState()
                    }
                }
            }
        }
        updateLiveWhole()
    }

    private func isCurrent(_ capture: WindowTileCapture) async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async { [self] in continuation.resume(returning: !stopped && captures[capture.tileID] === capture) }
        }
    }

    private func retuneCaptures() {
        let active = inputLock.withLock { targeting.keyboardTarget?.tileID }
        for a in assignments {
            guard let capture = captures[a.tileID] else { continue }
            let fps = WorkspaceCaptureBudget.fps(isActive: a.tileID == active, tileCount: assignments.count,
                                                 streamFPS: streamFPS, available: tileState[a.tileID] != "offscreen")
            let size = captureSize(for: a)
            let rect = cropRect(for: a)
            Task { await capture.update(size: size, fps: max(fps, 1), sourceRect: rect) }
        }
    }

    /// The zoomed-in part of the window in its own points, or nil for the whole window.
    /// The tile's source in global points: its window's frame, or its display's bounds.
    private func sourceFrame(_ a: WorkspaceTileAssignment) -> CGRect? {
        if let d = a.displayID { return inputLock.withLock { targeting.windowFrames[a.windowID] } ?? CGDisplayBounds(d) }
        return catalog[a.windowID]?.frame
    }

    private func cropRect(for a: WorkspaceTileAssignment) -> CGRect? {
        guard a.crop != WorkspaceCrop.full, let frame = sourceFrame(a)?.size else { return nil }
        return CGRect(x: frame.width * a.crop.x, y: frame.height * a.crop.y,
                      width: frame.width * a.crop.width, height: frame.height * a.crop.height)
    }

    private func captureSize(for a: WorkspaceTileAssignment) -> CGSize {
        let tilePx = CGSize(width: a.rect.width * canvas.width, height: a.rect.height * canvas.height)
        let whole = sourceFrame(a)?.size ?? tilePx
        // Zoomed in: the captured part is smaller, so it gets more pixels per point (up to the display's own).
        let frame = CGSize(width: whole.width * a.crop.width, height: whole.height * a.crop.height)
        let main = CGMainDisplayID(), points = CGDisplayBounds(main).width
        let scale = points > 0 ? max(Double(CGDisplayPixelsWide(main)) / points, 1) : 2
        return WorkspaceCaptureBudget.captureSize(tilePixels: tilePx, window: frame, backingScale: scale,
                                                  rotation: a.rotation, fit: a.crop != WorkspaceCrop.full ? .fill : a.fit)
    }

    private func setState(_ tile: String, _ state: String) { tileState[tile] = state }

    private func sendState(force: Bool = false) {
        let (t, decision) = inputLock.withLock { (targeting, keyboardDecision) }
        let tiles: [[String: Any]] = assignments.map { a in
            let entry = catalog[a.windowID]
            var tile: [String: Any] = [
                "id": a.tileID, "window": Int(a.windowID), "gen": Int(a.windowGeneration),
                "state": tileState[a.tileID] ?? "waiting", "app": entry?.appName ?? "", "bundle": a.bundleID,
                "title": String((entry?.title ?? "").prefix(120)), "follow": a.follow.rawValue,
                "rotation": a.rotation.rawValue, "fit": a.fit.rawValue, "crop": [a.crop.x, a.crop.y, a.crop.width, a.crop.height],
            ]
            if let d = a.displayID {
                tile["display"] = Int(d)
                tile["app"] = "Desktop"
                tile["title"] = String((browser.displayEntry(d)?.name ?? "").prefix(120))
            }
            return tile
        }
        var msg: [String: Any] = [
            "type": WireMessage.workspaceState, "host": hostID, "tiles": tiles,
            "hostFocus": decision.rawValue, "canvas": [Int(canvas.width), Int(canvas.height)],
            "limit": WorkspaceLayout.maximumTiles,
        ]
        if let active = t.keyboardTarget?.tileID { msg["active"] = active }
        if !rejected.isEmpty { msg["rejected"] = rejected }
        let key = (try? JSONSerialization.data(withJSONObject: msg, options: [.sortedKeys])).map { String(decoding: $0, as: UTF8.self) } ?? ""
        guard force || key != lastStateSent else { return }
        lastStateSent = key
        sendMessage?(msg)
    }

    // MARK: Window actions (need this session's input grant)

    private func performWindowAction(_ obj: [String: Any]) {
        guard let action = obj["action"] as? String else { return }
        switch action {
        case "activate":
            guard let id = (obj["window"] as? Int).flatMap({ UInt32(exactly: $0) }), let entry = catalog[id],
                  (obj["gen"] as? Int).flatMap({ UInt64(exactly: $0) }) == entry.generation else { return }
            Self.raise(pid: entry.pid, frame: entry.frame)
        case "launch":
            guard let bundle = obj["bundle"] as? String else { return }
            AppCatalog.shared.launch(bundle) { _ in }   // without activating: no focus steal
            refreshSoon()
        case "minimize":
            // Minimizes the real Mac window (explicit, confirmed by gen: a reused id is never touched).
            guard let id = (obj["window"] as? Int).flatMap({ UInt32(exactly: $0) }), let entry = catalog[id],
                  (obj["gen"] as? Int).flatMap({ UInt64(exactly: $0) }) == entry.generation else { return }
            let (pid, frame, title) = (entry.pid, entry.frame, entry.title)
            DispatchQueue.main.async { Self.minimize(pid: pid, frame: frame, title: title) }
            refreshSoon()
        case "close":
            // Closes the real Mac window: a separate, explicit action, never a
            // side effect of removing a tile.
            guard let id = (obj["window"] as? Int).flatMap({ UInt32(exactly: $0) }), let entry = catalog[id],
                  (obj["gen"] as? Int).flatMap({ UInt64(exactly: $0) }) == entry.generation else { return }
            Self.pressClose(pid: entry.pid, frame: entry.frame, title: entry.title)
            refreshSoon()
        default:
            break
        }
    }

    // MARK: Pane menus (PROTOCOL.md 6.13)

    /// The app shown in a tile (a window tile, not a desktop).
    private func menuApp(_ obj: [String: Any]) -> (tile: String, pid: Int32, windowID: UInt32)? {
        guard let tile = obj["tile"] as? String,
              let a = assignments.first(where: { $0.tileID == tile }), !WorkspaceSource.isDisplayKey(a.windowID), a.pid > 0 else { return nil }
        return (tile, a.pid, a.windowID)
    }

    private func menuPath(_ obj: [String: Any]) -> [Int]? {
        let path = (obj["path"] as? [Int]) ?? []
        return path.count < AppMenuReader.maxDepth && path.allSatisfy({ $0 >= 0 && $0 < 500 }) && (path.first.map { $0 >= 1 } ?? true) ? path : nil
    }

    private func replyMenu(tile: String?, path: [Int], req: Int?, error: String) {
        var m: [String: Any] = ["type": WireMessage.menu, "ok": false, "error": error, "path": path]
        if let tile { m["tile"] = String(tile.prefix(32)) }
        if let req { m["req"] = req }
        sendMessage?(m)
    }

    private func replyMenu(_ obj: [String: Any], error: String) {
        replyMenu(tile: obj["tile"] as? String, path: (obj["path"] as? [Int]) ?? [], req: obj["req"] as? Int, error: error)
    }

    private func readMenu(_ obj: [String: Any]) {
        guard let target = menuApp(obj), let path = menuPath(obj) else { return replyMenu(obj, error: "notFound") }
        let req = obj["req"] as? Int
        // AX calls can block for the messaging timeout: never on the engine's queue.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = AppMenuReader.items(pid: target.pid, path: path)
            let trusted = AXIsProcessTrusted()
            let app = result.map { String($0.app.prefix(80)) } ?? ""
            let items = MenuItemsBox(value: result?.items.map(\.wire) ?? [])
            let found = result != nil
            self?.queue.async {
                guard let self, self.running, !self.stopped else { return }
                guard found else { return self.replyMenu(tile: target.tile, path: path, req: req, error: trusted ? "unavailable" : "accessibility") }
                var m: [String: Any] = ["type": WireMessage.menu, "ok": true, "tile": target.tile, "path": path,
                                        "app": app, "items": items.value]
                if let req { m["req"] = req }
                self.sendMessage?(m)
            }
        }
    }

    private func replyMenuPress(req: Int?, ok: Bool, error: String? = nil) {
        var m: [String: Any] = ["type": WireMessage.menuResult, "ok": ok]
        if let error { m["error"] = error }
        if let req { m["req"] = req }
        sendMessage?(m)
    }

    private func replyMenuPress(_ obj: [String: Any], ok: Bool, error: String? = nil) {
        replyMenuPress(req: obj["req"] as? Int, ok: ok, error: error)
    }

    /// Presses one menu item of a pane's app. Like a click in that pane, its window comes
    /// to the front first, so the command acts on the window the pane shows.
    private func pressMenu(_ obj: [String: Any]) {
        let path = (obj["path"] as? [Int]) ?? []
        let titles = ((obj["titles"] as? [String]) ?? []).map { String($0.prefix(120)) }
        let req = obj["req"] as? Int
        guard let target = menuApp(obj), AppMenuReader.isValidPath(path, titles: titles), path.count >= 2 else {
            return replyMenuPress(req: req, ok: false, error: "notFound")
        }
        let frame = catalog[target.windowID]?.frame ?? inputLock.withLock { targeting.windowFrames[target.windowID] } ?? .zero
        DispatchQueue.main.async { [weak self] in
            if frame != .zero { Self.raise(pid: target.pid, frame: frame) }
            let ok = AppMenuReader.press(pid: target.pid, path: path, titles: titles)
            Log.info("workspace: menu item pressed ok=\(ok) depth=\(path.count)")
            self?.queue.async {
                self?.replyMenuPress(req: req, ok: ok, error: ok ? nil : "changed")
                self?.refreshSoon()
            }
        }
    }

    private func refreshSoon() {
        queue.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.refresh(sendCatalog: true) }
        queue.asyncAfter(deadline: .now() + 1.6) { [weak self] in self?.refresh(sendCatalog: true) }
    }

    // MARK: InputTargetMapper (network queue, under the injector's lock)

    func mapPointer(phase: InputMapPhase, x: Double?, y: Double?, dx: Double, dy: Double) -> CGPoint? {
        inputLock.lock()
        defer { inputLock.unlock() }
        let p = WorkspacePoint(x: x ?? 0, y: y ?? 0)
        let target: WorkspaceInputTargeting.Target?
        switch phase {
        case .down: target = x == nil ? targeting.resolveAtPointer(.down) : targeting.resolve(.down, at: p)
        case .drag, .hover: target = x == nil ? targeting.resolveRelative(dx: dx, dy: dy) : targeting.resolve(.move, at: p)
        case .up: target = x == nil ? targeting.resolveAtPointer(.up) : targeting.resolve(.up, at: p)
        case .scroll: target = targeting.resolveAtPointer(.scroll)
        }
        guard var target else { return nil }
        if phase == .up { return target.point }   // a release always goes through
        if WorkspaceSource.isDisplayKey(target.windowID) {
            // A desktop tile: input lands wherever it is on that display, as in Mirror. Nothing
            // is raised or activated first, and there is no window to be covered.
            return target.point
        }
        if phase == .down || phase == .scroll {
            // The window may have moved since the last refresh: map against its
            // current frame, and only while it is on screen.
            guard let fresh = Self.currentFrame(target.windowID) else {
                if phase == .down { targeting.cancelBinding() }
                return nil
            }
            if fresh != targeting.windowFrames[target.windowID] {
                targeting.windowFrames[target.windowID] = fresh
                // Re-map at the same pointer (a bound press stays bound to its tile).
                let again = x == nil ? targeting.resolveAtPointer(.scroll) : targeting.resolve(.scroll, at: p)
                guard let again else { if phase == .down { targeting.cancelBinding() }; return nil }
                target.point = again.point
            }
        }
        if phase == .down, !target.activates, !isTopmost(target.windowID, at: target.point, cached: false) {
            // The active tile's window was covered on the Mac since (someone
            // clicked another app there): a press in its tile brings it back,
            // as a press on another tile does.
            target.activates = true
        }
        if target.activates {
            Self.raise(pid: target.pid, frame: targeting.windowFrames[target.windowID] ?? .zero)
            keyboardCheckedAt = 0
            queue.async { [weak self] in self?.retuneCaptures(); self?.sendState(force: true) }
            // Bounded wait for the window to come to the front, so the press
            // that activated it is delivered once, to it.
            let deadline = ProcessInfo.processInfo.systemUptime + 0.25
            while !isTopmost(target.windowID, at: target.point, cached: false), ProcessInfo.processInfo.systemUptime < deadline {
                usleep(10_000)
            }
        }
        guard isTopmost(target.windowID, at: target.point, cached: phase == .hover || phase == .drag) else {
            // Something covers the window here (another app, a panel): send
            // nothing rather than click into the wrong window.
            if phase == .down { targeting.cancelBinding() }
            return nil
        }
        return target.point
    }

    /// The window's current on-screen frame, or nil when it isn't on screen.
    static func currentFrame(_ windowID: UInt32) -> CGRect? {
        guard let info = (CGWindowListCopyWindowInfo([.optionIncludingWindow], windowID) as? [[String: Any]])?.first,
              (info[kCGWindowIsOnscreen as String] as? Bool) == true,
              let dict = info[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: dict) else { return nil }
        return bounds
    }

    func scrollVector(dx: Double, dy: Double) -> CGVector {
        inputLock.withLock { targeting.sourceVector(dx: dx, dy: dy) }
    }

    func locate(x: Double, y: Double) -> CGPoint? {
        inputLock.withLock { targeting.globalPoint(at: WorkspacePoint(x: x, y: y)) }
    }

    func keyboardTargetReady() -> Bool {
        inputLock.lock()
        defer { inputLock.unlock() }
        let now = ProcessInfo.processInfo.systemUptime
        let active = inputLock.withLock { targeting.keyboardTarget }
        if now - keyboardCheckedAt > 0.2 {
            keyboardCheckedAt = now
            let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
            var focusedID: UInt32?
            var isChild = false
            if let active, frontPID == active.pid, let info = Self.focusedWindow(pid: active.pid) {
                isChild = info.isChild
                focusedID = WorkspaceKeyboardGate.focusedTileWindow(
                    active: active.windowID, focusedFrame: info.frame, isChild: info.isChild,
                    frames: inputLock.withLock { targeting.windowFrames }, matches: Self.framesMatch)
            }
            let decision = WorkspaceKeyboardGate.decide(active: active, frontmostPID: frontPID, focusedWindowID: focusedID,
                                                        focusedWindowIsChild: isChild)
            if decision != keyboardDecision {
                keyboardDecision = decision
                queue.async { [weak self] in self?.sendState(force: true) }
            }
        }
        return keyboardDecision == .deliver
    }

    func cursorCanvasPoint(forGlobal g: CGPoint) -> WorkspacePoint? {
        inputLock.withLock { targeting.canvasPoint(forGlobal: g) }
    }

    /// The focused text caret (global points) in normalized canvas
    /// coordinates, when it is in the window being typed into.
    func caretCanvasRect(forGlobal g: CGRect) -> CGRect? {
        inputLock.withLock { targeting.canvasCaretRect(forGlobal: g) }
    }

    private func activateBounded(_ a: WorkspaceTileAssignment) {
        guard a.displayID == nil, let frame = inputLock.withLock({ targeting.windowFrames[a.windowID] }) else { return }
        Self.raise(pid: a.pid, frame: frame)
    }

    /// Is `windowID` the frontmost window at `point`? Windows above it that
    /// contain the point (other apps, panels, menus, the Dock) mean no.
    private func isTopmost(_ windowID: UInt32, at point: CGPoint, cached: Bool) -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        if cached, let c = topmostCache[windowID], now - c.at < 0.1, c.rect.contains(point) { return c.ok }
        guard let above = CGWindowListCopyWindowInfo([.optionOnScreenAboveWindow], windowID) as? [[String: Any]] else { return false }
        var covering: CGRect?
        for info in above {
            guard let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict),
                  ((info[kCGWindowAlpha as String] as? Double) ?? 1) > 0.01,
                  (info[kCGWindowOwnerName as String] as? String) != "Window Server" else { continue }
            if bounds.contains(point) { covering = bounds; break }
        }
        // The point must also be inside the target itself, on screen.
        let ok = covering == nil && (Self.currentFrame(windowID)?.contains(point) ?? false)
        let around = CGRect(x: point.x - 40, y: point.y - 40, width: 80, height: 80)
        // Cached only as "covered by this window" or "fine near here"; outside the
        // target (or off screen) is never cached, so it is re-checked every time.
        if ok {
            topmostCache[windowID] = (now, around, true)
        } else if let covering {
            topmostCache[windowID] = (now, covering, false)
        } else {
            topmostCache[windowID] = nil
        }
        return ok
    }

    // MARK: Accessibility helpers

    static func framesMatch(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) <= 2 && abs(a.minY - b.minY) <= 2 && abs(a.width - b.width) <= 2 && abs(a.height - b.height) <= 2
    }

    private static func axFrame(_ element: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?, sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let posRef, let sizeRef else { return nil }
        var pos = CGPoint.zero, size = CGSize.zero
        // swiftlint:disable force_cast
        AXValueGetValue(posRef as! AXValue, .cgPoint, &pos)
        AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)
        // swiftlint:enable force_cast
        return CGRect(origin: pos, size: size)
    }

    private static func axWindow(pid: Int32, frame: CGRect) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.15)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return nil }
        return windows.first { axFrame($0).map { framesMatch($0, frame) } ?? false }
    }

    /// Bring one specific window to the front (AXRaise + activate its app).
    /// Bounded by the AX messaging timeout; an unresponsive app just fails.
    @discardableResult
    static func raise(pid: Int32, frame: CGRect) -> Bool {
        guard AXIsProcessTrusted() else { return false }
        let window = axWindow(pid: pid, frame: frame)
        if let window { AXUIElementPerformAction(window, kAXRaiseAction as CFString) }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.15)
        AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        NSRunningApplication(processIdentifier: pid)?.activate()
        return window != nil
    }

    /// Only an unambiguous match: one AX window with this frame (and title).
    /// Unhides the app (without activating it) and un-minimizes the one matching window.
    static func restoreQuietly(pid: Int32, frame: CGRect, title: String) {
        if let app = NSRunningApplication(processIdentifier: pid), app.isHidden {
            app.unhide()
            Log.info("workspace: unhid app pid=\(pid) for a tile")
        }
        guard AXIsProcessTrusted() else { return }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.15)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return }
        let minimized = windows.filter { w in
            var m: CFTypeRef?
            guard AXUIElementCopyAttributeValue(w, kAXMinimizedAttribute as CFString, &m) == .success, (m as? Bool) == true else { return false }
            var t: CFTypeRef?
            AXUIElementCopyAttributeValue(w, kAXTitleAttribute as CFString, &t)
            return title.isEmpty || (t as? String) == title
        }
        // Prefer the exact frame; a single minimized candidate is unambiguous.
        let byFrame = minimized.filter { w in axFrame(w).map { framesMatch($0, frame) } ?? false }
        guard let window = byFrame.count == 1 ? byFrame.first : (minimized.count == 1 ? minimized.first : nil) else {
            Log.info("workspace: restore skipped, \(minimized.count) minimized candidates")
            return
        }
        AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        Log.info("workspace: restored a minimized window pid=\(pid) for a tile")
    }

    static func pressClose(pid: Int32, frame: CGRect, title: String) {
        guard AXIsProcessTrusted() else { return }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.15)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return }
        let matches = windows.filter { w in
            guard let f = axFrame(w), framesMatch(f, frame) else { return false }
            var t: CFTypeRef?
            AXUIElementCopyAttributeValue(w, kAXTitleAttribute as CFString, &t)
            return title.isEmpty || (t as? String) == title
        }
        guard matches.count == 1, let window = matches.first else {
            Log.info("workspace: close refused, \(matches.count) matching windows")
            return
        }
        var button: CFTypeRef?
        if AXUIElementCopyAttributeValue(window, kAXCloseButtonAttribute as CFString, &button) == .success, let button {
            // swiftlint:disable:next force_cast
            AXUIElementPerformAction(button as! AXUIElement, kAXPressAction as CFString)
        }
    }

    /// Minimizes the one window with this frame and title (Minimize on Mac). Never activates its app.
    static func minimize(pid: Int32, frame: CGRect, title: String) {
        guard AXIsProcessTrusted() else { return }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.15)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return }
        let matches = windows.filter { w in
            guard let f = axFrame(w), framesMatch(f, frame) else { return false }
            var t: CFTypeRef?
            AXUIElementCopyAttributeValue(w, kAXTitleAttribute as CFString, &t)
            return title.isEmpty || (t as? String) == title
        }
        guard matches.count == 1, let window = matches.first else {
            Log.info("workspace: minimize refused, \(matches.count) matching windows")
            return
        }
        AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
    }

    private static func focusedWindow(pid: Int32) -> (frame: CGRect, isChild: Bool)? {
        guard AXIsProcessTrusted() else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.1)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &value) == .success, let value else { return nil }
        // swiftlint:disable:next force_cast
        let window = value as! AXUIElement
        guard let frame = axFrame(window) else { return nil }
        var subrole: CFTypeRef?
        AXUIElementCopyAttributeValue(window, kAXSubroleAttribute as CFString, &subrole)
        let s = subrole as? String ?? ""
        let child = s == (kAXDialogSubrole as String) || s == (kAXSystemDialogSubrole as String) || s == (kAXFloatingWindowSubrole as String)
        return (frame, child)
    }

    // MARK: Budget

    private static func reserveBudget() -> Bool {
        budgetLock.withLock {
            guard globalCaptures < globalCaptureLimit else { return false }
            globalCaptures += 1
            return true
        }
    }

    private static func releaseBudget(_ n: Int) {
        budgetLock.withLock { globalCaptures = max(globalCaptures - n, 0) }
    }
}

private struct MenuItemsBox: @unchecked Sendable { let value: [[String: Any]] }
