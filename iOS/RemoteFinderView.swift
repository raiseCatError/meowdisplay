import SwiftUI
import UIKit

/// Remote Finder: a Finder-like browser of what the Mac's owner allowed this device to reach,
/// drawn here over the unchanged picture. Viewing, saving, sharing, uploading and changing
/// files each follow the Mac's grant (shown under the title); "Open on Mac" also needs control
/// and never brings the app forward. Closing it changes nothing on the Mac.
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
    @State private var showTransfers = false
    @State private var importingFiles = false
    @State private var importingFolder = false
    @State private var renaming: RemoteFileEntry?
    @State private var renameText = ""
    @State private var askingNewFolder = false
    @State private var newFolderName = ""

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
        .sheet(isPresented: $showTransfers) { RemoteTransfersSheet(transfers: files.transfers) }
        .sheet(item: $files.info) { RemoteFileInfoView(sheet: $0) }
        .sheet(item: $files.export) { e in
            RemoteExportPresenter(export: e) { ok in files.exportFinished(e, completed: ok) }
                .ignoresSafeArea()
        }
        .fileImporter(isPresented: $importingFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { files.upload(urls) }
        }
        .background(Color.clear.fileImporter(isPresented: $importingFolder, allowedContentTypes: [.folder], allowsMultipleSelection: false) { result in
            if case .success(let urls) = result { files.upload(urls) }
        })
        .alert("Rename", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $renameText)
            Button("Cancel", role: .cancel) { renaming = nil }
            Button("Rename") {
                if let e = renaming { Task { await files.rename(e, to: renameText) } }
                renaming = nil
            }
        }
        .alert("New Folder", isPresented: $askingNewFolder) {
            TextField("Name", text: $newFolderName)
            Button("Cancel", role: .cancel) {}
            Button("Create") { Task { await files.newFolder(named: newFolderName) } }
        } message: {
            Text("The folder is made on the Mac, in \(title).")
        }
        .confirmationDialog(folderConflictTitle, isPresented: Binding(get: { files.folderConflict != nil },
                                                                     set: { if !$0 { files.folderConflict?.answer(nil) } }),
                            titleVisibility: .visible) {
            Button("Merge") { files.folderConflict?.answer(.merge) }
            Button("Keep Both") { files.folderConflict?.answer(.keepBoth) }
            Button("Skip") { files.folderConflict?.answer(.skip) }
            Button("Cancel", role: .cancel) { files.folderConflict?.answer(nil) }
        } message: {
            Text("Merge adds what you upload to the folder on the Mac; files with the same name ask again.")
        }
        .modifier(RemoteUploadConflictHost(transfers: files.transfers, canReplace: files.grant?.canDelete == true))
    }

    private var folderConflictTitle: String {
        String(localized: "“\(files.folderConflict?.name ?? "")” already exists on the Mac")
    }

    private var canEdit: Bool { files.grant.map { !$0.readOnly } ?? false }
    private var grant: RemoteFilesGrant { files.grant ?? RemoteFilesGrant() }
    private var inFolder: Bool { if case .folder = files.location { return true }; return false }

    // MARK: Panel

    private var panel: some View {
        VStack(spacing: 0) {
            header
            if files.access == .ready {
                StagePeekSearchPill(query: $files.query, focused: $searchFocused, placeholder: searchPlaceholder)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
                breadcrumbs
                grantBar
            }
            Divider().overlay(Color.white.opacity(0.12))
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if files.selecting && files.access == .ready {
                Divider().overlay(Color.white.opacity(0.12))
                selectionBar
            }
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
            if files.access == .ready, case .folder = files.location {
                Picker("View", selection: $files.style) {
                    Image(systemName: "list.bullet").tag(RemoteFilesModel.Style.list).accessibilityLabel("List")
                    Image(systemName: "square.grid.2x2").tag(RemoteFilesModel.Style.grid).accessibilityLabel("Icons")
                }
                .pickerStyle(.segmented)
                .frame(width: 96)
            }
            if files.busy { ProgressView().scaleEffect(0.8).accessibilityLabel("Working") }
            RemoteTransfersButton(transfers: files.transfers) { showTransfers = true }
            if files.access == .ready && inFolder && files.selecting {
                Button("Done") { files.selecting = false }
                    .font(.subheadline.weight(.semibold))
            } else {
                moreMenu
            }
            circleButton("xmark", label: "Close") { files.close() }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var moreMenu: some View {
        Menu {
            if files.access == .ready && inFolder {
                Section {
                    Button { files.selecting = true } label: { Label("Select", systemImage: "checkmark.circle") }
                    if grant.canUpload {
                        Button { newFolderName = String(localized: "untitled folder"); askingNewFolder = true } label: {
                            Label("New Folder", systemImage: "folder.badge.plus")
                        }
                        Button { importingFiles = true } label: { Label("Upload Files…", systemImage: "square.and.arrow.up") }
                        Button { importingFolder = true } label: { Label("Upload a Folder…", systemImage: "folder.badge.gearshape") }
                    }
                    if files.canPaste {
                        Button { Task { await files.paste() } } label: {
                            Label(files.clipboard?.move == true ? "Move Here" : "Paste", systemImage: "doc.on.clipboard")
                        }
                    }
                }
                Section {
                    Picker(selection: $files.sort) {
                        Text("Name").tag(RemoteFilesSort.name)
                        Text("Date Modified").tag(RemoteFilesSort.date)
                        Text("Size").tag(RemoteFilesSort.size)
                        Text("Kind").tag(RemoteFilesSort.kind)
                    } label: { Label("Sort By", systemImage: "arrow.up.arrow.down") }
                    .pickerStyle(.menu)
                    Toggle(isOn: $files.ascending) { Label("Ascending", systemImage: "arrow.up") }
                    Picker(selection: $files.kindFilter) {
                        Text("All Items").tag(RemoteFileKindFilter.all)
                        Text("Folders").tag(RemoteFileKindFilter.folders)
                        Text("Images").tag(RemoteFileKindFilter.images)
                        Text("Movies").tag(RemoteFileKindFilter.movies)
                        Text("Audio").tag(RemoteFileKindFilter.audio)
                        Text("Documents").tag(RemoteFileKindFilter.documents)
                        Text("Archives").tag(RemoteFileKindFilter.archives)
                    } label: { Label("Show", systemImage: "line.3.horizontal.decrease.circle") }
                    .pickerStyle(.menu)
                    if grant.hidden {
                        Toggle(isOn: $files.showHidden) { Label("Hidden Files", systemImage: "eye.slash") }
                    }
                }
            }
            Section {
                Button { files.close(); onFinderWindows() } label: { Label("Finder Windows", systemImage: "macwindow.on.rectangle") }
                Button { files.retry() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
            }
        } label: {
            Image(systemName: "ellipsis").frame(width: 34, height: 34).glass(Circle())
        }
        .accessibilityLabel("More")
    }

    /// What the Mac allows this device, and a way to ask for more.
    @ViewBuilder private var grantBar: some View {
        if let g = files.grant {
            HStack(spacing: 8) {
                Menu {
                    Section(grantDescription(g)) {
                        let missing = ["download", "upload", "modify", "delete"].filter { !g.capabilities.contains($0) }
                        if missing.isEmpty {
                            Text("Everything is allowed")
                        } else {
                            ForEach(missing, id: \.self) { cap in
                                Button { Task { await files.requestAccess([cap]) } } label: {
                                    Text("Ask the Mac for \(RemoteFilesModel.capabilityName(cap))")
                                }
                            }
                            if missing.count > 1 {
                                Button { Task { await files.requestAccess(missing) } } label: { Text("Ask the Mac for All of These") }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: g.readOnly ? "lock.fill" : "pencil")
                        Text(grantSummary(g))
                        Image(systemName: "chevron.down").font(.caption2)
                    }
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .glass(Capsule())
                }
                .accessibilityLabel(Text("Files access: \(grantDescription(g))"))
                if let c = files.clipboard, inFolder {
                    Button { Task { await files.paste() } } label: {
                        Label(c.move ? "Move \(c.names.count) Here" : "Paste \(c.names.count)", systemImage: "doc.on.clipboard")
                            .font(.caption.weight(.medium))
                    }
                    .disabled(!files.canPaste)
                    Button { files.clipboard = nil } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                        .accessibilityLabel("Clear Paste")
                }
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 8)
        }
    }

    private func grantSummary(_ g: RemoteFilesGrant) -> String {
        let what = g.readOnly ? (g.canDownload ? String(localized: "View & Save") : String(localized: "View Only"))
                              : String(localized: "Can Edit")
        let how = g.always ? String(localized: "Always") : String(localized: "This Session")
        return what + " · " + how
    }

    private func grantDescription(_ g: RemoteFilesGrant) -> String {
        var parts = [g.always ? String(localized: "Always allowed for this device") : String(localized: "Allowed for this session")]
        parts.append(g.allFiles ? String(localized: "all files the Mac lets MeowDisplay read") : String(localized: "approved folders"))
        let caps = ["download", "upload", "modify", "delete"].filter { g.capabilities.contains($0) }.map(RemoteFilesModel.capabilityName)
        parts.append(caps.isEmpty ? String(localized: "viewing only") : String(localized: "viewing, ") + caps.joined(separator: ", "))
        return parts.joined(separator: " · ")
    }

    private var selectionBar: some View {
        let chosen = files.selectedEntries
        let none = chosen.isEmpty
        return HStack(spacing: 4) {
            Button(files.selection.count == files.visibleEntries.count ? "None" : "All") {
                if files.selection.count == files.visibleEntries.count { files.selection = [] } else { files.selectAll() }
            }
            .font(.subheadline)
            Text("\(chosen.count) selected").font(.subheadline).foregroundStyle(.secondary).frame(maxWidth: .infinity)
            if grant.canDownload {
                barButton("square.and.arrow.down", "Save to Device", none) { files.save(chosen) }
                barButton("square.and.arrow.up", "Share", none) { files.share(chosen) }
            }
            if grant.canModify {
                barButton("doc.on.doc", "Copy", none) { files.copyItems(chosen, move: false) }
                barButton("folder", "Move", none) { files.copyItems(chosen, move: true) }
                barButton("archivebox", "Compress", none) { Task { await files.compress(chosen) } }
            }
            if grant.canDelete {
                barButton("trash", "Move to Trash", none) { Task { await files.trash(chosen) } }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func barButton(_ symbol: String, _ label: LocalizedStringKey, _ disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 17)).frame(width: 38, height: 38) }
            .disabled(disabled)
            .accessibilityLabel(label)
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
        case .revoked:
            message("lock.rotation", title: "Files access ended",
                    detail: "The Mac's owner turned off access for this device. Ask again to show them the prompt on the Mac.",
                    retry: true)
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
            if retry {
                Button(files.access == .revoked ? "Ask Again" : "Try Again") { files.retry() }
                    .buttonStyle(.bordered).padding(.top, 4)
            }
        }
        .padding(28)
        .frame(maxWidth: 440)
    }

    private var locations: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                if !files.favorites.isEmpty {
                    sectionTitle("Favorites")
                    ForEach(files.favorites) { fav in
                        let reachable = files.roots.contains { $0.id == fav.root }
                        row(icon: AnyView(Image(systemName: "star.fill").font(.system(size: 20)).foregroundStyle(.yellow).frame(width: 34)),
                            name: fav.name, detail: reachable ? nil : String(localized: "Not reachable with this access"), chevron: reachable) {
                            if reachable { files.go(.folder(root: fav.root, path: fav.path)) }
                        }
                        .contextMenu {
                            Button(role: .destructive) { files.removeFavorite(fav) } label: { Label("Remove from Favorites", systemImage: "star.slash") }
                        }
                    }
                }
                if !files.recents.isEmpty {
                    sectionTitle("Recent")
                    ForEach(files.recents) { entry in
                        entryRow(entry, detail: ([files.roots.first { $0.id == entry.root }?.name ?? ""] + (entry.location ?? [])).joined(separator: " › "))
                    }
                }
                sectionTitle(files.grant?.allFiles == true ? "Locations" : "Approved Folders")
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
            case "timeout", "disconnected":
                message("wifi.exclamationmark", title: "The Mac didn't answer",
                        detail: "Check the connection, then try again.", retry: true)
            default:
                message("questionmark.folder", title: "This folder isn't available",
                        detail: "It may have moved, or it's no longer approved on the Mac.", retry: true)
            }
        } else if files.visibleEntries.isEmpty {
            VStack(spacing: 12) {
                message("folder", title: "This folder is empty",
                        detail: files.kindFilter != .all ? "Nothing here matches the filter." : "Hidden files aren't shown.")
                if grant.canUpload {
                    Button { importingFiles = true } label: { Label("Upload Files…", systemImage: "square.and.arrow.up") }
                        .buttonStyle(.bordered)
                }
            }
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    if files.style == .grid { grid } else { list }
                    if files.truncated {
                        Text("Showing the first 2,000 items.").font(.footnote).foregroundStyle(.secondary).padding()
                    }
                }
                .refreshable { files.refresh() }
                .onChange(of: files.highlighted) { name in
                    if let name { withAnimation { proxy.scrollTo(name, anchor: .center) } }
                }
                .onAppear { if let name = files.highlighted { proxy.scrollTo(name, anchor: .center) } }
            }
        }
    }

    private var list: some View {
        LazyVStack(spacing: 0) {
            ForEach(files.visibleEntries) { entry in
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
            ForEach(files.visibleEntries) { entry in
                Button { tap(entry) } label: {
                    VStack(spacing: 6) {
                        thumbnail(entry, size: 72)
                            .frame(width: 84, height: 76)
                            .overlay(alignment: .topTrailing) { selectionMark(entry) }
                        Text(entry.name).font(.caption).lineLimit(2).multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                    }
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 12).fill(
                        files.selection.contains(entry.id) ? meowAccent.opacity(0.45)
                            : files.highlighted == entry.name ? meowAccent.opacity(0.35) : .clear))
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

    /// In Select, a tap selects; otherwise it opens.
    private func tap(_ entry: RemoteFileEntry) {
        if files.selecting && entry.location == nil { files.toggleSelection(entry) } else { files.openEntry(entry) }
    }

    @ViewBuilder private func selectionMark(_ entry: RemoteFileEntry) -> some View {
        if files.selecting && entry.location == nil {
            Image(systemName: files.selection.contains(entry.id) ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(files.selection.contains(entry.id) ? meowAccent : .secondary)
                .background(Circle().fill(.black.opacity(0.35)))
                .accessibilityHidden(true)
        }
    }

    private func entryRow(_ entry: RemoteFileEntry, detail: String) -> some View {
        row(icon: AnyView(HStack(spacing: 6) {
                if files.selecting && entry.location == nil { selectionMark(entry) }
                thumbnail(entry, size: 30)
            }), name: entry.name, detail: detail, chevron: entry.isDirectory && !files.selecting,
            highlighted: files.highlighted == entry.name || files.selection.contains(entry.id)) {
            tap(entry)
        }
        .accessibilityAddTraits(files.selection.contains(entry.id) ? .isSelected : [])
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
        Section {
            if !entry.isDirectory {
                Button { files.showPreview(entry) } label: { Label("Quick Look", systemImage: "eye") }
            }
            Button { files.openOnMac(entry) } label: { Label("Open on Mac", systemImage: "macbook") }
            if entry.location != nil {
                Button { files.showInFolder(entry) } label: { Label("Show in Folder", systemImage: "folder") }
            }
            Button { Task { await files.getInfo(entry) } } label: { Label("Get Info", systemImage: "info.circle") }
            if entry.isDirectory && entry.kind != .app {
                Button { files.toggleFavorite(entry) } label: {
                    files.isFavorite(entry) ? Label("Remove from Favorites", systemImage: "star.slash")
                                            : Label("Add to Favorites", systemImage: "star")
                }
            }
        }
        if grant.canDownload && entry.kind != .app {
            Section {
                Button { files.save([entry]) } label: { Label("Save to Device", systemImage: "square.and.arrow.down") }
                Button { files.share([entry]) } label: { Label("Share…", systemImage: "square.and.arrow.up") }
            }
        }
        if entry.location == nil && (grant.canModify || grant.canDelete) {
            Section {
                if grant.canModify && !entry.readOnly {
                    Button { renameText = entry.name; renaming = entry } label: { Label("Rename", systemImage: "pencil") }
                }
                if grant.canModify {
                    Button { Task { await files.duplicate([entry]) } } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
                    Button { files.copyItems([entry], move: false) } label: { Label("Copy", systemImage: "doc.on.doc") }
                    Button { files.copyItems([entry], move: true) } label: { Label("Move…", systemImage: "folder") }
                    if entry.kind == .archive && entry.name.lowercased().hasSuffix(".zip") {
                        Button { Task { await files.expand(entry) } } label: { Label("Expand", systemImage: "archivebox") }
                    } else {
                        Button { Task { await files.compress([entry]) } } label: { Label("Compress", systemImage: "archivebox") }
                    }
                }
                if grant.canDelete {
                    Button(role: .destructive) { Task { await files.trash([entry]) } } label: { Label("Move to Trash", systemImage: "trash") }
                }
            }
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
        var action: (LocalizedStringKey, () -> Void)?
        switch notice {
        case .opened(let name): text = String(localized: "Opened \(name) on the Mac")
        case .needsControl: text = String(localized: "Ask for control of the Mac to open files there")
        case .openFailed: text = String(localized: "The Mac couldn't open it")
        case .macRefused: text = String(localized: "The Mac refused")
        case .text(let s): text = s
        case .trashed(let count, let tokens):
            text = count == 1 ? String(localized: "Moved to the Trash on the Mac") : String(localized: "Moved \(count) items to the Trash on the Mac")
            if !tokens.isEmpty, grant.canModify { action = ("Undo", { Task { await files.putBack(tokens) } }) }
        case .needs(let cap):
            text = String(localized: "The Mac doesn't allow \(RemoteFilesModel.capabilityName(cap)) for this device")
            if !cap.isEmpty { action = ("Ask", { Task { await files.requestAccess([cap]) } }) }
        }
        return HStack(spacing: 12) {
            Text(text).font(.subheadline.weight(.medium)).multilineTextAlignment(.leading)
            if let action {
                Button(action.0, action: action.1).font(.subheadline.weight(.bold)).foregroundStyle(meowAccent)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .frame(maxWidth: 520)
        .glass(Capsule())
        .accessibilityElement(children: .combine)
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

    /// The running apps from the window list until the Mac's full app list arrives.
    private var apps: [MacAppItem] {
        if !workspace.apps.isEmpty { return workspace.apps }
        return (workspace.catalog?.apps ?? []).map { MacAppItem(bundleID: $0.bundleID, name: $0.name, running: true, windowCount: 0, lastUsed: nil) }
    }

    var body: some View {
        ScrollView {
            if apps.isEmpty {
                ProgressView().padding(30)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 88, maximum: 120), spacing: 12)], spacing: 16) {
                ForEach(apps) { app in
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

/// Quick Look on this device: the Mac's still first, then the file itself where it helps —
/// movies and audio stream with seeking, PDFs show their pages, images come at full size.
private struct RemoteFilePreviewCard: View {
    @ObservedObject var files: RemoteFilesModel
    @ObservedObject var workspace: WorkspaceModel
    @ObservedObject var transfers: RemoteTransferQueue
    let preview: RemoteFilesModel.Preview
    let inputAllowed: Bool
    @State private var zoom: CGFloat = 1
    @GestureState private var pinch: CGFloat = 1
    @State private var macApps: [RemoteOpenWithApp] = []

    init(files: RemoteFilesModel, workspace: WorkspaceModel, preview: RemoteFilesModel.Preview, inputAllowed: Bool) {
        self.files = files
        self.workspace = workspace
        self.transfers = files.transfers
        self.preview = preview
        self.inputAllowed = inputAllowed
    }

    private var grant: RemoteFilesGrant { files.grant ?? RemoteFilesGrant() }
    private var viewer: RemoteFileViewer? { files.viewer.flatMap { $0.previewID == preview.id ? $0 : nil } }

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
            mainContent(viewer)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
            Divider().overlay(Color.white.opacity(0.12))
            actions.padding(12)
        }
        .glass(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .accessibilityAction(.escape) { files.closePreview() }
        .task(id: preview.id) { macApps = await files.openWithApps(preview.entry) }
    }

    /// The file itself when it's here; the Mac's still (with progress) until then.
    @ViewBuilder private func mainContent(_ viewer: RemoteFileViewer?) -> some View {
        switch viewer?.content {
        case .stream(let x, let size, let uti)?:
            RemoteMediaPlayer(files: files, entry: preview.entry, x: x, size: size, uti: uti) { code in
                files.viewer?.content = .failed(code)
            }
            .id(x)
        case .file(let url)?:
            switch preview.entry.kind {
            case .pdf: RemotePDFViewer(url: url)
            case .image: RemoteFullImage(url: url, placeholder: { if case .image(let i) = preview.content { return i }; return nil }())
            default: RemoteQuickLookView(url: url)
            }
        case .loading?:
            contentView(for: preview.content)
                .overlay(alignment: .bottom) {
                    VStack(spacing: 6) {
                        if let f = files.viewerProgress, f > 0 {
                            ProgressView(value: f).frame(maxWidth: 220)
                        } else {
                            ProgressView()
                        }
                        Text(preview.entry.kind == .video || preview.entry.kind == .audio ? "Connecting to the Mac…" : "Loading from the Mac…")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(10)
                    .glass(RoundedRectangle(cornerRadius: 12))
                    .padding(.bottom, 12)
                }
        case .failed(let code)?:
            contentView(for: preview.content)
                .overlay(alignment: .bottom) {
                    HStack(spacing: 10) {
                        Text(code == "unsupported" ? String(localized: "This format can't play here.") : RemoteFilesModel.errorText(code))
                            .font(.caption)
                        if code != "unsupported" { Button("Retry") { files.retryViewer() }.font(.caption.weight(.bold)) }
                    }
                    .padding(10)
                    .glass(Capsule())
                    .padding(.bottom, 12)
                }
        case nil:
            contentView(for: preview.content)
        }
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
                if grant.canDownload, !preview.entry.isDirectory, viewer == nil {
                    Button { files.quickLookCopy(preview.entry) } label: { Label("Open Here", systemImage: "eye") }
                        .buttonStyle(.bordered)
                }
            }
        case .failed(let code):
            VStack(spacing: 10) {
                kindIcon(preview.entry.kind, size: 64)
                Text(RemoteFilesModel.errorText(code)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button("Try Again") { files.retryPreview() }.buttonStyle(.bordered)
            }
            .padding()
        }
    }

    private var actions: some View {
        VStack(spacing: 6) {
            HStack(spacing: 10) {
                if preview.entry.location != nil {
                    Button { files.showInFolder(preview.entry) } label: { Label("Show in Folder", systemImage: "folder") }
                        .buttonStyle(.bordered)
                        .labelStyle(.iconOnly)
                }
                if grant.canDownload {
                    Button { files.save([preview.entry]) } label: { Label("Save to Device", systemImage: "square.and.arrow.down") }
                        .buttonStyle(.bordered)
                        .labelStyle(.iconOnly)
                    Button { files.share([preview.entry]) } label: { Label("Share", systemImage: "square.and.arrow.up") }
                        .buttonStyle(.bordered)
                        .labelStyle(.iconOnly)
                }
                Spacer()
                if !paneApps.isEmpty || !macApps.isEmpty {
                    Menu {
                        if !paneApps.isEmpty {
                            Section("Open in a pane's app") {
                                ForEach(paneApps, id: \.bundleID) { app in
                                    Button(app.name) { files.openOnMac(preview.entry, inApp: app.bundleID) }
                                }
                            }
                        }
                        if !macApps.isEmpty {
                            Section("Open on the Mac with") {
                                ForEach(macApps) { app in
                                    Button(app.isDefault ? String(localized: "\(app.name) (default)") : app.name) {
                                        files.openOnMac(preview.entry, inApp: app.bundleID)
                                    }
                                }
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

/// An image file from the Mac at full resolution (decoded off the main thread, up to 4096 px),
/// with pinch and double-tap zoom.
private struct RemoteFullImage: View {
    let url: URL
    let placeholder: CGImage?
    @State private var image: CGImage?
    @State private var zoom: CGFloat = 1
    @GestureState private var pinch: CGFloat = 1

    var body: some View {
        Group {
            if let img = image ?? placeholder {
                Image(decorative: img, scale: 1)
                    .resizable().scaledToFit()
                    .scaleEffect(zoom * pinch)
                    .gesture(MagnificationGesture()
                        .updating($pinch) { v, s, _ in s = v }
                        .onEnded { v in zoom = min(max(zoom * v, 1), 6) })
                    .onTapGesture(count: 2) { withAnimation { zoom = zoom > 1 ? 1 : 2.5 } }
                    .padding(10)
            } else {
                ProgressView()
            }
        }
        .task(id: url) {
            let u = url
            image = await Task.detached(priority: .userInitiated) { RemoteImageDecoder.image(at: u) }.value
        }
    }
}

/// The header's transfers button: shows how many are running.
struct RemoteTransfersButton: View {
    @ObservedObject var transfers: RemoteTransferQueue
    let action: () -> Void

    var body: some View {
        let visible = transfers.items.filter { $0.direction != .download(.view) }
        if !visible.isEmpty {
            let active = visible.filter { !$0.state.isFinished }.count
            Button(action: action) {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 34, height: 34)
                    .glass(Circle())
                    .overlay(alignment: .topTrailing) {
                        if active > 0 {
                            Text("\(active)").font(.caption2.weight(.bold)).foregroundStyle(.white)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Capsule().fill(meowAccent))
                                .offset(x: 4, y: -4)
                        }
                    }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(active > 0 ? Text("Transfers, \(active) running") : Text("Transfers"))
        }
    }
}

/// Asks what to do when an uploaded file's name exists on the Mac.
struct RemoteUploadConflictHost: ViewModifier {
    @ObservedObject var transfers: RemoteTransferQueue
    let canReplace: Bool

    func body(content: Content) -> some View {
        let item = transfers.firstConflict
        let several = item.map { c in transfers.items.filter { $0.batch == c.batch && !$0.state.isFinished }.count > 1 } ?? false
        return content.confirmationDialog(
            item.map { String(localized: "“\($0.name)” already exists on the Mac") } ?? "",
            isPresented: Binding(get: { item != nil }, set: { _ in }),
            titleVisibility: .visible
        ) {
            if let item {
                Button("Keep Both") { transfers.resolveConflict(item.id, .keepBoth, forAll: false) }
                if canReplace { Button("Replace") { transfers.resolveConflict(item.id, .replace, forAll: false) } }
                Button("Skip") { transfers.resolveConflict(item.id, .skip, forAll: false) }
                if several {
                    Button("Keep Both for All") { transfers.resolveConflict(item.id, .keepBoth, forAll: true) }
                    if canReplace { Button("Replace All") { transfers.resolveConflict(item.id, .replace, forAll: true) } }
                    Button("Skip All") { transfers.resolveConflict(item.id, .skip, forAll: true) }
                }
                Button("Stop Upload", role: .cancel) { transfers.cancel(item.id) }
            }
        } message: {
            Text("Replace moves the item on the Mac to its Trash.")
        }
    }
}
