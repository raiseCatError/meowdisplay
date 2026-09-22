import SwiftUI
import AppKit
import Combine
import Sparkle

/// Native AppKit split view controller managing the System Settings-style
/// window layout: sidebar on the left, detail on the right, with an
/// `NSTrackingSeparatorToolbarItem` connecting the split view divider through
/// the unified titlebar.
@MainActor
final class MacSettingsSplitViewController: NSSplitViewController, NSToolbarDelegate {
    let controller: SenderController
    let updater: SPUStandardUpdaterController?
    let navigationModel: SettingsNavigationModel
    let permissions = PermissionMonitor()

    private var didConfigureToolbar = false
    private weak var detailTitleField: NSTextField?
    private weak var navigationSegmentedControl: NSSegmentedControl?
    private weak var toolbar: NSToolbar?
    private var cancellables = Set<AnyCancellable>()

    init(controller: SenderController, updater: SPUStandardUpdaterController?) {
        self.controller = controller
        self.updater = updater
        self.navigationModel = SettingsNavigationModel(initialCategory: .overview)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        splitView.isVertical = true
        splitView.dividerStyle = .thin

        let sidebarView = MacSettingsSidebarView(navigationModel: navigationModel)
        let sidebarHosting = NSHostingController(rootView: sidebarView)
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarHosting)
        sidebarItem.canCollapse = false
        sidebarItem.holdingPriority = .defaultHigh
        sidebarItem.minimumThickness = 190
        sidebarItem.maximumThickness = 260
        addSplitViewItem(sidebarItem)

        let detailView = MacSettingsDetailView(
            controller: controller,
            permissions: permissions,
            updater: updater,
            navigationModel: navigationModel
        )
        let detailHosting = NSHostingController(rootView: detailView)
        let detailItem = NSSplitViewItem(viewController: detailHosting)
        detailItem.holdingPriority = .defaultLow
        addSplitViewItem(detailItem)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppDidBecomeActive),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )

        navigationModel.$current
            .sink { [weak self] category in
                guard let self else { return }
                self.detailTitleField?.stringValue = category.label
                self.navigationSegmentedControl?.setEnabled(self.navigationModel.canGoBack, forSegment: 0)
                self.navigationSegmentedControl?.setEnabled(self.navigationModel.canGoForward, forSegment: 1)
            }
            .store(in: &cancellables)

        controller.$keepMacAvailableActive
            .removeDuplicates()
            .sink { [weak self] isActive in
                self?.updateKeepAvailableToolbarItem(isActive: isActive)
            }
            .store(in: &cancellables)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func handleAppDidBecomeActive() {
        permissions.refresh()
    }

    @objc private func handleNavigationSegmentClicked(_ sender: NSSegmentedControl) {
        switch sender.selectedSegment {
        case 0: navigationModel.goBack()
        case 1: navigationModel.goForward()
        default: break
        }
    }

    func configureWindowAndToolbar(for window: NSWindow) {
        guard !didConfigureToolbar else { return }
        didConfigureToolbar = true

        window.styleMask.insert(.fullSizeContentView)
        window.toolbarStyle = .unified
        window.titleVisibility = .hidden
        window.titlebarSeparatorStyle = .automatic

        let toolbar = NSToolbar(identifier: "MeowDisplaySettingsToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        self.toolbar = toolbar
    }

    /// Inserts/removes the Keep Available item (plus the spacer that keeps
    /// its Liquid Glass capsule from merging with the status item's) as the
    /// assertion is acquired/released, so no empty gap is left when hidden.
    private func updateKeepAvailableToolbarItem(isActive: Bool) {
        guard let toolbar else { return }
        let keepIndex = toolbar.items.firstIndex { $0.itemIdentifier == Self.detailKeepAvailableID }
        if isActive {
            guard keepIndex == nil else { return }
            let insertionIndex = toolbar.items.count
            toolbar.insertItem(withItemIdentifier: .space, at: insertionIndex)
            toolbar.insertItem(withItemIdentifier: Self.detailKeepAvailableID, at: insertionIndex + 1)
        } else {
            guard let keepIndex else { return }
            toolbar.removeItem(at: keepIndex)
            if keepIndex - 1 >= 0, toolbar.items[keepIndex - 1].itemIdentifier == .space {
                toolbar.removeItem(at: keepIndex - 1)
            }
        }
    }

    // MARK: - NSToolbarDelegate

    private static let trackingSeparatorID = NSToolbarItem.Identifier("TrackingSeparator")
    private static let detailLeadingID = NSToolbarItem.Identifier("DetailLeading")
    private static let detailTitleID = NSToolbarItem.Identifier("DetailTitle")
    private static let detailStatusID = NSToolbarItem.Identifier("DetailStatus")
    private static let detailKeepAvailableID = NSToolbarItem.Identifier("DetailKeepAvailable")

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            Self.trackingSeparatorID,
            Self.detailLeadingID,
            .space,
            Self.detailTitleID,
            .flexibleSpace,
            Self.detailStatusID,
            Self.detailKeepAvailableID
        ]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        // The Keep Available item (and its preceding spacer) is added/removed
        // dynamically as the assertion is acquired/released; see
        // `updateKeepAvailableToolbarItem(isActive:)`.
        var items: [NSToolbarItem.Identifier] = [
            Self.trackingSeparatorID,
            Self.detailLeadingID,
            .space,
            Self.detailTitleID,
            .flexibleSpace,
            Self.detailStatusID
        ]
        if controller.keepMacAvailableActive {
            items.append(.space)
            items.append(Self.detailKeepAvailableID)
        }
        return items
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch itemIdentifier {
        case Self.trackingSeparatorID:
            return NSTrackingSeparatorToolbarItem(
                identifier: itemIdentifier,
                splitView: splitView,
                dividerIndex: 0
            )

        case Self.detailLeadingID:
            // A native NSSegmentedControl, not a SwiftUI/NSHostingView
            // capsule: on macOS 26's unified toolbar, letting AppKit draw a
            // real segmented control gives the single native rounded chrome
            // System Settings uses for Back/Forward, with no SwiftUI-drawn
            // background layered underneath it.
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            let segmented = NSSegmentedControl(
                images: [
                    NSImage(systemSymbolName: "chevron.backward", accessibilityDescription: "Back")!,
                    NSImage(systemSymbolName: "chevron.forward", accessibilityDescription: "Forward")!
                ],
                trackingMode: .momentary,
                target: self,
                action: #selector(handleNavigationSegmentClicked(_:))
            )
            segmented.segmentStyle = .separated
            segmented.setToolTip("Back (⌘[)", forSegment: 0)
            segmented.setToolTip("Forward (⌘])", forSegment: 1)
            segmented.setEnabled(navigationModel.canGoBack, forSegment: 0)
            segmented.setEnabled(navigationModel.canGoForward, forSegment: 1)
            item.view = segmented
            item.isNavigational = true
            navigationSegmentedControl = segmented
            return item

        case Self.detailTitleID:
            // A plain AppKit NSTextField, not a SwiftUI NSHostingView: on
            // macOS 26's unified toolbar, AppKit auto-wraps NSHostingView
            // toolbar items in a "Liquid Glass" capsule background, and
            // merges that capsule with an adjacent item's glass when the two
            // sit with no space between them (which is what fused the arrows
            // and the title into one pill). A raw NSView-based item isn't
            // auto-wrapped, so this renders as flat, backgroundless text.
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            let field = NSTextField(labelWithString: navigationModel.current.label)
            field.font = .systemFont(ofSize: 13, weight: .semibold)
            field.textColor = .labelColor
            item.view = field
            detailTitleField = field
            return item

        case Self.detailStatusID:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            let view = DetailToolbarStatusView(controller: controller)
            let hosting = NSHostingView(rootView: view)
            if #available(macOS 13.0, *) {
                hosting.sizingOptions = [.intrinsicContentSize]
            }
            item.view = hosting
            return item

        case Self.detailKeepAvailableID:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            let hosting = NSHostingView(rootView: KeepAvailablePill())
            if #available(macOS 13.0, *) {
                hosting.sizingOptions = [.intrinsicContentSize]
            }
            item.view = hosting
            return item

        default:
            return nil
        }
    }
}

/// Invisible, zero-footprint key equivalents for `⌘[`/`⌘]` history navigation.
/// The visible Back/Forward control now lives in the toolbar as a native
/// `NSSegmentedControl` (see `MacSettingsSplitViewController`), which has no
/// SwiftUI keyboard-shortcut mechanism of its own, so the shortcuts are kept
/// alive here in the always-present detail pane instead.
struct DetailNavigationKeyboardShortcuts: View {
    @ObservedObject var navigationModel: SettingsNavigationModel

    var body: some View {
        ZStack {
            Button("", action: navigationModel.goBack)
                .keyboardShortcut("[", modifiers: .command)
            Button("", action: navigationModel.goForward)
                .keyboardShortcut("]", modifiers: .command)
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }
}

/// Status toolbar item placed at the right side of the detail pane. Kept as
/// its own `NSToolbarItem` (separate from `DetailKeepAvailable`) so macOS 26
/// gives each its own Liquid Glass capsule instead of merging them into one.
struct DetailToolbarStatusView: View {
    @ObservedObject var controller: SenderController

    private var soleActiveSession: DeviceSession? {
        guard controller.activeDisplayEntries.count == 1,
              let id = controller.activeDisplayEntries.first?.id else { return nil }
        return controller.session(for: id)
    }

    var body: some View {
        HStack(spacing: 8) {
            if let session = soleActiveSession {
                ToolbarQuickActions(session: session, controller: controller)
            }
            StatusBadge(controller: controller)
        }
        .fixedSize(horizontal: true, vertical: false)
        .padding(.trailing, 6)
    }
}

/// AppKit NSSearchField bridged to SwiftUI for authentic macOS System Settings search behavior.
struct NativeSearchField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String = "Search"

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = placeholder
        field.bezelStyle = .roundedBezel
        field.controlSize = .small
        field.font = .systemFont(ofSize: NSFont.systemFontSize(for: .small))
        field.delegate = context.coordinator
        field.sendsWholeSearchString = false
        field.sendsSearchStringImmediately = true
        return field
    }

    func updateNSView(_ nsView: NSSearchField, context: Context) {
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        @Binding var text: String

        init(text: Binding<String>) {
            _text = text
        }

        func controlTextDidChange(_ obj: Notification) {
            if let field = obj.object as? NSSearchField {
                text = field.stringValue
            }
        }
    }
}

/// The sidebar view hosting search, category rows, and the bottom Quit button.
struct MacSettingsSidebarView: View {
    @ObservedObject var navigationModel: SettingsNavigationModel
    @State private var searchText = ""
    @State private var selectedSearchItemID: String?

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var searchResults: [SettingsSearchItem] {
        SettingsSearchIndex.shared.search(query: searchText)
    }

    private var sidebarSelection: Binding<SidebarItem?> {
        Binding(
            get: {
                if isSearching {
                    if let selectedSearchItemID,
                       let match = searchResults.first(where: { $0.id == selectedSearchItemID }) {
                        return .searchResult(match)
                    }
                    if let match = searchResults.first(where: { $0.category == navigationModel.current }) {
                        return .searchResult(match)
                    }
                    return nil
                } else {
                    return .category(navigationModel.current)
                }
            },
            set: { newItem in
                guard let newItem else { return }
                switch newItem {
                case .category(let category):
                    navigationModel.navigateTo(category)
                case .searchResult(let item):
                    selectedSearchItemID = item.id
                    navigationModel.navigateTo(item.category)
                }
            }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            // Native NSSearchField positioned below the traffic light zone
            // NSHostingController automatically respects safeAreaInsets.top,
            // so we only need a natural layout margin, not a hardcoded titlebar height.
            NativeSearchField(text: $searchText, placeholder: "Search")
                .frame(height: 22)
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 8)

            List(selection: sidebarSelection) {
                if isSearching {
                    if searchResults.isEmpty {
                        VStack(spacing: 6) {
                            Text("No Results")
                                .font(.headline)
                                .foregroundStyle(.secondary)
                            Text("No settings found for “\(searchText)”")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 24)
                        .listRowBackground(Color.clear)
                    } else {
                        ForEach(searchResults) { item in
                            HStack(spacing: 10) {
                                Image(systemName: item.systemImage)
                                    .font(.body)
                                    .foregroundStyle(item.category == navigationModel.current ? Color.accentColor : Color.secondary)
                                    .frame(width: 18, alignment: .center)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.title)
                                        .font(.body)
                                        .lineLimit(1)
                                    if let subtitle = item.subtitle {
                                        Text(subtitle)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                            }
                            .tag(SidebarItem.searchResult(item))
                        }
                    }
                } else {
                    ForEach(SettingsCategory.allCases) { category in
                        Label(category.label, systemImage: category.systemImage)
                            .tag(SidebarItem.category(category))
                    }
                }
            }
            .listStyle(.sidebar)

            Divider()

            Button(role: .destructive) {
                NSApp.terminate(nil)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "power")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("Quit MeowDisplay")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .help("Quit MeowDisplay entirely — equivalent to ⌘Q. Closing just this window keeps MEOW and any active stream running.")
            .accessibilityLabel("Quit MeowDisplay")
            .accessibilityHint("Terminates the application, ending any active connection.")
        }
    }
}

/// The detail pane displaying the active settings category.
struct MacSettingsDetailView: View {
    @ObservedObject var controller: SenderController
    @ObservedObject var permissions: PermissionMonitor
    let updater: SPUStandardUpdaterController?
    @ObservedObject var navigationModel: SettingsNavigationModel

    var body: some View {
        NavigationStack {
            Group {
                switch navigationModel.current {
                case .overview:
                    OverviewSettingsView(
                        controller: controller,
                        permissions: permissions,
                        onOpenDisplays: { navigationModel.navigateTo(.displays) },
                        onOpenDevices: { navigationModel.navigateTo(.devices) },
                        onOpenSystem: { navigationModel.navigateTo(.system) }
                    )
                case .displays:
                    DisplaysSettingsView(controller: controller)
                case .streaming:
                    StreamingSettingsView(controller: controller)
                case .input:
                    InputSettingsView(controller: controller, permissions: permissions)
                case .devices:
                    DevicesSettingsView(controller: controller)
                case .remoteAccess:
                    RemoteAccessSettingsView(controller: controller)
                case .system:
                    SystemSettingsView(controller: controller, permissions: permissions, updater: updater)
                #if DEBUG
                case .developer:
                    DeveloperSettingsView(controller: controller)
                #endif
                }
            }
        }
        .frame(minWidth: 500, minHeight: 450)
        .background(DetailNavigationKeyboardShortcuts(navigationModel: navigationModel))
    }
}

/// SwiftUI wrapper for `MacSettingsSplitViewController`.
struct MacSettingsView: View {
    @ObservedObject var controller: SenderController
    let updater: SPUStandardUpdaterController?

    var body: some View {
        MacSettingsSplitViewRepresentable(controller: controller, updater: updater)
    }
}

struct MacSettingsSplitViewRepresentable: NSViewControllerRepresentable {
    @ObservedObject var controller: SenderController
    let updater: SPUStandardUpdaterController?

    func makeNSViewController(context: Context) -> MacSettingsSplitViewController {
        let vc = MacSettingsSplitViewController(controller: controller, updater: updater)
        return vc
    }

    func updateNSViewController(_ nsViewController: MacSettingsSplitViewController, context: Context) {
        if let window = nsViewController.view.window {
            nsViewController.configureWindowAndToolbar(for: window)
        }
    }
}

/// The one canonical status readout — same source (`SenderController.
/// canonicalStatusText`/`canonicalPhase`, built from `activeDisplayEntries`)
/// the menu bar quick view and Overview also read.
struct StatusBadge: View {
    @ObservedObject var controller: SenderController

    private var dotColor: Color {
        switch controller.canonicalPhase {
        case .connected: return .green
        case .paused: return .secondary
        case .reconnecting: return .yellow
        case .lost: return .red
        case .idle: return .secondary.opacity(0.5)
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(dotColor)
                .frame(width: 7, height: 7)
            Text(controller.canonicalStatusText)
                .font(.subheadline)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 5)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Status: \(controller.canonicalStatusText)")
    }
}

/// Shown only while the power assertion is actually held.
struct KeepAvailablePill: View {
    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(Color.green)
                .frame(width: 7, height: 7)
            Text("Keeping Mac Available")
                .font(.subheadline)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 5)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Keeping Mac Available")
    }
}

/// Compact, state-aware toolbar actions for the sole active display.
struct ToolbarQuickActions: View {
    @ObservedObject var session: DeviceSession
    let controller: SenderController

    private var phase: CanonicalConnectionPhase {
        CanonicalRuntimeStatus.phase(capturePhase: session.capturePhase, failed: session.failed)
    }

    var body: some View {
        HStack(spacing: 0) {
            if session.canPauseOrResume, phase == .connected || phase == .paused {
                Button {
                    if session.isPaused {
                        session.sender.resumeDisplay()
                    } else {
                        session.sender.pauseDisplay()
                    }
                } label: {
                    Image(systemName: session.isPaused ? "play.fill" : "pause.fill")
                }
                .buttonStyle(.plain)
                .help(session.isPaused ? "Resume streaming" : "Pause streaming")
                .accessibilityLabel(session.isPaused ? "Resume" : "Pause")
                .padding(.horizontal, 6)
            }
            if phase == .reconnecting || phase == .lost {
                Button {
                    if session.failed {
                        controller.retry(session)
                    } else {
                        session.sender.forceReconnect()
                    }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .help("Reconnect")
                .accessibilityLabel("Reconnect")
                .padding(.horizontal, 6)
            }
            Button(role: .destructive) {
                controller.disconnect(session)
            } label: {
                Image(systemName: "xmark.circle")
            }
            .buttonStyle(.plain)
            .help("Disconnect")
            .accessibilityLabel("Disconnect")
            .padding(.horizontal, 6)
        }
    }
}
