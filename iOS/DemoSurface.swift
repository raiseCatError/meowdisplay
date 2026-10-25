import SwiftUI
import UIKit

// MARK: - Demo receiver surface
//
// Draws the interactive sample desktop (`DemoWorkspace`) where a real
// session shows the Mac, under the real control overlay. Touches go to
// `DemoInteraction`, which applies the configured input mode, gesture
// targets and local view policy. Nothing here sends anything.

struct DemoReceiverScreen: View {
    @ObservedObject var demo: DemoSession
    @ObservedObject var workspace: DemoWorkspace
    @ObservedObject var store: ReceiverControlStore
    @Binding var showSettings: Bool
    @Binding var keyboardActive: Bool
    let haptics: ReceiverHaptics
    let onExit: () -> Void

    @State private var padCanvas: CGRect?
    @State private var keyboardRect: CGRect?
    @State private var hint: DemoHint?
    @State private var hintGeneration = 0
    @State private var feedbackVisible = false
    @State private var showGuide = false

    init(demo: DemoSession, store: ReceiverControlStore, showSettings: Binding<Bool>,
         keyboardActive: Binding<Bool>, haptics: ReceiverHaptics, onExit: @escaping () -> Void) {
        self.demo = demo
        _workspace = ObservedObject(wrappedValue: demo.workspace)
        self.store = store
        _showSettings = showSettings
        _keyboardActive = keyboardActive
        self.haptics = haptics
        self.onExit = onExit
    }

    private var inputSettings: DemoInputSettings {
        let p = store.preferences
        return DemoInputSettings(inputMode: p.inputMode, trackpadSensitivity: p.trackpadSensitivity,
                                 pinchTarget: p.pinchTarget, rotateTarget: p.rotateTarget,
                                 snapRotation: p.snapRotation, allowLocalViewNavigation: p.allowLocalViewNavigation,
                                 invertVerticalScroll: p.invertVerticalScroll, inputAllowed: demo.inputAllowed,
                                 videoEnabled: demo.videoEnabled, moveViewActive: store.moveViewActive)
    }

    var body: some View {
        GeometryReader { geo in
            let insets = windowInsets(fallback: geo.safeAreaInsets)
            let canvas = canvas(in: geo.size)
            let area = displayArea(canvas: canvas, insets: insets)
            let base = DemoDisplayGeometry.baseTransform(area: area, desktopSize: workspace.interaction.desktop.size)
            let targetSize = desktopSize(receiverSize: geo.size)
            ZStack(alignment: .topLeading) {
                Color(white: 0.03).ignoresSafeArea()
                if demo.videoEnabled {
                    desktopLayer(base: base)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .mask(Rectangle().frame(width: area.width, height: area.height).position(x: area.midX, y: area.midY))
                } else {
                    DemoTrackpadPreview(interaction: workspace.interaction, inputMode: store.preferences.inputMode,
                                        inputAllowed: demo.inputAllowed)
                        .frame(width: area.width, height: area.height)
                        .position(x: area.midX, y: area.midY)
                        .allowsHitTesting(false)
                }
                DemoTouchSurface { points, time in
                    handle(points.map { CGPoint(x: $0.x + area.minX, y: $0.y + area.minY) }, at: time, base: base)
                }
                .frame(width: area.width, height: area.height)
                .position(x: area.midX, y: area.midY)
                .accessibilityElement()
                .accessibilityLabel(Text("Sample Mac desktop"))
                .accessibilityHint(Text(store.preferences.inputMode == .trackpad
                                        ? "Trackpad. Move one finger to move the pointer, tap to click."
                                        : "Direct Touch. Touch the desktop where you want to click."))
                .accessibilityAction(named: Text("Click at pointer")) {
                    tapAtPointer(base: base)
                }
                if !demo.videoEnabled {
                    videoOffActions
                        .position(x: area.midX, y: area.minY + 44)
                }
                RemoteKeyboardInputView(
                    isActive: $keyboardActive,
                    onCommitText: { demo.typeText($0) },
                    onSpecialPress: { demo.sendKeyboardPress(usage: $0) },
                    onHardwareKeyDown: { usage, modifiers in demo.sendKeyboardPress(usage: usage, modifiers: modifiers) },
                    onHardwareKeyUp: { _, _ in },
                    onRequestDismiss: { keyboardActive = false })
                    .frame(width: 1, height: 1)
                    .opacity(0)
                    .allowsHitTesting(false)
                ReceiverControlOverlay(
                    store: store,
                    receiver: demo,
                    keyboardActive: $keyboardActive,
                    showSettings: $showSettings,
                    keyboardAvailable: demo.inputAllowed,
                    keyboardVisibleRect: DemoDisplayGeometry.keyboardVisibleRect(
                        keyboardFrame: keyboardRect, canvas: canvas, screenBounds: UIScreen.main.bounds),
                    containerSize: geo.size,
                    safeInsets: insets,
                    notchSide: nil,
                    reservedRegions: [],
                    haptics: haptics,
                    onOccupiedFramesChange: { _ in },
                    onCanvasChange: { padCanvas = $0 },
                    surfaceOrigin: canvas.origin)
                chrome(canvas: canvas, insets: insets)
            }
            .onAppear { reconfigure(to: targetSize) }
            .onChange(of: DesktopKey(mode: demo.displayMode, size: targetSize)) { key in reconfigure(to: key.size) }
        }
        .ignoresSafeArea(.keyboard)
        .sheet(isPresented: $showGuide) { DemoGuideSheet() }
        .onAppear { store.applySessionInputState(demo.inputState) }
        .onChange(of: demo.inputState) { state in
            store.applySessionInputState(state)
            if state != .allowed { keyboardActive = false }
            showHint(state == .allowed ? .inputOn : .inputOff)
        }
        .onChange(of: store.preferences.inputMode) { mode in showHint(mode == .trackpad ? .trackpad : .direct) }
        .onChange(of: demo.displayMode) { mode in showHint(mode == .mirror ? .mirror : .extend) }
        .onChange(of: demo.extendShape) { shape in showHint(.shape(shape)) }
        .onChange(of: demo.videoEnabled) { enabled in showHint(enabled ? .videoOn : .videoOff) }
        .onChange(of: store.viewportResetGeneration) { _ in
            withAnimation(.easeOut(duration: 0.25)) { workspace.interaction.resetViewport() }
        }
        .onChange(of: keyboardActive) { active in if active { workspace.focusNotesForTyping() } }
        .onChange(of: workspace.feedbackGeneration) { generation in
            withAnimation(.easeOut(duration: 0.15)) { feedbackVisible = true }
            Task {
                try? await Task.sleep(nanoseconds: 2_200_000_000)
                guard generation == workspace.feedbackGeneration else { return }
                withAnimation(.easeIn(duration: 0.3)) { feedbackVisible = false }
            }
        }
        .onChange(of: workspace.interaction.clickGeneration) { generation in
            Task {
                try? await Task.sleep(nanoseconds: 350_000_000)
                guard generation == workspace.interaction.clickGeneration else { return }
                workspace.interaction.clearClickMarker()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { note in
            guard let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
            keyboardRect = frame
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            keyboardRect = nil
        }
    }

    // MARK: Geometry

    private struct DesktopKey: Equatable {
        let mode: ReceiverDisplayMode
        let size: CGSize
    }

    /// The desktop the sample Mac would show: Mirror follows the sample
    /// Mac's own display; Extend uses the Extend Shape and, for Automatic +
    /// Use Full Display, this device's screen in its current orientation.
    private func desktopSize(receiverSize: CGSize) -> CGSize {
        DemoDesktop.size(forAspect: DemoDisplayGeometry.desktopAspect(
            mode: demo.displayMode, shape: demo.extendShape, receiverSize: receiverSize))
    }

    private func reconfigure(to size: CGSize) {
        withAnimation(.easeInOut(duration: 0.25)) {
            workspace.interaction.reconfigure(mode: demo.displayMode, size: size)
        }
    }

    private func canvas(in size: CGSize) -> CGRect {
        let full = CGRect(origin: .zero, size: size)
        guard store.isPad, let padCanvas, padCanvas.width > 0, padCanvas.height > 0 else { return full }
        return padCanvas.intersection(full)
    }

    /// The surface ignores the safe area, so read the window's real insets
    /// (notch, Dynamic Island, home indicator) for the banner band.
    private func windowInsets(fallback: EdgeInsets) -> ControlSafeInsets {
        let window = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }.first
        guard let insets = window?.safeAreaInsets else {
            return ControlSafeInsets(top: fallback.top, leading: fallback.leading,
                                     bottom: fallback.bottom, trailing: fallback.trailing)
        }
        return ControlSafeInsets(top: insets.top, leading: insets.left, bottom: insets.bottom, trailing: insets.right)
    }

    /// Where the banner row starts.
    private static func bandTop(canvas: CGRect, insets: ControlSafeInsets) -> CGFloat {
        max(canvas.minY, insets.top) + 6
    }

    /// Below the banner row, so the banner never covers the desktop.
    private func displayArea(canvas: CGRect, insets: ControlSafeInsets) -> CGRect {
        let top = Self.bandTop(canvas: canvas, insets: insets) + DemoSessionBanner.rowHeight + 6
        return CGRect(x: canvas.minX, y: top, width: canvas.width, height: max(canvas.maxY - top, 1))
    }

    // MARK: Input

    private func handle(_ points: [CGPoint], at time: TimeInterval, base: RemoteViewportTransform) {
        let feedback = workspace.interaction.touches(points, at: time, base: base, settings: inputSettings)
        feedback.forEach(workspace.show)
        if points.isEmpty { store.scheduleAutoHide() } else { store.beginAutoHideActivity() }
    }

    private func tapAtPointer(base: RemoteViewportTransform) {
        let point = workspace.interaction.transform(base: base, videoEnabled: demo.videoEnabled)
            .viewPoint(forRemote: CGPoint(x: workspace.interaction.cursor.x / workspace.interaction.desktop.size.width,
                                          y: workspace.interaction.cursor.y / workspace.interaction.desktop.size.height))
        let now = CACurrentMediaTime()
        handle([point], at: now, base: base)
        handle([], at: now + 0.05, base: base)
    }

    // MARK: Layers

    private func desktopLayer(base: RemoteViewportTransform) -> some View {
        let interaction = workspace.interaction
        let transform = interaction.transform(base: base, videoEnabled: true)
        let rect = transform.displayedRect
        let size = interaction.desktop.size
        return DemoDesktopView(interaction: interaction, typing: keyboardActive,
                               showPointer: true, showGrid: store.preferences.showSurfaceGrid,
                               deviceKind: deviceKind)
            .frame(width: size.width, height: size.height)
            .scaleEffect(size.width > 0 ? rect.width / size.width : 1)
            .frame(width: rect.width, height: rect.height)
            .rotationEffect(.radians(transform.rotationRadians))
            .position(x: rect.midX, y: rect.midY)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var videoOffActions: some View {
        HStack(spacing: 10) {
            if store.preferences.inputMode == .direct {
                Button {
                    store.update { $0.inputMode = .trackpad }
                } label: {
                    Label("Try Trackpad", systemImage: "rectangle.and.hand.point.up.left")
                }
                .buttonStyle(.borderedProminent)
            }
            Button {
                demo.setVideoEnabled(true)
            } label: {
                Label("Turn Video On", systemImage: "video")
            }
            .buttonStyle(.bordered)
        }
        .tint(Color(white: 0.85))
        .controlSize(.regular)
    }

    private func chrome(canvas: CGRect, insets: ControlSafeInsets) -> some View {
        VStack(spacing: 6) {
            DemoSessionBanner(demo: demo, compact: canvas.width < 520, onExit: onExit,
                              onGuide: { showGuide = true },
                              onResetDesktop: {
                                  withAnimation(.easeInOut(duration: 0.25)) {
                                      workspace.interaction.desktop.resetLayout()
                                      workspace.interaction.resetViewport()
                                  }
                              },
                              onResetView: {
                                  withAnimation(.easeOut(duration: 0.25)) { workspace.interaction.resetViewport() }
                              })
            if let hint {
                DemoHintChip(hint: hint)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            } else if feedbackVisible, let feedback = workspace.feedback {
                DemoFeedbackChip(feedback: feedback) { demo.setInputAllowed(true) }
                    .transition(.opacity)
            }
        }
        .frame(width: canvas.width)
        .padding(.top, Self.bandTop(canvas: canvas, insets: insets))
        .offset(x: canvas.minX)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func showHint(_ newHint: DemoHint) {
        hintGeneration &+= 1
        let generation = hintGeneration
        withAnimation(.easeOut(duration: 0.2)) { hint = newHint }
        UIAccessibility.post(notification: .announcement, argument: newHint.title)
        Task {
            try? await Task.sleep(nanoseconds: 2_600_000_000)
            guard generation == hintGeneration else { return }
            withAnimation(.easeIn(duration: 0.3)) { hint = nil }
        }
    }
}

// MARK: - Touch capture

/// Reports every finger on the surface, in order of touch-down.
private struct DemoTouchSurface: UIViewRepresentable {
    let onTouches: ([CGPoint], TimeInterval) -> Void

    func makeUIView(context: Context) -> TouchView {
        let view = TouchView()
        view.onTouches = onTouches
        return view
    }

    func updateUIView(_ view: TouchView, context: Context) {
        view.onTouches = onTouches
    }

    final class TouchView: UIView {
        var onTouches: (([CGPoint], TimeInterval) -> Void)?
        private var active: [UITouch] = []

        override init(frame: CGRect) {
            super.init(frame: frame)
            isMultipleTouchEnabled = true
            backgroundColor = .clear
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            active += touches.sorted { $0.timestamp < $1.timestamp }
            report(event)
        }

        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) { report(event) }

        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
            active.removeAll { touches.contains($0) }
            report(event)
        }

        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
            active.removeAll { touches.contains($0) }
            report(event)
        }

        private func report(_ event: UIEvent?) {
            onTouches?(active.map { $0.location(in: self) }, event?.timestamp ?? CACurrentMediaTime())
        }
    }
}

// MARK: - Sample desktop drawing

/// The sample Mac desktop: neutral wallpaper, a menu bar, a few working
/// windows and, on the Mac's own display (Mirror), a small dock.
struct DemoDesktopView: View {
    let interaction: DemoInteraction
    let typing: Bool
    let showPointer: Bool
    let showGrid: Bool
    let deviceKind: String

    private var desktop: DemoDesktop { interaction.desktop }

    var body: some View {
        ZStack(alignment: .topLeading) {
            wallpaper
            if showGrid { grid }
            ForEach(desktop.visibleWindows) { window in
                DemoWindowView(window: window, desktop: desktop, focused: desktop.focused == window.kind,
                               typing: typing, deviceKind: deviceKind)
                    .frame(width: window.frame.width, height: window.frame.height)
                    .offset(x: window.frame.minX, y: window.frame.minY)
            }
            menuBar
            if desktop.hasDock { dock }
            if let marker = interaction.clickMarker {
                Circle()
                    .strokeBorder(Color.white.opacity(0.85), lineWidth: 2)
                    .frame(width: 30, height: 30)
                    .offset(x: marker.x - 15, y: marker.y - 15)
            }
            if showPointer {
                Image(systemName: "cursorarrow")
                    .font(.system(size: 20, weight: .regular))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.6), radius: 1.5, y: 1)
                    .offset(x: interaction.cursor.x - 5, y: interaction.cursor.y - 3)
            }
        }
        .frame(width: desktop.size.width, height: desktop.size.height, alignment: .topLeading)
        .clipped()
    }

    private var wallpaper: some View {
        ZStack(alignment: .bottomTrailing) {
            LinearGradient(colors: desktop.mode == .mirror
                           ? [Color(white: 0.20), Color(white: 0.09)]
                           : [Color(red: 0.13, green: 0.15, blue: 0.19), Color(white: 0.07)],
                           startPoint: .top, endPoint: .bottom)
            if desktop.mode == .extend {
                Text("Extended display")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.28))
                    .padding(14)
            }
        }
    }

    private var grid: some View {
        Path { path in
            let step: CGFloat = 80
            stride(from: step, to: desktop.size.width, by: step).forEach {
                path.move(to: CGPoint(x: $0, y: 0)); path.addLine(to: CGPoint(x: $0, y: desktop.size.height))
            }
            stride(from: step, to: desktop.size.height, by: step).forEach {
                path.move(to: CGPoint(x: 0, y: $0)); path.addLine(to: CGPoint(x: desktop.size.width, y: $0))
            }
        }
        .stroke(Color.white.opacity(0.05), lineWidth: 1)
    }

    private var menuBar: some View {
        HStack(spacing: 16) {
            Text(verbatim: desktop.focused.map(DemoDesktop.title) ?? "Desktop").fontWeight(.semibold)
            Text("File")
            Text("Edit")
            Text("View")
            Text("Window")
            Spacer()
            Image(systemName: "wifi")
            Text(verbatim: "9:41")
        }
        .font(.system(size: 12))
        .foregroundStyle(.white.opacity(0.9))
        .padding(.horizontal, 14)
        .frame(width: desktop.size.width, height: DemoDesktop.menuBarHeight)
        .background(Color.black.opacity(0.35))
    }

    private var dock: some View {
        let frames = desktop.dockFrames()
        let bounds = frames.reduce(CGRect.null) { $0.union($1.1) }.insetBy(dx: -10, dy: -6)
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.white.opacity(0.12))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.white.opacity(0.12)))
                .frame(width: bounds.width, height: bounds.height)
                .offset(x: bounds.minX, y: bounds.minY)
            ForEach(frames, id: \.0) { kind, frame in
                VStack(spacing: 3) {
                    Image(systemName: DemoWindowView.symbol(kind))
                        .font(.system(size: 19, weight: .medium))
                        .foregroundStyle(.white)
                        .frame(width: frame.width, height: frame.height - 8)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(white: 0.28)))
                    Circle().fill(Color.white.opacity(desktop.window(kind) != nil ? 0.8 : 0)).frame(width: 4, height: 4)
                }
                .frame(width: frame.width, height: frame.height)
                .offset(x: frame.minX, y: frame.minY)
            }
        }
    }
}

struct DemoWindowView: View {
    let window: DemoWindow
    let desktop: DemoDesktop
    let focused: Bool
    let typing: Bool
    let deviceKind: String

    static func symbol(_ kind: DemoWindowKind) -> String {
        switch kind {
        case .notes: return "note.text"
        case .files: return "folder"
        case .preview: return "eye"
        case .arrangement: return "rectangle.on.rectangle"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            titleBar
            // Taller content (a long list) scrolls inside the window; it must
            // never grow the window.
            content
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .topLeading)
                .clipped()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(white: 0.14))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(Color.white.opacity(focused ? 0.22 : 0.1), lineWidth: 1))
        .shadow(color: .black.opacity(focused ? 0.55 : 0.3), radius: focused ? 18 : 8, y: focused ? 8 : 3)
    }

    private var titleBar: some View {
        ZStack {
            Text(verbatim: DemoDesktop.title(window.kind))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(focused ? 0.92 : 0.5))
            HStack(spacing: 7) {
                ZStack {
                    Circle().fill(Color(white: focused ? 0.55 : 0.32))
                    if focused {
                        Image(systemName: "xmark").font(.system(size: 7, weight: .bold)).foregroundStyle(.black.opacity(0.7))
                    }
                }
                .frame(width: 13, height: 13)
                Circle().fill(Color(white: 0.32)).frame(width: 13, height: 13)
                Circle().fill(Color(white: 0.32)).frame(width: 13, height: 13)
                Spacer()
            }
            .padding(.leading, 9)
        }
        .frame(height: DemoDesktop.titleBarHeight)
        .background(Color(white: focused ? 0.21 : 0.17))
    }

    @ViewBuilder
    private var content: some View {
        switch window.kind {
        case .notes: notes
        case .files: files
        case .preview: preview
        case .arrangement: arrangement
        }
    }

    private var notes: some View {
        (Text(desktop.notes) + Text(focused && typing ? "|" : "").foregroundColor(.accentColor))
            .font(.system(size: 13))
            .lineSpacing(6)
            .foregroundStyle(.white.opacity(0.88))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .offset(y: -window.scrollOffset)
    }

    private var files: some View {
        VStack(spacing: 0) {
            ForEach(DemoFile.samples) { file in
                HStack(spacing: 10) {
                    Image(systemName: file.symbol)
                        .font(.system(size: 13))
                        .frame(width: 18)
                        .foregroundStyle(.white.opacity(0.75))
                    Text(verbatim: file.name).font(.system(size: 13))
                    Spacer(minLength: 6)
                    Text(verbatim: file.detail).font(.system(size: 11)).foregroundStyle(.white.opacity(0.45))
                }
                .foregroundStyle(.white.opacity(0.9))
                .padding(.horizontal, 12)
                .frame(height: DemoDesktop.rowHeight)
                .background(desktop.selectedFile == file.id
                            ? Color.accentColor.opacity(focused ? 0.55 : 0.28) : Color.clear)
            }
        }
        .offset(y: -window.scrollOffset)
    }

    private var preview: some View {
        let file = DemoFile.samples.first { $0.id == desktop.previewFile } ?? DemoFile.samples[0]
        return VStack(spacing: 8) {
            Image(systemName: file.symbol)
                .font(.system(size: 54 * desktop.previewZoom, weight: .thin))
                .foregroundStyle(.white.opacity(0.85))
                .frame(maxHeight: .infinity)
            Text(verbatim: file.name).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
            Text(verbatim: file.detail).font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
            Text("Double-click to zoom").font(.system(size: 10)).foregroundStyle(.white.opacity(0.35))
                .padding(.bottom, 10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(white: 0.1))
        .clipped()
    }

    private var arrangement: some View {
        let frames = desktop.arrangementFrames(in: window.frame)
        let origin = CGPoint(x: window.frame.minX, y: window.frame.minY + DemoDesktop.titleBarHeight)
        let labels = [String(localized: "Review Mac"), String(localized: "This \(deviceKind)")]
        let roles = [String(localized: "Main display"), String(localized: "Extended")]
        return ZStack(alignment: .topLeading) {
            Text("Displays").font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
                .offset(x: 16, y: 10)
            ForEach(frames.indices, id: \.self) { index in
                let frame = frames[index]
                VStack(spacing: 2) {
                    Text(verbatim: labels[index]).font(.system(size: 11, weight: .semibold))
                    Text(verbatim: roles[index]).font(.system(size: 10)).foregroundStyle(.white.opacity(0.55))
                }
                .foregroundStyle(.white)
                .frame(width: frame.width, height: frame.height)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(white: index == 0 ? 0.24 : 0.19)))
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(desktop.highlightedDisplay == index ? Color.accentColor : Color.white.opacity(0.15),
                                  lineWidth: desktop.highlightedDisplay == index ? 2 : 1))
                .offset(x: frame.minX - origin.x, y: frame.minY - origin.y)
            }
        }
    }
}

// MARK: - Video Off

/// Video Off: the stream is hidden, but the surface still works as an input
/// surface. Shows where the pointer is on the (hidden) sample desktop.
struct DemoTrackpadPreview: View {
    let interaction: DemoInteraction
    let inputMode: PointerInputMode
    let inputAllowed: Bool

    var body: some View {
        VStack(spacing: 10) {
            Spacer(minLength: 56)
            Image(systemName: "rectangle.and.hand.point.up.left")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.white.opacity(0.7))
            Text("Trackpad Preview").font(.headline).foregroundStyle(.white)
            Text("Video is off. With a connected Mac, this surface can still control the pointer.")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.6))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 360)
            pointerMap
            hints
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Color(white: 0.08)))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Color.white.opacity(0.1)))
        .padding(10)
    }

    /// A small outline of the sample desktop with the pointer on it.
    private var pointerMap: some View {
        let desktop = interaction.desktop
        let width: CGFloat = 150
        let scale = width / max(desktop.size.width, 1)
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 5).fill(Color(white: 0.14))
            ForEach(desktop.visibleWindows) { window in
                RoundedRectangle(cornerRadius: 2)
                    .strokeBorder(Color.white.opacity(desktop.focused == window.kind ? 0.5 : 0.2))
                    .frame(width: window.frame.width * scale, height: window.frame.height * scale)
                    .offset(x: window.frame.minX * scale, y: window.frame.minY * scale)
            }
            Circle().fill(Color.accentColor)
                .frame(width: 7, height: 7)
                .offset(x: interaction.cursor.x * scale - 3.5, y: interaction.cursor.y * scale - 3.5)
        }
        .frame(width: width, height: desktop.size.height * scale)
        .accessibilityHidden(true)
    }

    private var hints: some View {
        let items: [(String, String)] = inputMode == .trackpad
            ? [("hand.point.up.left", String(localized: "Move one finger")),
               ("hand.tap", String(localized: "Tap to click")),
               ("arrow.up.and.down", String(localized: "Two fingers to scroll"))]
            : [("hand.point.up", String(localized: "Direct Touch maps your finger to the Mac's screen"))]
        return HStack(spacing: 8) {
            ForEach(items, id: \.1) { symbol, text in
                Label(text, systemImage: symbol)
                    .font(.caption)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Color.white.opacity(0.08)))
            }
        }
        .foregroundStyle(.white.opacity(inputAllowed ? 0.75 : 0.35))
    }
}

// MARK: - Chrome

/// Always visible: DEMO, the sample Mac, Allow Input, options and Exit Demo.
struct DemoSessionBanner: View {
    static let rowHeight: CGFloat = 38

    @ObservedObject var demo: DemoSession
    let compact: Bool
    let onExit: () -> Void
    let onGuide: () -> Void
    let onResetDesktop: () -> Void
    let onResetView: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            DemoBadge()
            HStack(spacing: 4) {
                Text(verbatim: DemoSession.macName).font(.footnote.weight(.semibold))
                if !compact {
                    Text("· Sample session").font(.footnote).foregroundStyle(.white.opacity(0.6))
                }
            }
            .accessibilityElement(children: .combine)
            Button {
                demo.setInputAllowed(!demo.inputAllowed)
            } label: {
                Image(systemName: demo.inputAllowed ? "hand.tap.fill" : "hand.raised.slash")
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Color.white.opacity(demo.inputAllowed ? 0.16 : 0.06)))
            }
            .accessibilityLabel(Text("Allow Input (Demo)"))
            .accessibilityValue(demo.inputAllowed ? Text("On") : Text("Off"))
            Menu {
                Button { onGuide() } label: { Label("What can I try?", systemImage: "lightbulb") }
                Button { onResetView() } label: { Label("Reset View", systemImage: "arrow.counterclockwise") }
                Button { onResetDesktop() } label: { Label("Reset Sample Desktop", systemImage: "macwindow") }
            } label: {
                Image(systemName: "ellipsis").frame(width: 28, height: 28)
            }
            .accessibilityLabel(Text("Demo Options"))
            Button(action: onExit) {
                Text("Exit Demo").font(.footnote.weight(.semibold))
            }
            .buttonStyle(.bordered)
            .tint(.white)
            .controlSize(.small)
            .accessibilityHint(Text("Returns to the home screen."))
        }
        .foregroundStyle(.white)
        .padding(.leading, 10)
        .padding(.trailing, 5)
        .frame(height: Self.rowHeight)
        .background(Capsule().fill(.ultraThinMaterial))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.12)))
        .environment(\.colorScheme, .dark)
        .fixedSize()
    }
}

/// The DEMO label: text, never only color.
struct DemoBadge: View {
    var body: some View {
        Text("DEMO")
            .font(.caption2.weight(.bold))
            .tracking(0.6)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .overlay(Capsule().strokeBorder(Color.secondary, lineWidth: 1))
            .accessibilityLabel(Text("Demo Mode"))
    }
}

/// A short note when a meaningful mode changes.
enum DemoHint: Equatable {
    case direct, trackpad, mirror, extend, videoOn, videoOff, inputOn, inputOff
    case shape(ExtendDisplayShapePreference)

    var title: String {
        switch self {
        case .direct: return String(localized: "Direct Touch. Touch the desktop directly.")
        case .trackpad: return String(localized: "Trackpad. Move your finger to control the pointer.")
        case .mirror: return String(localized: "Mirror. You see the Mac's own screen.")
        case .extend: return String(localized: "Extend. This device adds a second desktop beside the Mac.")
        case .videoOn: return String(localized: "Video on.")
        case .videoOff: return String(localized: "Video off. The surface still works as a trackpad.")
        case .inputOn: return String(localized: "Input allowed (Demo).")
        case .inputOff: return String(localized: "Input off (Demo). Controls are hidden; view navigation still works.")
        case .shape(let shape):
            if shape.shape == .automatic {
                return shape.useFullDisplay
                    ? String(localized: "Extend fills this display.")
                    : String(localized: "Extend Automatic: 16:10.")
            }
            return String(localized: "Extend shape \(shape.shape.title).")
        }
    }
}

private struct DemoHintChip: View {
    let hint: DemoHint

    var body: some View {
        Text(hint.title)
            .font(.footnote.weight(.medium))
            .multilineTextAlignment(.center)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Capsule().fill(.ultraThinMaterial))
            .environment(\.colorScheme, .dark)
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
    }
}

private struct DemoFeedbackChip: View {
    let feedback: DemoFeedback
    let onAllowInput: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).foregroundStyle(.white.opacity(0.75))
            Text(text).font(.footnote.weight(.medium)).lineLimit(2)
            if feedback == .inputOff {
                Button("Allow Input", action: onAllowInput)
                    .font(.footnote.weight(.semibold))
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .tint(.white)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Capsule().fill(.ultraThinMaterial))
        .environment(\.colorScheme, .dark)
        .padding(.horizontal, 16)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.updatesFrequently)
    }

    private var symbol: String {
        switch feedback {
        case .local: return "checkmark.circle"
        case .modifierHeld: return "command"
        case .inputOff: return "hand.raised.slash"
        case .gestureOff: return "nosign"
        case .macShortcut, .macGesture, .macAppCommand, .macSecondaryClick, .macTyping: return "laptopcomputer"
        }
    }

    private var text: String {
        let toMac = String(localized: "would be sent to the Mac")
        switch feedback {
        case .local(let text): return text
        case .modifierHeld(let modifier):
            return String(localized: "\(DemoSession.symbols[modifier.rawValue] ?? modifier.rawValue) held. Choose a shortcut.")
        case .inputOff: return String(localized: "Input is off (Demo).")
        case .gestureOff(let reason): return reason
        case .macShortcut(let usage, let modifiers):
            let keys = DemoSession.describe(usage: usage, modifiers: modifiers)
            if let name = DemoFeedback.shortcutName(usage: usage, modifiers: modifiers) {
                return "\(keys) \(name) · \(toMac)"
            }
            return "\(keys) · \(toMac)"
        case .macGesture(let raw):
            return "\(ReceiverGesture(rawValue: raw)?.title ?? raw) · \(toMac)"
        case .macAppCommand(let kind):
            return String(localized: "\(kind.title) command · \(toMac)")
        case .macSecondaryClick:
            return String(localized: "Secondary click · \(toMac)")
        case .macTyping:
            return String(localized: "Typing \(toMac). Open Notes to type here.")
        }
    }
}

/// "What can I try?": a short list, nothing more.
private struct DemoGuideSheet: View {
    @Environment(\.dismiss) private var dismiss

    private let items: [(String, String, String)] = [
        ("hand.tap", String(localized: "Tap and drag"), String(localized: "Tap a window to focus it, drag its title bar, scroll the Files list, double-click a file.")),
        ("rectangle.and.hand.point.up.left", String(localized: "Trackpad"), String(localized: "Settings, Input: switch to Trackpad and move the pointer with one finger.")),
        ("arrow.up.left.and.arrow.down.right", String(localized: "Zoom your view"), String(localized: "Pinch to zoom, drag with two fingers to pan, double-tap with two fingers to reset.")),
        ("rectangle.on.rectangle", String(localized: "Mirror and Extend"), String(localized: "Settings, Display: switch modes and try Extend Shape.")),
        ("video.slash", String(localized: "Video Off"), String(localized: "Turn video off to use the surface as a trackpad.")),
        ("command", String(localized: "Controls"), String(localized: "Use the control trays and keyboard. Mac-only actions show what would be sent.")),
    ]

    var body: some View {
        NavigationStack {
            List(items, id: \.1) { symbol, title, detail in
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(.body.weight(.semibold))
                        Text(detail).font(.footnote).foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: symbol)
                }
            }
            .navigationTitle("What can I try?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
