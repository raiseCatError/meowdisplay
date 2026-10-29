import SwiftUI
import UIKit

/// Remote Finder: a temporary, read-only, Finder-like browser of the Mac's approved folders,
/// drawn here over the unchanged picture. Nothing happens on the Mac until "Open on Mac"
/// (which needs control and never brings the app forward). Closing it changes nothing.
struct RemoteFinderView: View {
    @ObservedObject var files: RemoteFilesModel
    @ObservedObject var workspace: WorkspaceModel
    let inputAllowed: Bool
    /// The safe area of the screen, in this view's coordinates.
    let safe: CGRect
    /// "Finder Windows": Finder's own windows in Stage Peek instead.
    let onFinderWindows: () -> Void

    @FocusState private var searchFocused: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var macName: String { workspace.hostName }

    var body: some View {
        ZStack {
            Color.black.opacity(reduceTransparency ? 0.75 : 0.45)
                .ignoresSafeArea()
                .onTapGesture { files.close() }
                .accessibilityHidden(true)
            panel
                .frame(width: min(safe.width - 16, 760), height: max(240, safe.height - 16))
                .position(x: safe.midX, y: safe.midY)
            if let preview = files.preview {
                RemoteFilePreviewCard(files: files, workspace: workspace, preview: preview, inputAllowed: inputAllowed)
                    .frame(width: min(safe.width - 24, 640), height: max(220, safe.height - 40))
                    .position(x: safe.midX, y: safe.midY)
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
                    .zIndex(2)
            }
            if let notice = files.notice {
                noticeView(notice)
                    .position(x: safe.midX, y: safe.maxY - 40)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .zIndex(3)
            }
        }
        .environment(\.colorScheme, .dark)
        .animation(.easeOut(duration: 0.18), value: files.preview?.id)
        .animation(.easeOut(duration: 0.2), value: files.notice)
        .accessibilityAction(.escape) { files.close() }
    }

    // MARK: Panel

    private var panel: some View {
        VStack(spacing: 0) {
            header
            if files.access == .ready {
                StagePeekSearchPill(query: $files.query, focused: $searchFocused, placeholder: searchPlaceholder)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
                breadcrumbs
            }
            Divider().overlay(Color.white.opacity(0.12))
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .glass(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Files on \(macName)"))
    }

    private var searchPlaceholder: String {
        if let root = files.currentRoot, case .folder(_, let path) = files.location {
            return String(localized: "Search \(path.last ?? root.name)")
        }
        return String(localized: "Search all approved folders")
    }

    private var title: String {
        switch files.location {
        case .locations: return String(localized: "Files on \(macName)")
        case .applications: return String(localized: "Applications")
        case .folder(_, let path): return path.last ?? files.currentRoot?.name ?? ""
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            circleButton("chevron.left", label: "Back") { files.goBack() }
                .disabled(!files.canGoBack)
                .opacity(files.canGoBack ? 1 : 0.35)
            Text(title)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            if files.access == .ready, files.location != .locations {
                Picker("View", selection: $files.style) {
                    Image(systemName: "list.bullet").tag(RemoteFilesModel.Style.list).accessibilityLabel("List")
                    Image(systemName: "square.grid.2x2").tag(RemoteFilesModel.Style.grid).accessibilityLabel("Icons")
                }
                .pickerStyle(.segmented)
                .frame(width: 96)
            }
            Menu {
                Button { files.close(); onFinderWindows() } label: { Label("Finder Windows", systemImage: "macwindow.on.rectangle") }
                Button { files.retry() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
            } label: {
                Image(systemName: "ellipsis").frame(width: 34, height: 34).glass(Circle())
            }
            .accessibilityLabel("More")
            circleButton("xmark", label: "Close") { files.close() }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func circleButton(_ symbol: String, label: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 15, weight: .semibold)).frame(width: 34, height: 34).glass(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private var breadcrumbs: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    let crumbs = files.breadcrumbs
                    ForEach(Array(crumbs.enumerated()), id: \.offset) { i, crumb in
                        if i > 0 { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.secondary) }
                        Button(crumb.title) { files.go(crumb.location) }
                            .font(.subheadline.weight(i == crumbs.count - 1 ? .semibold : .regular))
                            .foregroundStyle(i == crumbs.count - 1 ? .primary : .secondary)
                            .lineLimit(1)
                            .id(i)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }
            .onChange(of: files.breadcrumbs.count) { n in proxy.scrollTo(n - 1, anchor: .trailing) }
        }
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        switch files.access {
        case .unknown, .asking:
            message("hand.raised", title: "Waiting for \(macName)",
                    detail: "Allow this device on the Mac to browse the folders you approved there. Nothing is shown until you do.",
                    progress: true)
        case .off:
            message("folder.badge.questionmark", title: "Files is off on \(macName)",
                    detail: "On the Mac, open MeowDisplay Settings › Displays › Files and turn on “Let devices browse approved folders”.",
                    retry: true)
        case .denied:
            message("hand.raised.slash", title: "\(macName) said Not Now",
                    detail: "Reconnect to ask again.")
        case .noFolders:
            message("folder.badge.plus", title: "No folders approved",
                    detail: "On the Mac, add folders in MeowDisplay Settings › Displays › Files.", retry: true)
        case .ready:
            if !files.query.trimmingCharacters(in: .whitespaces).isEmpty {
                searchResults
            } else {
                switch files.location {
                case .locations: locations
                case .applications: RemoteFinderApps(workspace: workspace, inputAllowed: inputAllowed)
                case .folder: folder
                }
            }
        }
    }

    private func message(_ symbol: String, title: LocalizedStringKey, detail: LocalizedStringKey,
                         progress: Bool = false, retry: Bool = false) -> some View {
        VStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 40, weight: .light)).foregroundStyle(.secondary)
            Text(title).font(.title3.weight(.semibold)).multilineTextAlignment(.center)
            Text(detail).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if progress { ProgressView().padding(.top, 4) }
            if retry { Button("Try Again") { files.retry() }.buttonStyle(.bordered).padding(.top, 4) }
        }
        .padding(28)
        .frame(maxWidth: 440)
    }

    private var locations: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                sectionTitle("Approved Folders")
                ForEach(files.roots) { root in
                    row(icon: AnyView(kindIcon(.folder, size: 28)), name: root.name, detail: nil, chevron: true) {
                        files.go(.folder(root: root.id, path: []))
                    }
                }
                sectionTitle("Mac")
                row(icon: AnyView(Image(systemName: "square.grid.3x3.fill").font(.system(size: 22)).foregroundStyle(meowAccent).frame(width: 34)),
                    name: String(localized: "Applications"), detail: nil, chevron: true) {
                    files.go(.applications)
                }
            }
            .padding(.vertical, 8)
        }
    }

    private func sectionTitle(_ text: LocalizedStringKey) -> some View {
        Text(text).font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
            .padding(.horizontal, 18).padding(.top, 12).padding(.bottom, 4)
    }

    @ViewBuilder private var folder: some View {
        if files.loading && files.entries.isEmpty {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = files.folderError {
            switch error {
            case "permission":
                message("lock", title: "macOS didn't allow this",
                        detail: "On the Mac, allow MeowDisplay in System Settings › Privacy & Security › Files and Folders, then try again.",
                        retry: true)
            default:
                message("questionmark.folder", title: "This folder isn't available",
                        detail: "It may have moved, or it's no longer approved on the Mac.", retry: true)
            }
        } else if files.entries.isEmpty {
            message("folder", title: "This folder is empty", detail: "Hidden files aren't shown.")
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    if files.style == .grid { grid } else { list }
                    if files.truncated {
                        Text("Showing the first 2,000 items.").font(.footnote).foregroundStyle(.secondary).padding()
                    }
                }
                .onChange(of: files.highlighted) { name in
                    if let name { withAnimation { proxy.scrollTo(name, anchor: .center) } }
                }
                .onAppear { if let name = files.highlighted { proxy.scrollTo(name, anchor: .center) } }
            }
        }
    }

    private var list: some View {
        LazyVStack(spacing: 0) {
            ForEach(files.entries) { entry in
                entryRow(entry, detail: entry.isDirectory
                         ? RemoteFilesFormat.date(entry.modified)
                         : "\(RemoteFilesFormat.size(entry.size)) · \(RemoteFilesFormat.date(entry.modified))")
                    .id(entry.name)
            }
        }
        .padding(.vertical, 6)
    }

    private var grid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 104, maximum: 150), spacing: 12)], spacing: 16) {
            ForEach(files.entries) { entry in
                Button { files.openEntry(entry) } label: {
                    VStack(spacing: 6) {
                        thumbnail(entry, size: 72)
                            .frame(width: 84, height: 76)
                        Text(entry.name).font(.caption).lineLimit(2).multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                    }
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 12).fill(files.highlighted == entry.name ? meowAccent.opacity(0.35) : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .contextMenu { entryMenu(entry) }
                .onAppear { files.wantThumbnail(entry) }
                .onDisappear { files.dropThumbnail(entry) }
                .id(entry.name)
                .accessibilityLabel(accessibilityName(entry))
            }
        }
        .padding(14)
    }

    private var searchResults: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if files.searching && files.results.isEmpty {
                    ProgressView().padding(30)
                } else if files.results.isEmpty {
                    Text("No matches").foregroundStyle(.secondary).padding(30)
                }
                ForEach(files.results) { entry in
                    let place = ([files.roots.first { $0.id == entry.root }?.name ?? ""] + (entry.location ?? [])).joined(separator: " › ")
                    entryRow(entry, detail: place)
                }
                if !files.searchComplete, !files.searching {
                    Text("Showing the first matches. Type more to narrow it down.")
                        .font(.footnote).foregroundStyle(.secondary).padding()
                }
            }
            .padding(.vertical, 6)
        }
    }

    private func entryRow(_ entry: RemoteFileEntry, detail: String) -> some View {
        row(icon: AnyView(thumbnail(entry, size: 30)), name: entry.name, detail: detail, chevron: entry.isDirectory,
            highlighted: files.highlighted == entry.name) {
            files.openEntry(entry)
        }
        .contextMenu { entryMenu(entry) }
        .onAppear { files.wantThumbnail(entry) }
        .onDisappear { files.dropThumbnail(entry) }
        .accessibilityLabel(accessibilityName(entry))
    }

    private func row(icon: AnyView, name: String, detail: String?, chevron: Bool, highlighted: Bool = false,
                     action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                icon.frame(width: 36, height: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).lineLimit(1).truncationMode(.middle)
                    if let detail, !detail.isEmpty {
                        Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                }
                Spacer(minLength: 8)
                if chevron { Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary) }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(highlighted ? meowAccent.opacity(0.35) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private func entryMenu(_ entry: RemoteFileEntry) -> some View {
        if !entry.isDirectory {
            Button { files.showPreview(entry) } label: { Label("Quick Look", systemImage: "eye") }
        }
        Button { files.openOnMac(entry) } label: { Label("Open on Mac", systemImage: "macbook") }
        if entry.location != nil {
            Button { files.showInFolder(entry) } label: { Label("Show in Folder", systemImage: "folder") }
        }
    }

    private func accessibilityName(_ entry: RemoteFileEntry) -> Text {
        Text("\(entry.name), \(RemoteFilesFormat.kindName(entry.kind))")
    }

    @ViewBuilder private func thumbnail(_ entry: RemoteFileEntry, size: CGFloat) -> some View {
        if let key = files.thumbnailKey(entry), let image = files.thumbnails[key] {
            Image(decorative: image, scale: 1)
                .resizable().scaledToFit()
                .frame(maxWidth: size, maxHeight: size)
                .clipShape(RoundedRectangle(cornerRadius: size > 40 ? 6 : 3))
                .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
        } else {
            kindIcon(entry.kind, size: size)
        }
    }

    private func noticeView(_ notice: RemoteFilesModel.Notice) -> some View {
        let text: String
        switch notice {
        case .opened(let name): text = String(localized: "Opened \(name) on the Mac")
        case .needsControl: text = String(localized: "Ask for control of the Mac to open files there")
        case .openFailed: text = String(localized: "The Mac couldn't open it")
        case .macRefused: text = String(localized: "The Mac refused")
        }
        return Text(text).font(.subheadline.weight(.medium)).padding(.horizontal, 16).padding(.vertical, 10)
            .glass(Capsule())
    }
}

/// Finder-like symbol for a kind of file.
func kindIcon(_ kind: RemoteFileKind, size: CGFloat) -> some View {
    let (symbol, color): (String, Color) = {
        switch kind {
        case .folder: return ("folder.fill", Color(red: 0.36, green: 0.68, blue: 0.98))
        case .app: return ("app.fill", .indigo)
        case .image: return ("photo", .teal)
        case .video: return ("film", .purple)
        case .audio: return ("music.note", .pink)
        case .pdf: return ("doc.richtext", .red)
        case .archive: return ("archivebox", .brown)
        case .text: return ("doc.plaintext", .gray)
        case .document: return ("doc.text", .orange)
        case .file: return ("doc", .gray)
        }
    }()
    return Image(systemName: symbol)
        .font(.system(size: size * 0.78, weight: .regular))
        .foregroundStyle(color)
        .frame(width: size, height: size)
}

/// The Mac's apps, as a grid. Opening one needs control and never brings it forward.
private struct RemoteFinderApps: View {
    @ObservedObject var workspace: WorkspaceModel
    let inputAllowed: Bool

    var body: some View {
        ScrollView {
            if workspace.apps.isEmpty {
                ProgressView().padding(30)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 88, maximum: 120), spacing: 12)], spacing: 16) {
                ForEach(workspace.apps) { app in
                    Button { workspace.launch(app.bundleID) } label: {
                        VStack(spacing: 6) {
                            if let icon = workspace.icons[app.bundleID] {
                                Image(decorative: icon, scale: 1).resizable().scaledToFit().frame(width: 52, height: 52)
                            } else {
                                kindIcon(.app, size: 52)
                            }
                            Text(app.name).font(.caption).lineLimit(2).multilineTextAlignment(.center)
                            if workspace.launching.contains(app.bundleID) { ProgressView().scaleEffect(0.6) }
                        }
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!inputAllowed)
                    .accessibilityLabel(Text("Open \(app.name) on the Mac"))
                }
            }
            .padding(14)
            if !inputAllowed {
                Text("Ask for control of the Mac to open apps there.")
                    .font(.footnote).foregroundStyle(.secondary).padding()
            }
        }
        .onAppear { if workspace.apps.isEmpty { workspace.requestApps() } }
    }
}

/// Quick Look on this device: the Mac's own preview, read-only.
private struct RemoteFilePreviewCard: View {
    @ObservedObject var files: RemoteFilesModel
    @ObservedObject var workspace: WorkspaceModel
    let preview: RemoteFilesModel.Preview
    let inputAllowed: Bool
    @State private var zoom: CGFloat = 1
    @GestureState private var pinch: CGFloat = 1

    /// Apps shown in panes now: a file can open in one of them ("drop it on that pane").
    private var paneApps: [(bundleID: String, name: String)] {
        var seen = Set<String>()
        return (workspace.remote?.tiles ?? []).compactMap { t in
            guard !t.bundleID.isEmpty, seen.insert(t.bundleID).inserted else { return nil }
            return (t.bundleID, t.app.isEmpty ? t.bundleID : t.app)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                kindIcon(preview.entry.kind, size: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(preview.entry.name).font(.headline).lineLimit(1).truncationMode(.middle)
                    Text(details).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Button { files.closePreview() } label: {
                    Image(systemName: "xmark").font(.system(size: 14, weight: .semibold)).frame(width: 32, height: 32).glass(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close Quick Look")
            }
            .padding(12)
            Divider().overlay(Color.white.opacity(0.12))
            contentView(for: preview.content)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
            Divider().overlay(Color.white.opacity(0.12))
            actions.padding(12)
        }
        .glass(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .accessibilityAction(.escape) { files.closePreview() }
    }

    private var details: String {
        var parts = [RemoteFilesFormat.kindName(preview.entry.kind)]
        if !preview.entry.isDirectory { parts.append(RemoteFilesFormat.size(preview.entry.size)) }
        let date = RemoteFilesFormat.date(preview.entry.modified)
        if !date.isEmpty { parts.append(date) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private func contentView(for content: RemoteFilesModel.PreviewContent) -> some View {
        switch content {
        case .loading:
            ProgressView()
        case .image(let image):
            Image(decorative: image, scale: 1)
                .resizable().scaledToFit()
                .scaleEffect(zoom * pinch)
                .gesture(MagnificationGesture()
                    .updating($pinch) { v, s, _ in s = v }
                    .onEnded { v in zoom = min(max(zoom * v, 1), 4) })
                .onTapGesture(count: 2) { withAnimation { zoom = zoom > 1 ? 1 : 2 } }
                .padding(10)
        case .text(let text, let truncated):
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Text(text).font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if truncated { Text("Showing the beginning of the file.").font(.caption).foregroundStyle(.secondary) }
                }
                .padding(14)
            }
        case .unavailable:
            VStack(spacing: 10) {
                kindIcon(preview.entry.kind, size: 72)
                Text("No preview").foregroundStyle(.secondary)
            }
        }
    }

    private var actions: some View {
        VStack(spacing: 6) {
            HStack(spacing: 10) {
                if preview.entry.location != nil {
                    Button { files.showInFolder(preview.entry) } label: { Label("Show in Folder", systemImage: "folder") }
                        .buttonStyle(.bordered)
                }
                Spacer()
                if !paneApps.isEmpty {
                    Menu {
                        Section("Open in a pane's app") {
                            ForEach(paneApps, id: \.bundleID) { app in
                                Button(app.name) { files.openOnMac(preview.entry, inApp: app.bundleID) }
                            }
                        }
                    } label: { Label("Open With", systemImage: "rectangle.split.2x1") }
                        .buttonStyle(.bordered)
                        .disabled(!inputAllowed)
                }
                Button { files.openOnMac(preview.entry) } label: { Label("Open on Mac", systemImage: "macbook") }
                    .buttonStyle(.borderedProminent)
                    .tint(meowAccent)
                    .disabled(!inputAllowed)
            }
            if !inputAllowed {
                Text("Opening on the Mac needs control of the Mac.").font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }
}
