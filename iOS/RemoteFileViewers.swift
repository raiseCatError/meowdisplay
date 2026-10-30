import AVFoundation
import AVKit
import ImageIO
import PDFKit
import Photos
import QuickLook
import SwiftUI
import UIKit
import UniformTypeIdentifiers

// Remote Finder viewers on iPhone and iPad: movies and audio stream from the Mac with seeking,
// PDFs show their pages, images come at full resolution, other documents open in Quick Look
// (only with the download capability, since Quick Look can share what it shows). Copies live
// in the app's temporary folder and go when the viewer or Remote Finder closes.

// MARK: Streaming playback

/// Answers AVPlayer's byte-range requests from the Mac (`RemoteFileStream`), so a movie starts
/// in a moment and seeks without copying the whole file first.
@MainActor
final class RemoteStreamLoader: NSObject, AVAssetResourceLoaderDelegate {
    private weak var files: RemoteFilesModel?
    let x: Int
    let size: Int64
    let uti: String?

    private final class Load {
        let request: AVAssetResourceLoadingRequest
        var next: Int64
        let end: Int64
        var outstanding = 0
        var cancelled = false
        init(_ r: AVAssetResourceLoadingRequest, next: Int64, end: Int64) { request = r; self.next = next; self.end = end }
    }

    private var loads: [Load] = []
    static let scheme = "meowfile"

    init(files: RemoteFilesModel, x: Int, size: Int64, uti: String?) {
        self.files = files; self.x = x; self.size = size; self.uti = uti
    }

    func asset(named name: String) -> AVURLAsset {
        let ext = (name as NSString).pathExtension
        let url = URL(string: "\(Self.scheme)://stream/\(x)" + (ext.isEmpty ? "" : ".\(ext)"))!
        let asset = AVURLAsset(url: url)
        asset.resourceLoader.setDelegate(self, queue: .main)
        return asset
    }

    nonisolated func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                                    shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        Task { @MainActor in self.start(loadingRequest) }
        return true
    }

    nonisolated func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        Task { @MainActor in
            for l in self.loads where l.request === loadingRequest { l.cancelled = true }
            self.loads.removeAll { $0.cancelled }
            self.pumpAll()
        }
    }

    private func start(_ r: AVAssetResourceLoadingRequest) {
        if let info = r.contentInformationRequest {
            info.contentType = uti ?? UTType.movie.identifier
            info.contentLength = size
            info.isByteRangeAccessSupported = true
        }
        guard let d = r.dataRequest else { return r.finishLoading() }
        let from = d.currentOffset != 0 ? d.currentOffset : d.requestedOffset
        let end = d.requestsAllDataToEndOfResource ? size : min(size, d.requestedOffset + Int64(d.requestedLength))
        guard from < end else { return r.finishLoading() }
        loads.append(Load(r, next: from, end: end))
        pumpAll()
    }

    private func pumpAll() {
        guard let stream = files?.stream(x) else {
            for l in loads { l.request.finishLoading(with: Self.error("closed")) }
            loads = []
            return
        }
        // Earliest requests first; at most two reads ahead per request.
        for l in loads where !l.cancelled {
            while l.outstanding < 2, l.next < l.end, stream.canRead {
                let o = l.next
                let n = Int(min(Int64(RemoteFileStream.readBytes), l.end - o))
                l.next += Int64(n)
                l.outstanding += 1
                stream.read(o, n) { [weak self] data in
                    l.outstanding -= 1
                    guard let self, !l.cancelled else { self?.pumpAll(); return }
                    guard let data else {
                        l.cancelled = true
                        l.request.finishLoading(with: Self.error(stream.failed ?? "failed"))
                        self.loads.removeAll { $0 === l }
                        return
                    }
                    l.request.dataRequest?.respond(with: data)
                    if l.next >= l.end, l.outstanding == 0 {
                        l.request.finishLoading()
                        self.loads.removeAll { $0 === l }
                    }
                    self.pumpAll()
                }
            }
        }
    }

    static func error(_ code: String) -> NSError {
        NSError(domain: "MeowDisplay.RemoteFiles", code: 1, userInfo: [NSLocalizedDescriptionKey: RemoteFilesModel.errorText(code)])
    }
}

/// A movie or a song from the Mac, streamed: the system player with scrubbing.
struct RemoteMediaPlayer: UIViewControllerRepresentable {
    let files: RemoteFilesModel
    let entry: RemoteFileEntry
    let x: Int
    let size: Int64
    let uti: String?
    var onFailed: @MainActor @Sendable (String) -> Void

    final class Coordinator {
        var loader: RemoteStreamLoader?
        var status: NSKeyValueObservation?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let loader = RemoteStreamLoader(files: files, x: x, size: size, uti: uti)
        context.coordinator.loader = loader
        let item = AVPlayerItem(asset: loader.asset(named: entry.name))
        let player = AVPlayer(playerItem: item)
        let failed = onFailed
        context.coordinator.status = item.observe(\.status) { item, _ in
            if item.status == .failed { Task { @MainActor in failed("unsupported") } }
        }
        let vc = AVPlayerViewController()
        vc.player = player
        vc.allowsPictureInPicturePlayback = false
        vc.updatesNowPlayingInfoCenter = false
        vc.entersFullScreenWhenPlaybackBegins = false
        player.play()
        return vc
    }

    func updateUIViewController(_ vc: AVPlayerViewController, context: Context) {}

    static func dismantleUIViewController(_ vc: AVPlayerViewController, coordinator: Coordinator) {
        vc.player?.pause()
        vc.player?.replaceCurrentItem(with: nil)
        coordinator.status = nil
        coordinator.loader = nil
    }
}

// MARK: PDF

/// A PDF's pages, scrolled and zoomed; "3 of 12" shows where you are.
struct RemotePDFViewer: View {
    let url: URL
    @State private var page = 1
    @State private var pages = 0

    var body: some View {
        RemotePDFKitView(url: url, page: $page, pages: $pages)
            .overlay(alignment: .bottom) {
                if pages > 1 {
                    Text("\(page) of \(pages)")
                        .font(.caption.monospacedDigit().weight(.medium))
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .glass(Capsule())
                        .padding(.bottom, 10)
                        .accessibilityLabel(Text("Page \(page) of \(pages)"))
                }
            }
    }
}

private struct RemotePDFKitView: UIViewRepresentable {
    let url: URL
    @Binding var page: Int
    @Binding var pages: Int

    @MainActor final class Coordinator: NSObject {
        var parent: RemotePDFKitView
        init(_ p: RemotePDFKitView) { parent = p }
        @objc func changed(_ n: Notification) {
            guard let v = n.object as? PDFView, let doc = v.document, let p = v.currentPage else { return }
            parent.page = doc.index(for: p) + 1
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> PDFView {
        let v = PDFView()
        v.autoScales = true
        v.displayMode = .singlePageContinuous
        v.displayDirection = .vertical
        v.backgroundColor = .clear
        v.document = PDFDocument(url: url)
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.changed(_:)),
                                               name: .PDFViewPageChanged, object: v)
        let count = v.document?.pageCount ?? 0
        DispatchQueue.main.async { pages = count; page = count > 0 ? 1 : 0 }
        return v
    }

    func updateUIView(_ v: PDFView, context: Context) { context.coordinator.parent = self }

    static func dismantleUIView(_ v: PDFView, coordinator: Coordinator) {
        NotificationCenter.default.removeObserver(coordinator)
    }
}

// MARK: Full-resolution images

enum RemoteImageDecoder {
    /// Decodes up to `maxSide` pixels, turned upright (JPEG, PNG, HEIC, WebP and what ImageIO reads).
    static func image(at url: URL, maxSide: Int = 4096) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxSide,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }
}

// MARK: Quick Look

struct RemoteQuickLookView: UIViewControllerRepresentable {
    let url: URL

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        var url: URL
        init(url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem { url as NSURL }
    }

    func makeCoordinator() -> Coordinator { Coordinator(url: url) }

    func makeUIViewController(context: Context) -> QLPreviewController {
        let c = QLPreviewController()
        c.dataSource = context.coordinator
        return c
    }

    func updateUIViewController(_ c: QLPreviewController, context: Context) {
        if context.coordinator.url != url { context.coordinator.url = url; c.reloadData() }
    }
}

// MARK: Save and share

/// The system's Save to Files picker or share sheet for copies from the Mac; the copies are
/// removed once it is done.
/// Save (the system "Save to Files" picker) or Share (the share sheet) for copies made on this
/// device, presented from the top-most view controller. Inside a SwiftUI sheet these showed
/// nothing or a blank sheet, and tearing the sheet down deleted the copies early.
/// `done` runs once; a shared copy stays a minute so the receiving app can still read it.
@MainActor
enum RemoteExportPresenting {
    private static var active: Coordinator?

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private var done: ((Bool) -> Void)?
        init(done: @escaping (Bool) -> Void) { self.done = done }
        func finish(_ ok: Bool) { let d = done; done = nil; d?(ok) }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { finish(true) }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { finish(false) }
    }

    static func present(_ export: RemoteFilesExport, done: @escaping (Bool) -> Void) { present(export, attempt: 0, done: done) }

    /// A copy that was quick finishes while the long-press menu (or a sheet) is still going
    /// away; presenting then shows nothing (owner report 2026-10-31: Share from the long-press
    /// menu never showed the share sheet). Wait for the screen to settle, up to 3 s.
    private static func present(_ export: RemoteFilesExport, attempt: Int, done: @escaping (Bool) -> Void) {
        guard let top = topViewController() else { done(false); return }
        let busy = top.transitionCoordinator != nil || top.isBeingPresented || top.isBeingDismissed
            || top.presentedViewController?.isBeingDismissed == true
        if busy, attempt < 20 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { present(export, attempt: attempt + 1, done: done) }
            return
        }
        active?.finish(false)
        let c = Coordinator { ok in active = nil; done(ok) }
        active = c
        switch export.mode {
        case .save:
            let picker = UIDocumentPickerViewController(forExporting: export.urls, asCopy: true)
            picker.delegate = c
            top.present(picker, animated: true)
        case .share:
            let sheet = UIActivityViewController(activityItems: export.urls, applicationActivities: nil)
            sheet.completionWithItemsHandler = { _, completed, _, _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + (completed ? 60 : 0)) { c.finish(completed) }
            }
            if let pop = sheet.popoverPresentationController {   // iPad: required, centred near the bottom
                pop.sourceView = top.view
                pop.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.maxY - 80, width: 1, height: 1)
                pop.permittedArrowDirections = []
            }
            top.present(sheet, animated: true)
        }
    }

    static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        // The app's own visible, normal-level windows: never a menu's or the keyboard's.
        let windows = (scenes.filter { $0.activationState == .foregroundActive }.flatMap(\.windows) + scenes.flatMap(\.windows))
            .filter { !$0.isHidden && $0.windowLevel == .normal && $0.rootViewController != nil }
        var top = (windows.first { $0.isKeyWindow } ?? windows.first)?.rootViewController
        while let p = top?.presentedViewController, !p.isBeingDismissed { top = p }
        return top
    }
}

/// Save to Device without a picker (owner, 2026-10-31): photos and videos go to Photos, everything
/// else (and anything Photos refuses) to Files ▸ On My iPhone/iPad ▸ MeowDisplay ▸ Downloads.
@MainActor
enum RemoteSaveToDevice {
    struct Result: Equatable { var photos = 0; var files = 0; var photosDenied = false }

    static var downloads: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Downloads", isDirectory: true)
    }

    /// Photos takes still images and movies; anything else, or a type it can't read, is a file.
    nonisolated static func photosResource(for url: URL) -> PHAssetResourceType? {
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else { return nil }
        if type.conforms(to: .movie) { return .video }
        if type.conforms(to: .image), !type.conforms(to: .svg), type != .ico, type != .icns { return .photo }
        return nil
    }

    /// A name not taken in `folder`: "name.ext", then "name 2.ext", "name 3.ext"...
    nonisolated static func freeName(_ name: String, in folder: URL, exists: (URL) -> Bool) -> URL {
        let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        var candidate = folder.appendingPathComponent(name)
        var n = 2
        while exists(candidate) {
            candidate = folder.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            n += 1
        }
        return candidate
    }

    static func save(_ urls: [URL]) async -> Result {
        var result = Result()
        let fm = FileManager.default
        var media: [(URL, PHAssetResourceType)] = []
        var files: [URL] = []
        for url in urls {
            var dir: ObjCBool = false
            if fm.fileExists(atPath: url.path, isDirectory: &dir), !dir.boolValue, let kind = photosResource(for: url) {
                media.append((url, kind))
            } else {
                files.append(url)
            }
        }
        if !media.isEmpty {
            let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            if status == .authorized || status == .limited {
                for (url, kind) in media {
                    do {
                        try await PHPhotoLibrary.shared().performChanges {
                            PHAssetCreationRequest.forAsset().addResource(with: kind, fileURL: url, options: nil)
                        }
                        result.photos += 1
                    } catch {
                        files.append(url)   // a format Photos refuses still lands in Downloads
                    }
                }
            } else {
                result.photosDenied = true
                files += media.map(\.0)
            }
        }
        if !files.isEmpty {
            try? fm.createDirectory(at: downloads, withIntermediateDirectories: true)
            for url in files {
                let dest = freeName(url.lastPathComponent, in: downloads) { fm.fileExists(atPath: $0.path) }
                if (try? fm.copyItem(at: url, to: dest)) != nil { result.files += 1 }
            }
        }
        return result
    }

    static func message(_ r: Result, failed: Int) -> String {
        var parts: [String] = []
        if r.photos > 0 { parts.append(String(localized: "\(r.photos) to Photos")) }
        if r.files > 0 { parts.append(String(localized: "\(r.files) to Files ▸ MeowDisplay ▸ Downloads")) }
        var text = parts.isEmpty ? String(localized: "Nothing could be saved.") : String(localized: "Saved \(parts.joined(separator: ", ")).")
        if r.photosDenied { text += " " + String(localized: "Photos access is off, so photos and videos went to Downloads.") }
        if failed > 0 { text += " " + String(localized: "\(failed) couldn't be copied from the Mac.") }
        return text
    }
}

/// Copies from the Mac being prepared for Save or Share: one bar with the batch's progress.
struct RemoteExportProgressBar: View {
    @ObservedObject var transfers: RemoteTransferQueue
    let batches: [UUID: RemoteFilesExportBatch]
    let cancel: () -> Void

    var body: some View {
        let items = transfers.items.filter { batches[$0.batch] != nil }
        let total = items.reduce(Int64(0)) { $0 + max($1.size, 0) }
        let done = items.reduce(Int64(0)) { $0 + min($1.transferred, max($1.size, 0)) }
        let share = batches.values.contains { $0.mode == .share }
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(share ? "Preparing to share…" : "Copying to this device…").font(.footnote.weight(.semibold))
                if total > 0 {
                    ProgressView(value: Double(done), total: Double(total))
                    Text("\(ByteCountFormatter.string(fromByteCount: done, countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file))")
                        .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                } else {
                    ProgressView(value: nil as Double?).progressViewStyle(.linear)
                }
            }
            Button("Cancel", action: cancel).buttonStyle(.bordered).controlSize(.small)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .frame(maxWidth: 420)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

struct RemoteExportPresenter: UIViewControllerRepresentable {
    let export: RemoteFilesExport
    let done: (Bool) -> Void

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let done: (Bool) -> Void
        var finished = false
        init(done: @escaping (Bool) -> Void) { self.done = done }
        func finish(_ ok: Bool) { guard !finished else { return }; finished = true; done(ok) }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { finish(true) }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { finish(false) }
    }

    func makeCoordinator() -> Coordinator { Coordinator(done: done) }

    func makeUIViewController(context: Context) -> UIViewController {
        switch export.mode {
        case .save:
            let picker = UIDocumentPickerViewController(forExporting: export.urls, asCopy: true)
            picker.delegate = context.coordinator
            return picker
        case .share:
            let sheet = UIActivityViewController(activityItems: export.urls, applicationActivities: nil)
            let c = context.coordinator
            sheet.completionWithItemsHandler = { _, completed, _, _ in c.finish(completed) }
            return sheet
        }
    }

    func updateUIViewController(_ vc: UIViewController, context: Context) {}

    static func dismantleUIViewController(_ vc: UIViewController, coordinator: Coordinator) {
        coordinator.finish(false)
    }
}

// MARK: Transfers

struct RemoteTransfersSheet: View {
    @ObservedObject var transfers: RemoteTransferQueue
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if !transfers.items.contains(where: { $0.direction != .download(.view) }) {
                    Text("Nothing is being copied.").foregroundStyle(.secondary)
                }
                ForEach(transfers.items.reversed().filter { $0.direction != .download(.view) }) { item in
                    row(item)
                }
            }
            .navigationTitle("Transfers")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if transfers.items.contains(where: { $0.state.isFinished }) {
                        Button("Clear Finished") { transfers.clearFinished() }
                    }
                }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }

    private func row(_ item: RemoteTransferItem) -> some View {
        HStack(spacing: 12) {
            Image(systemName: item.direction == .upload ? "arrow.up.circle" : "arrow.down.circle")
                .font(.title3)
                .foregroundStyle(item.direction == .upload ? Color.orange : meowAccent)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.resultName ?? item.name).lineLimit(1).truncationMode(.middle)
                if item.state == .running || item.state == .waiting {
                    ProgressView(value: item.fraction)
                }
                Text(status(item)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 4)
            switch item.state {
            case .running, .waiting, .conflict:
                Button { transfers.cancel(item.id) } label: { Image(systemName: "xmark.circle.fill").font(.title3) }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .accessibilityLabel(Text("Cancel \(item.name)"))
            case .failed:
                Button { transfers.retry(item.id) } label: { Image(systemName: "arrow.clockwise.circle.fill").font(.title3) }
                    .buttonStyle(.plain).foregroundStyle(meowAccent)
                    .accessibilityLabel(Text("Retry \(item.name)"))
            default:
                EmptyView()
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func status(_ item: RemoteTransferItem) -> String {
        let done = ByteCountFormatter.string(fromByteCount: item.transferred, countStyle: .file)
        let total = ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file)
        switch item.state {
        case .waiting: return String(localized: "Waiting")
        case .running:
            let speed = item.bytesPerSecond > 0 ? " · " + ByteCountFormatter.string(fromByteCount: Int64(item.bytesPerSecond), countStyle: .file) + "/s" : ""
            return "\(done) of \(total)" + speed
        case .conflict: return String(localized: "Already on the Mac: choose what to do")
        case .done:
            switch item.direction {
            case .upload: return String(localized: "Uploaded")
            case .download(.save): return String(localized: "Copied")
            case .download(.view): return String(localized: "Ready to view")
            }
        case .skipped: return String(localized: "Skipped")
        case .cancelled: return String(localized: "Cancelled")
        case .failed(let code): return RemoteFilesModel.errorText(code)
        }
    }
}

// MARK: Info

struct RemoteFileInfoView: View {
    let sheet: RemoteFileInfoSheet
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 12) {
                        kindIcon(sheet.entry.kind, size: 40)
                        VStack(alignment: .leading) {
                            Text(sheet.info.name.isEmpty ? sheet.entry.name : sheet.info.name).font(.headline)
                            Text(sheet.info.kind).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                }
                Section("General") {
                    if let size = sheet.info.size {
                        line("Size", ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
                             + (sheet.info.complete ? "" : "+"))
                    }
                    if let items = sheet.info.items { line("Items", "\(items)") }
                    if let d = sheet.info.created { line("Created", d.formatted(date: .abbreviated, time: .shortened)) }
                    if let d = sheet.info.modified { line("Modified", d.formatted(date: .abbreviated, time: .shortened)) }
                    if let d = sheet.info.opened { line("Last opened", d.formatted(date: .abbreviated, time: .shortened)) }
                    if let c = sheet.info.cloud { line("iCloud", c) }
                }
                Section("Sharing & Permissions") {
                    if !sheet.info.owner.isEmpty { line("Owner", sheet.info.owner) }
                    if !sheet.info.permissions.isEmpty { line("Permissions", sheet.info.permissions) }
                    line("Can be changed", sheet.info.writable && !sheet.info.locked ? String(localized: "Yes") : String(localized: "No"))
                    if sheet.info.locked { line("Locked", String(localized: "Yes")) }
                }
            }
            .navigationTitle("Info")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }

    private func line(_ title: LocalizedStringKey, _ value: String) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(value).multilineTextAlignment(.trailing).textSelection(.enabled)
        }
    }
}
