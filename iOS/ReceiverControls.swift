import CoreHaptics
import SwiftUI
import UIKit

@MainActor
final class ReceiverControlStore: ObservableObject {
    @Published private(set) var preferences: ReceiverControlPreferences
    // Live, per-session input-consent state (per-device/per-session
    // milestone) — deliberately NOT part of `ReceiverControlPreferences`,
    // which persists to disk: this must never survive a relaunch or a new
    // connection as anything but `.off`, since the Mac defines a brand-new
    // logical session as starting with no grant. Mirrors `preferences.
    // allowInput` (kept for every existing call site that already gates
    // input generation on that bool) purely for richer receiver UI text.
    @Published private(set) var sessionInputState: SessionInputWireState = .off
    /// Transient Auto-hide presentation state — deliberately separate from
    /// `preferences.trayCollapsed` (the user's manual, persisted choice).
    /// Owned here (rather than by `ReceiverControlOverlay`) so ANY
    /// receiver-surface interaction — not just a touch on the tray itself —
    /// can reveal it (see `VideoLayerView`'s `onActivityBegan`/
    /// `onActivityEnded` in `OpenSidecarPhoneApp.swift`). Never persisted: a
    /// relaunch always starts `false`.
    @Published private(set) var autoHidden = false
    private var autoHideTask: Task<Void, Never>?
    private static let autoHideDelay: Duration = .seconds(9)
    private let repository: ReceiverControlPreferencesRepository
    var onInputResetRequested: (() -> Void)?
    /// The iPad-only presentation (Strip/Overlay/Custom, Control Size, …)
    /// applies only when true; the iPhone keeps its compact tray.
    let isPad: Bool
    /// Move View: while true the receiver surface moves the local viewport
    /// instead of controlling the Mac. Transient — never persisted, and
    /// dropped whenever input stops reaching the Mac.
    @Published private(set) var moveViewActive = false
    /// Bumped to ask the receiver surface to reset its local viewport.
    @Published private(set) var viewportResetGeneration = 0
    /// The modifiers the on-screen chord currently holds down on the Mac —
    /// a read-only projection of the overlay's `ControlInteractionState`,
    /// so the software keyboard can type ⌘C after ⌘ is latched. Never a
    /// second modifier state.
    @Published private(set) var activeChordModifiers: Set<ControlModifier> = []
    /// Whether the user turned input off themselves (Settings → Input →
    /// Turn Off), so the on-surface prompt offers Enable rather than
    /// Request. Transient.
    @Published private(set) var userTurnedOffInput = false

    func projectChord(_ modifiers: Set<ControlModifier>) {
        guard modifiers != activeChordModifiers else { return }
        activeChordModifiers = modifiers
    }

    func noteInputTurnedOffByUser(_ turnedOff: Bool) {
        userTurnedOffInput = turnedOff
    }

    init(repository: ReceiverControlPreferencesRepository = ReceiverControlPreferencesRepository(),
         isPad: Bool = UIDevice.current.userInterfaceIdiom == .pad) {
        self.repository = repository
        self.isPad = isPad
        preferences = repository.load()
    }

    /// The iPad layout mode actually in effect: Custom needs a layout to
    /// show, otherwise it presents as Overlay.
    var effectivePadLayout: PadControlLayoutMode {
        let stored = preferences.padControlLayout
        return stored == .custom && preferences.activeCustomLayout == nil ? .overlay : stored
    }

    func setMoveViewActive(_ active: Bool) {
        guard moveViewActive != active else { return }
        moveViewActive = active
        if active { beginAutoHideActivity() } else { scheduleAutoHide() }
    }

    func requestViewportReset() {
        viewportResetGeneration &+= 1
    }

    /// Call at the start of ANY meaningful interaction — anywhere on the
    /// receiver surface, not only the tray. Reveals immediately (never
    /// touches `trayEnabled`/`functionTrayEnabled`/`trayCollapsed`/profile
    /// state) and suspends the countdown; pair with `scheduleAutoHide` once
    /// the interaction is fully over.
    func beginAutoHideActivity() {
        autoHideTask?.cancel()
        autoHidden = false
    }

    /// (Re)starts the 9-second Auto-hide countdown from now, or declines to
    /// schedule at all when hiding wouldn't be appropriate right now: the
    /// feature is off, the tray can't show, it's manually collapsed, or
    /// `interactionIdle` is false because some other interaction (a touch
    /// still down, a latched chord, an open palette, …) is still ongoing.
    /// Re-validates the same conditions when the delay elapses so a stale
    /// task can never hide the tray after a newer interaction already
    /// cancelled it.
    func scheduleAutoHide(interactionIdle: Bool = true) {
        autoHideTask?.cancel()
        guard autoHideAllowed, interactionIdle else { return }
        autoHideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.autoHideDelay)
            guard let self, !Task.isCancelled, self.autoHideAllowed else { return }
            self.autoHidden = true
        }
    }

    /// Move View keeps its controls up so the mode can always be left.
    private var autoHideAllowed: Bool {
        preferences.autoHideEnabled && preferences.trayCanBeShown && !preferences.trayCollapsed
            && !moveViewActive
            && ControlAutoHidePolicy.applies(isPad: isPad, layout: effectivePadLayout)
    }

    /// Cancels any pending countdown and clears auto-hidden state, then
    /// restarts the countdown from now. The shared "something happened"
    /// entry point for state transitions (new session, profile switch, a
    /// preference changing) where the right behavior is simply "start over
    /// from visible."
    func resetAutoHide() {
        beginAutoHideActivity()
        scheduleAutoHide()
    }

    var activeProfile: ControlProfile {
        preferences.profile(for: preferences.activeControlProfile)
    }

    /// Independent of `activeProfile` — the Function Tray's own profile
    /// selection never moves in lockstep with the Main Tray's.
    var activeFunctionTrayProfile: FunctionTrayProfile {
        preferences.functionTrayProfile(for: preferences.activeFunctionTrayProfile)
    }

    func update(_ change: (inout ReceiverControlPreferences) -> Void) {
        let previous = preferences
        let previousActiveProfile = activeProfile
        let previousActiveFunctionProfile = activeFunctionTrayProfile
        change(&preferences)
        repository.save(preferences)
        let activeProfileChanged = previous.activeControlProfile != preferences.activeControlProfile
            || previousActiveProfile != activeProfile
        let activeFunctionProfileChanged = previous.activeFunctionTrayProfile != preferences.activeFunctionTrayProfile
            || previousActiveFunctionProfile != activeFunctionTrayProfile
        // Allow Input turning off must cancel any in-flight session (PRODUCT
        // RULE — see the milestone's SETTINGS / ALLOW INPUT INVARIANTS), and
        // an input-mode switch must never leave a stale touch/drag behind
        // either — both reuse this same cancellation hook.
        let allowInputDisabled = previous.allowInput && !preferences.allowInput
        let inputModeChanged = previous.inputMode != preferences.inputMode
        if (previous.trayEnabled && !preferences.trayEnabled) || activeProfileChanged
            || activeFunctionProfileChanged || allowInputDisabled || inputModeChanged {
            onInputResetRequested?()
        }
    }

    func updateActiveProfile(_ change: (inout ControlProfile) -> Void) {
        var profile = activeProfile
        change(&profile)
        update { $0.updateProfile(profile) }
    }

    /// Never coupled to `updateActiveProfile`/the Main Tray's profile —
    /// switching one tray's profile must never move the other's.
    func updateActiveFunctionTrayProfile(_ change: (inout FunctionTrayProfile) -> Void) {
        var profile = activeFunctionTrayProfile
        change(&profile)
        update { $0.updateFunctionTrayProfile(profile) }
    }

    /// Reuses `ReceiverUIPreferenceUpdate.apply(to:)` — the exact same
    /// mapping `MacSender`'s push and this receiver's decode both already
    /// agree on — rather than re-enumerating the field list a third time.
    func applyRemote(_ preferenceUpdate: ReceiverUIPreferenceUpdate) {
        update { preferenceUpdate.apply(to: &$0) }
    }

    /// The connected Mac is authoritative for input consent (a security-
    /// relevant, Mac-owned decision — see `StreamReceiver.
    /// onAllowInputStateChange`) so its confirmed state always overwrites
    /// local state rather than merging with it — exactly one source of
    /// truth once connected, and NEVER set optimistically ahead of this.
    func applySessionInputState(_ state: SessionInputWireState) {
        sessionInputState = state
        update { $0.allowInput = (state == .allowed) }
    }
}

@MainActor
final class ReceiverHaptics {
    private let enabled: () -> Bool

    init(enabled: @escaping () -> Bool) { self.enabled = enabled }

    func play(_ event: ControlHapticEvent) {
        guard ControlHapticPolicy.shouldPlay(event, enabled: enabled()) else { return }
        switch event {
        case .selection:
            UISelectionFeedbackGenerator().selectionChanged()
        case .latch, .expandCollapse, .profileChange, .settings:
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        case .confirmation, .reset:
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
    }
}

/// Renders `SmartTouchFeedback` as haptics. Owned by the video surface for
/// its lifetime, since the title bar build-up is a continuous pattern that
/// must be stopped again, not a one-shot event.
///
/// Title bar hold: a soft continuous haptic ramps up while the hold builds,
/// then a single crisp tick confirms the window drag has armed.
@MainActor
final class SmartTouchHaptics {
    /// `SmartTouchHapticPolicy` for the current settings. Turning it off
    /// mid-hold stops the build-up at once.
    var isEnabled = true {
        didSet { if !isEnabled { stopBuildUp() } }
    }

    private let supportsHaptics = CHHapticEngine.capabilitiesForHardware().supportsHaptics
    private var engine: CHHapticEngine?
    private var buildUp: CHHapticPatternPlayer?

    func play(_ feedback: SmartTouchFeedback) {
        switch feedback {
        case .directTouchOverride:
            guard isEnabled else { return }
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        case .titleBarHoldBegan(let deadline):
            guard isEnabled else { return }
            startBuildUp(duration: deadline - CACurrentMediaTime())
        case .titleBarHoldCancelled:
            stopBuildUp()
        case .windowDragArmed:
            stopBuildUp()
            guard isEnabled else { return }
            UIImpactFeedbackGenerator(style: .rigid).impactOccurred(intensity: 0.8)
        }
    }

    /// One continuous event whose intensity rises from barely-there to
    /// moderate over the rest of the hold. Low sharpness keeps it a soft
    /// swell rather than a buzz. Devices without Core Haptics (iPad) get
    /// nothing here, like every other receiver haptic.
    private func startBuildUp(duration: TimeInterval) {
        stopBuildUp()
        guard supportsHaptics, duration > 0.05 else { return }
        do {
            let engine = try hapticEngine()
            let event = CHHapticEvent(eventType: .hapticContinuous, parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.45),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.2),
            ], relativeTime: 0, duration: duration)
            let ramp = CHHapticParameterCurve(parameterID: .hapticIntensityControl, controlPoints: [
                .init(relativeTime: 0, value: 0.15),
                .init(relativeTime: duration, value: 1),
            ], relativeTime: 0)
            let player = try engine.makePlayer(with: CHHapticPattern(events: [event], parameterCurves: [ramp]))
            try player.start(atTime: CHHapticTimeImmediate)
            buildUp = player
        } catch {
            buildUp = nil
        }
    }

    private func stopBuildUp() {
        guard let player = buildUp else { return }
        buildUp = nil
        try? player.stop(atTime: CHHapticTimeImmediate)
    }

    private func hapticEngine() throws -> CHHapticEngine {
        if let engine {
            try engine.start()
            return engine
        }
        let engine = try CHHapticEngine()
        engine.isAutoShutdownEnabled = true
        engine.playsHapticsOnly = true
        engine.stoppedHandler = { [weak self] _ in
            Task { @MainActor in self?.buildUp = nil }
        }
        engine.resetHandler = { [weak self] in
            Task { @MainActor in self?.buildUp = nil }
        }
        try engine.start()
        self.engine = engine
        return engine
    }
}

private struct ControlFramePreference: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

struct ReceiverControlOverlay: View {
    @ObservedObject var store: ReceiverControlStore
    @ObservedObject var receiver: StreamReceiver
    @Binding var keyboardActive: Bool
    @Binding var showSettings: Bool
    let keyboardAvailable: Bool
    let keyboardVisibleRect: CGRect?
    let containerSize: CGSize
    let safeInsets: ControlSafeInsets
    /// Physical notch side — see `PhysicalNotchSide`. `nil` in portrait, on
    /// a flat/unknown orientation, or a non-notched device.
    let notchSide: LandscapeTraySide?
    /// Active system-reserved regions (iOS 27.1+; empty before). Divisions
    /// can move the tray's effective side — see `ControlPlacementArea`.
    let reservedRegions: [ControlReservedRegion]
    let haptics: ReceiverHaptics
    let onOccupiedFramesChange: ([CGRect]) -> Void
    /// iPad only: where the Mac canvas goes (the Strip reserves rails).
    var onCanvasChange: (CGRect) -> Void = { _ in }
    /// Where the receiver surface starts in this overlay's coordinates —
    /// `keyboardVisibleRect` is in the surface's own.
    var surfaceOrigin: CGPoint = .zero

    @State private var interaction = ControlInteractionState()
    @State private var initiatingMoveView = false
    /// The Wheel palette on screen, for hit-testing its wedges.
    @State private var wheelHit: WheelHitTarget?
    /// The modifier whose placement a Custom-layout palette blooms around.
    @State private var paletteAnchor: ControlModifier?
    @State private var frames: [String: CGRect] = [:]
    @State private var holdTask: Task<Void, Never>?
    @State private var initiatingModifier: ControlModifier?
    @State private var initiatingItem: ControlTrayItem?
    @State private var gestureActive = false
    @State private var lastHoveredModifier: ControlModifier?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    #if DEBUG
    /// Visual diagnostic for the Avoid Notch runtime path (see the
    /// "Notch Debug Overlay" toggle in Settings → Analytics): red =
    /// computed unsafe/obstacle regions, yellow = the raw (Avoid Notch OFF)
    /// tray frame, green = the final (Avoid Notch's actual effect) frame.
    @AppStorage("notchDebugOverlay") private var notchDebugOverlayEnabled = false
    #endif

    /// Every control is its own free-floating circle: there is no tray card
    /// and no palette card, so nothing blurs the stream except the chips
    /// themselves. The geometry below has to agree with the chip sizes — the
    /// tray/palette frames it produces are what the gesture region hit-tests.
    private enum Metrics {
        static let trayItem: CGFloat = 40
        static let trayGap: CGFloat = 4
        static let collapsed: CGFloat = 46
        static let paletteKey: CGFloat = 38
        static let paletteGap: CGFloat = 5
        /// Slack around the chips so a slightly-off finger still lands inside
        /// the gesture region.
        static let touchSlack: CGFloat = 4
    }

    private var profile: ControlProfile { store.activeProfile }
    /// `visibleGroups` (see its doc) — the Function Tray's ordered item
    /// list clustered for rendering; `functionItems` is the flattened form
    /// used wherever only "is there anything to show at all" matters.
    private var functionGroups: [[ShortcutItem]] {
        // Deliberately independent of `store.autoHidden` — Auto-hide fades
        // this content out in place (opacity/offset/hit-testing, see
        // `body`) rather than removing it, so the transition has something
        // to animate. Never touches the user's own "Show Function Tray"
        // preference.
        guard store.preferences.functionTrayCanBeShown else { return [] }
        return store.activeFunctionTrayProfile.visibleGroups
    }
    private var functionItems: [ShortcutItem] { functionGroups.flatMap { $0 } }
    private var controls: [ControlTrayItem] {
        // The gear is permanent receiver chrome, never a tray item subject
        // to the tray's own visibility rules: it stays reachable whenever
        // the actual shortcut/action tray can't show, whether that's
        // because Allow Input is off or simply because the user turned
        // "Show Control Tray" off — those every-other-item cases only ever
        // drive remote input, which either isn't allowed or isn't wanted
        // right now.
        guard store.preferences.trayCanBeShown else { return [.settings] }
        // Collapsed means the tray is gone — a single gear remains so
        // Settings (where it is un-collapsed) stays reachable without a
        // shake. It ignores per-profile visibility for that reason.
        guard !store.preferences.trayCollapsed else { return [.settings] }
        // Deliberately NOT gated on `store.autoHidden` here — see
        // `functionGroups`'s doc above; the full tray (settings gear
        // included, since it is one of `visibleTrayItems` whenever the tray
        // isn't manually collapsed) stays mounted and fades out in place.
        return profile.visibleTrayItems.filter(capabilityAllows)
    }

    /// Modifiers need a Mac that understands receiver controls; Keyboard
    /// needs the keyboard wire and its own switch.
    private func capabilityAllows(_ item: ControlTrayItem) -> Bool {
        if item.modifier != nil {
            return receiver.macProtocolVersion >= WireProtocol.receiverControlsWireVersion
        }
        return item != .keyboard || (store.preferences.keyboardButtonEnabled && keyboardAvailable)
    }

    /// The tray items the chord gesture can start on in the current
    /// presentation. Custom layouts place items themselves, independent of
    /// the profile's tray visibility.
    private var interactiveTrayItems: [ControlTrayItem] {
        if presentation == .keyboardBar { return keyboardBarTrayItems }
        guard store.isPad, store.effectivePadLayout == .custom else { return controls }
        guard store.preferences.trayCanBeShown, !store.preferences.trayCollapsed else { return [.settings] }
        return ControlTrayItem.allCases.filter(capabilityAllows)
    }

    private var presentation: ReceiverControlPresentation {
        ReceiverControlPresentation.mode(softwareKeyboardVisible: keyboardVisibleRect != nil)
    }

    var body: some View {
        Group {
            switch presentation {
            case .keyboardBar:
                keyboardBarBody
            case .normal:
                if store.isPad {
                    padBody
                } else {
                    phoneBody
                }
            }
        }
        .onAppear {
            if !interaction.latchedModifiers.isEmpty || !interaction.temporaryModifiers.isEmpty {
                apply(interaction.resetAll())
            }
        }
        // A fresh mount (new session, view recreated) always begins visible
        // according to the normal tray settings, then starts counting down
        // if Auto-hide is on.
        .onAppear { store.resetAutoHide() }
        .animation(.snappy(duration: 0.24), value: store.preferences.trayCollapsed)
        // One coordinated animation for the whole Auto-hide fade (Main Tray +
        // Function Tray, see their `.opacity`/`.scaleEffect`/`.offset`)
        // — restrained and short, never the tray's own spring/snappy feel.
        // Reduce Motion collapses it to a near-instant fade.
        .animation(reduceMotion ? .easeInOut(duration: 0.12) : .easeInOut(duration: 0.28), value: store.autoHidden)
        .animation(.snappy(duration: 0.2), value: interaction.phase)
        // Any session interruption — pause, recovery, a failed recovery or a
        // plain disconnect — drops every latched modifier/held control, so no
        // transient control state survives into the next live session.
        .onChange(of: receiver.session.phase) { phase in
            if phase != .connected {
                apply(interaction.resetAll())
                store.setMoveViewActive(false)
            }
            store.resetAutoHide()
        }
        .onChange(of: receiver.displayState) { state in
            if state != .running {
                apply(interaction.resetAll())
                store.setMoveViewActive(false)
            }
            store.resetAutoHide()
        }
        .onChange(of: receiver.videoEnabled) { enabled in
            if !enabled { store.setMoveViewActive(false) }
        }
        .onChange(of: store.preferences.activeControlProfile) { _ in
            apply(interaction.resetAll())
            store.resetAutoHide()
        }
        .onChange(of: store.preferences.activeFunctionTrayProfile) { _ in
            apply(interaction.resetAll())
            store.resetAutoHide()
        }
        // The Mac released its synthetic input state; drop the matching
        // local latch silently. A Mac-originated refresh is not a
        // receiver-confirmed action and must not buzz.
        .onChange(of: receiver.inputResetGeneration) { _ in
            apply(interaction.resetAll())
            store.resetAutoHide()
        }
        .onChange(of: receiver.controlResetGeneration) { _ in
            apply(interaction.resetAll())
            store.resetAutoHide()
        }
        .onChange(of: store.preferences.autoHideEnabled) { _ in store.resetAutoHide() }
        .onChange(of: store.preferences.trayCollapsed) { _ in store.resetAutoHide() }
        .onChange(of: store.preferences.trayCanBeShown) { _ in store.resetAutoHide() }
        .onChange(of: store.preferences.padControlLayout) { _ in
            apply(interaction.resetAll())
            store.resetAutoHide()
        }
        .onChange(of: store.preferences.activeCustomLayoutID) { _ in apply(interaction.resetAll()) }
        .onChange(of: interaction.activeChord) { store.projectChord($0.modifiers) }
        .onDisappear { store.projectChord([]) }
        .onPreferenceChange(WheelHitPreference.self) { wheelHit = $0 }
    }

    @ViewBuilder
    private var phoneBody: some View {
        // The gear is permanent receiver chrome and must always be
        // reachable while this overlay exists at all (its parent only
        // mounts it while actively streaming) — `controls` and `collapsed`
        // already fall back to gear-only whenever the real tray can't show
        // (Allow Input off, or the stored "Show Control Tray" preference
        // off), so there is deliberately no top-level condition here that
        // could hide the gear itself.
        let portrait = containerSize.height > containerSize.width
        let collapsed = store.preferences.trayCollapsed || !store.preferences.trayCanBeShown
        let count = max(controls.count, 1)
        let traySize = calculatedTraySize(collapsed: collapsed, portrait: portrait, count: count)
        // Auto-hide fades the (always-mounted, see `controls`/`functionGroups`)
        // tray content out in place rather than removing it — `collapsed`
        // above is untouched by it, since `store.autoHidden` can only ever
        // be true while `collapsed` is false (see `ReceiverControlStore.
        // scheduleAutoHide`'s guard). Reduce Motion drops the positional/
        // scale nudge and shortens the animation to a near-instant fade.
        let autoHiding = store.autoHidden
        let autoHideRetreat: CGFloat = reduceMotion ? 0 : 3
        let autoHideOpacity: Double = autoHiding ? 0 : 1
        let autoHideScale: CGFloat = autoHiding && !reduceMotion ? 0.98 : 1
        let paletteChord = interaction.paletteChord
        let actions = paletteChord.map(profile.actions(for:)) ?? []
        let paletteSize = calculatedPaletteSize(actions: actions, portrait: portrait)
        let safe = safeInsets
        let layout = ControlTrayGeometry.layout(
            container: CGRect(origin: .zero, size: containerSize),
            safeInsets: safe,
            keyboardVisibleRect: keyboardVisibleRect,
            portrait: portrait,
            side: store.preferences.preferredLandscapeSide,
            traySize: traySize,
            paletteSize: paletteSize,
            avoidNotch: store.preferences.avoidNotch,
            notchSide: notchSide,
            reservedRegions: reservedRegions)
        // Retreats toward the edge the tray actually uses this pass, which a
        // fold can move away from the stored preference.
        let autoHideOffset: CGSize = autoHiding
            ? (portrait
                ? CGSize(width: 0, height: autoHideRetreat)
                : CGSize(width: layout.side == .leading
                                 ? -autoHideRetreat : autoHideRetreat, height: 0))
            : .zero
        let rawLayout = ControlTrayGeometry.layout(
            container: CGRect(origin: .zero, size: containerSize),
            safeInsets: safe,
            keyboardVisibleRect: keyboardVisibleRect,
            portrait: portrait,
            side: store.preferences.preferredLandscapeSide,
            traySize: traySize,
            paletteSize: paletteSize,
            avoidNotch: false,
            notchSide: notchSide,
            reservedRegions: reservedRegions)
        // Independent of the Main Tray's own visibility — only `allowInput`
        // and the Function Tray's own "Show Function Tray" preference
        // gate it (see `functionGroups`). One frame per visual group (see
        // `ControlTrayGeometry.functionTrayLayout`), displaced only while a
        // temporary shortcut palette would actually collide with it.
        let functionGroupSizes = functionGroups.map { calculatedFunctionGroupSize($0, portrait: portrait) }
        // A SwiftUI stack keeps drawing at its intrinsic size when its
        // enclosing frame is smaller. Geometry clamps `layout.trayFrame`
        // to the visible screen, so reconstruct the actual rendered
        // footprint for collision detection instead of under-reporting it.
        let renderedMainTrayFrame = CGRect(
            x: layout.trayFrame.midX - traySize.width / 2,
            y: layout.trayFrame.midY - traySize.height / 2,
            width: traySize.width,
            height: traySize.height)
        // The palette's Grid has the same intrinsic-overflow behavior as
        // the Main Tray stack. Use its live intrinsic footprint whenever
        // `paletteChord` is non-nil; closing the palette passes nil again,
        // so no space remains reserved and the group animates home.
        let renderedPaletteFrame = paletteChord.map { _ in
            CGRect(x: layout.paletteFrame.midX - paletteSize.width / 2,
                   y: layout.paletteFrame.midY - paletteSize.height / 2,
                   width: paletteSize.width,
                   height: paletteSize.height)
        }
        let functionFrames = ControlTrayGeometry.functionTrayLayout(
            container: CGRect(origin: .zero, size: containerSize),
            safeInsets: safe,
            keyboardVisibleRect: keyboardVisibleRect,
            portrait: portrait,
            mainSide: layout.side,
            position: store.preferences.functionTrayPosition,
            mainTrayFrame: renderedMainTrayFrame,
            groupSizes: functionGroupSizes,
            avoiding: renderedPaletteFrame,
            avoidNotch: store.preferences.avoidNotch,
            notchSide: notchSide,
            reservedRegions: reservedRegions)
        #if DEBUG
        // Only computed when the overlay is actually on — a second,
        // avoidNotch:false pass purely for the debug visualization below.
        let rawFunctionFrames = notchDebugOverlayEnabled ? ControlTrayGeometry.functionTrayLayout(
            container: CGRect(origin: .zero, size: containerSize),
            safeInsets: safe,
            keyboardVisibleRect: keyboardVisibleRect,
            portrait: portrait,
            mainSide: rawLayout.side,
            position: store.preferences.functionTrayPosition,
            mainTrayFrame: renderedMainTrayFrame,
            groupSizes: functionGroupSizes,
            avoiding: renderedPaletteFrame,
            avoidNotch: false,
            reservedRegions: reservedRegions) : []
        #endif
        let occupiedFrames = [renderedMainTrayFrame]
            + functionFrames
            + (renderedPaletteFrame.map { [$0] } ?? [])

        ZStack(alignment: .topLeading) {
            if let paletteChord {
                shortcutPalette(actions, portrait: portrait, chord: paletteChord)
                    .frame(width: layout.paletteFrame.width, height: layout.paletteFrame.height)
                    .position(x: layout.paletteFrame.midX, y: layout.paletteFrame.midY)
                    .transition(.scale(scale: 0.75).combined(with: .opacity))
            }

            if collapsed {
                Image(systemName: ControlTrayItem.settings.displayLabel)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: Metrics.collapsed, height: Metrics.collapsed)
                    .background(frameReader("tray:more"))
                    .background(chip(selected: false))
                    .accessibilityLabel(ControlTrayItem.settings.title)
                    .position(x: layout.trayFrame.midX, y: layout.trayFrame.midY)
            } else {
                controlsRow(axis: layout.axis == .horizontal ? .horizontal : .vertical)
                    .frame(width: layout.trayFrame.width, height: layout.trayFrame.height)
                    .position(x: layout.trayFrame.midX, y: layout.trayFrame.midY)
                    .opacity(autoHideOpacity)
                    .scaleEffect(autoHideScale)
                    .offset(autoHideOffset)
                    .allowsHitTesting(!autoHiding)
            }

            ForEach(Array(functionGroups.enumerated()), id: \.offset) { index, group in
                if index < functionFrames.count {
                    let frame = functionFrames[index]
                    functionGroupCluster(group, axis: layout.axis == .horizontal ? .horizontal : .vertical)
                        .frame(width: frame.width, height: frame.height)
                        .position(x: frame.midX, y: frame.midY)
                        .opacity(autoHideOpacity)
                        .scaleEffect(autoHideScale)
                        .offset(autoHideOffset)
                        .allowsHitTesting(!autoHiding)
                        .animation(.snappy(duration: 0.24), value: frame)
                }
            }

            if let selected = selectedAction(in: actions) {
                shortcutHUD(selected)
                    .position(x: containerSize.width / 2,
                              y: max(safeInsets.top + 48, layout.paletteFrame.minY - 34))
                    .transition(.opacity.combined(with: .scale))
            }

            Color.clear
                .frame(width: containerSize.width, height: containerSize.height)
                .contentShape(ControlRegionShape(rects: [autoHiding ? .zero : layout.trayFrame]
                                                    + (paletteChord == nil ? [] : [layout.paletteFrame])))
                .gesture(controlGesture())

            #if DEBUG
            if notchDebugOverlayEnabled {
                notchDebugOverlay(container: CGRect(origin: .zero, size: containerSize),
                                  safeInsets: safe, portrait: portrait, notchSide: notchSide,
                                  mainRaw: rawLayout.trayFrame, mainFinal: layout.trayFrame,
                                  functionRaw: rawFunctionFrames, functionFinal: functionFrames)
                    .allowsHitTesting(false)
            }
            #endif
        }
        .coordinateSpace(name: "receiverControls")
        .frame(width: containerSize.width, height: containerSize.height,
               alignment: .topLeading)
        .onPreferenceChange(ControlFramePreference.self) {
            frames = $0
            #if DEBUG
            // `windowScene.interfaceOrientation` and the raw
            // `window.safeAreaInsets` that fed `notchSide`/`safe` are logged
            // separately as `safeAreaTrace:` (see `ReceiverSafeAreaProbe`,
            // the only place with a UIWindow reference); this line covers
            // everything downstream of that: the resolved insets this pass
            // actually used, which physical side (if any) was treated as the
            // notch, the depth used for its obstacle, and the raw vs. final
            // tray frame.
            let notchDepth: CGFloat = notchSide == .leading ? safe.leading
                : notchSide == .trailing ? safe.trailing : 0
            Log.info("notchTrace: orientation=\(portrait ? "portrait" : "landscape") "
                     + "avoidNotch=\(store.preferences.avoidNotch) trayPreferredSide=\(store.preferences.preferredLandscapeSide) "
                     + "trayEffectiveSide=\(layout.side) reservedRegions=\(reservedRegions) "
                     + "container=\(containerSize) resolvedSafeInsets=\(safe) "
                     + "physicalNotchSide=\(notchSide.map(String.init(describing:)) ?? "none") notchDepthUsed=\(notchDepth) "
                     + "rawMain=\(rawLayout.trayFrame) "
                     + "exclusions=\(ControlTrayGeometry.unsafeRegions(in: CGRect(origin: .zero, size: containerSize), safeInsets: safe, portrait: portrait, notchSide: notchSide)) "
                     + "finalMain=\(layout.trayFrame) renderedControls=\($0)")
            #endif
        }
        .onAppear { onOccupiedFramesChange(occupiedFrames) }
        .onChange(of: occupiedFrames) { onOccupiedFramesChange($0) }
    }

    #if DEBUG
    /// Draws exactly what `ControlTrayGeometry` computed this layout pass —
    /// nothing recomputed or approximated — so a mismatch between this
    /// overlay and the physical notch/home-indicator edge on a real device
    /// says precisely where the runtime path is wrong: red not aligned with
    /// the physical obstruction means the safe-area/notch-side input is bad;
    /// a colored (final) frame still overlapping red means the geometry
    /// math itself isn't consuming its own avoidance result. Main Tray uses
    /// yellow (raw) / green (final); Function Tray uses orange (raw) / cyan
    /// (final) — a distinct pair per tray so it stays obvious which frame
    /// belongs to which control while both are avoiding the same notch.
    @ViewBuilder
    private func notchDebugOverlay(container: CGRect, safeInsets: ControlSafeInsets, portrait: Bool,
                                   notchSide: LandscapeTraySide?,
                                   mainRaw: CGRect, mainFinal: CGRect,
                                   functionRaw: [CGRect], functionFinal: [CGRect]) -> some View {
        ForEach(Array(ControlTrayGeometry.unsafeRegions(in: container, safeInsets: safeInsets, portrait: portrait, notchSide: notchSide).enumerated()),
                id: \.offset) { _, rect in
            Rectangle().fill(Color.red.opacity(0.35))
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
        }
        // Pink: system-reported reserved regions (iOS 27.1+), exactly as
        // the geometry received them.
        ForEach(Array(reservedRegions.enumerated()), id: \.offset) { _, region in
            Rectangle().fill(Color.pink.opacity(region.kind == .division ? 0.35 : 0.2))
                .frame(width: region.frame.width, height: region.frame.height)
                .position(x: region.frame.midX, y: region.frame.midY)
        }
        Rectangle().strokeBorder(Color.yellow, lineWidth: 2)
            .frame(width: mainRaw.width, height: mainRaw.height)
            .position(x: mainRaw.midX, y: mainRaw.midY)
        Rectangle().strokeBorder(Color.green, lineWidth: 2)
            .frame(width: mainFinal.width, height: mainFinal.height)
            .position(x: mainFinal.midX, y: mainFinal.midY)
        ForEach(Array(functionRaw.enumerated()), id: \.offset) { _, rect in
            Rectangle().strokeBorder(Color.orange, lineWidth: 2)
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
        }
        ForEach(Array(functionFinal.enumerated()), id: \.offset) { _, rect in
            Rectangle().strokeBorder(Color.cyan, lineWidth: 2)
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
        }
    }
    #endif

    private func calculatedTraySize(collapsed: Bool, portrait: Bool, count: Int) -> CGSize {
        let thickness = Metrics.trayItem + Metrics.touchSlack
        guard !collapsed else {
            return CGSize(width: Metrics.collapsed + Metrics.touchSlack,
                          height: Metrics.collapsed + Metrics.touchSlack)
        }
        let length = CGFloat(count) * Metrics.trayItem
            + CGFloat(Swift.max(0, count - 1)) * Metrics.trayGap + Metrics.touchSlack
        return portrait
            ? CGSize(width: length, height: thickness)
            : CGSize(width: thickness, height: length)
    }

    /// Size of ONE Function Tray group's own cluster frame — each group
    /// gets its own independently-positioned frame now (see
    /// `ControlTrayGeometry.functionTrayLayout`), not a shared combined one.
    private func calculatedFunctionGroupSize(_ group: [ShortcutItem], portrait: Bool) -> CGSize {
        let thickness = Metrics.trayItem + Metrics.touchSlack
        let length = CGFloat(group.count) * Metrics.trayItem
            + CGFloat(Swift.max(0, group.count - 1)) * Metrics.trayGap + Metrics.touchSlack
        return portrait
            ? CGSize(width: length, height: thickness)
            : CGSize(width: thickness, height: length)
    }

    private func calculatedPaletteSize(actions: [ShortcutItem], portrait: Bool) -> CGSize {
        let count = max(actions.count, 1)
        func span(_ n: Int) -> CGFloat {
            CGFloat(n) * Metrics.paletteKey
                + CGFloat(Swift.max(0, n - 1)) * Metrics.paletteGap + Metrics.touchSlack
        }
        guard portrait else { return CGSize(width: span(1), height: span(count)) }
        let rows = actions.count > 8 ? 2 : 1
        let columns = max(1, Int(ceil(Double(count) / Double(rows))))
        return CGSize(width: span(columns), height: span(rows))
    }

    /// The one visual primitive: a translucent circle. Deliberately lighter
    /// than a system material card — it has to read over live video without
    /// frosting the desktop behind it.
    private func chip(selected: Bool) -> some View {
        Circle()
            .fill(.ultraThinMaterial)
            .opacity(selected ? 0.9 : 0.45)
            .overlay(Circle().fill(selected ? Color.white.opacity(0.82)
                                            : Color.white.opacity(0.07)))
            .overlay(Circle().strokeBorder(.white.opacity(selected ? 0.55 : 0.28),
                                           lineWidth: 0.5))
            .shadow(color: .black.opacity(0.28), radius: 5, y: 1)
    }

    @ViewBuilder
    private func controlsRow(axis: Axis) -> some View {
        let stack = axis == .horizontal
            ? AnyLayout(HStackLayout(spacing: Metrics.trayGap))
            : AnyLayout(VStackLayout(spacing: Metrics.trayGap))
        stack {
            ForEach(controls) { item in
                if let modifier = item.modifier {
                    modifierButton(modifier)
                } else {
                    actionButton(item)
                }
            }
        }
    }

    /// Function Tray items fire immediately on tap — no modifier hold, no
    /// palette — so each is a plain button, much simpler than
    /// `controlsRow`'s chord/hold gesture machinery. Renders ONE group's
    /// cluster; each group gets its own independently-positioned frame
    /// (see `ControlTrayGeometry.functionTrayLayout`), which is what keeps
    /// e.g. the default Zoom and Edit clusters visually distinct rather
    /// than one continuous panel — never a single solid tray/card
    /// background.
    private func functionGroupCluster(_ group: [ShortcutItem], axis: Axis) -> some View {
        let stack = axis == .horizontal
            ? AnyLayout(HStackLayout(spacing: Metrics.trayGap))
            : AnyLayout(VStackLayout(spacing: Metrics.trayGap))
        return stack {
            ForEach(group) { item in functionButton(item) }
        }
    }

    private func functionButton(_ item: ShortcutItem) -> some View {
        ShortcutButtonFaceView(face: item.face, diameter: Metrics.trayItem)
        .foregroundStyle(.white)
        .frame(width: Metrics.trayItem, height: Metrics.trayItem)
        .background(chip(selected: false))
        .contentShape(Circle())
        .onTapGesture { performFunctionAction(item) }
        .accessibilityLabel(item.title)
    }

    private func performFunctionAction(_ item: ShortcutItem) {
        OneTapActionRunner.run(item.action, receiver: receiver, inputAllowed: { store.preferences.allowInput })
        haptics.play(.confirmation)
        store.scheduleAutoHide()
    }

    private func modifierButton(_ modifier: ControlModifier) -> some View {
        let selected = interaction.latchedModifiers.contains(modifier)
            || interaction.temporaryModifiers.contains(modifier)
        return Text(modifier.symbol)
            .font(.system(size: 21, weight: .semibold))
            .foregroundStyle(selected ? Color.black : Color.white)
            .frame(width: Metrics.trayItem, height: Metrics.trayItem)
            .background(frameReader("modifier:\(modifier.rawValue)"))
            .background(chip(selected: selected))
            .accessibilityLabel(modifier.title)
            .accessibilityValue(selected ? "On" : "Off")
    }

    private func actionButton(_ item: ControlTrayItem) -> some View {
        Group {
            if item == .escape || item == .tab {
                Text(item.displayLabel).font(.system(size: 13, weight: .semibold))
            } else {
                Image(systemName: item.displayLabel)
                    .font(.system(size: 18, weight: .semibold))
            }
        }
        .foregroundStyle(.white)
        .frame(width: Metrics.trayItem, height: Metrics.trayItem)
        .background(frameReader("tray:\(item.rawValue)"))
        .background(chip(selected: false))
        .accessibilityLabel(item.title)
    }

    private func shortcutPalette(_ actions: [ShortcutItem], portrait: Bool,
                                 chord: ModifierChord) -> some View {
        Group {
            if actions.isEmpty {
                Text("No shortcuts for \(chord.displayName)")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(Capsule().fill(.ultraThinMaterial).opacity(0.45))
                    .overlay(Capsule().strokeBorder(.white.opacity(0.28), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.28), radius: 5, y: 1)
            } else {
                let rows = portrait ? (actions.count > 8 ? 2 : 1) : actions.count
                Grid(horizontalSpacing: Metrics.paletteGap, verticalSpacing: Metrics.paletteGap) {
                    ForEach(0..<rows, id: \.self) { row in
                        GridRow {
                            ForEach(Array(actions.enumerated()).filter { $0.offset % rows == row },
                                    id: \.element.id) { _, action in
                                shortcutButton(action, portrait: portrait)
                            }
                        }
                    }
                }
            }
        }
    }

    private func shortcutButton(_ action: ShortcutItem, portrait: Bool,
                                diameter: CGFloat = Metrics.paletteKey) -> some View {
        let selected = interaction.selectedActionID == action.id
        return ShortcutButtonFaceView(face: action.face, diameter: diameter)
        .foregroundStyle(selected ? Color.black : Color.white)
        .frame(width: diameter, height: diameter)
        .background(frameReader("action:\(action.id)"))
        .background(Group {
            if store.isPad {
                PadChip(selected: selected, onRail: false)
            } else {
                chip(selected: selected)
            }
        })
        .scaleEffect(selected ? 1.12 : 1)
        .animation(.snappy(duration: 0.14), value: selected)
        .accessibilityLabel(action.title)
    }

    /// Shows the combination the finger is currently on — the live chord,
    /// not the shortcut's stored one, so a latched modifier reads correctly.
    private func shortcutHUD(_ action: ShortcutItem) -> some View {
        Text(interaction.activeChord.hudText(for: action.displayKey))
        .font(.system(size: 16, weight: .semibold, design: .rounded))
        .foregroundStyle(.white)
        .padding(.horizontal, 13)
        .padding(.vertical, 7)
        .background(Capsule().fill(.ultraThinMaterial).opacity(0.5))
        .overlay(Capsule().strokeBorder(.white.opacity(0.3), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.3), radius: 6, y: 1)
    }

    private func frameReader(_ id: String) -> some View {
        GeometryReader { proxy in
            Color.clear.preference(key: ControlFramePreference.self,
                                   value: [id: proxy.frame(in: .named("receiverControls"))])
        }
    }

    private func controlGesture() -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("receiverControls"))
            .onChanged { value in
                if !gestureActive {
                    gestureActive = true
                    // A touch is down on the tray: reveal immediately (a
                    // no-op if already visible) and never let a pending
                    // Auto-hide fire out from under it mid-interaction.
                    store.beginAutoHideActivity()
                    initiatingItem = trayItem(at: value.startLocation)
                    initiatingMoveView = initiatingItem == nil
                        && frames["control:moveView"]?.contains(value.startLocation) == true
                    if let modifier = initiatingItem?.modifier {
                        initiatingModifier = modifier
                        paletteAnchor = modifier
                        interaction.press(modifier)
                        holdTask?.cancel()
                        holdTask = Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(350))
                            guard !Task.isCancelled, interaction.phase == .pressed(modifier) else { return }
                            apply(interaction.beginPalette(with: modifier))
                        }
                    } else if let actionID = action(at: value.startLocation)?.id {
                        apply(interaction.selectAction(actionID))
                    }
                }

                // Sliding onto another modifier only builds a chord during a
                // hold; a latched palette is browsed, not rebuilt.
                if case .palette = interaction.phase {
                    let hovered = modifier(at: value.location)
                    if hovered != lastHoveredModifier {
                        lastHoveredModifier = hovered
                        if let hovered { apply(interaction.addTemporaryModifier(hovered)) }
                    }
                }
                // Highlight tracking runs for any visible palette — including
                // the persistent one a latched modifier leaves on screen —
                // except when the gesture began on a plain tray button.
                if interaction.paletteChord != nil, initiatingItem?.modifier != nil || initiatingItem == nil {
                    apply(interaction.selectAction(action(at: value.location)?.id))
                }
            }
            .onEnded { value in
                holdTask?.cancel()
                let finishedOn = selectedAction(under: value.location)
                if let modifier = initiatingModifier {
                    // A press that never became a hold is a latch toggle;
                    // otherwise the hold ends on whatever key it is over.
                    if interaction.phase == .pressed(modifier) {
                        apply(interaction.tap(modifier))
                    } else {
                        apply(interaction.finish(with: finishedOn))
                    }
                } else if let finishedOn {
                    // Tap on a latched chord's palette: fire it and keep the
                    // latch, so ⌘ then C then V is two shortcuts, not one.
                    apply(interaction.finish(with: finishedOn))
                } else if let item = initiatingItem,
                          frames["tray:\(item.rawValue)"]?.contains(value.location) == true {
                    perform(item)
                } else if initiatingMoveView,
                          frames["control:moveView"]?.contains(value.location) == true {
                    store.setMoveViewActive(!store.moveViewActive)
                    haptics.play(.selection)
                } else if interaction.paletteChord != nil {
                    apply(interaction.finish(with: nil))
                }
                initiatingModifier = nil
                initiatingItem = nil
                initiatingMoveView = false
                lastHoveredModifier = nil
                gestureActive = false
                // The touch lifted: safe to (re)start counting down again,
                // unless a latched chord is still active (`scheduleAutoHide`
                // itself declines in that case).
                store.scheduleAutoHide(interactionIdle: interaction.phase == .idle)
            }
    }

    private func trayItem(at point: CGPoint) -> ControlTrayItem? {
        interactiveTrayItems.first { item in
            if let modifier = item.modifier {
                return frames["modifier:\(modifier.rawValue)"]?.contains(point) == true
            }
            return frames["tray:\(item.rawValue)"]?.contains(point) == true
        }
    }

    private func modifier(at point: CGPoint) -> ControlModifier? {
        ControlModifier.allCases.first { frames["modifier:\($0.rawValue)"]?.contains(point) == true }
    }

    private func action(at point: CGPoint) -> ShortcutItem? {
        let actions = profile.actions(for: interaction.activeChord)
        if let wheelHit, wheelHit.actionIDs == actions.map(\.id),
           let index = wheelHit.layout.segmentIndex(at: point) {
            return actions[index]
        }
        return actions.first { frames["action:\($0.id)"]?.contains(point) == true }
    }

    private func selectedAction(in actions: [ShortcutItem]) -> ShortcutItem? {
        actions.first { $0.id == interaction.selectedActionID }
    }

    /// The highlighted shortcut, but only if the finger actually lifted on it
    /// — sliding off a key must cancel it, not fire it.
    private func selectedAction(under point: CGPoint) -> ShortcutItem? {
        guard let under = action(at: point), under.id == interaction.selectedActionID else { return nil }
        return under
    }

    private func perform(_ item: ControlTrayItem) {
        switch item {
        case .escape:
            receiver.sendKeyboardPress(usage: 41)
            haptics.play(.confirmation)
        case .tab:
            receiver.sendKeyboardPress(usage: 43)
            haptics.play(.confirmation)
        case .dock:
            receiver.sendKeyboardPress(usage: 7,
                                       modifiers: [ControlModifier.option.rawValue,
                                                   ControlModifier.command.rawValue])
            haptics.play(.confirmation)
        case .keyboard:
            keyboardActive.toggle()
            haptics.play(.selection)
        case .settings:
            apply(interaction.resetAll())
            showSettings = true
            haptics.play(.settings)
        default: break
        }
    }

    private func apply(_ effects: [ControlInteractionEffect]) {
        for effect in effects {
            switch effect {
            case .modifierDown(let modifier): receiver.sendModifier(modifier, down: true)
            case .modifierUp(let modifier): receiver.sendModifier(modifier, down: false)
            case .execute(let item):
                if case .keyboardShortcut(let shortcut) = item.action, shortcut.additionalUsages.isEmpty {
                    receiver.sendKeyboardPress(usage: shortcut.usage,
                                               modifiers: shortcut.modifiers.modifiers.map(\.rawValue))
                } else {
                    // User-made palette actions: chords, sequences, system
                    // actions — the same runner as one-tap buttons.
                    OneTapActionRunner.run(item.action, receiver: receiver,
                                           inputAllowed: { store.preferences.allowInput })
                }
            case .haptic(let event): haptics.play(event)
            }
        }
    }
}

// MARK: - Keyboard accessory bar

extension ReceiverControlOverlay {
    /// The tray items the bar's gesture can start on — see `KeyboardBarItem`.
    fileprivate var keyboardBarTrayItems: [ControlTrayItem] {
        keyboardBarItems.map { item in
            switch item {
            case .modifier(let modifier): return ControlTrayItem.item(for: modifier)
            case .escape: return .escape
            case .tab: return .tab
            case .dismissKeyboard: return .keyboard
            }
        }
    }

    private var keyboardBarItems: [KeyboardBarItem] {
        KeyboardBarItem.defaultItems.filter { item in
            if case .modifier = item { return capabilityAllows(.command) }
            return true
        }
    }

    /// While the software keyboard is up, a flat bar right above it holds
    /// only keyboard companions — modifiers, Escape, Tab, and a dismiss
    /// key — instead of the whole receiver UI squeezed into what's left.
    /// Modifiers here are the same chord as everywhere else: latch ⌘, type
    /// C, and the Mac gets ⌘C. The normal controls return, unchanged, when
    /// the keyboard closes.
    @ViewBuilder
    var keyboardBarBody: some View {
        let keyboardTop = (keyboardVisibleRect?.maxY ?? containerSize.height) + surfaceOrigin.y
        let items = keyboardBarItems
        let item: CGFloat = store.isPad ? (PadControlMetrics.baseItem * CGFloat(PadControlScale.clamped(store.preferences.padControlScale))).rounded() : 38
        let gap: CGFloat = 8
        let padding: CGFloat = 6
        let barWidth = CGFloat(items.count) * item + CGFloat(items.count - 1) * gap + padding * 2
        let bar = CGRect(x: containerSize.width / 2 - barWidth / 2, y: keyboardTop - 8 - item - padding * 2,
                         width: barWidth, height: item + padding * 2)
        let cells = items.indices.map { index in
            CGRect(x: bar.minX + padding + CGFloat(index) * (item + gap), y: bar.minY + padding, width: item, height: item)
        }
        let paletteChord = interaction.paletteChord
        let actions = paletteChord.map(profile.actions(for:)) ?? []
        let key = item * 0.92
        let perRow = max(1, Int((containerSize.width - 32 + gap) / (key + gap)))
        let rows = Int(ceil(Double(max(actions.count, 1)) / Double(perRow)))
        let columns = min(max(actions.count, 1), perRow)
        let paletteSize = CGSize(width: CGFloat(columns) * key + CGFloat(columns - 1) * gap + padding * 2,
                                 height: CGFloat(rows) * key + CGFloat(rows - 1) * gap + padding * 2)
        let paletteFrame = CGRect(x: containerSize.width / 2 - paletteSize.width / 2,
                                  y: bar.minY - 10 - paletteSize.height,
                                  width: paletteSize.width, height: paletteSize.height)
        let keys: [(action: ShortcutItem, frame: CGRect)] = actions.enumerated().map { index, action in
            let row = index / perRow
            let column = index % perRow
            return (action, CGRect(x: paletteFrame.minX + padding + CGFloat(column) * (key + gap),
                                   y: paletteFrame.minY + padding + CGFloat(row) * (key + gap), width: key, height: key))
        }
        ZStack(alignment: .topLeading) {
            ControlTray()
                .frame(width: bar.width, height: bar.height)
                .position(x: bar.midX, y: bar.midY)
                .allowsHitTesting(false)
            ForEach(Array(zip(items, cells)), id: \.0) { entry, cell in
                keyboardBarKey(entry, frame: cell)
            }
            if let paletteChord {
                if actions.isEmpty {
                    emptyPaletteLabel(paletteChord)
                        .position(x: paletteFrame.midX, y: paletteFrame.maxY - 18)
                } else {
                    ControlTray()
                        .frame(width: paletteFrame.width, height: paletteFrame.height)
                        .position(x: paletteFrame.midX, y: paletteFrame.midY)
                        .allowsHitTesting(false)
                    ForEach(keys, id: \.action.id) { key in
                        shortcutButton(key.action, portrait: true, diameter: key.frame.width)
                            .position(x: key.frame.midX, y: key.frame.midY)
                    }
                }
            }
            if let selected = selectedAction(in: actions) {
                shortcutHUD(selected)
                    .position(x: containerSize.width / 2, y: max(safeInsets.top + 30, paletteFrame.minY - 26))
            }
            Color.clear
                .frame(width: containerSize.width, height: containerSize.height)
                .contentShape(ControlRegionShape(rects: [bar] + (paletteChord == nil ? [] : [paletteFrame])))
                .gesture(controlGesture())
        }
        .coordinateSpace(name: "receiverControls")
        .frame(width: containerSize.width, height: containerSize.height, alignment: .topLeading)
        .onPreferenceChange(ControlFramePreference.self) { frames = $0 }
        .onAppear { onOccupiedFramesChange([bar]) }
    }

    @ViewBuilder
    private func keyboardBarKey(_ entry: KeyboardBarItem, frame: CGRect) -> some View {
        switch entry {
        case .modifier(let modifier):
            let selected = interaction.latchedModifiers.contains(modifier)
                || interaction.temporaryModifiers.contains(modifier)
                || interaction.phase == .pressed(modifier)
            Text(modifier.symbol)
                .font(.system(size: frame.width * 0.46, weight: .semibold))
                .foregroundStyle(selected ? Color.black : Color.white)
                .frame(width: frame.width, height: frame.height)
                .background(frameReader("modifier:\(modifier.rawValue)"))
                .background(PadChip(selected: selected, onRail: true))
                .position(x: frame.midX, y: frame.midY)
                .accessibilityLabel(modifier.title)
                .accessibilityValue(selected ? "On" : "Off")
        case .escape, .tab:
            let item: ControlTrayItem = entry == .escape ? .escape : .tab
            Text(item.displayLabel)
                .font(.system(size: frame.width * 0.3, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: frame.width, height: frame.height)
                .background(frameReader("tray:\(item.rawValue)"))
                .background(PadChip(selected: false, onRail: true))
                .position(x: frame.midX, y: frame.midY)
                .accessibilityLabel(item.title)
        case .dismissKeyboard:
            Image(systemName: "keyboard.chevron.compact.down")
                .font(.system(size: frame.width * 0.38, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: frame.width, height: frame.height)
                .background(frameReader("tray:\(ControlTrayItem.keyboard.rawValue)"))
                .background(PadChip(selected: false, onRail: true))
                .position(x: frame.midX, y: frame.midY)
                .accessibilityLabel(Text("Hide Keyboard"))
        }
    }
}

// MARK: - iPad presentation (Strip / Overlay / Custom)

/// One placed iPad control, resolved for this layout pass.
private struct PadPlacedControl: Identifiable {
    let id: String
    let kind: CustomControlKind
    /// The control's circle.
    let frame: CGRect
    /// The circle plus its caption while Strip hints show.
    let cell: CGRect
}

extension ReceiverControlOverlay {
    private var padMetricsScale: Double { store.preferences.padControlScale }
    private var padCollapsed: Bool { store.preferences.trayCollapsed || !store.preferences.trayCanBeShown }

    /// Move View needs live video and Local View Navigation — the button
    /// never bypasses that policy.
    private var padShowsMoveView: Bool {
        !padCollapsed && LocalViewNavigationPolicy.showsMoveView(
            controlVisible: true, localNavigationAllowed: store.preferences.allowLocalViewNavigation,
            videoEnabled: receiver.videoEnabled)
    }

    @ViewBuilder
    var padBody: some View {
        let mode = store.effectivePadLayout
        let container = CGRect(origin: .zero, size: containerSize)
        ZStack(alignment: .topLeading) {
            if mode == .custom, let layout = store.preferences.activeCustomLayout {
                customLayoutContent(layout, container: container)
            } else {
                edgeLayoutContent(mode: mode, container: container)
            }
            if store.moveViewActive {
                moveViewBanner
                    .position(x: containerSize.width / 2, y: safeInsets.top + 34)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .coordinateSpace(name: "receiverControls")
        .frame(width: containerSize.width, height: containerSize.height, alignment: .topLeading)
        .onPreferenceChange(ControlFramePreference.self) { frames = $0 }
        .animation(.snappy(duration: 0.22), value: store.moveViewActive)
    }

    // MARK: Strip / Overlay

    @ViewBuilder
    private func edgeLayoutContent(mode: PadControlLayoutMode, container: CGRect) -> some View {
        let strip = mode == .strip
        let hints = strip && store.preferences.padShowControlHints
        let metrics = PadControlMetrics(scale: padMetricsScale, showsHints: hints)
        let mainGroups = padCollapsed ? [] : padMainGroups
        let mainKinds = mainGroups.flatMap { $0 }
        let groups = functionGroups
        let mainEdge = store.preferences.padMainEdge
        let functionEdge = store.preferences.padFunctionEdge
        let pass: (CGFloat?) -> PadEdgeLayout = { keyboardTop in
            PadEdgeGeometry.layout(container: container, safeInsets: safeInsets, reservesStrips: strip,
                                   mainEdge: mainEdge, functionEdge: functionEdge,
                                   mainGroupCounts: mainGroups.map(\.count),
                                   mainGroupAlignments: PadRailComposition.alignments(for: mainGroups),
                                   functionGroupCounts: groups.map(\.count), metrics: metrics,
                                   keyboardTop: keyboardTop)
        }
        let firstPass = pass(nil)
        let keyboardTop = keyboardVisibleRect.map { $0.maxY + firstPass.canvas.minY }
        let layout = keyboardTop == nil ? firstPass : pass(keyboardTop)
        // Collapsed (or the tray can't show): only the gear, floating at the
        // Main edge, never a rail.
        let gearFrame: CGRect? = padCollapsed ? PadEdgeGeometry.layout(
            container: container, safeInsets: safeInsets, reservesStrips: false,
            mainEdge: mainEdge, functionEdge: functionEdge, mainGroupCounts: [1], mainGroupAlignments: [.end],
            functionGroupCounts: [],
            metrics: PadControlMetrics(scale: padMetricsScale), keyboardTop: keyboardTop).mainFrame : nil
        let mainControls: [PadPlacedControl] = zip(mainKinds, layout.mainCells).map { kind, cell in
            PadPlacedControl(id: padID(kind), kind: kind,
                             frame: PadEdgeGeometry.circleFrame(inCell: cell, metrics: metrics), cell: cell)
        }
        let functionControls: [(item: ShortcutItem, frame: CGRect)] =
            zip(groups.flatMap { $0 }, layout.functionCells).map { item, cell in
                (item, PadEdgeGeometry.circleFrame(inCell: cell, metrics: metrics))
            }
        let autoHiding = store.autoHidden
        let paletteChord = interaction.paletteChord
        let actions = paletteChord.map(profile.actions(for:)) ?? []
        let keySize = hints
            ? CGSize(width: 132 * metrics.scale, height: 36 * metrics.scale)
            : CGSize(width: metrics.item * 0.92, height: metrics.item * 0.92)
        let paletteBounds = Self.boundsAboveKeyboard(
            layout.canvas.insetBy(dx: PadControlMetrics.edgeMargin, dy: PadControlMetrics.edgeMargin),
            keyboardTop: keyboardTop)
        let wheel: WheelPaletteLayout? = store.preferences.padOverlayPaletteStyle == .wheel && !actions.isEmpty
            ? padWheelAnchor(mainControls: mainControls, gearFrame: gearFrame).flatMap {
                WheelPaletteGeometry.layout(count: actions.count, anchor: $0, keyDiameter: metrics.item * 0.92,
                                            spacing: metrics.gap, bounds: paletteBounds)
            } : nil
        let grid = PadEdgeGeometry.paletteGrid(count: actions.count, key: keySize, gap: metrics.gap,
                                               edge: mainEdge, available: paletteBounds.size)
        let paletteAnchor = PadEdgeGeometry.paletteAnchor(for: layout, mainEdge: mainEdge, functionEdge: functionEdge)
        let paletteFrame: CGRect? = paletteChord.flatMap { _ in
            (paletteAnchor ?? gearFrame).map {
                PadEdgeGeometry.paletteFrame(size: actions.isEmpty ? CGSize(width: 220, height: 36) : grid.size,
                                             anchor: $0, edge: mainEdge, bounds: paletteBounds, gap: metrics.gap * 2)
            }
        }
        let paletteKeys: [(action: ShortcutItem, frame: CGRect)] = wheel != nil ? [] : paletteFrame.map { frame in
            actions.enumerated().map { index, action in
                // Column-major along a vertical edge, row-major along a
                // horizontal one — so keys read outward from the rail.
                let row = mainEdge.stacksVertically ? index % grid.rows : index / grid.columns
                let column = mainEdge.stacksVertically ? index / grid.rows : index % grid.columns
                let origin = CGPoint(x: frame.minX + CGFloat(column) * (keySize.width + metrics.gap),
                                     y: frame.minY + CGFloat(row) * (keySize.height + metrics.gap))
                return (action, CGRect(origin: origin, size: keySize))
            }
        } ?? []
        // Overlay groups sit in compact floating trays; the Strip's solid
        // rail already holds its controls.
        let trays: [CGRect] = strip ? [] : (layout.mainSegments + layout.functionSegments)
            .map { PadEdgeGeometry.circleRun(of: $0, metrics: metrics).insetBy(dx: -Self.trayPadding, dy: -Self.trayPadding) }
        let occupied = layout.mainSegments.map(\.frame) + layout.functionSegments.map(\.frame)
            + [gearFrame, paletteFrame].compactMap { $0 }

        ZStack(alignment: .topLeading) {
            ForEach(Array(layout.strips.enumerated()), id: \.offset) { _, strip in
                PadStripBackground(edge: strip.edge)
                    .frame(width: strip.frame.width, height: strip.frame.height)
                    .position(x: strip.frame.midX, y: strip.frame.midY)
            }
            ForEach(Array(trays.enumerated()), id: \.offset) { _, tray in
                ControlTray()
                    .frame(width: tray.width, height: tray.height)
                    .position(x: tray.midX, y: tray.midY)
                    .opacity(autoHiding ? 0 : 1)
                    .allowsHitTesting(false)
            }
            if let gearFrame {
                padControlChip(.tray(.settings), frame: gearFrame, onRail: false, hint: nil)
            }
            ForEach(mainControls) { control in
                Group {
                    if case .function(let id) = control.kind, let item = functionItem(id) {
                        padFunctionChip(item, frame: control.frame, onRail: true,
                                        hint: hints ? item.title.lowercased() : nil)
                    } else {
                        padControlChip(control.kind, frame: control.frame, onRail: true,
                                       hint: hints ? padHint(control.kind) : nil)
                    }
                }
                .opacity(autoHiding ? 0 : 1)
                .allowsHitTesting(!autoHiding)
            }
            ForEach(Array(functionControls.enumerated()), id: \.element.item.id) { _, control in
                padFunctionChip(control.item, frame: control.frame, onRail: true,
                                hint: hints ? control.item.title.lowercased() : nil)
                    .opacity(autoHiding ? 0 : 1)
                    .allowsHitTesting(!autoHiding)
            }
            if let paletteChord, let wheel {
                WheelPaletteView(layout: wheel, actions: actions, selectedID: interaction.selectedActionID,
                                 centerLabel: paletteChord.symbols)
                    .transition(.scale(scale: 0.85).combined(with: .opacity))
            } else if let paletteChord, let paletteFrame {
                if !actions.isEmpty {
                    ControlTray()
                        .frame(width: paletteFrame.width + Self.trayPadding * 2,
                               height: paletteFrame.height + Self.trayPadding * 2)
                        .position(x: paletteFrame.midX, y: paletteFrame.midY)
                        .allowsHitTesting(false)
                }
                padPalette(actions: actions, keys: paletteKeys, frame: paletteFrame, chord: paletteChord,
                           pills: hints)
            }
            if let selected = selectedAction(in: actions), let hudAnchor = wheel?.frame ?? paletteFrame {
                shortcutHUD(selected)
                    .position(x: hudAnchor.midX,
                              y: max(safeInsets.top + 30, hudAnchor.minY - 28))
                    .transition(.opacity.combined(with: .scale))
            }
            // One-tap Function actions (Show Desktop, Control Center) sit
            // outside this region and take their own taps.
            Color.clear
                .frame(width: containerSize.width, height: containerSize.height)
                .contentShape(ControlRegionShape(
                    rects: (autoHiding ? [] : mainControls.filter { !$0.kind.isOneTapAction }
                                .map { $0.frame.insetBy(dx: -4, dy: -4) })
                        + (gearFrame.map { [$0.insetBy(dx: -4, dy: -4)] } ?? [])
                        + (wheel.map { [$0.frame.insetBy(dx: -8, dy: -8)] } ?? paletteFrame.map { [$0] } ?? [])))
                .gesture(controlGesture())
        }
        .onAppear {
            onCanvasChange(layout.canvas)
            onOccupiedFramesChange(occupied)
        }
        .onChange(of: layout.canvas) { onCanvasChange($0) }
        .onChange(of: occupied) { onOccupiedFramesChange($0) }
    }

    static let trayPadding: CGFloat = 6

    /// Chord palettes and previews stay above the software keyboard.
    static func boundsAboveKeyboard(_ bounds: CGRect, keyboardTop: CGFloat?) -> CGRect {
        guard let keyboardTop, keyboardTop.isFinite, keyboardTop < bounds.maxY else { return bounds }
        let limit = keyboardTop - PadControlMetrics.edgeMargin
        return CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: max(0, limit - bounds.minY))
    }

    /// The Wheel opens around the modifier that opened it.
    private func padWheelAnchor(mainControls: [PadPlacedControl], gearFrame: CGRect?) -> CGRect? {
        let modifier = paletteAnchor.flatMap { anchor in interaction.activeChord.contains(anchor) ? anchor : nil }
            ?? ControlModifier.allCases.first(where: interaction.activeChord.contains)
        return mainControls.first { $0.kind.modifier == modifier && modifier != nil }?.frame
            ?? mainControls.first { $0.kind.modifier != nil }?.frame ?? gearFrame
    }

    /// The Strip/Overlay Main rail — see `PadRailComposition`: system
    /// actions, then modifiers and keys, then Move View and Settings.
    private var padMainGroups: [[CustomControlKind]] {
        let modifiers = profile.visibleTrayItems.compactMap(\.modifier)
            .filter { _ in capabilityAllows(.command) }
        return PadRailComposition.mainGroups(
            visibility: store.preferences.padStandardControls,
            availability: .init(modifiers: modifiers,
                                keyboardAvailable: capabilityAllows(.keyboard),
                                moveViewAvailable: padShowsMoveView))
    }

    /// Any Function Tray item by id, visible in the tray or not.
    private func functionItem(_ id: String) -> ShortcutItem? {
        store.activeFunctionTrayProfile.allItems.first { $0.id == id }
    }

    // MARK: Custom

    @ViewBuilder
    private func customLayoutContent(_ layout: CustomControlLayout, container: CGRect) -> some View {
        let portrait = containerSize.height > containerSize.width
        let arrangement = customArrangementWithSettings(layout.arrangement(portrait: portrait))
        let metrics = PadControlMetrics(scale: padMetricsScale)
        // With the software keyboard up, the whole layout compresses into the
        // space above it, so every control stays reachable, then returns.
        let keyboardTop = keyboardVisibleRect?.maxY
        let area = CustomLayoutGeometry.layoutArea(
            container: Self.boundsAboveKeyboard(container, keyboardTop: keyboardTop.map { $0 + PadControlMetrics.edgeMargin }),
            safeInsets: keyboardTop == nil ? safeInsets
                : ControlSafeInsets(top: safeInsets.top, leading: safeInsets.leading, bottom: 0,
                                    trailing: safeInsets.trailing))
        let allFrames = CustomLayoutGeometry.frames(for: arrangement, in: area, baseDiameter: metrics.item)
        let functionItems = store.preferences.functionTrayProfile(
            for: layout.functionProfile ?? store.preferences.activeFunctionTrayProfile).allItems
        let item: (String) -> ShortcutItem? = { id in functionItems.first { $0.id == id } }
        let controlsPlaced: [PadPlacedControl] = customPlacements(arrangement).compactMap { placement in
            allFrames[placement.id].map { PadPlacedControl(id: placement.id, kind: placement.kind, frame: $0, cell: $0) }
        }
        let autoHiding = store.autoHidden
        let paletteChord = interaction.paletteChord
        let actions = paletteChord.map(profile.actions(for:)) ?? []
        let keyDiameter = CustomLayoutGeometry.paletteKeyDiameter(baseDiameter: metrics.item)
        let anchorModifier = paletteAnchor.flatMap { arrangement.placement(for: $0) != nil ? $0 : nil }
            ?? ControlModifier.allCases.first { interaction.activeChord.contains($0)
                && arrangement.placement(for: $0) != nil }
        let anchorControl = anchorModifier.flatMap { modifier in
            controlsPlaced.first { $0.kind.modifier == modifier }
        }
        let anchorStyle = anchorControl.flatMap { control in
            arrangement.placements.first { $0.id == control.id }?.palette
        } ?? PalettePresentation()
        let wheel: WheelPaletteLayout? = anchorStyle.shape == .wheel && paletteChord != nil && !actions.isEmpty
            ? anchorControl.flatMap {
                WheelPaletteGeometry.layout(count: actions.count, anchor: $0.frame, keyDiameter: keyDiameter,
                                            spacing: metrics.gap, bounds: area)
            } : nil
        let paletteKeys: [(action: ShortcutItem, frame: CGRect)] = {
            guard paletteChord != nil, wheel == nil, let anchorControl else { return [] }
            let points = CustomLayoutGeometry.palettePoints(
                count: actions.count, anchorID: anchorControl.id, arrangement: arrangement,
                frames: allFrames, area: area, baseDiameter: metrics.item, spacing: metrics.gap)
            return zip(actions, points).map { action, point in
                (action, CGRect(x: point.x - keyDiameter / 2, y: point.y - keyDiameter / 2,
                                width: keyDiameter, height: keyDiameter))
            }
        }()
        let assistState = TwoHandAssist.state(
            enabled: layout.twoHandAssist && !padCollapsed && store.preferences.allowInput,
            interaction: interaction)
        let assistIdleItems = layout.assistActionIDs.compactMap(item)
        let assistCount: Int = {
            switch assistState {
            case .hidden: return 0
            case .idle: return store.preferences.functionTrayCanBeShown ? assistIdleItems.count : 0
            case .helper: return TwoHandAssist.helperModifiers.count
            }
        }()
        let assistPoints = TwoHandAssist.helperPoints(count: assistCount, arrangement: arrangement, frames: allFrames,
                                                      area: area, itemDiameter: metrics.item, spacing: metrics.gap)
        let assistFrames = assistPoints.map {
            CGRect(x: $0.x - metrics.item / 2, y: $0.y - metrics.item / 2, width: metrics.item, height: metrics.item)
        }
        let regionControls = controlsPlaced.filter { !$0.kind.isOneTapAction }
        let occupied = controlsPlaced.map(\.frame) + paletteKeys.map(\.frame) + assistFrames
            + (wheel.map { [$0.frame] } ?? [])

        ZStack(alignment: .topLeading) {
            ForEach(controlsPlaced) { control in
                Group {
                    switch control.kind {
                    case .function(let id):
                        if let item = item(id) {
                            padFunctionChip(item, frame: control.frame, onRail: false, hint: nil)
                        }
                    case .shortcut(let item):
                        padFunctionChip(item, frame: control.frame, onRail: false, hint: nil)
                    case .tray, .moveView:
                        padControlChip(control.kind, frame: control.frame, onRail: false, hint: nil)
                    }
                }
                .opacity(autoHiding && control.kind != .tray(.settings) ? 0 : 1)
                .allowsHitTesting(!autoHiding || control.kind == .tray(.settings))
            }
            if let paletteChord, let wheel {
                WheelPaletteView(layout: wheel, actions: actions, selectedID: interaction.selectedActionID,
                                 centerLabel: paletteChord.symbols)
                    .transition(.scale(scale: 0.85).combined(with: .opacity))
            } else if let paletteChord {
                if paletteKeys.isEmpty, let anchorControl {
                    emptyPaletteLabel(paletteChord)
                        .position(x: anchorControl.frame.midX,
                                  y: anchorControl.frame.minY - metrics.item * 0.9)
                } else {
                    ForEach(paletteKeys, id: \.action.id) { key in
                        shortcutButton(key.action, portrait: portrait, diameter: key.frame.width)
                            .position(x: key.frame.midX, y: key.frame.midY)
                            .transition(.scale(scale: 0.6).combined(with: .opacity))
                    }
                }
            }
            twoHandAssistLayer(state: assistState, idleItems: assistIdleItems, frames: assistFrames)
                .opacity(autoHiding ? 0 : 1)
                .allowsHitTesting(!autoHiding)
            if let selected = selectedAction(in: actions) {
                shortcutHUD(selected)
                    .position(x: containerSize.width / 2, y: safeInsets.top + 44)
                    .transition(.opacity.combined(with: .scale))
            }
            Color.clear
                .frame(width: containerSize.width, height: containerSize.height)
                .contentShape(ControlRegionShape(
                    rects: regionControls.filter { !autoHiding || $0.kind == .tray(.settings) }
                        .map { $0.frame.insetBy(dx: -4, dy: -4) }
                        + paletteKeys.map { $0.frame.insetBy(dx: -3, dy: -3) }
                        + (wheel.map { [$0.frame.insetBy(dx: -8, dy: -8)] } ?? [])))
                .gesture(controlGesture())
        }
        .animation(.snappy(duration: 0.22), value: assistState)
        .onAppear {
            onCanvasChange(container)
            onOccupiedFramesChange(occupied)
        }
        .onChange(of: occupied) { onOccupiedFramesChange($0) }
    }

    /// Settings is permanent chrome, so a layout without it still gets one
    /// in its corner.
    private func customArrangementWithSettings(_ arrangement: CustomControlArrangement) -> CustomControlArrangement {
        guard !arrangement.placements.contains(where: { $0.kind == .tray(.settings) }) else { return arrangement }
        var result = arrangement
        let corner = arrangement.corner.unitPoint
        result.placements.append(CustomControlPlacement(id: "settings", kind: .tray(.settings),
                                                        x: Double(corner.x), y: Double(corner.y), size: 0.9))
        return result
    }

    /// The placements to render: those whose control can act right now.
    private func customPlacements(_ arrangement: CustomControlArrangement) -> [CustomControlPlacement] {
        let allowed = Set(interactiveTrayItems)
        return arrangement.placements.filter { placement in
            switch placement.kind {
            case .tray(let item): return allowed.contains(item)
            case .function: return store.preferences.functionTrayCanBeShown && !padCollapsed
            case .shortcut: return store.preferences.trayCanBeShown && !padCollapsed
            case .moveView: return padShowsMoveView
            }
        }
    }

    /// The opposite side: idle Function actions, or — while a chord is in
    /// progress — helper modifiers projecting the same chord state.
    @ViewBuilder
    private func twoHandAssistLayer(state: TwoHandAssistState, idleItems: [ShortcutItem],
                                    frames: [CGRect]) -> some View {
        switch state {
        case .hidden:
            EmptyView()
        case .idle:
            ForEach(Array(zip(idleItems, frames)), id: \.0.id) { item, frame in
                padFunctionChip(item, frame: frame, onRail: false, hint: nil)
                    .transition(.opacity)
            }
        case .helper(let active):
            ForEach(Array(zip(TwoHandAssist.helperModifiers, frames)), id: \.0) { modifier, frame in
                let selected = active.contains(modifier)
                Text(modifier.symbol)
                    .font(.system(size: frame.width * 0.46, weight: .semibold))
                    .foregroundStyle(selected ? Color.black : Color.white)
                    .frame(width: frame.width, height: frame.height)
                    .background(PadChip(selected: selected, onRail: false))
                    .contentShape(Circle())
                    .onTapGesture {
                        apply(interaction.toggleAssistModifier(modifier))
                        store.beginAutoHideActivity()
                    }
                    .position(x: frame.midX, y: frame.midY)
                    .accessibilityLabel(modifier.title)
                    .accessibilityValue(selected ? "On" : "Off")
                    .transition(.opacity.combined(with: .scale(scale: 0.85)))
            }
        }
    }

    // MARK: Pieces

    private func padID(_ kind: CustomControlKind) -> String {
        switch kind {
        case .tray(let item): return "tray-\(item.rawValue)"
        case .function(let id): return "function-\(id)"
        case .moveView: return "moveView"
        case .shortcut(let item): return "shortcut-\(item.id)"
        }
    }

    private func padHint(_ kind: CustomControlKind) -> String {
        switch kind {
        case .tray(let item):
            switch item {
            case .command: return String(localized: "command", comment: "Strip control hint under the ⌘ key.")
            case .option: return String(localized: "option", comment: "Strip control hint under the ⌥ key.")
            case .control: return String(localized: "control", comment: "Strip control hint under the ⌃ key.")
            case .shift: return String(localized: "shift", comment: "Strip control hint under the ⇧ key.")
            case .escape: return String(localized: "escape", comment: "Strip control hint.")
            case .tab: return String(localized: "tab", comment: "Strip control hint.")
            case .dock: return String(localized: "dock", comment: "Strip control hint.")
            case .keyboard: return String(localized: "keyboard", comment: "Strip control hint.")
            case .settings: return String(localized: "settings", comment: "Strip control hint.")
            }
        case .function(let id): return id
        case .shortcut(let item): return item.title.lowercased()
        case .moveView: return String(localized: "move view", comment: "Strip control hint.")
        }
    }

    /// A Main control: modifier, tray action, or Move View. Taps are handled
    /// by `controlGesture` (via the frames reported here), exactly as on
    /// iPhone.
    @ViewBuilder
    private func padControlChip(_ kind: CustomControlKind, frame: CGRect, onRail: Bool, hint: String?) -> some View {
        let diameter = frame.width
        let selected: Bool = {
            switch kind {
            case .tray(let item):
                guard let modifier = item.modifier else { return false }
                return interaction.latchedModifiers.contains(modifier)
                    || interaction.temporaryModifiers.contains(modifier)
                    || interaction.phase == .pressed(modifier)
            case .moveView: return store.moveViewActive
            case .function, .shortcut: return false
            }
        }()
        let frameID: String = {
            switch kind {
            case .tray(let item):
                return item.modifier.map { "modifier:\($0.rawValue)" } ?? "tray:\(item.rawValue)"
            case .moveView: return "control:moveView"
            case .function(let id): return "function:\(id)"
            case .shortcut(let item): return "shortcut:\(item.id)"
            }
        }()
        VStack(spacing: 2) {
            Group {
                switch kind {
                case .tray(let item) where item.modifier != nil:
                    Text(item.modifier?.symbol ?? "")
                        .font(.system(size: diameter * 0.46, weight: .semibold))
                case .tray(let item) where item == .escape || item == .tab:
                    Text(item.displayLabel).font(.system(size: diameter * 0.3, weight: .semibold))
                case .tray(let item):
                    Image(systemName: item.displayLabel).font(.system(size: diameter * 0.4, weight: .semibold))
                case .moveView:
                    Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
                        .font(.system(size: diameter * 0.38, weight: .semibold))
                case .function, .shortcut:
                    EmptyView()
                }
            }
            .foregroundStyle(selected ? Color.black : Color.white)
            .frame(width: diameter, height: diameter)
            .background(frameReader(frameID))
            .background(PadChip(selected: selected, onRail: onRail))
            if let hint {
                Text(hint)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(width: diameter + PadControlMetrics.hintWidthAllowance,
                           height: PadControlMetrics.hintHeight)
            }
        }
        .position(x: frame.midX, y: frame.minY + (diameter + (hint == nil ? 0 : PadControlMetrics.hintHeight + 2)) / 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(padAccessibilityLabel(kind))
        .accessibilityValue(kind.modifier != nil || kind == .moveView ? (selected ? "On" : "Off") : "")
    }

    private func padAccessibilityLabel(_ kind: CustomControlKind) -> String {
        switch kind {
        case .tray(let item): return item.title
        case .moveView: return String(localized: "Move View")
        case .function(let id): return id
        case .shortcut(let item): return item.title
        }
    }

    /// A Function control fires on tap, exactly like the iPhone tray.
    private func padFunctionChip(_ item: ShortcutItem, frame: CGRect, onRail: Bool, hint: String?) -> some View {
        let diameter = frame.width
        return VStack(spacing: 2) {
            ShortcutButtonFaceView(face: item.face, diameter: diameter)
            .foregroundStyle(.white)
            .frame(width: diameter, height: diameter)
            .background(PadChip(selected: false, onRail: onRail))
            .contentShape(Circle())
            .onTapGesture { performFunctionAction(item) }
            if let hint {
                Text(hint)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(width: diameter + PadControlMetrics.hintWidthAllowance,
                           height: PadControlMetrics.hintHeight)
            }
        }
        .position(x: frame.midX, y: frame.minY + (diameter + (hint == nil ? 0 : PadControlMetrics.hintHeight + 2)) / 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.title)
        .accessibilityAddTraits(.isButton)
    }

    @ViewBuilder
    private func padPalette(actions: [ShortcutItem], keys: [(action: ShortcutItem, frame: CGRect)],
                            frame: CGRect, chord: ModifierChord, pills: Bool) -> some View {
        if actions.isEmpty {
            emptyPaletteLabel(chord)
                .position(x: frame.midX, y: frame.midY)
        } else {
            ForEach(keys, id: \.action.id) { key in
                Group {
                    if pills {
                        paletteHintKey(key.action, size: key.frame.size)
                    } else {
                        shortcutButton(key.action, portrait: true, diameter: key.frame.width)
                    }
                }
                .position(x: key.frame.midX, y: key.frame.midY)
                .transition(.scale(scale: 0.8).combined(with: .opacity))
            }
        }
    }

    /// Strip hint key: the key cap beside its action name ("C  Copy").
    private func paletteHintKey(_ action: ShortcutItem, size: CGSize) -> some View {
        let selected = interaction.selectedActionID == action.id
        return HStack(spacing: 8) {
            Text(action.displayKey)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .frame(minWidth: 22)
            Text(action.title)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .foregroundStyle(selected ? Color.black : Color.white)
        .frame(width: size.width, height: size.height)
        .background(frameReader("action:\(action.id)"))
        .background(Capsule().fill(selected ? Color.white.opacity(0.92) : Color.black.opacity(0.55)))
        .overlay(Capsule().strokeBorder(.white.opacity(selected ? 0.5 : 0.2), lineWidth: 0.75))
        .scaleEffect(selected ? 1.05 : 1)
        .animation(.snappy(duration: 0.14), value: selected)
        .accessibilityLabel(action.title)
    }

    private func emptyPaletteLabel(_ chord: ModifierChord) -> some View {
        Text("No shortcuts for \(chord.displayName)")
            .font(.caption)
            .foregroundStyle(.white.opacity(0.9))
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(Capsule().fill(Color.black.opacity(0.6)))
            .overlay(Capsule().strokeBorder(.white.opacity(0.22), lineWidth: 0.5))
    }

    /// Move View is a mode, so it says so while it's on — with a way back.
    private var moveViewBanner: some View {
        HStack(spacing: 12) {
            Label("Move View", systemImage: "arrow.up.and.down.and.arrow.left.and.right")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
            Divider().frame(height: 18)
            Button("Reset") {
                store.requestViewportReset()
                haptics.play(.reset)
            }
            Button("Done") {
                store.setMoveViewActive(false)
                haptics.play(.selection)
            }
            .fontWeight(.semibold)
        }
        .font(.subheadline)
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.25), radius: 10, y: 3)
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .contain)
    }
}

/// The iPad control face, in the same restrained neutral language as the
/// trackpad surface: a quiet key inside a rail or tray, and a solid neutral
/// disc when floating on its own (Custom) — no glow, no halo.
struct PadChip: View {
    let selected: Bool
    let onRail: Bool

    var body: some View {
        Circle()
            .fill(selected ? Color.white.opacity(0.92)
                           : (onRail ? Color.white.opacity(0.12) : Color(white: 0.2).opacity(0.88)))
            .overlay(Circle().strokeBorder(.white.opacity(selected ? 0.5 : (onRail ? 0.08 : 0.16)),
                                           lineWidth: 0.75))
            .shadow(color: .black.opacity(onRail ? 0 : 0.22), radius: 3, y: 1)
    }
}

/// A compact floating tray holding one Overlay control group (or a chord
/// palette): rounded, dark and translucent, with a hairline edge.
struct ControlTray: View {
    var body: some View {
        GeometryReader { proxy in
            let radius = min(proxy.size.width, proxy.size.height) / 2
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Color.black.opacity(0.32)))
                .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.75))
                .shadow(color: .black.opacity(0.25), radius: 8, y: 2)
                .environment(\.colorScheme, .dark)
        }
    }
}

// MARK: - Wheel palette

/// The Wheel on screen, for hit-testing its wedges in `controlGesture`.
struct WheelHitTarget: Equatable {
    var layout: WheelPaletteLayout
    var actionIDs: [String]
}

struct WheelHitPreference: PreferenceKey {
    static let defaultValue: WheelHitTarget? = nil
    static func reduce(value: inout WheelHitTarget?, nextValue: () -> WheelHitTarget?) {
        value = nextValue() ?? value
    }
}

/// A ring of wedge segments around a center disc showing the held chord —
/// the Wheel palette. Drawn in the overlay's coordinate space.
struct WheelPaletteView: View {
    let layout: WheelPaletteLayout
    let actions: [ShortcutItem]
    let selectedID: String?
    let centerLabel: String

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(zip(layout.segments.indices, actions)), id: \.1.id) { index, action in
                let segment = layout.segments[index]
                let selected = action.id == selectedID
                WheelWedge(center: layout.center, inner: layout.innerRadius, outer: layout.outerRadius,
                           start: segment.startAngle, end: segment.endAngle)
                    .fill(selected ? Color.white.opacity(0.92) : Color(white: 0.18).opacity(0.9))
                WheelWedge(center: layout.center, inner: layout.innerRadius, outer: layout.outerRadius,
                           start: segment.startAngle, end: segment.endAngle)
                    .stroke(selected ? Color.accentColor : Color.white.opacity(0.14), lineWidth: selected ? 2 : 0.75)
                ShortcutButtonFaceView(face: action.face, diameter: min(layout.outerRadius - layout.innerRadius, 52))
                    .foregroundStyle(selected ? Color.black : Color.white)
                    .frame(width: layout.outerRadius - layout.innerRadius,
                           height: layout.outerRadius - layout.innerRadius)
                    .scaleEffect(selected ? 1.12 : 1)
                    .position(segment.labelPoint)
                    .accessibilityLabel(action.title)
            }
            Circle()
                .fill(Color(white: 0.12).opacity(0.92))
                .overlay(Circle().strokeBorder(Color.white.opacity(0.14), lineWidth: 0.75))
                .overlay(Text(centerLabel).font(.system(size: 17, weight: .semibold)).foregroundStyle(.white))
                .frame(width: (layout.innerRadius - 4) * 2, height: (layout.innerRadius - 4) * 2)
                .position(layout.center)
                .accessibilityHidden(true)
        }
        .shadow(color: .black.opacity(0.25), radius: 8, y: 2)
        .allowsHitTesting(false)
        .preference(key: WheelHitPreference.self, value: WheelHitTarget(layout: layout, actionIDs: actions.map(\.id)))
    }
}

private struct WheelWedge: Shape {
    let center: CGPoint
    let inner: CGFloat
    let outer: CGFloat
    let start: CGFloat
    let end: CGFloat

    func path(in rect: CGRect) -> Path {
        // A hairline of air between wedges.
        let inset = min(0.04, (end - start) * 0.08)
        var path = Path()
        path.addArc(center: center, radius: outer, startAngle: .radians(start + inset),
                    endAngle: .radians(end - inset), clockwise: false)
        path.addArc(center: center, radius: inner, startAngle: .radians(end - inset),
                    endAngle: .radians(start + inset), clockwise: true)
        path.closeSubpath()
        return path
    }
}

/// Runs a one-tap action over the existing wire in plan order. Single
/// actions go out at once; a sequence's pauses run on the main actor, and
/// stop between steps if input is revoked — each step's keys are sent
/// down and up together, so nothing is left held.
@MainActor
enum OneTapActionRunner {
    static func run(_ action: ControlAction, receiver: StreamReceiver, inputAllowed: @escaping @MainActor () -> Bool) {
        let operations = ControlActionPlan.operations(for: action)
        guard !operations.isEmpty, inputAllowed() else { return }
        let pauses = operations.contains { if case .pause = $0 { return true } else { return false } }
        guard pauses else {
            operations.forEach { perform($0, receiver: receiver) }
            return
        }
        Task { @MainActor in
            for operation in operations {
                if case .pause(let milliseconds) = operation {
                    try? await Task.sleep(nanoseconds: UInt64(milliseconds) * 1_000_000)
                    continue
                }
                guard inputAllowed() else { return }
                perform(operation, receiver: receiver)
            }
        }
    }

    private static func perform(_ operation: ControlActionOperation, receiver: StreamReceiver) {
        switch operation {
        case .press(let usage, let modifiers):
            receiver.sendKeyboardPress(usage: usage, modifiers: modifiers)
        case .key(let event):
            switch event.phase {
            case .down: receiver.sendKeyboardDown(usage: event.usage, modifiers: event.modifiers)
            case .up: receiver.sendKeyboardUp(usage: event.usage, modifiers: event.modifiers)
            }
        case .gesture(let name):
            guard ReceiverGesture(rawValue: name) != nil else { return }
            receiver.sendGesture(name: name)
        case .pause:
            break
        }
    }
}

/// The Strip rail: solid black, with a hairline where it meets the canvas.
private struct PadStripBackground: View {
    let edge: ControlEdge

    var body: some View {
        Rectangle()
            .fill(Color.black)
            .overlay(alignment: innerAlignment) {
                Rectangle()
                    .fill(Color.white.opacity(0.08))
                    .frame(width: edge.stacksVertically ? 0.5 : nil, height: edge.stacksVertically ? nil : 0.5)
            }
    }

    private var innerAlignment: Alignment {
        switch edge {
        case .leading: return .trailing
        case .trailing: return .leading
        case .top: return .bottom
        case .bottom: return .top
        }
    }
}

private struct ControlRegionShape: Shape {
    var rects: [CGRect]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        for region in rects where !region.isEmpty { path.addRect(region) }
        return path
    }
}

struct ControlProfileEditor: View {
    @ObservedObject var store: ReceiverControlStore
    let haptics: ReceiverHaptics

    var body: some View {
        List {
            Section("Main Tray") {
                ForEach(store.activeProfile.trayItems) { configuration in
                    Toggle(configuration.item.title, isOn: Binding(
                        get: { store.activeProfile.trayItems.first(where: { $0.item == configuration.item })?.isVisible ?? false },
                        set: { visible in
                            store.updateActiveProfile { profile in
                                if let index = profile.trayItems.firstIndex(where: { $0.item == configuration.item }) {
                                    profile.trayItems[index].isVisible = visible
                                }
                            }
                        }))
                }
                .onMove { source, destination in
                    store.updateActiveProfile { $0.moveTrayItems(from: source, to: destination) }
                }
            }

            Section("Shortcut Palettes") {
                ForEach(Self.supportedChords) { chord in
                    NavigationLink {
                        ChordPaletteEditor(store: store, chord: chord, haptics: haptics)
                    } label: {
                        LabeledContent(chord.displayName,
                                       value: "\(store.activeProfile.actions(for: chord).count)")
                    }
                }
            }
        }
        .navigationTitle("Edit \(store.preferences.activeControlProfile.title)")
        .toolbar { EditButton() }
    }

    static let supportedChords: [ModifierChord] = (1..<16).map { mask in
        ModifierChord(Set(ControlModifier.allCases.enumerated().compactMap { index, modifier in
            mask & (1 << index) == 0 ? nil : modifier
        }))
    }
}

/// The actions in one modifier chord's palette — the same data the Strip,
/// Overlay, Custom (every palette style, Wheel included) and the editor's
/// Preview all show. Add keyboard chords, sequences, Function actions or
/// system actions; remove, reorder, and change each one's face separately
/// from what it does.
struct ChordPaletteEditor: View {
    @ObservedObject var store: ReceiverControlStore
    let chord: ModifierChord
    let haptics: ReceiverHaptics
    @State private var editing: ShortcutEditorRequest?

    private var actions: [ShortcutItem] { store.activeProfile.actions(for: chord) }

    var body: some View {
        List {
            Section {
                ForEach(actions) { action in
                    Button {
                        editing = ShortcutEditorRequest(placementID: action.id, item: action)
                    } label: {
                        HStack(spacing: 12) {
                            ShortcutButtonFaceView(face: action.face, diameter: 30)
                                .foregroundStyle(.white)
                                .frame(width: 30, height: 30)
                                .background(Circle().fill(Color(white: 0.22)))
                            VStack(alignment: .leading, spacing: 1) {
                                Text(action.title).foregroundStyle(.primary)
                                Text(action.keysDescription).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                }
                .onMove { source, destination in
                    store.updateActiveProfile { $0.moveActions(for: chord, from: source, to: destination) }
                }
                .onDelete { offsets in
                    store.updateActiveProfile { profile in
                        var actions = profile.actions(for: chord)
                        actions.remove(atOffsets: offsets)
                        profile.setActions(actions, for: chord)
                    }
                }
            } footer: {
                Text("Hold or latch \(chord.symbols) to show these. Tap one to change what it sends or how it looks; drag to reorder.")
            }
            Section {
                Button("Restore This Palette") {
                    let defaults = ControlProfile.canonical().actions(for: chord)
                    store.updateActiveProfile { $0.setActions(defaults, for: chord) }
                    haptics.play(.reset)
                }
            }
        }
        .navigationTitle(chord.displayName)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                addMenu
                EditButton()
            }
        }
        .sheet(item: $editing) { request in
            ShortcutButtonEditor(initial: request.item, defaultModifiers: chord.modifiers) { item in
                store.updateActiveProfile { profile in
                    var actions = profile.actions(for: chord)
                    if let index = actions.firstIndex(where: { $0.id == item.id }) {
                        actions[index] = item
                    } else {
                        actions.append(item)
                    }
                    profile.setActions(actions, for: chord)
                }
            }
        }
    }

    private var addMenu: some View {
        Menu {
            Button { editing = ShortcutEditorRequest(placementID: nil, item: nil) } label: {
                Label("Shortcut or Sequence…", systemImage: "keyboard")
            }
            Menu("Function Action") {
                ForEach(store.activeFunctionTrayProfile.allItems) { item in
                    Button(item.title) { append(copy(of: item)) }
                }
            }
            Menu("System Action") {
                ForEach(ReceiverGesture.oneTapActions, id: \.self) { gesture in
                    Button(gesture.title) {
                        append(ShortcutItem(id: UUID().uuidString, title: gesture.title, gesture: gesture,
                                            systemImage: "sparkles"))
                    }
                }
            }
        } label: {
            Label("Add Action", systemImage: "plus")
        }
    }

    /// Palette entries own their definition; a copied Function action is
    /// independent of the tray it came from.
    private func copy(of item: ShortcutItem) -> ShortcutItem {
        var copy = item
        copy.id = UUID().uuidString
        return copy
    }

    private func append(_ item: ShortcutItem) {
        store.updateActiveProfile { profile in
            profile.setActions(profile.actions(for: chord) + [item], for: chord)
        }
    }
}

/// Submenu listing the four App-mode command bindings (spec section D) —
/// hidden from the main Gestures section entirely unless Pinch/Zoom or
/// Rotation is currently set to App (see `SettingsView`'s conditional
/// `NavigationLink`).
struct AppGestureCommandsView: View {
    @ObservedObject var store: ReceiverControlStore
    @State private var confirmingReset = false

    var body: some View {
        List {
            Section {
                Text("Experimental")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.orange)
                Text("Some Mac apps use different shortcuts for zooming and rotating. Customize the commands MeowDisplay sends when App mode is selected.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("Zoom") {
                commandRow(.zoomIn)
                commandRow(.zoomOut)
            }
            Section("Rotation") {
                commandRow(.rotateLeft)
                commandRow(.rotateRight)
            }
            Section {
                Button("Reset to Defaults", role: .destructive) {
                    confirmingReset = true
                }
            }
        }
        .navigationTitle("App Gesture Commands")
        .confirmationDialog("Reset App Gesture Commands to their defaults?",
                            isPresented: $confirmingReset, titleVisibility: .visible) {
            Button("Reset to Defaults", role: .destructive) {
                store.update { $0.resetAppGestureCommands() }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func commandRow(_ kind: AppGestureCommandKind) -> some View {
        NavigationLink {
            AppGestureCommandEditor(store: store, kind: kind)
        } label: {
            LabeledContent(kind.title,
                           value: appGestureCommandDisplayText(for: store.preferences.appGestureCommands.shortcut(for: kind)))
        }
    }
}

/// Editable, not recordable (spec section E): modifiers are toggles and the
/// key comes from a picker — there is no physical-shortcut recording on
/// iPhone.
struct AppGestureCommandEditor: View {
    @ObservedObject var store: ReceiverControlStore
    let kind: AppGestureCommandKind

    private var shortcut: KeyboardShortcut {
        store.preferences.appGestureCommands.shortcut(for: kind)
    }

    var body: some View {
        Form {
            Section("Modifiers") {
                ForEach(ControlModifier.allCases) { modifier in
                    Toggle(modifier.title, isOn: modifierBinding(modifier))
                }
            }
            Section("Key") {
                Picker("Key", selection: usageBinding) {
                    ForEach(appGestureCommandEditableKeys, id: \.1) { Text($0.0).tag($0.1) }
                }
            }
            Section("Preview") {
                Text(appGestureCommandDisplayText(for: shortcut))
                    .font(.title2.monospaced())
            }
        }
        .navigationTitle(kind.title)
    }

    private func update(_ transform: (inout KeyboardShortcut) -> Void) {
        store.update { preferences in
            var current = preferences.appGestureCommands.shortcut(for: kind)
            transform(&current)
            preferences.appGestureCommands.setShortcut(current, for: kind)
        }
    }

    private func modifierBinding(_ modifier: ControlModifier) -> Binding<Bool> {
        Binding(get: { shortcut.modifiers.contains(modifier) },
                set: { enabled in
                    update {
                        var values = $0.modifiers.modifiers
                        if enabled { values.insert(modifier) } else { values.remove(modifier) }
                        $0.modifiers = ModifierChord(values)
                    }
                })
    }

    private var usageBinding: Binding<Int> {
        Binding(get: { shortcut.usage }, set: { usage in update { $0.usage = usage } })
    }
}

/// A one-tap button's face: its SF Symbol, or its text, emoji or keys.
struct ShortcutButtonFaceView: View {
    let face: ShortcutButtonFace
    let diameter: CGFloat

    var body: some View {
        switch face {
        case .symbol(let name):
            Image(systemName: name).font(.system(size: diameter * 0.4, weight: .semibold))
        case .text(let text):
            Text(text)
                .font(.system(size: diameter * (text.count > 2 ? 0.28 : 0.36), weight: .semibold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .padding(.horizontal, diameter * 0.08)
        }
    }
}
