import AVFoundation
import AVKit
import ImageIO
import PDFKit
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
