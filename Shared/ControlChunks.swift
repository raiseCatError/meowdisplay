import CryptoKit
import Foundation

// Large control messages (PROTOCOL.md 6.14). A control frame must stay under 32768 bytes
// (PROTOCOL.md 4): every receiver treats a longer one as not-control and drops it. A Mac
// message that is longer (a Remote Finder preview, a window still, a pane's whole-source
// still) travels as ordered `chunk` messages, each well under the limit, only to a receiver
// that said in its hello that it reassembles them. The receiver bounds what it holds.

enum ControlChunkWire {
    static let type = "chunk"
    /// Hello field: the chunk version this receiver reassembles; absent = none.
    static let helloField = "chunks"
    static let version = 1
    /// A message this long or longer is split (32768 is the hard limit; the margin is for safety).
    static let threshold = 32_000
    /// Raw bytes per part: its base64 (29 336 bytes) plus the envelope stays far under the limit.
    static let partBytes = 22_000
    /// Largest message a receiver reassembles.
    static let maxTotalBytes = 4 << 20
    /// Most messages a receiver assembles at once; a newer one evicts the oldest.
    static let maxInFlight = 4
    /// A message whose next part doesn't come within this many seconds is dropped.
    static let timeout: TimeInterval = 15

    /// First 16 hex digits of the SHA-256 of the whole message.
    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// The chunk messages for one oversized message, in order; nil if it is too big to send.
    static func split(_ message: Data, id: Int, partBytes: Int = partBytes) -> [[String: Any]]? {
        guard !message.isEmpty, message.count <= maxTotalBytes, partBytes > 0 else { return nil }
        let n = (message.count + partBytes - 1) / partBytes
        var parts: [[String: Any]] = []
        parts.reserveCapacity(n)
        for i in 0..<n {
            let start = message.startIndex + i * partBytes
            let end = min(start + partBytes, message.endIndex)
            var m: [String: Any] = ["type": type, "id": id, "i": i, "n": n, "d": message[start..<end].base64EncodedString()]
            if i == 0 {
                m["len"] = message.count
                m["sha"] = digest(message)
            }
            parts.append(m)
        }
        return parts
    }
}

/// Reassembles `chunk` messages on the receiver: in order, bounded in size, count and time,
/// checked against the sender's digest. One per connection.
struct ControlChunkAssembler {
    enum Outcome: Equatable {
        case pending
        case complete(Data)
        /// The message was abandoned (gap, oversize, bad digest, …); the reason is for logs.
        case dropped(String)
    }

    private struct Partial {
        var n: Int
        var length: Int
        var digest: String
        var next: Int
        var data: Data
        var touched: TimeInterval
    }

    private var partials: [Int: Partial] = [:]

    var inFlight: Int { partials.count }

    mutating func reset() { partials.removeAll() }

    mutating func add(_ obj: [String: Any], now: TimeInterval) -> Outcome {
        partials = partials.filter { now - $0.value.touched <= ControlChunkWire.timeout }
        guard let id = obj["id"] as? Int, let i = obj["i"] as? Int, let n = obj["n"] as? Int,
              let d = obj["d"] as? String, d.count <= 4 * ControlChunkWire.partBytes / 3 + 8 else {
            return .dropped("malformed")
        }
        guard let part = Data(base64Encoded: d) else {
            partials[id] = nil
            return .dropped("bad base64")
        }
        if i == 0 {
            guard let length = obj["len"] as? Int, length > 0, length <= ControlChunkWire.maxTotalBytes,
                  let digest = obj["sha"] as? String, digest.count == 16,
                  n >= 1, n <= length else {
                partials[id] = nil
                return .dropped("bad header")
            }
            if partials[id] == nil, partials.count >= ControlChunkWire.maxInFlight,
               let oldest = partials.min(by: { $0.value.touched < $1.value.touched })?.key {
                partials[oldest] = nil
            }
            var data = Data()
            data.reserveCapacity(length)
            partials[id] = Partial(n: n, length: length, digest: digest, next: 0, data: data, touched: now)
        }
        guard var p = partials[id] else { return .dropped("no start") }
        guard i == p.next, n == p.n else {
            partials[id] = nil
            return .dropped("out of order")
        }
        guard p.data.count + part.count <= p.length else {
            partials[id] = nil
            return .dropped("too long")
        }
        p.data.append(part)
        p.next += 1
        p.touched = now
        guard p.next == p.n else {
            partials[id] = p
            return .pending
        }
        partials[id] = nil
        guard p.data.count == p.length else { return .dropped("short") }
        guard ControlChunkWire.digest(p.data) == p.digest else { return .dropped("digest") }
        return .complete(p.data)
    }
}
