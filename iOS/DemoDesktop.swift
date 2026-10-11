import CoreGraphics
import Foundation

// MARK: - Demo desktop model
//
// The interactive part of Demo Mode, kept free of UIKit/SwiftUI so the unit
// tests drive the same gesture sequences the screen does. Geometry and
// gesture policy reuse the real receiver's pure models
// (`RemoteViewportCalculator`, `ManualViewportState`,
// `ViewportNavigationSession`, `TwoFingerGestureSession`,
// `TwoFingerRoutingPolicy`, `ExtendDisplayShapePreference`). Nothing here can
// reach a network or a store: every effect lands in this value or is
// returned as `DemoFeedback` for the screen to show.

/// What one demo interaction did, for the screen's feedback chip.
enum DemoFeedback: Equatable {
    /// Happened here, on the sample desktop.
    case local(String)
    /// A key combination a real session would send to the Mac.
    case macShortcut(usage: Int, modifiers: [String])
    /// A semantic Mac action (`ReceiverGesture` raw value).
    case macGesture(String)
    /// An App Gesture Command a real session would send.
    case macAppCommand(AppGestureCommandKind)
    /// A two-finger tap: a secondary click on the Mac.
    case macSecondaryClick
    /// Typing with no sample field focused.
    case macTyping
    /// An on-screen modifier held for the next key.
    case modifierHeld(ControlModifier)
    /// A touch was meant for the Mac while Allow Input is off.
    case inputOff
    /// A pinch or rotation that Settings turns off.
    case gestureOff(String)
}

/// Sample windows. A small, fixed set: each one exists to show a behavior.
enum DemoWindowKind: String, CaseIterable, Identifiable {
    case notes
    case files
    case preview
    case arrangement

    var id: String { rawValue }
}

struct DemoWindow: Identifiable, Equatable {
    let kind: DemoWindowKind
    /// Desktop points, top-left origin.
    var frame: CGRect
    var scrollOffset: CGFloat = 0
    var id: DemoWindowKind { kind }
}

struct DemoFile: Identifiable, Equatable {
    let id: String
    let name: String
    let symbol: String
    let detail: String

    static let samples: [DemoFile] = [
        DemoFile(id: "plan", name: "Project Plan", symbol: "doc.text", detail: "Text · 4 KB"),
        DemoFile(id: "sketch", name: "Interface Sketch", symbol: "pencil.and.outline", detail: "Drawing · 1.2 MB"),
        DemoFile(id: "chart", name: "Weekly Chart", symbol: "chart.bar", detail: "Chart · 88 KB"),
        DemoFile(id: "photo", name: "Desk Photo", symbol: "photo", detail: "Image · 2.4 MB"),
        DemoFile(id: "slides", name: "Team Slides", symbol: "rectangle.on.rectangle", detail: "Slides · 6.1 MB"),
        DemoFile(id: "recording", name: "Voice Memo", symbol: "waveform", detail: "Audio · 3.0 MB"),
        DemoFile(id: "budget", name: "Budget", symbol: "tablecells", detail: "Table · 120 KB"),
        DemoFile(id: "archive", name: "Old Drafts", symbol: "archivebox", detail: "Folder · 12 items"),
        DemoFile(id: "map", name: "Route Map", symbol: "map", detail: "Image · 900 KB"),
        DemoFile(id: "readme", name: "Read Me", symbol: "doc.plaintext", detail: "Text · 2 KB"),
    ]
}

/// Where a desktop point lands.
enum DemoHit: Equatable {
    case menuBar
    case dock(DemoWindowKind)
    case close(DemoWindowKind)
    case titleBar(DemoWindowKind)
    case fileRow(DemoWindowKind, String)
    case arrangementDisplay(Int)
    case content(DemoWindowKind)
    case desktop
}

struct DemoDesktop: Equatable {
    static let longEdge: CGFloat = 960
    static let menuBarHeight: CGFloat = 24
    static let titleBarHeight: CGFloat = 28
    static let rowHeight: CGFloat = 30
    static let dockHeight: CGFloat = 56
    static let dockItemSize: CGFloat = 44
    static let notesLineHeight: CGFloat = 22
    static let initialNotes = """
        Welcome to MeowDisplay.

        This sample desktop runs on this device, so you can try the controls without a Mac.

        Tap or click to focus a window. Drag a title bar to move it. Scroll the Files list. Double-click a file to preview it.

        Open the keyboard to type here.
        """

    private(set) var mode: ReceiverDisplayMode
    private(set) var size: CGSize
    /// Back to front.
    private(set) var windows: [DemoWindow]
    private(set) var focused: DemoWindowKind?
    private(set) var selectedFile: String?
    private(set) var previewFile: String = DemoFile.samples[0].id
    private(set) var previewZoom: CGFloat = 1
    private(set) var notes = Self.initialNotes
    private(set) var highlightedDisplay = 1
    private(set) var showingDesktop = false
    private var undoStack: [String] = []
    private var redoStack: [String] = []

    init(mode: ReceiverDisplayMode, size: CGSize) {
        self.mode = mode
        self.size = size
        windows = Self.layout(for: mode, size: size)
        focused = windows.last?.kind
    }

    /// Desktop size for an aspect ratio (width / height), long edge fixed.
    static func size(forAspect aspect: Double) -> CGSize {
        let aspect = aspect.isFinite && aspect > 0 ? CGFloat(aspect) : 1.6
        return aspect >= 1
            ? CGSize(width: longEdge, height: (longEdge / aspect).rounded())
            : CGSize(width: (longEdge * aspect).rounded(), height: longEdge)
    }

    var hasDock: Bool { mode == .mirror }
    var visibleWindows: [DemoWindow] { showingDesktop ? [] : windows }

    func window(_ kind: DemoWindowKind) -> DemoWindow? { windows.first { $0.kind == kind } }

    // MARK: Layout

    static func windowKinds(for mode: ReceiverDisplayMode) -> [DemoWindowKind] {
        mode == .mirror ? [.files, .preview, .notes] : [.arrangement, .notes, .preview]
    }

    /// Initial frames, back to front. Landscape-ish desktops place windows
    /// side by side; tall ones stack them.
    static func layout(for mode: ReceiverDisplayMode, size: CGSize) -> [DemoWindow] {
        let top = menuBarHeight + 12
        let bottom = size.height - (mode == .mirror ? dockHeight + 16 : 12)
        let usable = CGRect(x: 12, y: top, width: size.width - 24, height: max(bottom - top, 120))
        let kinds = windowKinds(for: mode)
        var frames: [DemoWindowKind: CGRect] = [:]
        if size.width >= size.height * 1.15 {
            let w = usable.width, h = usable.height
            switch mode {
            case .mirror:
                frames[.notes] = CGRect(x: usable.minX, y: usable.minY, width: w * 0.46, height: h * 0.78)
                frames[.files] = CGRect(x: usable.minX + w * 0.5, y: usable.minY, width: w * 0.5, height: h * 0.52)
                frames[.preview] = CGRect(x: usable.minX + w * 0.42, y: usable.minY + h * 0.4, width: w * 0.5, height: h * 0.6)
            case .extend:
                frames[.preview] = CGRect(x: usable.minX, y: usable.minY, width: w * 0.58, height: h * 0.9)
                frames[.notes] = CGRect(x: usable.minX + w * 0.6, y: usable.minY + h * 0.36, width: w * 0.4, height: h * 0.64)
                frames[.arrangement] = CGRect(x: usable.minX + w * 0.6, y: usable.minY, width: w * 0.4, height: h * 0.34)
            }
        } else {
            let gap: CGFloat = 10
            let h = (usable.height - gap * 2) / 3
            for (index, kind) in kinds.reversed().enumerated() {
                frames[kind] = CGRect(x: usable.minX, y: usable.minY + CGFloat(index) * (h + gap),
                                      width: usable.width, height: h)
            }
        }
        return kinds.map { DemoWindow(kind: $0, frame: frames[$0]!.integral) }
    }

    /// New mode or desktop size: a fresh arrangement for that desktop, with
    /// the text, selection and preview carried over.
    mutating func reconfigure(mode: ReceiverDisplayMode, size: CGSize) {
        guard mode != self.mode || size != self.size else { return }
        self.mode = mode
        self.size = size
        windows = Self.layout(for: mode, size: size)
        if let focused, windows.contains(where: { $0.kind == focused }) { raise(focused) } else {
            focused = windows.last?.kind
        }
        showingDesktop = false
    }

    mutating func resetLayout() {
        windows = Self.layout(for: mode, size: size)
        focused = windows.last?.kind
        showingDesktop = false
        previewZoom = 1
    }

    // MARK: Hit testing

    func dockFrames() -> [(DemoWindowKind, CGRect)] {
        guard hasDock else { return [] }
        let kinds: [DemoWindowKind] = [.notes, .files, .preview]
        let spacing: CGFloat = 10
        let total = CGFloat(kinds.count) * Self.dockItemSize + CGFloat(kinds.count - 1) * spacing
        let originX = (size.width - total) / 2
        let y = size.height - Self.dockHeight + (Self.dockHeight - Self.dockItemSize) / 2 - 6
        return kinds.enumerated().map { index, kind in
            (kind, CGRect(x: originX + CGFloat(index) * (Self.dockItemSize + spacing), y: y,
                          width: Self.dockItemSize, height: Self.dockItemSize))
        }
    }

    static func closeButtonFrame(in frame: CGRect) -> CGRect {
        CGRect(x: frame.minX + 8, y: frame.minY + 7, width: 14, height: 14).insetBy(dx: -6, dy: -6)
    }

    func arrangementFrames(in frame: CGRect) -> [CGRect] {
        let content = CGRect(x: frame.minX + 16, y: frame.minY + Self.titleBarHeight + 34,
                             width: frame.width - 32, height: max(frame.height - Self.titleBarHeight - 46, 30))
        let mac = CGRect(x: content.minX, y: content.minY + 6, width: content.width * 0.52, height: content.height - 12)
        let device = CGRect(x: mac.maxX + 8, y: content.minY + content.height * 0.2,
                            width: content.width - mac.width - 8, height: content.height * 0.6)
        return [mac, device]
    }

    func hit(_ point: CGPoint) -> DemoHit {
        if point.y < Self.menuBarHeight { return .menuBar }
        for (kind, frame) in dockFrames() where frame.insetBy(dx: -4, dy: -4).contains(point) { return .dock(kind) }
        for window in visibleWindows.reversed() where window.frame.contains(point) {
            if Self.closeButtonFrame(in: window.frame).contains(point) { return .close(window.kind) }
            if point.y < window.frame.minY + Self.titleBarHeight { return .titleBar(window.kind) }
            switch window.kind {
            case .files:
                let y = point.y - window.frame.minY - Self.titleBarHeight + window.scrollOffset
                let index = Int(y / Self.rowHeight)
                if DemoFile.samples.indices.contains(index) { return .fileRow(.files, DemoFile.samples[index].id) }
            case .arrangement:
                if let index = arrangementFrames(in: window.frame).firstIndex(where: { $0.contains(point) }) {
                    return .arrangementDisplay(index)
                }
            case .notes, .preview:
                break
            }
            return .content(window.kind)
        }
        return .desktop
    }

    // MARK: Actions

    mutating func raise(_ kind: DemoWindowKind) {
        guard let index = windows.firstIndex(where: { $0.kind == kind }) else { return }
        windows.append(windows.remove(at: index))
        focused = kind
    }

    /// One click (or tap) at a desktop point.
    mutating func click(at point: CGPoint) -> DemoFeedback? {
        switch hit(point) {
        case .menuBar:
            return .macGesture(ReceiverGesture.menuBar.rawValue)
        case .dock(let kind):
            showingDesktop = false
            if window(kind) == nil {
                windows.append(Self.layout(for: mode, size: size).first { $0.kind == kind }
                                ?? DemoWindow(kind: kind, frame: CGRect(x: 40, y: 60, width: 320, height: 240)))
            }
            raise(kind)
            return .local(String(localized: "Opened \(Self.title(kind))"))
        case .close(let kind):
            windows.removeAll { $0.kind == kind }
            focused = windows.last?.kind
            return .local(String(localized: "Closed \(Self.title(kind))"))
        case .titleBar(let kind), .content(let kind):
            raise(kind)
            return nil
        case .fileRow(let kind, let id):
            raise(kind)
            selectedFile = id
            return nil
        case .arrangementDisplay(let index):
            raise(.arrangement)
            highlightedDisplay = index
            return nil
        case .desktop:
            if showingDesktop { showingDesktop = false; return .local(String(localized: "Windows restored")) }
            focused = nil
            selectedFile = nil
            return nil
        }
    }

    /// A double-click: opens a file in Preview, or zooms Preview.
    mutating func doubleClick(at point: CGPoint) -> DemoFeedback? {
        switch hit(point) {
        case .fileRow(_, let id):
            selectedFile = id
            previewFile = id
            if window(.preview) == nil {
                windows.append(Self.layout(for: mode, size: size).first { $0.kind == .preview }
                                ?? DemoWindow(kind: .preview, frame: CGRect(x: 60, y: 60, width: 360, height: 260)))
            }
            raise(.preview)
            return .local(String(localized: "Opened \(DemoFile.samples.first { $0.id == id }?.name ?? "")"))
        case .content(.preview):
            raise(.preview)
            previewZoom = previewZoom > 1 ? 1 : 1.6
            return .local(previewZoom > 1 ? String(localized: "Zoomed in") : String(localized: "Actual size"))
        default:
            return click(at: point)
        }
    }

    /// Moves a window by its title bar, keeping the bar reachable.
    mutating func moveWindow(_ kind: DemoWindowKind, by delta: CGVector) {
        guard let index = windows.firstIndex(where: { $0.kind == kind }) else { return }
        var frame = windows[index].frame.offsetBy(dx: delta.dx, dy: delta.dy)
        frame.origin.x = min(max(frame.minX, 40 - frame.width), size.width - 40)
        frame.origin.y = min(max(frame.minY, Self.menuBarHeight), size.height - Self.titleBarHeight)
        windows[index].frame = frame
    }

    func contentHeight(_ kind: DemoWindowKind) -> CGFloat {
        switch kind {
        case .files: return CGFloat(DemoFile.samples.count) * Self.rowHeight + 8
        case .notes: return CGFloat(notes.components(separatedBy: "\n").count + 6) * Self.notesLineHeight
        case .preview, .arrangement: return 0
        }
    }

    func maxScroll(_ kind: DemoWindowKind) -> CGFloat {
        guard let window = window(kind) else { return 0 }
        return max(contentHeight(kind) - (window.frame.height - Self.titleBarHeight), 0)
    }

    /// Scrolls the window under `point` by `dy` content points. Returns
    /// whether anything scrolled.
    @discardableResult
    mutating func scroll(at point: CGPoint, dy: CGFloat) -> Bool {
        let kind: DemoWindowKind
        switch hit(point) {
        case .titleBar(let k), .content(let k), .fileRow(let k, _), .close(let k): kind = k
        default: return false
        }
        guard let index = windows.firstIndex(where: { $0.kind == kind }) else { return false }
        let limit = maxScroll(kind)
        let next = min(max(windows[index].scrollOffset + dy, 0), limit)
        guard next != windows[index].scrollOffset else { return false }
        windows[index].scrollOffset = next
        return true
    }

    // MARK: Keys and text

    mutating func type(_ text: String) -> Bool {
        guard focused == .notes, window(.notes) != nil, !text.isEmpty else { return false }
        record()
        notes += text
        return true
    }

    mutating func deleteBackward() -> Bool {
        guard focused == .notes, !notes.isEmpty else { return false }
        record()
        notes.removeLast()
        return true
    }

    private mutating func record() {
        undoStack.append(notes)
        if undoStack.count > 50 { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    mutating func undo() -> Bool {
        guard let previous = undoStack.popLast() else { return false }
        redoStack.append(notes)
        notes = previous
        return true
    }

    mutating func redo() -> Bool {
        guard let next = redoStack.popLast() else { return false }
        undoStack.append(notes)
        notes = next
        return true
    }

    /// Ordinary keys, as HID usages with modifier names. Returns what
    /// happened locally, or `nil` when only a Mac could act on it.
    mutating func key(usage: Int, modifiers: [String]) -> DemoFeedback? {
        let mods = Set(modifiers)
        switch (usage, mods) {
        case (29, ["command"]):
            return undo() ? .local(String(localized: "Undo")) : .local(String(localized: "Nothing to undo"))
        case (29, ["command", "shift"]):
            return redo() ? .local(String(localized: "Redo")) : .local(String(localized: "Nothing to redo"))
        case (46, ["command"]) where focused == .preview:
            previewZoom = min(previewZoom + 0.25, 2.5)
            return .local(String(localized: "Preview zoomed in"))
        case (45, ["command"]) where focused == .preview:
            previewZoom = max(previewZoom - 0.25, 0.5)
            return .local(String(localized: "Preview zoomed out"))
        case (26, ["command"]):
            guard let focused else { return nil }
            windows.removeAll { $0.kind == focused }
            self.focused = windows.last?.kind
            return .local(String(localized: "Closed \(Self.title(focused))"))
        case (43, []):
            guard !windows.isEmpty else { return nil }
            raise(windows[0].kind)
            return .local(String(localized: "Focused \(Self.title(focused ?? .notes))"))
        case (41, []):
            if showingDesktop { showingDesktop = false; return .local(String(localized: "Windows restored")) }
            selectedFile = nil
            return .local(String(localized: "Selection cleared"))
        case (42, []):
            return deleteBackward() ? .local(String(localized: "Deleted")) : nil
        case (40, []):
            return type("\n") ? .local(String(localized: "New line")) : nil
        case (81, []), (82, []):
            guard focused == .files else { return nil }
            let ids = DemoFile.samples.map(\.id)
            let current = selectedFile.flatMap { ids.firstIndex(of: $0) } ?? -1
            let next = min(max(current + (usage == 81 ? 1 : -1), 0), ids.count - 1)
            selectedFile = ids[next]
            return .local(String(localized: "Selected \(DemoFile.samples[next].name)"))
        default:
            if mods.isEmpty || mods == ["shift"], let character = Self.character(usage: usage, shift: mods.contains("shift")),
               type(character) {
                return .local(String(localized: "Typed in Notes"))
            }
            return nil
        }
    }

    mutating func toggleShowDesktop() -> DemoFeedback {
        showingDesktop.toggle()
        return .local(showingDesktop ? String(localized: "Showing the desktop") : String(localized: "Windows restored"))
    }

    static func character(usage: Int, shift: Bool) -> String? {
        switch usage {
        case 4...29:
            let scalar = UnicodeScalar(UInt8(usage - 4) + (shift ? 65 : 97))
            return String(Character(scalar))
        case 30...38: return String(usage - 29)
        case 39: return "0"
        case 44: return " "
        default: return nil
        }
    }

    static func title(_ kind: DemoWindowKind) -> String {
        switch kind {
        case .notes: return String(localized: "Notes")
        case .files: return String(localized: "Files")
        case .preview: return String(localized: "Preview")
        case .arrangement: return String(localized: "Displays")
        }
    }
}

// MARK: - Display geometry

enum DemoDisplayGeometry {
    /// The sample Mac's own built-in display (points), which Mirror shows.
    static let mirrorSourceSize = CGSize(width: 1512, height: 982)

    /// The simulated Mac desktop's aspect (width / height). Mirror follows
    /// the sample Mac's display; Extend uses the real Extend Shape model.
    static func desktopAspect(mode: ReceiverDisplayMode, shape: ExtendDisplayShapePreference,
                              receiverSize: CGSize) -> Double {
        switch mode {
        case .mirror:
            return Double(mirrorSourceSize.width / mirrorSourceSize.height)
        case .extend:
            let physical = receiverSize.height > 0 ? Double(receiverSize.width / receiverSize.height) : nil
            return shape.resolvedAspect(receiverPhysicalAspect: physical)
        }
    }

    /// The point size a real Mac would build this Extend display at, from
    /// the same `ExtendDisplaySizing` the Mac uses.
    static func extendPointSize(shape: ExtendDisplayShapePreference, receiverPixels: CGSize) -> (wide: Int, high: Int) {
        let wide = Int(receiverPixels.width), high = Int(receiverPixels.height)
        let aspect = shape.resolvedAspect(receiverPhysicalAspect: high > 0 ? Double(wide) / Double(high) : nil)
        return ExtendDisplaySizing.pointSize(receiverPixelsWide: wide, receiverPixelsHigh: high, aspect: aspect)
    }

    /// The desktop aspect-fit into the available area: never stretched.
    static func baseTransform(area: CGRect, desktopSize: CGSize) -> RemoteViewportTransform {
        RemoteViewportCalculator.normal(viewBounds: area, remoteAspectSize: desktopSize)
    }
}

// MARK: - Input

/// The settings that decide what a touch does, read from the demo's own
/// control store and session.
struct DemoInputSettings: Equatable {
    var inputMode: PointerInputMode = .direct
    var trackpadSensitivity: Double = PointerGestureConfig.defaultTrackpadSensitivity
    var pinchTarget: ReceiverGestureTarget = .viewport
    var rotateTarget: ReceiverGestureTarget = .disabled
    var snapRotation = true
    var allowLocalViewNavigation = true
    var invertVerticalScroll = true
    var inputAllowed = true
    var videoEnabled = true
    var moveViewActive = false
}

/// One touch sequence's interpretation, fed the live finger positions in
/// view coordinates. Owns the sample desktop, the local viewport and the
/// pointer; every effect lands here or comes back as feedback.
struct DemoInteraction: Equatable {
    static let tapSlop: CGFloat = 10
    static let doubleTapInterval: TimeInterval = 0.35
    static let doubleTapDistance: CGFloat = 30

    var desktop: DemoDesktop
    var viewport = ManualViewportState.identity
    /// Pointer position, desktop points.
    var cursor: CGPoint
    /// Brief click marker at a desktop point (cleared by the screen).
    private(set) var clickMarker: CGPoint?
    private(set) var clickGeneration = 0

    private enum Phase: Equatable {
        case idle
        case one(start: CGPoint, last: CGPoint, began: TimeInterval, moved: Bool, drag: DemoWindowKind?, trackpadDrag: Bool)
        case two(initial: [CGPoint], began: TimeInterval)
        case finished
    }

    private var phase = Phase.idle
    private var twoFinger = TwoFingerGestureSession()
    private var navigation = ViewportNavigationSession()
    private var navigationActive = false
    private var lastTap: (time: TimeInterval, point: CGPoint)?
    private var lastTwoFingerTap: TimeInterval?
    private var reportedGestureOff = false
    private var reportedAppCommand = false

    init(desktop: DemoDesktop) {
        self.desktop = desktop
        cursor = CGPoint(x: desktop.size.width / 2, y: desktop.size.height / 2)
    }

    static func == (lhs: DemoInteraction, rhs: DemoInteraction) -> Bool {
        lhs.desktop == rhs.desktop && lhs.viewport == rhs.viewport && lhs.cursor == rhs.cursor
            && lhs.clickMarker == rhs.clickMarker && lhs.clickGeneration == rhs.clickGeneration
    }

    // MARK: Geometry

    func transform(base: RemoteViewportTransform, videoEnabled: Bool) -> RemoteViewportTransform {
        VideoInteractionPolicy.viewportTransform(base: base, state: viewport, videoEnabled: videoEnabled)
    }

    func desktopPoint(forView point: CGPoint, base: RemoteViewportTransform, videoEnabled: Bool) -> CGPoint? {
        guard let normalized = transform(base: base, videoEnabled: videoEnabled).remotePoint(forView: point) else { return nil }
        return CGPoint(x: normalized.x * desktop.size.width, y: normalized.y * desktop.size.height)
    }

    /// Desktop points per view point at the current magnification.
    func desktopScale(base: RemoteViewportTransform, videoEnabled: Bool) -> CGFloat {
        let shown = transform(base: base, videoEnabled: videoEnabled).displayedRect.width
        return shown > 0 ? desktop.size.width / shown : 1
    }

    mutating func resetViewport() { viewport = .identity }

    mutating func clearClickMarker() { clickMarker = nil }

    mutating func reconfigure(mode: ReceiverDisplayMode, size: CGSize) {
        let old = desktop.size
        desktop.reconfigure(mode: mode, size: size)
        if old != size, old.width > 0, old.height > 0 {
            cursor = CGPoint(x: cursor.x / old.width * size.width, y: cursor.y / old.height * size.height)
        }
        viewport = .identity
    }

    private mutating func clickAt(_ point: CGPoint, now: TimeInterval, viewPoint: CGPoint) -> DemoFeedback? {
        let isDouble = lastTap.map { now - $0.time < Self.doubleTapInterval
            && hypot($0.point.x - viewPoint.x, $0.point.y - viewPoint.y) < Self.doubleTapDistance } ?? false
        lastTap = isDouble ? nil : (now, viewPoint)
        clickMarker = point
        clickGeneration &+= 1
        return isDouble ? desktop.doubleClick(at: point) : desktop.click(at: point)
    }

    // MARK: Touches

    /// Feeds the current set of fingers (view coordinates); an empty array
    /// ends the sequence.
    mutating func touches(_ points: [CGPoint], at now: TimeInterval, base: RemoteViewportTransform,
                          settings: DemoInputSettings) -> [DemoFeedback] {
        var feedback: [DemoFeedback] = []
        let viewportAllowed = LocalViewNavigationPolicy.allowsViewportChanges(
            localNavigationAllowed: settings.allowLocalViewNavigation, videoEnabled: settings.videoEnabled)

        if points.isEmpty {
            feedback += end(at: now, settings: settings)
            phase = .idle
            return feedback
        }
        if case .finished = phase { return [] }

        // Move View: fingers navigate the local view only.
        if settings.moveViewActive, viewportAllowed {
            if !navigationActive { navigation = ViewportNavigationSession(); navigationActive = true }
            viewport = navigation.update(points: points, current: viewport, base: base.displayedRect,
                                         allowsZoom: true, allowsRotation: settings.rotateTarget == .viewport)
            phase = .two(initial: points, began: now)
            return []
        }

        if points.count >= 2 {
            let pair = Array(points.prefix(2))
            switch phase {
            case .two(let initial, _):
                feedback += twoFingerMoved(initial: initial, current: pair, base: base, settings: settings,
                                           viewportAllowed: viewportAllowed)
            default:
                phase = .two(initial: pair, began: now)
                twoFinger = TwoFingerGestureSession()
                navigation = ViewportNavigationSession()
                navigationActive = false
                reportedGestureOff = false
                reportedAppCommand = false
                _ = navigation.update(points: pair, current: viewport, base: base.displayedRect,
                                      allowsZoom: true, allowsRotation: true)
            }
            return feedback
        }

        let point = points[0]
        switch phase {
        case .idle:
            var drag: DemoWindowKind?
            var trackpadDrag = false
            if settings.inputAllowed {
                switch settings.inputMode {
                case .direct:
                    if let desktopPoint = desktopPoint(forView: point, base: base, videoEnabled: settings.videoEnabled) {
                        cursor = desktopPoint
                        if case .titleBar(let kind) = desktop.hit(desktopPoint) {
                            drag = kind
                            desktop.raise(kind)
                        }
                    }
                case .trackpad:
                    // Tap, then touch again and move: drag what's under the pointer.
                    if let lastTap, now - lastTap.time < Self.doubleTapInterval,
                       case .titleBar(let kind) = desktop.hit(cursor) {
                        drag = kind
                        trackpadDrag = true
                        desktop.raise(kind)
                    }
                }
            }
            phase = .one(start: point, last: point, began: now, moved: false, drag: drag, trackpadDrag: trackpadDrag)
        case .one(let start, let last, let began, var moved, let drag, let trackpadDrag):
            if hypot(point.x - start.x, point.y - start.y) > Self.tapSlop { moved = true }
            guard settings.inputAllowed else {
                phase = .one(start: start, last: point, began: began, moved: moved, drag: drag, trackpadDrag: trackpadDrag)
                break
            }
            let scale = desktopScale(base: base, videoEnabled: settings.videoEnabled)
            let delta = CGVector(dx: (point.x - last.x) * scale, dy: (point.y - last.y) * scale)
            switch settings.inputMode {
            case .direct:
                if let drag {
                    desktop.moveWindow(drag, by: delta)
                } else if moved, let desktopPoint = desktopPoint(forView: point, base: base, videoEnabled: settings.videoEnabled) {
                    // A one-finger drag over content scrolls it, like dragging a list.
                    desktop.scroll(at: desktopPoint, dy: -delta.dy)
                    cursor = desktopPoint
                }
                if let desktopPoint = desktopPoint(forView: point, base: base, videoEnabled: settings.videoEnabled) {
                    cursor = desktopPoint
                }
            case .trackpad:
                let gain = CGFloat(settings.trackpadSensitivity)
                let moveDelta = CGVector(dx: delta.dx * gain, dy: delta.dy * gain)
                let before = cursor
                moveCursor(by: moveDelta)
                if let drag {
                    desktop.moveWindow(drag, by: CGVector(dx: cursor.x - before.x, dy: cursor.y - before.y))
                }
            }
            phase = .one(start: start, last: point, began: began, moved: moved, drag: drag, trackpadDrag: trackpadDrag)
        case .two, .finished:
            break
        }
        return feedback
    }

    mutating func moveCursor(by delta: CGVector) {
        cursor = CGPoint(x: min(max(cursor.x + delta.dx, 0), desktop.size.width - 1),
                         y: min(max(cursor.y + delta.dy, 0), desktop.size.height - 1))
    }

    private mutating func twoFingerMoved(initial: [CGPoint], current: [CGPoint], base: RemoteViewportTransform,
                                         settings: DemoInputSettings, viewportAllowed: Bool) -> [DemoFeedback] {
        let initialDistance = hypot(initial[1].x - initial[0].x, initial[1].y - initial[0].y)
        let currentDistance = hypot(current[1].x - current[0].x, current[1].y - current[0].y)
        let initialMid = CGPoint(x: (initial[0].x + initial[1].x) / 2, y: (initial[0].y + initial[1].y) / 2)
        let currentMid = CGPoint(x: (current[0].x + current[1].x) / 2, y: (current[0].y + current[1].y) / 2)
        let initialAngle = atan2(initial[1].y - initial[0].y, initial[1].x - initial[0].x)
        let currentAngle = atan2(current[1].y - current[0].y, current[1].x - current[0].x)
        let rotation = ManualViewportState.normalizedAngle(currentAngle - initialAngle)
        let intent = twoFinger.update(initialDistance: initialDistance, currentDistance: currentDistance,
                                      initialMidpoint: initialMid, currentMidpoint: currentMid,
                                      rotationDelta: rotation)
        let routes = TwoFingerRoutingPolicy.routes(
            intent: intent, remoteInputAllowed: settings.inputAllowed,
            localNavigationAllowed: settings.allowLocalViewNavigation, videoEnabled: settings.videoEnabled,
            pinchTarget: settings.pinchTarget, rotateTarget: settings.rotateTarget)
        var feedback: [DemoFeedback] = []
        switch intent {
        case .undecided:
            break
        case .scroll:
            guard routes.contains(.remoteScroll) else {
                if !reportedGestureOff { reportedGestureOff = true; feedback.append(.inputOff) }
                break
            }
            let previous = navigationMid
            navigationMid = currentMid
            let dyView = currentMid.y - (previous ?? currentMid).y
            let scale = desktopScale(base: base, videoEnabled: settings.videoEnabled)
            let natural = settings.invertVerticalScroll
            let dy = (natural ? -dyView : dyView) * scale
            let target: CGPoint
            if settings.inputMode == .direct,
               let point = desktopPoint(forView: currentMid, base: base, videoEnabled: settings.videoEnabled) {
                target = point
            } else {
                target = cursor
            }
            desktop.scroll(at: target, dy: dy)
        case .viewportZoomPan:
            let pinch = VideoInteractionPolicy.effectiveTarget(stored: settings.pinchTarget, videoEnabled: settings.videoEnabled)
            let rotate = VideoInteractionPolicy.effectiveTarget(stored: settings.rotateTarget, videoEnabled: settings.videoEnabled)
            if routes.contains(.viewport) {
                viewport = navigation.update(points: current, current: viewport, base: base.displayedRect,
                                             allowsZoom: pinch == .viewport, allowsRotation: rotate == .viewport)
                navigationActive = true
            }
            if routes.contains(.appCommands), !reportedAppCommand {
                reportedAppCommand = true
                let rotating = abs(rotation) > TwoFingerGestureClassifier.rotationIntentThreshold
                if rotating, rotate == .app {
                    feedback.append(.macAppCommand(rotation > 0 ? .rotateRight : .rotateLeft))
                } else if pinch == .app {
                    feedback.append(.macAppCommand(currentDistance > initialDistance ? .zoomIn : .zoomOut))
                }
            }
            if !routes.contains(.viewport), !routes.contains(.appCommands), !reportedGestureOff {
                reportedGestureOff = true
                if !viewportAllowed, settings.videoEnabled, pinch == .viewport {
                    feedback.append(.gestureOff(String(localized: "Local View Navigation is off")))
                } else if pinch == .disabled {
                    feedback.append(.gestureOff(String(localized: "Pinch is off in Settings, Gestures")))
                } else if !settings.inputAllowed {
                    feedback.append(.inputOff)
                }
            }
        }
        return feedback
    }

    private var navigationMid: CGPoint?

    private mutating func end(at now: TimeInterval, settings: DemoInputSettings) -> [DemoFeedback] {
        defer {
            navigation.end()
            navigationActive = false
            navigationMid = nil
        }
        switch phase {
        case .one(let start, let last, let began, let moved, let drag, _):
            guard !moved, drag == nil || hypot(last.x - start.x, last.y - start.y) <= Self.tapSlop,
                  now - began < 0.6 else { return [] }
            guard settings.inputAllowed else { return [.inputOff] }
            return clickAt(cursor, now: now, viewPoint: settings.inputMode == .direct ? start : .zero).map { [$0] } ?? []
        case .two(_, let began):
            if settings.snapRotation, viewport.rotationRadians != 0 {
                viewport.rotationRadians = ViewportRotationSnap.snappedAngle(viewport.rotationRadians, enabled: true).angle
            }
            guard twoFinger.intent == .undecided, now - began < 0.35 else { return [] }
            // Two-finger double tap resets the view, like the real receiver.
            if let previous = lastTwoFingerTap, now - previous < 0.5,
               LocalViewNavigationPolicy.allowsViewportChanges(localNavigationAllowed: settings.allowLocalViewNavigation,
                                                               videoEnabled: settings.videoEnabled) {
                lastTwoFingerTap = nil
                viewport = .identity
                return [.local(String(localized: "View reset"))]
            }
            lastTwoFingerTap = now
            guard settings.inputAllowed else { return [.inputOff] }
            return [.macSecondaryClick]
        case .idle, .finished:
            return []
        }
    }
}

extension DemoFeedback {
    /// Names for common Mac shortcuts, shown in the preview chip.
    static func shortcutName(usage: Int, modifiers: [String]) -> String? {
        let mods = Set(modifiers)
        guard mods.contains("command") else {
            switch usage {
            case 41: return String(localized: "Escape")
            case 43: return String(localized: "Tab")
            default: return nil
            }
        }
        switch usage {
        case 4: return String(localized: "Select All")
        case 6: return String(localized: "Copy")
        case 25: return String(localized: "Paste")
        case 27: return String(localized: "Cut")
        case 22: return String(localized: "Save")
        case 9: return String(localized: "Find")
        case 20: return String(localized: "Quit")
        case 26: return String(localized: "Close Window")
        case 29: return mods.contains("shift") ? String(localized: "Redo") : String(localized: "Undo")
        case 43: return String(localized: "Switch Apps")
        case 44: return String(localized: "Spotlight")
        case 46: return String(localized: "Zoom In")
        case 45: return String(localized: "Zoom Out")
        case 7 where mods.contains("option"): return String(localized: "Show or Hide Dock")
        default: return nil
        }
    }
}
