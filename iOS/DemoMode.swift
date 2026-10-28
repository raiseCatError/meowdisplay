import SwiftUI
import UIKit

// MARK: - Demo Mode
//
// Demo Mode shows the receiver with a sample Mac so MeowDisplay can be
// explored without one. The boundary: the real control overlay, Settings
// shell and local-only pages are reused, driven by a `DemoSession` (in place
// of `StreamReceiver`) and a `ReceiverControlStore` saved to its own defaults
// domain. Nothing here holds the real receiver's wire, trust or endpoints.

/// The demo's own control store: saved to a separate defaults domain that is
/// cleared on entry and exit, so the reviewer's changes never reach the real
/// receiver preferences.
@MainActor
enum DemoControlStoreFactory {
    static func make() -> ReceiverControlStore {
        DemoSession.discardPreferences()
        let defaults = DemoSession.preferenceDefaults(demoActive: true)
        let store = ReceiverControlStore(repository: ReceiverControlPreferencesRepository(defaults: defaults))
        store.update { $0.audioPreferred = true }
        store.applySessionInputState(.allowed)
        return store
    }

    static func discard() {
        DemoSession.discardPreferences()
    }
}

/// The sample stream size: this device's own screen in pixels, landscape.
@MainActor
func demoVideoSize() -> CGSize {
    let bounds = ActiveScene.screen.nativeBounds.size
    return CGSize(width: max(bounds.width, bounds.height), height: min(bounds.width, bounds.height))
}

// MARK: - Home entry point

/// The home screen's entry while no Mac is paired: one row-shaped button,
/// compact enough to sit ahead of the connection instructions in iPhone
/// landscape without pushing anything off screen.
struct ExploreDemoCard: View {
    let onExplore: () -> Void
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        Button(action: onExplore) {
            HStack(spacing: 12) {
                Image(systemName: "play.rectangle.fill")
                    .font(.title3)
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Explore Demo")
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text("Try MeowDisplay with an interactive sample Mac. No connection required.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.forward")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            // iPad's grouped page needs the grouped card color to stand apart;
            // the phone page is plain, like the instructions card.
            .background(horizontalSizeClass == .regular ? Color(.secondarySystemGroupedBackground)
                                                        : Color(.secondarySystemBackground),
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        // As wide as the status card on iPad; the phone column's width elsewhere.
        .frame(maxWidth: horizontalSizeClass == .regular ? .infinity : 420)
        // Label the button itself: wrapping it in its own element hid the
        // button trait (and the button from UI tests) behind a plain group.
        .accessibilityLabel(Text("Explore Demo"))
        .accessibilityHint(Text("Opens a sample session. Nothing connects to another device."))
        .accessibilityIdentifier("exploreDemo")
    }
}

/// The home screen's entry once a Mac is paired: a collapsed section in the
/// Connection Instructions style, with the one Explore Demo action inside.
struct ExploreDemoSection: View {
    let onExplore: () -> Void
    /// Persisted like the instructions section; starts collapsed.
    @AppStorage("home.demoSectionExpanded") private var expanded = false
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        VStack(spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.25)) { expanded.toggle() }
            } label: {
                HStack {
                    Text("Demo Mode")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.footnote.weight(.semibold))
                }
                .foregroundStyle(expanded ? HierarchicalShapeStyle.primary : .secondary)
                .padding(.horizontal, 4)
                .frame(minHeight: 36)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(expanded ? "Expanded" : "Collapsed")
            .accessibilityHint("Double-tap to \(expanded ? "collapse" : "expand")")

            if expanded {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Try the controls with a sample Mac. No connection required.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(action: onExplore) {
                        Label("Explore Demo", systemImage: "play.rectangle")
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("exploreDemo")
                    .accessibilityHint(Text("Opens a sample session. Nothing connects to another device."))
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(horizontalSizeClass == .regular ? Color(.secondarySystemGroupedBackground)
                                                            : Color(.secondarySystemBackground),
                            in: RoundedRectangle(cornerRadius: 16))
                .transition(.opacity)
            }
        }
        .frame(maxWidth: 420)
    }
}

/// The home screen's Demo Mode entry for the current presentation.
struct ExploreDemoEntry: View {
    let presentation: ExploreDemoPresentation
    let onExplore: () -> Void

    var body: some View {
        switch presentation {
        case .prominent: ExploreDemoCard(onExplore: onExplore)
        case .compact: ExploreDemoSection(onExplore: onExplore)
        }
    }
}

// MARK: - Settings

/// Shown along the bottom of Settings while Demo Mode is active.
struct DemoSettingsBanner: View {
    var body: some View {
        HStack(spacing: 8) {
            DemoBadge()
            Text("Sample session with \(DemoSession.macName). No Mac is connected.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
        .accessibilityElement(children: .combine)
    }
}

/// Settings pages that need a real Mac, populated from the demo session.
/// Every value here is labeled Demo or Sample, and nothing is persisted.
struct DemoSettingsPage: View {
    let category: MobileSettingsCategory
    @ObservedObject var demo: DemoSession
    @ObservedObject var controlStore: ReceiverControlStore

    var body: some View {
        SettingsForm {
            switch category {
            case .general: general
            case .display: display
            case .audio: audio
            case .connections: connections
            case .pairedMacs: pairedMacs
            case .remoteAccess: remoteAccess
            case .permissions: permissions
            case .diagnostics: diagnostics
            default: EmptyView()
            }
        }
        .navigationTitle(category.title)
    }

    private func sample(_ value: String) -> String {
        String(localized: "\(value) (Sample)", comment: "A demo value, such as 60 fps (Sample).")
    }

    /// This device's screen in pixels, current orientation.
    private var receiverPixels: CGSize {
        let screen = ActiveScene.screen
        return CGSize(width: screen.bounds.width * screen.scale, height: screen.bounds.height * screen.scale)
    }

    /// Mirror streams the sample Mac's own display; Extend streams the
    /// display the real `ExtendDisplaySizing` would build (Retina, 2x).
    private var streamText: String {
        let wide: Int, high: Int
        if demo.displayMode == .mirror {
            wide = Int(DemoDisplayGeometry.mirrorSourceSize.width) * 2
            high = Int(DemoDisplayGeometry.mirrorSourceSize.height) * 2
        } else {
            let points = DemoDisplayGeometry.extendPointSize(shape: demo.extendShape, receiverPixels: receiverPixels)
            wide = points.wide * 2
            high = points.high * 2
        }
        return "\(wide)×\(high) @ \(demo.fps) fps"
    }

    // MARK: General

    @ViewBuilder
    private var general: some View {
        Section {
            TextField("Device name", text: $demo.deviceName)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
        } header: {
            Text("Name")
        } footer: {
            Text("Demo: changes here last only for this demo and don't rename this \(deviceKind).")
        }
        Section {
            Toggle("Auto-Reconnect", isOn: $demo.autoReconnect)
        } header: {
            Text("Connection")
        } footer: {
            Text("Automatically reconnect to paired devices after connection interruptions. In the demo this only changes the sample session.")
        }
        Section {
            Toggle("Haptics", isOn: preferenceBinding(controlStore, \.hapticsEnabled))
        }
    }

    // MARK: Display

    @ViewBuilder
    private var display: some View {
        Section {
            LabeledContent("Mac", value: DemoSession.macName)
            LabeledContent("Stream", value: sample(streamText))
            LabeledContent("Codec", value: sample(demo.codec == .hevc ? "HEVC" : "H.264"))
        } header: {
            Text("Sample Session")
        }
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Toggle("Video", isOn: Binding(get: { demo.videoEnabled }, set: { demo.setVideoEnabled($0) }))
                SettingNote("Turning video off keeps the connection, keyboard, controls, and selected input mode active.")
            }
            Picker("Display Mode", selection: $demo.displayMode) {
                ForEach(ReceiverDisplayMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            SettingNote("Demo: switching changes the sample display only. With a real Mac, the Mac switches between mirroring its screen and adding this device as a second display.")
            if demo.displayMode == .extend {
                Picker("Extend Shape", selection: Binding(
                    get: { demo.extendShape.shape },
                    set: { demo.extendShape.shape = $0 })) {
                    ForEach(ExtendDisplayShape.allCases) { shape in
                        Text(shape.title).tag(shape)
                    }
                }
                if demo.extendShape.shape == .automatic {
                    Toggle("Use Full Display", isOn: Binding(
                        get: { demo.extendShape.useFullDisplay },
                        set: { demo.extendShape.useFullDisplay = $0 }))
                }
                SettingNote("Automatic uses 16:10. Use Full Display matches this \(deviceKind)'s screen in its current orientation. The sample desktop changes shape to match.")
            } else {
                LabeledContent("Mirror Display", value: sample(String(localized: "\(DemoSession.macName) built-in display")))
                SettingNote("Mirror shows the Mac's own display at its own shape. Extend Shape applies only to Extend.")
            }
            Toggle("Show Surface Grid", isOn: preferenceBinding(controlStore, \.showSurfaceGrid))
        }
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Toggle("Picture in Picture", isOn: preferenceBinding(controlStore, \.pictureInPictureEnabled))
                SettingNote("Leaving MeowDisplay during a session keeps your Mac visible in a floating window. It shows your Mac; control stays in MeowDisplay.")
                SettingNote("Picture in Picture needs live video from a Mac, so it doesn't start from the demo.")
            }
        }
        Section("Streaming") {
            Picker("Streaming Profile", selection: $demo.streamingProfile) {
                ForEach(StreamingProfile.allCases) { profile in
                    Text(profile.label).tag(profile)
                }
            }
            Text(demo.streamingProfile.explanation).font(.footnote).foregroundStyle(.secondary)
        }
    }

    // MARK: Audio

    @ViewBuilder
    private var audio: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Toggle("Audio", isOn: Binding(
                    get: { demo.audioEnabled },
                    set: { value in
                        demo.audioEnabled = value
                        controlStore.update { $0.audioPreferred = value }
                    }))
                SettingNote("Plays a copy of what the Mac is playing. It keeps playing there too — this never changes the Mac's output device.")
            }
            LabeledContent("System Audio", value: demo.audioEnabled ? sample(String(localized: "Playing")) : String(localized: "Off"))
        } footer: {
            Text("Demo: no sound plays from the sample Mac.")
        }
        Section {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("A/V Sync")
                    Spacer()
                    Text("\(controlStore.preferences.avSyncOffsetMs) ms").foregroundStyle(.secondary)
                }
                Slider(value: Binding(
                    get: { Double(controlStore.preferences.avSyncOffsetMs) },
                    set: { value in
                        let stepped = Int((value / Double(AVSyncOffset.stepMs)).rounded()) * AVSyncOffset.stepMs
                        controlStore.update { $0.avSyncOffsetMs = AVSyncOffset.clamped(stepped) }
                    }),
                       in: Double(AVSyncOffset.range.lowerBound)...Double(AVSyncOffset.range.upperBound),
                       step: Double(AVSyncOffset.stepMs))
                SettingNote("Adjust if sound plays slightly before or after the picture.")
            }
            Button("Resync") { demo.log("Demo audio resynced") }
                .disabled(!demo.audioEnabled)
        }
        .disabled(!demo.audioEnabled)
    }

    // MARK: Connections

    @ViewBuilder
    private var connections: some View {
        Section {
            LabeledContent("Mac", value: DemoSession.macName)
            LabeledContent("Connection", value: String(localized: "Connected (Demo)"))
            LabeledContent("Route", value: sample("Wi-Fi"))
            LabeledContent("Stream", value: sample(streamText))
            LabeledContent("Latency", value: sample("\(demo.latencyMs) ms"))
            LabeledContent("Throughput", value: sample("\(Int(demo.throughputMbps)) Mbps"))
        } header: {
            Text("Status")
        } footer: {
            Text("Sample values for the demo. No network connection is open.")
        }
        Section {
            Label("USB: plug in the cable, run the Mac app — it connects automatically through the wire (lowest latency).",
                  systemImage: "cable.connector")
            Label("Wi-Fi: both devices on the same network, then pick this \(deviceKind) in the Mac app's Connection menu.",
                  systemImage: "wifi")
            Label("Rotate the \(deviceKind) for a vertical second monitor.",
                  systemImage: "rectangle.portrait.rotate")
            Label("Touch: tap to click, drag to drag, two-finger pan to scroll.",
                  systemImage: "hand.tap")
        } header: {
            Text("How to connect")
        }
    }

    // MARK: Paired Macs

    @ViewBuilder
    private var pairedMacs: some View {
        Section {
            HStack {
                Image(systemName: "laptopcomputer").accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: DemoSession.macName)
                    Text("Paired · Connected").font(.footnote).foregroundStyle(.secondary)
                }
                Spacer()
                DemoBadge()
            }
            .accessibilityElement(children: .combine)
            Toggle("Request Control Automatically", isOn: $demo.requestInputAutomatically)
                .font(.subheadline)
            Button("Forget…", role: .destructive) {}
                .disabled(true)
        } footer: {
            Text("Demo: \(DemoSession.macName) is a sample and isn't saved as a paired Mac. Forget is unavailable for it. Your real paired Macs aren't shown in the demo. Pairing with a real Mac is confirmed on both devices.")
        }
    }

    // MARK: Remote Access

    @ViewBuilder
    private var remoteAccess: some View {
        Section {
            Text("Use a reachable private-network address for this paired Mac, such as its Tailscale address or MagicDNS name. This lets you connect when the Mac isn't on the same network — it's only used to reach the device, it does not grant trust, and every connection still requires the existing secure pairing.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        Section {
            LabeledContent("Paired Mac", value: DemoSession.macName)
            LabeledContent("Network", value: sample("Tailscale"))
            LabeledContent("Address", value: DemoSession.remoteHost)
            LabeledContent("Port", value: String(DemoSession.remotePort))
            Toggle("Use Remote Access", isOn: $demo.remoteAccessEnabled)
            LabeledContent("Status", value: demo.remoteAccessEnabled ? sample(String(localized: "Ready")) : String(localized: "Off"))
        } header: {
            Text("Remote Access")
        } footer: {
            Text("Sample configuration. Nothing is saved and no connection is attempted.")
        }
    }

    // MARK: Permissions

    @ViewBuilder
    private var permissions: some View {
        Section {
            Button("Open iOS Settings for MeowDisplay") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
        } header: {
            Text("This \(deviceKind)")
        } footer: {
            Text("Wi-Fi mode needs Local Network access. If your Mac can't find this \(deviceKind), enable it under Settings → Privacy & Security → Local Network → MeowDisplay. USB mode works without it. Face ID or your passcode confirms each new pairing.")
        }
        Section {
            Label("Screen Recording: lets the Mac app send its screen to this \(deviceKind).", systemImage: "rectangle.dashed.badge.record")
            Label("Accessibility: lets touches and keys from this \(deviceKind) control the Mac.", systemImage: "accessibility")
        } header: {
            Text("On the Mac")
        } footer: {
            Text("Shown for reference in the demo. These are granted on the Mac when you set up the Mac app. The demo hasn't checked or changed any permission.")
        }
    }

    // MARK: Diagnostics

    @ViewBuilder
    private var diagnostics: some View {
        Section {
            ForEach(demo.events) { event in
                HStack(alignment: .firstTextBaseline) {
                    Text(verbatim: "+\(event.secondsIntoSession)s")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 44, alignment: .leading)
                    Text(event.message).font(.callout)
                }
            }
        } header: {
            Text("Demo Diagnostics")
        } footer: {
            Text("Sample session data. It isn't saved to the connection log, and no network activity took place.")
        }
        Section {
            Toggle("Performance overlay", isOn: $demo.showPerformanceOverlay)
        } header: {
            Text("Analytics")
        } footer: {
            Text("Shows FPS, bitrate, frame timing and latency graphs over the display. In the demo the numbers are samples.")
        }
    }
}

/// Adds the Demo Settings banner inside a scrolling column, so the column
/// insets its content and no row is left under the banner.
struct DemoSettingsBannerInset: ViewModifier {
    let active: Bool

    func body(content: Content) -> some View {
        content.safeAreaInset(edge: .bottom, spacing: 0) {
            if active { DemoSettingsBanner() }
        }
    }
}
