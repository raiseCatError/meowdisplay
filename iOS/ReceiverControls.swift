import SwiftUI
import UIKit

@MainActor
final class ReceiverControlStore: ObservableObject {
    @Published private(set) var preferences: ReceiverControlPreferences
    private let repository: ReceiverControlPreferencesRepository
    var onInputResetRequested: (() -> Void)?

    init(repository: ReceiverControlPreferencesRepository = ReceiverControlPreferencesRepository()) {
        self.repository = repository
        preferences = repository.load()
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

    /// The connected Mac is authoritative for Allow Input (a security-
    /// relevant, Mac-owned gate — see `StreamReceiver.onAllowInputStateChange`)
    /// so its confirmed state always overwrites the local preference rather
    /// than merging with it — exactly one source of truth once connected.
    func applyAllowInput(_ allowed: Bool) {
        update { $0.allowInput = allowed }
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

private struct ControlFramePreference: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
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
    let haptics: ReceiverHaptics
    let onOccupiedFramesChange: ([CGRect]) -> Void

    @State private var interaction = ControlInteractionState()
    @State private var frames: [String: CGRect] = [:]
    @State private var holdTask: Task<Void, Never>?
    @State private var initiatingModifier: ControlModifier?
    @State private var initiatingItem: ControlTrayItem?
    @State private var gestureActive = false
    @State private var lastHoveredModifier: ControlModifier?
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
        return profile.visibleTrayItems.filter {
            if $0.modifier != nil {
                return receiver.macProtocolVersion >= WireProtocol.receiverControlsWireVersion
            }
            return $0 != .keyboard || (store.preferences.keyboardButtonEnabled && keyboardAvailable)
        }
    }

    var body: some View {
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
            notchSide: notchSide)
        let rawLayout = ControlTrayGeometry.layout(
            container: CGRect(origin: .zero, size: containerSize),
            safeInsets: safe,
            keyboardVisibleRect: keyboardVisibleRect,
            portrait: portrait,
            side: store.preferences.preferredLandscapeSide,
            traySize: traySize,
            paletteSize: paletteSize,
            avoidNotch: false,
            notchSide: notchSide)
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
            mainSide: store.preferences.preferredLandscapeSide,
            position: store.preferences.functionTrayPosition,
            mainTrayFrame: renderedMainTrayFrame,
            groupSizes: functionGroupSizes,
            avoiding: renderedPaletteFrame,
            avoidNotch: store.preferences.avoidNotch,
            notchSide: notchSide)
        #if DEBUG
        // Only computed when the overlay is actually on — a second,
        // avoidNotch:false pass purely for the debug visualization below.
        let rawFunctionFrames = notchDebugOverlayEnabled ? ControlTrayGeometry.functionTrayLayout(
            container: CGRect(origin: .zero, size: containerSize),
            safeInsets: safe,
            keyboardVisibleRect: keyboardVisibleRect,
            portrait: portrait,
            mainSide: store.preferences.preferredLandscapeSide,
            position: store.preferences.functionTrayPosition,
            mainTrayFrame: renderedMainTrayFrame,
            groupSizes: functionGroupSizes,
            avoiding: renderedPaletteFrame,
            avoidNotch: false) : []
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
            }

            ForEach(Array(functionGroups.enumerated()), id: \.offset) { index, group in
                if index < functionFrames.count {
                    let frame = functionFrames[index]
                    functionGroupCluster(group, axis: layout.axis == .horizontal ? .horizontal : .vertical)
                        .frame(width: frame.width, height: frame.height)
                        .position(x: frame.midX, y: frame.midY)
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
                .contentShape(ControlRegionShape(tray: layout.trayFrame,
                                                 palette: paletteChord == nil ? nil : layout.paletteFrame))
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
                     + "container=\(containerSize) resolvedSafeInsets=\(safe) "
                     + "physicalNotchSide=\(notchSide.map(String.init(describing:)) ?? "none") notchDepthUsed=\(notchDepth) "
                     + "rawMain=\(rawLayout.trayFrame) "
                     + "exclusions=\(ControlTrayGeometry.unsafeRegions(in: CGRect(origin: .zero, size: containerSize), safeInsets: safe, portrait: portrait, notchSide: notchSide)) "
                     + "finalMain=\(layout.trayFrame) renderedControls=\($0)")
            #endif
        }
        .onAppear { onOccupiedFramesChange(occupiedFrames) }
        .onChange(of: occupiedFrames) { onOccupiedFramesChange($0) }
        .onAppear {
            if !interaction.latchedModifiers.isEmpty || !interaction.temporaryModifiers.isEmpty {
                apply(interaction.resetAll())
            }
        }
        .animation(.snappy(duration: 0.24), value: store.preferences.trayCollapsed)
        .animation(.snappy(duration: 0.2), value: interaction.phase)
        // Any session interruption — pause, recovery, a failed recovery or a
        // plain disconnect — drops every latched modifier/held control, so no
        // transient control state survives into the next live session.
        .onChange(of: receiver.session.phase) { phase in
            if phase != .connected { apply(interaction.resetAll()) }
        }
        .onChange(of: receiver.displayState) { state in
            if state != .running { apply(interaction.resetAll()) }
        }
        .onChange(of: store.preferences.activeControlProfile) { _ in
            apply(interaction.resetAll())
        }
        .onChange(of: store.preferences.activeFunctionTrayProfile) { _ in
            apply(interaction.resetAll())
        }
        // The Mac released its synthetic input state; drop the matching
        // local latch silently. A Mac-originated refresh is not a
        // receiver-confirmed action and must not buzz.
        .onChange(of: receiver.inputResetGeneration) { _ in
            apply(interaction.resetAll())
        }
        .onChange(of: receiver.controlResetGeneration) { _ in
            apply(interaction.resetAll())
        }
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
        Group {
            if let systemImage = item.systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 17, weight: .semibold))
            } else {
                Text(item.displayKey)
                    .font(.system(size: 15, weight: .semibold))
            }
        }
        .foregroundStyle(.white)
        .frame(width: Metrics.trayItem, height: Metrics.trayItem)
        .background(chip(selected: false))
        .contentShape(Circle())
        .onTapGesture { performFunctionAction(item) }
        .accessibilityLabel(item.title)
    }

    private func performFunctionAction(_ item: ShortcutItem) {
        guard case .keyboardShortcut(let shortcut) = item.action else { return }
        receiver.sendKeyboardPress(usage: shortcut.usage,
                                   modifiers: shortcut.modifiers.modifiers.map(\.rawValue))
        haptics.play(.confirmation)
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

    private func shortcutButton(_ action: ShortcutItem, portrait: Bool) -> some View {
        let selected = interaction.selectedActionID == action.id
        return Text(action.displayKey)
        .font(.system(size: action.displayKey.count > 2 ? 11 : 15, weight: .semibold))
        .minimumScaleFactor(0.7)
        .lineLimit(1)
        .foregroundStyle(selected ? Color.black : Color.white)
        .frame(width: Metrics.paletteKey, height: Metrics.paletteKey)
        .background(frameReader("action:\(action.id)"))
        .background(chip(selected: selected))
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
                    initiatingItem = trayItem(at: value.startLocation)
                    if let modifier = initiatingItem?.modifier {
                        initiatingModifier = modifier
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
                } else if interaction.paletteChord != nil {
                    apply(interaction.finish(with: nil))
                }
                initiatingModifier = nil
                initiatingItem = nil
                lastHoveredModifier = nil
                gestureActive = false
            }
    }

    private func trayItem(at point: CGPoint) -> ControlTrayItem? {
        controls.first { item in
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
        profile.actions(for: interaction.activeChord).first {
            frames["action:\($0.id)"]?.contains(point) == true
        }
    }

    private func selectedAction(in actions: [ShortcutItem]) -> ShortcutItem? {
        actions.first { $0.id == interaction.selectedActionID }
    }

    /// The highlighted shortcut, but only if the finger actually lifted on it
    /// — sliding off a key must cancel it, not fire it.
    private func selectedAction(under point: CGPoint) -> ShortcutItem? {
        profile.actions(for: interaction.activeChord).first {
            $0.id == interaction.selectedActionID
                && frames["action:\($0.id)"]?.contains(point) == true
        }
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
                if case .keyboardShortcut(let shortcut) = item.action {
                    receiver.sendKeyboardPress(usage: shortcut.usage,
                                               modifiers: shortcut.modifiers.modifiers.map(\.rawValue))
                }
            case .haptic(let event): haptics.play(event)
            }
        }
    }
}

private struct ControlRegionShape: Shape {
    var tray: CGRect
    var palette: CGRect?

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addRect(tray)
        if let palette { path.addRect(palette) }
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

/// Editor for the Function Tray's own, independent profile — visibility
/// and order only; items themselves aren't user-authored this milestone
/// (see `FunctionTrayProfile.canonical`'s doc on staying generic for
/// future actions).
struct FunctionTrayProfileEditor: View {
    @ObservedObject var store: ReceiverControlStore

    var body: some View {
        List {
            Section("Function Tray") {
                ForEach(store.activeFunctionTrayProfile.items) { configuration in
                    Toggle(configuration.item.title, isOn: Binding(
                        get: { configuration.isVisible },
                        set: { visible in
                            store.updateActiveFunctionTrayProfile { profile in
                                if let index = profile.items.firstIndex(where: { $0.id == configuration.id }) {
                                    profile.items[index].isVisible = visible
                                }
                            }
                        }))
                }
                .onMove { source, destination in
                    store.updateActiveFunctionTrayProfile { $0.moveItems(from: source, to: destination) }
                }
            }
        }
        .navigationTitle("Edit \(store.preferences.activeFunctionTrayProfile.title)")
        .toolbar { EditButton() }
    }
}

struct ChordPaletteEditor: View {
    @ObservedObject var store: ReceiverControlStore
    let chord: ModifierChord
    let haptics: ReceiverHaptics
    @State private var adding = false

    var body: some View {
        List {
            ForEach(store.activeProfile.actions(for: chord)) { action in
                NavigationLink {
                    ShortcutItemEditor(store: store, chord: chord, itemID: action.id)
                } label: {
                    LabeledContent(action.title, value: action.displayKey)
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
        }
        .navigationTitle(chord.displayName)
        .toolbar {
            EditButton()
            Button { adding = true } label: { Image(systemName: "plus") }
        }
        .sheet(isPresented: $adding) {
            NavigationStack {
                NewShortcutEditor(store: store, chord: chord, isPresented: $adding)
            }
        }
        .safeAreaInset(edge: .bottom) {
            Button("Restore This Palette") {
                let defaults = ControlProfile.canonical().actions(for: chord)
                store.updateActiveProfile { $0.setActions(defaults, for: chord) }
                haptics.play(.reset)
            }
            .buttonStyle(.bordered).padding(8)
        }
    }
}

private let editableShortcutKeys: [(String, Int)] = {
    let letters = zip(Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ"), 4...29).map { (String($0), $1) }
    return letters + [("1", 30), ("2", 31), ("3", 32), ("4", 33), ("5", 34),
                      ("Esc", 41), ("Space", 44), ("Return", 40), ("Tab", 43)]
}()

struct ShortcutItemEditor: View {
    @ObservedObject var store: ReceiverControlStore
    let chord: ModifierChord
    let itemID: String

    private var item: ShortcutItem? {
        store.activeProfile.actions(for: chord).first(where: { $0.id == itemID })
    }

    var body: some View {
        Form {
            if let item {
                TextField("Name", text: itemBinding(item, keyPath: \.title))
                Picker("Key", selection: usageBinding(item)) {
                    ForEach(editableShortcutKeys, id: \.1) { Text($0.0).tag($0.1) }
                }
                Section("Modifiers") {
                    ForEach(ControlModifier.allCases) { modifier in
                        Toggle(modifier.title, isOn: modifierBinding(item, modifier))
                    }
                }
            }
        }
        .navigationTitle("Shortcut")
    }

    private func update(_ transform: (inout ShortcutItem) -> Void) {
        store.updateActiveProfile { profile in
            var actions = profile.actions(for: chord)
            guard let index = actions.firstIndex(where: { $0.id == itemID }) else { return }
            transform(&actions[index])
            profile.setActions(actions, for: chord)
        }
    }

    private func itemBinding(_ item: ShortcutItem, keyPath: WritableKeyPath<ShortcutItem, String>) -> Binding<String> {
        Binding(get: { self.item?[keyPath: keyPath] ?? item[keyPath: keyPath] },
                set: { value in update { $0[keyPath: keyPath] = value } })
    }

    private func usageBinding(_ item: ShortcutItem) -> Binding<Int> {
        Binding(get: {
            guard let current = self.item, case .keyboardShortcut(let shortcut) = current.action else { return 4 }
            return shortcut.usage
        }, set: { usage in
            update {
                let key = editableShortcutKeys.first(where: { $0.1 == usage })?.0 ?? "Key"
                $0.displayKey = key
                $0.action = .keyboardShortcut(KeyboardShortcut(usage: usage, modifiers: chord))
            }
        })
    }

    private func modifierBinding(_ item: ShortcutItem, _ modifier: ControlModifier) -> Binding<Bool> {
        Binding(get: {
            let current = self.item ?? item
            guard case .keyboardShortcut(let shortcut) = current.action else { return false }
            return shortcut.modifiers.contains(modifier)
        }, set: { enabled in
            update {
                guard case .keyboardShortcut(var shortcut) = $0.action else { return }
                var values = shortcut.modifiers.modifiers
                if enabled { values.insert(modifier) } else { values.remove(modifier) }
                shortcut.modifiers = ModifierChord(values)
                $0.action = .keyboardShortcut(shortcut)
            }
        })
    }
}

/// Full key list for App Gesture Commands editing (spec section E) —
/// letters, 0-9, the listed symbol keys, and the listed special keys.
/// Deliberately a separate list from `editableShortcutKeys` (Main Tray
/// shortcuts): that one predates this feature and keeps its own smaller,
/// unrelated key set. "+" is not a distinct physical key — it is Shift
/// held with "=" — so it is not listed separately; toggling Shift on the
/// "=" key produces it.
let appGestureCommandEditableKeys: [(String, Int)] = {
    let letters = zip(Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ"), 4...29).map { (String($0), $1) }
    let digits: [(String, Int)] = [("1", 30), ("2", 31), ("3", 32), ("4", 33), ("5", 34),
                                   ("6", 35), ("7", 36), ("8", 37), ("9", 38), ("0", 39)]
    let symbols: [(String, Int)] = [("=", 46), ("-", 45), ("[", 47), ("]", 48),
                                    ("/", 56), ("\\", 49), (",", 54), (".", 55),
                                    (";", 51), ("'", 52)]
    let special: [(String, Int)] = [("Space", 44), ("Return", 40), ("Tab", 43), ("Escape", 41),
                                    ("Delete", 42), ("↑", 82), ("↓", 81), ("←", 80), ("→", 79)]
    return letters + digits + symbols + special
}()

func appGestureCommandKeyLabel(for usage: Int) -> String {
    appGestureCommandEditableKeys.first(where: { $0.1 == usage })?.0 ?? "?"
}

func appGestureCommandDisplayText(for shortcut: KeyboardShortcut) -> String {
    shortcut.modifiers.symbols + appGestureCommandKeyLabel(for: shortcut.usage)
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
                Text("Some Mac apps use different shortcuts for zooming and rotating. Customize the commands OpenDisplay sends when App mode is selected.")
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

struct NewShortcutEditor: View {
    @ObservedObject var store: ReceiverControlStore
    let chord: ModifierChord
    @Binding var isPresented: Bool
    @State private var title = "Shortcut"
    @State private var usage = 4

    var body: some View {
        Form {
            TextField("Name", text: $title)
            Picker("Key", selection: $usage) {
                ForEach(editableShortcutKeys, id: \.1) { Text($0.0).tag($0.1) }
            }
        }
        .navigationTitle("Add Shortcut")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { isPresented = false } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Add") {
                    let key = editableShortcutKeys.first(where: { $0.1 == usage })?.0 ?? "Key"
                    store.updateActiveProfile { profile in
                        var actions = profile.actions(for: chord)
                        actions.append(ShortcutItem(title: title, displayKey: key,
                                                    usage: usage, modifiers: chord))
                        profile.setActions(actions, for: chord)
                    }
                    isPresented = false
                }
            }
        }
    }
}
