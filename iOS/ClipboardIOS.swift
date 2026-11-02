import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// UIPasteboard for the Unified Clipboard. Copies from the Mac are written for this device
/// only (never passed on through Universal Clipboard). Reading goes through the system: iOS
/// asks first unless the person allowed pasting from other apps, and the system Paste button
/// never asks.
@MainActor
final class IOSClipboardPlatform: ClipboardPlatform {
    static let shared = IOSClipboardPlatform()
    private let outRoot = FileManager.default.temporaryDirectory.appendingPathComponent("MeowDisplay-Clipboard-Out", isDirectory: true)

    var changeCount: Int { UIPasteboard.general.changeCount }

    func write(_ items: [[(kind: ClipKind, data: Data)]]) -> Int {
        let out: [[String: Any]] = items.map { reps in
            var d: [String: Any] = [:]
            for r in reps {
                switch r.kind {
                case .text: d[UTType.utf8PlainText.identifier] = String(decoding: r.data, as: UTF8.self)
                case .url: if let u = URL(string: String(decoding: r.data, as: UTF8.self)) { d[UTType.url.identifier] = u }
                case .html: d[UTType.html.identifier] = r.data
                case .rtf: d[UTType.rtf.identifier] = r.data
                case .png: d[UTType.png.identifier] = r.data
                case .jpeg: d[UTType.jpeg.identifier] = r.data
                }
            }
            return d
        }.filter { !$0.isEmpty }
        UIPasteboard.general.setItems(out, options: [.localOnly: true])
        return UIPasteboard.general.changeCount
    }

    func read(textOnly: Bool, maxBytes: Int, completion: @escaping @MainActor (ClipLocalContent?) -> Void) {
        content(from: UIPasteboard.general.itemProviders, textOnly: textOnly, maxBytes: maxBytes, completion: completion)
    }

    /// Content of item providers: text, links, rich text, images, and other files by name.
    func content(from providers: [NSItemProvider], textOnly: Bool, maxBytes: Int,
                 completion: @escaping @MainActor (ClipLocalContent?) -> Void) {
        // Copies kept for the Mac to read: only the newest set.
        try? FileManager.default.removeItem(at: outRoot)
        let dir = outRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let root = outRoot
        Task { @MainActor in
            var items: [[(kind: ClipKind, data: Data)]] = []
            var files: [(name: String, url: URL, size: Int)] = []
            for p in providers.prefix(ClipboardWire.maxItems) {
                var reps: [(kind: ClipKind, data: Data)] = []
                func has(_ t: UTType) -> Bool { p.hasItemConformingToTypeIdentifier(t.identifier) }
                if has(.url), !has(.fileURL), let d = await Self.data(p, .url),
                   let u = URL(dataRepresentation: d, relativeTo: nil) ?? URL(string: String(decoding: d, as: UTF8.self)), !u.isFileURL {
                    reps.append((.url, Data(u.absoluteString.utf8)))
                }
                if has(.plainText) {
                    var d = await Self.data(p, .utf8PlainText)
                    if d == nil { d = await Self.data(p, .plainText) }
                    if let d, d.count <= maxBytes { reps.append((.text, d)) }
                }
                if !textOnly {
                    if has(.html), let d = await Self.data(p, .html), d.count <= maxBytes { reps.append((.html, d)) }
                    if has(.rtf), let d = await Self.data(p, .rtf), d.count <= maxBytes { reps.append((.rtf, d)) }
                    if has(.png), let d = await Self.data(p, .png), d.count <= maxBytes { reps.append((.png, d)) }
                    else if has(.jpeg), let d = await Self.data(p, .jpeg), d.count <= maxBytes { reps.append((.jpeg, d)) }
                    else if has(.image), let d = await Self.data(p, .image), let jpeg = UIImage(data: d)?.jpegData(compressionQuality: 0.9),
                            jpeg.count <= maxBytes { reps.append((.jpeg, jpeg)) }
                    // Anything else (a PDF, a document): a file, by its name.
                    if reps.isEmpty, let type = p.registeredTypeIdentifiers.first,
                       let f = await Self.file(p, type, into: dir), f.size <= maxBytes {
                        files.append(f)
                    }
                }
                if !reps.isEmpty { items.append(reps) }
            }
            if files.isEmpty { try? FileManager.default.removeItem(at: root) }
            completion(items.isEmpty && files.isEmpty ? nil : ClipLocalContent(items: items, files: files))
        }
    }

    private static func data(_ p: NSItemProvider, _ type: UTType) async -> Data? {
        await withCheckedContinuation { c in
            _ = p.loadDataRepresentation(forTypeIdentifier: type.identifier) { d, _ in c.resume(returning: d) }
        }
    }

    private static func file(_ p: NSItemProvider, _ type: String, into dir: URL) async -> (name: String, url: URL, size: Int)? {
        let suggested = p.suggestedName
        return await withCheckedContinuation { c in
            _ = p.loadFileRepresentation(forTypeIdentifier: type) { url, _ in
                // The system deletes `url` when this returns: copy it first.
                guard let url else { return c.resume(returning: nil) }
                var name = suggested ?? url.lastPathComponent
                if (name as NSString).pathExtension.isEmpty, !url.pathExtension.isEmpty { name += "." + url.pathExtension }
                guard ClipFiles.isSafeName(name) else { return c.resume(returning: nil) }
                let dest = dir.appendingPathComponent(name)
                do {
                    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    try FileManager.default.copyItem(at: url, to: dest)
                    let size = (try? dest.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                    c.resume(returning: (name, dest, size))
                } catch { c.resume(returning: nil) }
            }
        }
    }
}

/// Settings ▸ Clipboard on iPhone and iPad.
struct ClipboardSettingsPage: View {
    @ObservedObject var clipboard: ClipboardModel

    var body: some View {
        SettingsForm {
            Section {
                Toggle("Unified Clipboard", isOn: $clipboard.enabled)
            } footer: {
                Text("Copy on your Mac and paste here, and the other way round. The Mac asks the first time (or follows its own setting for this iPhone or iPad). Copies can contain passwords or private messages, so turn this on only for Macs you trust. Nothing is kept after it is replaced.")
            }
            if clipboard.enabled {
                Section("What Syncs") {
                    Picker("Direction", selection: $clipboard.direction) {
                        Text("Both Ways").tag(ClipDirection.both)
                        Text("Mac to This Device Only").tag(ClipDirection.toDevice)
                        Text("This Device to Mac Only").tag(ClipDirection.toMac)
                    }
                    Picker("Types", selection: $clipboard.types) {
                        Text("Text and Links Only").tag(ClipTypes.text)
                        Text("All Supported Types").tag(ClipTypes.all)
                    }
                    Toggle("Copied Files", isOn: $clipboard.syncFiles).disabled(clipboard.types == .text)
                    Picker("Transfer Automatically Up To", selection: $clipboard.maxBytes) {
                        ForEach(ClipboardWire.sizeChoices, id: \.self) { n in
                            Text(ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file)).tag(n)
                        }
                    }
                }
                Section {
                    Toggle("Send Copies Automatically", isOn: $clipboard.autoSend)
                } footer: {
                    Text("When on, what you copy in other apps goes to the Mac as soon as you return to MeowDisplay. iOS asks before each read unless you choose Allow in Settings ▸ Apps ▸ MeowDisplay ▸ Paste from Other Apps. When off, use the Send to Mac button that appears after you copy. Copies from the Mac always arrive while MeowDisplay is open.")
                }
                Section("Status") {
                    LabeledContent("Mac") { Text(stateText) }
                    if let t = clipboard.lastTransfer {
                        LabeledContent(t.fromMac ? "Last from the Mac" : "Last sent to the Mac") {
                            Text(t.failure.map { "\(t.summary): \($0)" } ?? "\(t.summary), \(t.at.formatted(date: .omitted, time: .shortened))")
                        }
                    }
                    if clipboard.progress != nil {
                        Button("Cancel Transfer", role: .destructive) { clipboard.cancelTransfer() }
                    }
                }
            }
        }
        .navigationTitle("Clipboard")
    }

    private var stateText: String {
        switch clipboard.macState {
        case .unavailable: return String(localized: "Not connected, or the Mac doesn't support it")
        case .off: return String(localized: "Off on the Mac (Settings ▸ Clipboard)")
        case .idle: return String(localized: "Off on this device")
        case .asking: return String(localized: "Waiting for the Mac to allow it")
        case .denied: return String(localized: "Not allowed by the Mac")
        case .paused: return String(localized: "Paused on the Mac")
        case .revoked: return String(localized: "Revoked on the Mac")
        case .ready:
            let way = clipboard.toDevice && clipboard.toMac ? String(localized: "both ways")
                : clipboard.toDevice ? String(localized: "from the Mac only") : String(localized: "to the Mac only")
            return clipboard.always ? String(localized: "On, \(way) (always allowed)") : String(localized: "On, \(way) (this session)")
        }
    }
}

/// Small, transient prompts over the picture: send a copy made elsewhere (the system Paste
/// button, which never asks), files the Mac copied, a same-moment copy to choose. Never shows
/// the content itself.
struct ClipboardBanner: View {
    @ObservedObject var clipboard: ClipboardModel

    var body: some View {
        VStack(spacing: 8) {
            if clipboard.localChangePending, clipboard.canSendToMac {
                pill {
                    Text("You copied something").font(.footnote.weight(.semibold))
                    PasteButton(supportedContentTypes: [.data]) { providers in
                        IOSClipboardPlatform.shared.content(from: providers, textOnly: clipboard.types == .text, maxBytes: clipboard.maxBytes) { c in
                            if let c { clipboard.sendLocal(c) }
                        }
                    }
                    .labelStyle(.titleAndIcon)
                    .buttonBorderShape(.capsule)
                    .accessibilityHint("Sends it to the Mac's clipboard")
                }
            }
            if let e = clipboard.macFiles {
                pill {
                    Text("The Mac copied \(e.summary)").font(.footnote.weight(.semibold))
                    Button("Save") { clipboard.getMacFiles(.save) }.buttonStyle(.borderedProminent)
                    Button("Share") { clipboard.getMacFiles(.share) }.buttonStyle(.bordered)
                    Button { clipboard.dismissMacFiles() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("Dismiss")
                }
            }
            if clipboard.alternativeWaiting {
                pill {
                    Text("The Mac copied something at the same moment").font(.footnote.weight(.semibold))
                    Button("Use the Mac's Copy") { clipboard.useAlternative() }.buttonStyle(.bordered)
                }
            }
            if let p = clipboard.progress {
                pill {
                    ProgressView(value: Double(p.done), total: Double(max(p.total, 1))).frame(width: 120)
                    Button("Cancel") { clipboard.cancelTransfer() }
                }
            }
            if let n = clipboard.notice {
                pill { Text(n).font(.footnote) }
                    .task { try? await Task.sleep(nanoseconds: 2_500_000_000); clipboard.dismissNotice() }
            }
        }
        .onChange(of: clipboard.export?.id) { _ in
            guard let e = clipboard.export else { return }
            RemoteExportPresenting.present(e) { ok in clipboard.exportFinished(e, completed: ok) }
        }
    }

    private func pill<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 10) { content() }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(.ultraThinMaterial, in: Capsule())
            .environment(\.colorScheme, .dark)
    }
}
