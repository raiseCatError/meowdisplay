import AppKit
import Combine
import Sparkle
import SwiftUI

/// The Mac Receiver's Settings window: the same System Settings-style shell
/// as Mac Sender's `MacSettingsSplitViewController` — a native AppKit split
/// view (sidebar + detail) under a unified toolbar with Back/Forward, the
/// page title, and the status badge, joined to the divider by an
/// `NSTrackingSeparatorToolbarItem`. Everything here is AppKit/SwiftUI API
/// available on macOS 12, the receiver's deployment floor, which is also
/// why this is not a `NavigationSplitView` (macOS 13).
@MainActor
enum ReceiverSettingsWindow {
    private static var window: NSWindow?
    private static let autosaveName = "ReceiverSettingsWindow"

    static func show(controller: ReceiverController, updater: SPUStandardUpdaterController?) {
        if window == nil {
            let splitViewController = ReceiverSettingsSplitViewController(controller: controller, updater: updater)
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 800, height: 580),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered, defer: false)
            w.title = String(localized: "MeowDisplay Receiver", comment: "Settings window title. \"MeowDisplay\" is the product name and must stay untranslated; only \"Receiver\" (this Mac acting as a display for another Mac) is translatable.")
            w.minSize = NSSize(width: 700, height: 480)
            w.contentViewController = splitViewController
            // Assigning the controller sizes the window to its fitting size.
            w.setContentSize(NSSize(width: 800, height: 580))
            splitViewController.configureWindowAndToolbar(for: w)
            w.isReleasedWhenClosed = false
            if !w.setFrameUsingName(autosaveName) { w.center() }
            w.setFrameAutosaveName(autosaveName)
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
    }
}

@MainActor
final class ReceiverSettingsSplitViewController: NSSplitViewController, NSToolbarDelegate {
    let controller: ReceiverController
    let updater: SPUStandardUpdaterController?
    let navigationModel = ReceiverSettingsNavigationModel()

    private var didConfigureToolbar = false
    private weak var detailTitleField: NSTextField?
    private weak var navigationSegmentedControl: NSSegmentedControl?
    private var cancellables = Set<AnyCancellable>()

    init(controller: ReceiverController, updater: SPUStandardUpdaterController?) {
        self.controller = controller
        self.updater = updater
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        splitView.isVertical = true
        splitView.dividerStyle = .thin

        let sidebarHosting = NSHostingController(rootView: ReceiverSettingsSidebarView(navigationModel: navigationModel))
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarHosting)
        sidebarItem.canCollapse = false
        sidebarItem.holdingPriority = .defaultHigh
        // A little wider than Mac Sender's 190 so "Quit MeowDisplay
        // Receiver" fits on one line.
        sidebarItem.minimumThickness = 215
        sidebarItem.maximumThickness = 260
        addSplitViewItem(sidebarItem)

        let detailHosting = NSHostingController(rootView: ReceiverSettingsDetailView(
            controller: controller, updater: updater, navigationModel: navigationModel))
        let detailItem = NSSplitViewItem(viewController: detailHosting)
        detailItem.holdingPriority = .defaultLow
        addSplitViewItem(detailItem)

        navigationModel.$current
            .sink { [weak self] category in
                guard let self else { return }
                // The history stacks are updated before `current`, so they
                // already reflect this navigation.
                self.detailTitleField?.stringValue = category.label
                self.navigationSegmentedControl?.setEnabled(self.navigationModel.canGoBack, forSegment: 0)
                self.navigationSegmentedControl?.setEnabled(self.navigationModel.canGoForward, forSegment: 1)
            }
            .store(in: &cancellables)
    }

    func configureWindowAndToolbar(for window: NSWindow) {
        guard !didConfigureToolbar else { return }
        didConfigureToolbar = true

        window.styleMask.insert(.fullSizeContentView)
        window.toolbarStyle = .unified
        window.titleVisibility = .hidden
        window.titlebarSeparatorStyle = .automatic

        let toolbar = NSToolbar(identifier: "MeowDisplayReceiverSettingsToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
    }

    @objc private func handleNavigationSegmentClicked(_ sender: NSSegmentedControl) {
        switch sender.selectedSegment {
        case 0: navigationModel.goBack()
        case 1: navigationModel.goForward()
        default: break
        }
    }

    // MARK: - NSToolbarDelegate

    private static let trackingSeparatorID = NSToolbarItem.Identifier("TrackingSeparator")
    private static let detailLeadingID = NSToolbarItem.Identifier("DetailLeading")
    private static let detailTitleID = NSToolbarItem.Identifier("DetailTitle")
    private static let detailStatusID = NSToolbarItem.Identifier("DetailStatus")

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            Self.trackingSeparatorID,
            Self.detailLeadingID,
            .space,
            Self.detailTitleID,
            .flexibleSpace,
            Self.detailStatusID
        ]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch itemIdentifier {
        case Self.trackingSeparatorID:
            return NSTrackingSeparatorToolbarItem(identifier: itemIdentifier, splitView: splitView, dividerIndex: 0)

        case Self.detailLeadingID:
            // Native segmented control, as in Mac Sender: AppKit draws the
            // system Back/Forward chrome rather than a SwiftUI imitation.
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            let back = String(localized: "Back", comment: "Settings toolbar: go to the previously viewed page.")
            let forward = String(localized: "Forward", comment: "Settings toolbar: go to the next page in history.")
            let segmented = NSSegmentedControl(
                images: [
                    NSImage(systemSymbolName: "chevron.backward", accessibilityDescription: back)!,
                    NSImage(systemSymbolName: "chevron.forward", accessibilityDescription: forward)!
                ],
                trackingMode: .momentary,
                target: self,
                action: #selector(handleNavigationSegmentClicked(_:))
            )
            segmented.segmentStyle = .separated
            segmented.setToolTip("\(back) (⌘[)", forSegment: 0)
            segmented.setToolTip("\(forward) (⌘])", forSegment: 1)
            segmented.setEnabled(navigationModel.canGoBack, forSegment: 0)
            segmented.setEnabled(navigationModel.canGoForward, forSegment: 1)
            item.view = segmented
            item.isNavigational = true
            navigationSegmentedControl = segmented
            return item

        case Self.detailTitleID:
            // Plain NSTextField, as in Mac Sender, so the unified toolbar
            // shows flat text rather than wrapping it in a glass capsule.
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            let field = NSTextField(labelWithString: navigationModel.current.label)
            field.font = .systemFont(ofSize: 13, weight: .semibold)
            field.textColor = .labelColor
            item.view = field
            detailTitleField = field
            return item

        case Self.detailStatusID:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            let hosting = NSHostingView(rootView: ReceiverStatusBadge(controller: controller)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.trailing, 6))
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

/// The toolbar status readout — `controller.statusTitle`/`statusColor`, the
/// receiver's one canonical status projection (also on Overview), styled
/// like Mac Sender's `StatusBadge`.
struct ReceiverStatusBadge: View {
    @ObservedObject var controller: ReceiverController

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(controller.statusColor)
                .frame(width: 7, height: 7)
            Text(controller.statusTitle)
                .font(.subheadline)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 5)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Status: \(controller.statusTitle)"))
    }
}

/// Invisible ⌘[ / ⌘] key equivalents for history navigation — the toolbar's
/// native segmented control has no SwiftUI shortcut of its own (same
/// approach as Mac Sender's `DetailNavigationKeyboardShortcuts`).
private struct ReceiverNavigationKeyboardShortcuts: View {
    @ObservedObject var navigationModel: ReceiverSettingsNavigationModel

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

/// Search, the category list (or search results), and Quit at the bottom —
/// laid out exactly like Mac Sender's `MacSettingsSidebarView`.
struct ReceiverSettingsSidebarView: View {
    @ObservedObject var navigationModel: ReceiverSettingsNavigationModel
    @State private var searchText = ""
    @State private var selectedSearchItemID: String?
    /// View-owned `List` selection — see `ReceiverSidebarSelection`.
    @State private var selection: ReceiverSidebarItem?

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var searchResults: [ReceiverSettingsSearchItem] {
        ReceiverSettingsSearchIndex.shared.search(query: searchText)
    }

    private var derivedSelection: ReceiverSidebarItem? {
        ReceiverSidebarSelection.derived(current: navigationModel.current, isSearching: isSearching,
                                         results: searchResults, selectedSearchItemID: selectedSearchItemID)
    }

    var body: some View {
        VStack(spacing: 0) {
            NativeSearchField(text: $searchText, placeholder: String(localized: "Search"))
                .frame(height: 22)
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 8)

            List(selection: $selection) {
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
                            .tag(ReceiverSidebarItem.searchResult(item))
                        }
                    }
                } else {
                    ForEach(ReceiverSettingsCategory.allCases) { category in
                        Label(category.label, systemImage: category.systemImage)
                            .tag(ReceiverSidebarItem.category(category))
                    }
                }
            }
            .listStyle(.sidebar)
            .onAppear { selection = derivedSelection }
            // A user selection navigates after the update that changed it;
            // an echo of the current category is a no-op in `navigateTo`.
            .onChange(of: selection) { newItem in
                if case .searchResult(let item) = newItem { selectedSearchItemID = item.id }
                if let destination = ReceiverSidebarSelection.destination(of: newItem) {
                    navigationModel.navigateTo(destination)
                }
            }
            // Model -> highlight (Back/Forward, Overview buttons) and search
            // results changing: re-derive the view-owned selection.
            .onChange(of: navigationModel.current) { _ in selection = derivedSelection }
            .onChange(of: searchText) { _ in
                if !isSearching { selectedSearchItemID = nil }
                selection = derivedSelection
            }

            Divider()

            Button(role: .destructive) {
                NSApp.terminate(nil)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "power")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("Quit MeowDisplay Receiver")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .help("Quit MeowDisplay Receiver entirely — equivalent to ⌘Q. Closing just this window keeps this Mac available as a display and any stream running.")
            .accessibilityLabel(Text("Quit MeowDisplay Receiver"))
            .accessibilityHint(Text("Terminates the application, ending any active connection."))
        }
    }
}

/// The detail pane for the selected category.
struct ReceiverSettingsDetailView: View {
    @ObservedObject var controller: ReceiverController
    let updater: SPUStandardUpdaterController?
    @ObservedObject var navigationModel: ReceiverSettingsNavigationModel

    var body: some View {
        Group {
            switch navigationModel.current {
            case .overview:
                ReceiverOverviewSettingsView(controller: controller, navigationModel: navigationModel)
            case .displays:
                ReceiverDisplaysSettingsView(controller: controller)
            case .streaming:
                ReceiverStreamingSettingsView(controller: controller)
            case .devices:
                ReceiverDevicesSettingsView(controller: controller)
            case .remoteAccess:
                ReceiverRemoteAccessSettingsView(controller: controller)
            case .system:
                ReceiverSystemSettingsView(controller: controller, updater: updater)
            #if DEBUG
            case .developer:
                ReceiverDeveloperSettingsView(controller: controller)
            #endif
            }
        }
        .frame(minWidth: 500, minHeight: 450)
        .background(ReceiverNavigationKeyboardShortcuts(navigationModel: navigationModel))
        // The sender is headless, so Mirror has nothing to capture. "Use
        // Extend" sends the existing displayModeRequest; the sender decides.
        .alert("Mirror isn’t available",
               isPresented: Binding(get: { controller.mirrorUnavailableOffer }, set: { _ in })) {
            Button("Cancel", role: .cancel) { controller.declineMirrorUnavailableOffer() }
            Button("Use Extend") { controller.acceptMirrorUnavailableOffer() }
        } message: {
            Text("The other Mac has no active physical display, for example its lid is closed. Use Extend to create a virtual display instead?")
        }
    }
}

// MARK: - Shared page building blocks

/// A settings page body: the grouped Form Mac Sender uses on macOS 13+; on
/// macOS 12, where grouped forms do not exist, the same sections in a plain
/// scrolling Form.
struct ReceiverSettingsForm<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        if #available(macOS 13, *) {
            Form { content }
                .formStyle(.grouped)
        } else {
            ScrollView {
                Form { content }
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/// A read-only "Title ……… value" row — `LabeledContent` is macOS 13.
struct ReceiverValueRow: View {
    let title: LocalizedStringKey
    let value: String

    init(_ title: LocalizedStringKey, value: String) {
        self.title = title
        self.value = value
    }

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
    }
}

/// A caption under a control, styled like Mac Sender's inline explanations.
struct ReceiverCaption: View {
    private let text: Text

    init(_ key: LocalizedStringKey) { text = Text(key) }
    init(verbatim string: String) { text = Text(string) }

    var body: some View {
        text
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Runs `content` only while the receiver exists (it is created at launch and
/// torn down only on quit), observing it directly so its published state
/// refreshes the page — nested ObservableObjects don't republish.
struct WithReceiver<Content: View>: View {
    @ObservedObject var controller: ReceiverController
    let content: (StreamReceiver) -> Content

    init(_ controller: ReceiverController, @ViewBuilder content: @escaping (StreamReceiver) -> Content) {
        self.controller = controller
        self.content = content
    }

    var body: some View {
        if let receiver = controller.receiver {
            content(receiver)
        } else {
            ReceiverSettingsForm {
                ReceiverCaption("The receiver is not running.")
            }
        }
    }
}
