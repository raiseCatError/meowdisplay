import CryptoKit
import Foundation

// Unified Clipboard (PROTOCOL.md 6.15): copy on one connected device, paste on another.
//
// Every genuine copy is an event named by its origin device (the authenticated install id)
// and that device's own sequence number. Each event carries its causal context (the newest
// event it had seen from every device), so ordering never depends on device clocks:
// - an event whose context includes the current one is newer and wins;
// - an event the current one already includes is older and is dropped;
// - two events that never saw each other are concurrent: the higher Lamport counter wins
//   (ties: the larger origin id), on every device alike, and the other one is kept as an
//   alternative the person can choose.
// Applying a remote event never creates an event, nothing goes back to its origin, and a
// reconnect only exchanges what each side has seen. Content is never logged.

enum ClipboardWire {
    static let type = "clip"
    /// In `welcome.features`: the Mac takes part in the Unified Clipboard.
    static let welcomeFeature = "clipboard"
    /// Raw bytes a representation may carry inside its event (every frame stays under the
    /// 32 KB control limit, base64 included). Larger data is fetched with `read`.
    static let inlineBytes = 16_000
    /// Raw bytes in one `data` message.
    static let partBytes = 22_000
    /// Bytes one `read` may ask for.
    static let readMax = 262_144
    static let maxItems = 16
    static let maxReps = 6
    static let maxFiles = 2_000
    static let maxDepth = 32
    static let maxOriginLength = 128
    /// Hard caps on declared sizes (a representation; one file), so totals never overflow.
    static let maxRepBytes = 200_000_000
    static let maxFileBytes = 1 << 40
    /// Size limits the person can choose for automatic transfers (bytes).
    static let sizeChoices = [1_000_000, 10_000_000, 50_000_000, 200_000_000]
    static let defaultMaxBytes = 10_000_000
}

/// One clipboard representation, in a form every platform maps to its own types.
enum ClipKind: String, Sendable, CaseIterable, Codable {
    case text, url, html, rtf, png, jpeg

    /// Text-only sync keeps these.
    var isText: Bool { self == .text || self == .url }
    var mime: String {
        switch self {
        case .text: return "text/plain"
        case .url: return "text/uri-list"
        case .html: return "text/html"
        case .rtf: return "text/rtf"
        case .png: return "image/png"
        case .jpeg: return "image/jpeg"
        }
    }
    var uti: String {
        switch self {
        case .text: return "public.utf8-plain-text"
        case .url: return "public.url"
        case .html: return "public.html"
        case .rtf: return "public.rtf"
        case .png: return "public.png"
        case .jpeg: return "public.jpeg"
        }
    }
}

/// Which types sync: text and links only, or everything supported.
enum ClipTypes: String, Sendable, CaseIterable, Codable {
    case text, all
}

/// Which way this device syncs.
enum ClipDirection: String, Sendable, CaseIterable, Codable {
    case both, toDevice, toMac
    var toDeviceAllowed: Bool { self != .toMac }
    var toMacAllowed: Bool { self != .toDevice }
}

struct ClipRep: Equatable, Sendable {
    var kind: ClipKind
    var size: Int
    /// First 16 hex digits of the SHA-256 of the bytes.
    var hash: String
    /// The bytes, when small enough to travel inside the event.
    var inline: Data?
    /// Otherwise: which blob of the event to `read`.
    var blob: Int?
}

struct ClipItem: Equatable, Sendable {
    var reps: [ClipRep]
    func rep(_ kind: ClipKind) -> ClipRep? { reps.first { $0.kind == kind } }
}

/// A copied file or folder, with its place in the copied hierarchy.
struct ClipFile: Equatable, Sendable {
    /// Names from the copied item down (["Photos", "2026", "a.jpg"]); never a full path.
    var path: [String]
    var size: Int
    var dir: Bool
    var blob: Int?
    var name: String { path.last ?? "" }
}

struct ClipEventID: Hashable, Sendable, Codable {
    var origin: String
    var seq: UInt64
}

/// What ordering needs to know about an event.
struct ClipHeader: Equatable, Sendable {
    var id: ClipEventID
    var lamport: UInt64
    /// The newest sequence number the origin had seen from each device (its own included).
    var context: [String: UInt64]
    /// Identity of the content (reps and files), for "the same thing copied again".
    var contentHash: String

    /// This event happened after `other` (its origin had seen it).
    func follows(_ other: ClipHeader) -> Bool { (context[other.id.origin] ?? 0) >= other.id.seq }

    /// Deterministic winner between two concurrent events.
    func beats(_ other: ClipHeader) -> Bool {
        lamport != other.lamport ? lamport > other.lamport : id.origin > other.id.origin
    }
}

struct ClipEvent: Equatable, Sendable {
    var header: ClipHeader
    /// The origin's clock (ms), for display only — never for ordering.
    var at: Int64
    var items: [ClipItem]
    var files: [ClipFile]

    var id: ClipEventID { header.id }
    var totalBytes: Int { items.reduce(0) { $0 + $1.reps.reduce(0) { $0 + $1.size } } + files.reduce(0) { $0 + $1.size } }
    var hasFiles: Bool { !files.isEmpty }
    var fileCount: Int { files.filter { !$0.dir }.count }

    /// A short description for status lines (never the content itself).
    var summary: String {
        if hasFiles {
            let n = files.filter { $0.path.count == 1 }.count
            return n == 1 ? String(localized: "1 item") : String(localized: "\(n) items")
        }
        let kinds = Set(items.flatMap { $0.reps.map(\.kind) })
        if kinds.contains(.png) || kinds.contains(.jpeg) { return String(localized: "An image") }
        if kinds == [.url] || (kinds.contains(.url) && !kinds.contains(.html)) { return String(localized: "A link") }
        return String(localized: "Text")
    }

    static func contentHash(items: [ClipItem], files: [ClipFile]) -> String {
        var h = SHA256()
        for item in items {
            for r in item.reps { h.update(data: Data("\(r.kind.rawValue):\(r.size):\(r.hash);".utf8)) }
            h.update(data: Data("|".utf8))
        }
        for f in files { h.update(data: Data("\(f.path.joined(separator: "/")):\(f.size):\(f.dir);".utf8)) }
        return ClipHash.hex16(h.finalize())
    }

    // MARK: Wire

    var wire: [String: Any] {
        var m: [String: Any] = [
            "type": ClipboardWire.type, "op": "event",
            "o": header.id.origin, "s": Int(header.id.seq), "lc": Int(header.lamport),
            "vv": header.context.mapValues { Int($0) }, "ch": header.contentHash, "at": Int(at),
        ]
        m["items"] = items.map { item in
            ["reps": item.reps.map { r -> [String: Any] in
                var o: [String: Any] = ["t": r.kind.rawValue, "n": r.size, "h": r.hash]
                if let d = r.inline { o["d"] = d.base64EncodedString() }
                if let b = r.blob { o["b"] = b }
                return o
            }]
        }
        if !files.isEmpty {
            m["files"] = files.map { f -> [String: Any] in
                var o: [String: Any] = ["p": f.path, "n": f.size, "dir": f.dir]
                if let b = f.blob { o["b"] = b }
                return o
            }
        }
        return m
    }

    /// Bounded, defensive: nil for anything malformed. Names that could leave their folder
    /// (".", "..", "/", NUL) drop the whole event.
    static func parse(_ obj: [String: Any]) -> ClipEvent? {
        guard let origin = obj["o"] as? String, !origin.isEmpty, origin.count <= ClipboardWire.maxOriginLength,
              let seqInt = obj["s"] as? Int, seqInt > 0, let lc = obj["lc"] as? Int, lc > 0,
              let ch = obj["ch"] as? String, ch.count <= 64 else { return nil }
        var context: [String: UInt64] = [:]
        for (k, v) in (obj["vv"] as? [String: Any] ?? [:]).prefix(64) {
            guard k.count <= ClipboardWire.maxOriginLength, let n = v as? Int, n >= 0 else { return nil }
            context[k] = UInt64(n)
        }
        let seq = UInt64(seqInt)
        context[origin] = max(context[origin] ?? 0, seq)
        var items: [ClipItem] = []
        for raw in (obj["items"] as? [[String: Any]] ?? []).prefix(ClipboardWire.maxItems) {
            var reps: [ClipRep] = []
            for r in (raw["reps"] as? [[String: Any]] ?? []).prefix(ClipboardWire.maxReps) {
                guard let t = (r["t"] as? String).flatMap(ClipKind.init(rawValue:)) else { continue }   // unknown types: skipped
                guard let n = r["n"] as? Int, n >= 0, n <= ClipboardWire.maxRepBytes, let h = r["h"] as? String, h.count == 16 else { return nil }
                let inline = (r["d"] as? String).flatMap { s -> Data? in
                    s.count <= (ClipboardWire.inlineBytes * 4 / 3 + 8) ? Data(base64Encoded: s) : nil
                }
                if let inline, inline.count != n { return nil }
                let blob = r["b"] as? Int
                if inline == nil, blob == nil, n > 0 { return nil }
                reps.append(ClipRep(kind: t, size: n, hash: h, inline: inline, blob: blob.flatMap { $0 >= 0 ? $0 : nil }))
            }
            if !reps.isEmpty { items.append(ClipItem(reps: reps)) }
        }
        var files: [ClipFile] = []
        for f in (obj["files"] as? [[String: Any]] ?? []).prefix(ClipboardWire.maxFiles) {
            guard let path = f["p"] as? [String], !path.isEmpty, path.count <= ClipboardWire.maxDepth,
                  path.allSatisfy(ClipFiles.isSafeName), let n = f["n"] as? Int, n >= 0, n <= ClipboardWire.maxFileBytes else { return nil }
            files.append(ClipFile(path: path, size: n, dir: f["dir"] as? Bool ?? false, blob: (f["b"] as? Int).flatMap { $0 >= 0 ? $0 : nil }))
        }
        guard !items.isEmpty || !files.isEmpty else { return nil }
        let at = Int64(obj["at"] as? Int ?? 0)
        return ClipEvent(header: ClipHeader(id: ClipEventID(origin: origin, seq: seq), lamport: UInt64(lc), context: context, contentHash: ch),
                         at: at, items: items, files: files)
    }
}

enum ClipHash {
    static func hex16<D: Digest>(_ d: D) -> String { d.prefix(8).map { String(format: "%02x", $0) }.joined() }
    static func of(_ data: Data) -> String { hex16(SHA256.hash(data: data)) }
}

enum ClipFiles {
    /// A name that stays inside its folder on every platform.
    static func isSafeName(_ s: String) -> Bool {
        !s.isEmpty && s != "." && s != ".." && !s.contains("/") && !s.contains("\0") && !s.contains("\\") && s.utf8.count <= 255
    }
}

/// The ordering rules, with no I/O: the same on the Mac, iOS and Android (vectors in
/// fixtures/clipboard/vectors.json).
struct ClipboardSync: Equatable, Sendable {
    enum Decision: String, Sendable {
        /// Newer (or the concurrent winner): becomes the shared clipboard.
        case apply
        /// Concurrent and lost: kept as the alternative to choose.
        case alternative
        /// Already seen (a repeat or a reconnect).
        case duplicate
        /// Ours, coming back.
        case echo
        /// Older than what is current here: never overwrites a newer copy.
        case older
    }

    let origin: String
    private(set) var seq: UInt64
    private(set) var lamport: UInt64
    private(set) var seen: [String: UInt64] = [:]
    private(set) var current: ClipHeader?
    /// A concurrent copy that lost the tie-break: still available to choose.
    private(set) var alternative: ClipHeader?

    init(origin: String, seq: UInt64 = 0, lamport: UInt64 = 0) {
        self.origin = origin
        self.seq = seq
        self.lamport = lamport
        if seq > 0 { seen[origin] = seq }
    }

    /// A genuine copy on this device. Nil when it is what the shared clipboard already holds.
    mutating func localCopy(contentHash: String) -> ClipHeader? {
        if current?.contentHash == contentHash { return nil }
        seq += 1
        lamport += 1
        seen[origin] = seq
        let header = ClipHeader(id: ClipEventID(origin: origin, seq: seq), lamport: lamport, context: seen, contentHash: contentHash)
        current = header
        alternative = nil
        return header
    }

    /// An event from another device.
    mutating func receive(_ h: ClipHeader) -> Decision {
        if h.id.origin == origin { return .echo }
        if (seen[h.id.origin] ?? 0) >= h.id.seq { return .duplicate }
        seen[h.id.origin] = h.id.seq
        for (o, s) in h.context where o != origin && (seen[o] ?? 0) < s && o != h.id.origin {
            // What the sender had seen is known to have happened; it is not applied here.
            seen[o] = s
        }
        lamport = max(lamport, h.lamport)
        guard let cur = current else { current = h; return .apply }
        if h.follows(cur) {
            current = h
            alternative = nil
            return .apply
        }
        if cur.follows(h) { return .older }
        if h.beats(cur) {
            alternative = cur
            current = h
            return .apply
        }
        alternative = h
        return .alternative
    }

    /// What the other side has seen, exchanged when a connection starts: marks those events
    /// as seen without applying anything (a reconnect is never a new copy).
    mutating func merge(seen other: [String: UInt64]) {
        for (o, s) in other where o != origin { seen[o] = max(seen[o] ?? 0, s) }
    }

    /// A fetch for `id` finished: apply it only if it is still the shared clipboard.
    func isCurrent(_ id: ClipEventID) -> Bool { current?.id == id }

    mutating func dropAlternative() { alternative = nil }
}

/// Ranged reads of an event's blobs, the same both ways (`read` → `data`… → `readEnd`).
enum ClipBlobWire {
    static func read(req: Int, id: ClipEventID, blob: Int, offset: Int, count: Int) -> [String: Any] {
        ["type": ClipboardWire.type, "op": "read", "req": req, "o": id.origin, "s": Int(id.seq), "b": blob, "off": offset, "n": count]
    }

    /// The answer to one `read`: parts of at most `partBytes`, then `readEnd` with the
    /// range's digest. `bytes` nil: the error code instead.
    static func answer(req: Int, offset: Int, bytes: Data?, error: String? = nil) -> [[String: Any]] {
        guard let bytes else {
            return [["type": ClipboardWire.type, "op": "readEnd", "req": req, "error": error ?? "gone"]]
        }
        var out: [[String: Any]] = []
        var i = 0
        while i < bytes.count {
            let part = bytes.subdata(in: i..<min(bytes.count, i + ClipboardWire.partBytes))
            out.append(["type": ClipboardWire.type, "op": "data", "req": req, "off": offset + i, "d": part.base64EncodedString()])
            i += ClipboardWire.partBytes
        }
        out.append(["type": ClipboardWire.type, "op": "readEnd", "req": req, "off": offset, "n": bytes.count, "sha": ClipHash.of(bytes)])
        return out
    }
}

/// One blob being fetched by ranged reads: tracks what arrived and checks every range.
struct ClipBlobFetch: Sendable {
    let req: Int
    let id: ClipEventID
    let blob: Int
    let size: Int
    /// The whole blob's digest when known (representations), checked at the end.
    let expectedHash: String?
    private(set) var received = 0
    private var range = Data()
    /// Bytes the outstanding `read` asked for: a peer can't push more than that into memory.
    private var asked = 0
    private var whole = SHA256()

    init(req: Int, id: ClipEventID, blob: Int, size: Int, expectedHash: String?) {
        self.req = req; self.id = id; self.blob = blob; self.size = size; self.expectedHash = expectedHash
    }

    var done: Bool { received >= size }
    /// The next `read` to send (remembers how much it asks for).
    mutating func nextRead() -> [String: Any]? {
        guard !done else { return nil }
        asked = min(ClipboardWire.readMax, size - received)
        return ClipBlobWire.read(req: req, id: id, blob: blob, offset: received, count: asked)
    }

    enum Step: Equatable { case more, rangeDone(Data), failed(String) }

    /// A `data` or `readEnd` message for this fetch. `rangeDone` hands over the verified bytes.
    mutating func handle(_ m: [String: Any]) -> Step {
        switch m["op"] as? String {
        case "data":
            guard let off = m["off"] as? Int, off == received + range.count,
                  let d = (m["d"] as? String).flatMap({ Data(base64Encoded: $0) }), d.count <= ClipboardWire.partBytes,
                  range.count + d.count <= asked, received + range.count + d.count <= size else { return .failed("badRange") }
            range.append(d)
            return .more
        case "readEnd":
            if let e = m["error"] as? String { return .failed(String(e.prefix(32))) }
            guard m["off"] as? Int == received, m["n"] as? Int == range.count, range.count > 0 || size == 0,
                  m["sha"] as? String == ClipHash.of(range) else { return .failed("digest") }
            let bytes = range
            whole.update(data: bytes)
            received += bytes.count
            range = Data()
            if done, let expectedHash, ClipHash.hex16(whole.finalize()) != expectedHash { return .failed("digest") }
            return .rangeDone(bytes)
        default:
            return .failed("badRange")
        }
    }
}
