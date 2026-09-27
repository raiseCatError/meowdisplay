// Compiled into every target that compiles Shared/ (Mac sender, Mac receiver,
// iOS receiver, unit tests). Foundation-only on purpose: everything here is
// the pure, directly testable half of the QUIC transport — constants, the
// per-stream preface, bounded deframing, per-group channel bookkeeping and
// the authenticated capability model. Network.framework plumbing lives in
// `Mac/QUICTransportSession.swift` (sender) and `Shared/QUICReceiverSession.swift`
// (receivers).

import Foundation

/// Fixed identity of the QUIC transport. TCP (`WireCrypto.tlsPort`) stays a
/// first-class path; QUIC is an additive second secure transport on the same
/// port NUMBER over UDP (TCP and UDP port spaces are separate), so no
/// `RemoteEndpointStore` schema change is needed. See PROTOCOL.md §8.
enum QUICTransport {
    /// TLS application protocol (ALPN). A mismatch fails the handshake.
    static let alpn = "meowdisplay-quic/1"
    /// QUIC application framing version carried in every stream preface and
    /// advertised as `qv` (Bonjour hint + authenticated hello capability).
    static let applicationVersion = 1
    /// UDP port of the receiver's QUIC listener.
    static let udpPort: UInt16 = WireCrypto.tlsPort
    /// Discovery HINT only — never trust. Carries `id`/`pv`/`qv` and nothing
    /// else (in particular never the one-shot `cr` connect-request token,
    /// which stays on `_opensidecar._tcp` so one user action is handled once).
    static let bonjourServiceType = "_meowdisp-q._udp"
    /// Wire name of this transport in the authenticated `transports` list.
    static let transportName = "quic"
    static let tcpTransportName = "tcp"
}

/// Runtime availability of the QUIC transport on THIS device. Every QUIC API
/// used (NWProtocolQUIC, NWMultiplexGroup, NWConnectionGroup,
/// NWConnection(from:), NWListener.newConnectionGroupHandler) exists from
/// macOS 12 / iOS 15 — at or below every target's deployment floor (sender
/// macOS 14, Mac Receiver macOS 12, iOS receiver 16.4) — so no floor is
/// raised and no runtime gate is needed today. Kept as the one switch that
/// turns QUIC off (TCP stays) should a floor ever drop below that.
enum QUICRuntimeAvailability {
    static var isAvailable: Bool { true }
}

/// The three MeowDisplay application channels. Over TCP every channel maps
/// onto the one TLS byte stream (bytes unchanged); over QUIC each has its own
/// reliable stream, so a large Video write no longer delays Control/Audio.
enum TransportChannel: UInt8, Sendable, CaseIterable, CustomStringConvertible {
    case control = 0x01
    case video = 0x02
    case audio = 0x03

    var description: String {
        switch self {
        case .control: return "control"
        case .video: return "video"
        case .audio: return "audio"
        }
    }

    /// Every MeowDisplay QUIC stream is opened by the sender (the dialing
    /// Mac). Control is bidirectional; Video and Audio carry bytes only
    /// Mac -> receiver, and any byte the receiver writes on them is a
    /// protocol violation.
    var receiverMayWrite: Bool { self == .control }

    /// Hard ceiling on one application payload (the bytes after the 4-byte
    /// length), enforced BEFORE any allocation for it.
    var maxPayloadBytes: Int {
        switch self {
        case .control: return QUICFrameLimits.controlMaxPayloadBytes
        case .video: return QUICFrameLimits.videoMaxPayloadBytes
        case .audio: return QUICFrameLimits.audioMaxPayloadBytes
        }
    }
}

/// Stable, documented QUIC application error codes (PROTOCOL.md §8.6). Used
/// for bounded local diagnostics and, where the SDK exposes it, as the
/// application close code.
enum QUICApplicationError: UInt64, Error, Sendable, CustomStringConvertible {
    case invalidStreamPreface = 0x100
    case unsupportedTransportVersion = 0x101
    case duplicateChannel = 0x102
    case unexpectedChannel = 0x103
    case sessionNotAdmitted = 0x104
    case protocolViolation = 0x105
    case peerRevoked = 0x106

    var description: String {
        switch self {
        case .invalidStreamPreface: return "invalidStreamPreface(0x100)"
        case .unsupportedTransportVersion: return "unsupportedTransportVersion(0x101)"
        case .duplicateChannel: return "duplicateChannel(0x102)"
        case .unexpectedChannel: return "unexpectedChannel(0x103)"
        case .sessionNotAdmitted: return "sessionNotAdmitted(0x104)"
        case .protocolViolation: return "protocolViolation(0x105)"
        case .peerRevoked: return "peerRevoked(0x106)"
        }
    }
}

enum QUICFrameLimits {
    static let controlMaxPayloadBytes = 1 << 20   // 1 MiB — control JSON
    static let audioMaxPayloadBytes = 1 << 20     // 1 MiB — one AAC/PCM frame
    /// Largest frame edge any receiver advertises today: both receivers send
    /// `maxEncodeWide`/`maxEncodeHigh` no larger than 4096 on either axis
    /// (`iOSDecodeCeiling`, `MacReceiver`), and the Mac clamps the capture to
    /// that ceiling (`DecodeCeiling.clamp`). A QUIC-capable receiver always
    /// sends that ceiling.
    static let maxVideoEdgePixels = 4096
    /// Uncompressed 8-bit 4:2:0 size of the largest possible frame. An
    /// H.264/HEVC access unit cannot legitimately exceed the raw picture by
    /// more than small syntax overhead (even I_PCM macroblocks are raw
    /// samples), so this bounds every legitimate keyframe.
    static let maxRawVideoFrameBytes = maxVideoEdgePixels * maxVideoEdgePixels * 3 / 2
    /// Raw worst case (24 MiB) + 8 MiB headroom for parameter sets, SEI and
    /// the JSON telemetry prefix = 32 MiB. Never unlimited.
    static let videoMaxPayloadBytes = maxRawVideoFrameBytes + (8 << 20)
    /// Largest chunk one `NWConnection.receive` call asks for on a QUIC stream.
    static let receiveChunkBytes = 1 << 18
}

// MARK: - Stream preface

/// The 8 bytes that open every MeowDisplay QUIC stream (sender -> receiver):
///
///     0..3  "MEOW"
///     4     QUIC application framing version (1)
///     5     channel (TransportChannel)
///     6..7  flags, big-endian — zero in v1
///
/// Channel identity comes ONLY from this preface, never from QUIC stream IDs
/// or open order. Anything malformed is rejected, never reinterpreted.
struct QUICStreamPreface: Equatable, Sendable {
    static let magic: [UInt8] = Array("MEOW".utf8)
    static let length = 8

    let version: UInt8
    let channel: TransportChannel
    let flags: UInt16

    init(channel: TransportChannel) {
        self.version = UInt8(QUICTransport.applicationVersion)
        self.channel = channel
        self.flags = 0
    }

    func encode() -> Data {
        var bytes = Self.magic
        bytes.append(version)
        bytes.append(channel.rawValue)
        bytes.append(UInt8(flags >> 8))
        bytes.append(UInt8(flags & 0xFF))
        return Data(bytes)
    }

    enum ParseResult: Equatable {
        /// Fewer than 8 bytes so far — wait for more (split preface).
        case needMoreData
        /// A valid preface; `consumed` is always 8, bytes after it belong to
        /// the stream's framed payload.
        case parsed(QUICStreamPreface, consumed: Int)
        case rejected(QUICApplicationError)
    }

    /// Pure validation of a stream's first bytes. Accepts exactly version 1,
    /// flags 0 and a known channel; everything else is rejected.
    static func parse(_ data: Data) -> ParseResult {
        guard data.count >= length else {
            // A short prefix that already contradicts the magic can be
            // refused right away instead of waiting on a hostile stream.
            let prefix = Array(data.prefix(magic.count))
            return prefix == Array(magic.prefix(prefix.count)) ? .needMoreData : .rejected(.invalidStreamPreface)
        }
        let bytes = Array(data.prefix(length))
        guard Array(bytes[0..<4]) == magic else { return .rejected(.invalidStreamPreface) }
        guard Int(bytes[4]) == QUICTransport.applicationVersion else { return .rejected(.unsupportedTransportVersion) }
        let flags = UInt16(bytes[6]) << 8 | UInt16(bytes[7])
        guard flags == 0 else { return .rejected(.invalidStreamPreface) }
        guard let channel = TransportChannel(rawValue: bytes[5]) else { return .rejected(.unexpectedChannel) }
        return .parsed(QUICStreamPreface(channel: channel), consumed: length)
    }
}

// MARK: - Bounded deframing

/// Incremental `[UInt32 BE length][payload]` deframer for one QUIC stream.
/// The declared length is checked against the channel's cap BEFORE any
/// buffering for it, and the retained buffer can never exceed one maximal
/// frame plus one receive chunk — a hostile length cannot force an
/// unbounded allocation. Zero-length frames are a protocol violation (no
/// MeowDisplay message is empty).
struct QUICFrameAssembler {
    enum Failure: Error, Equatable {
        case frameTooLarge(declared: Int, limit: Int)
        case emptyFrame
        case bufferOverflow
        case truncatedAtEndOfStream
    }

    let maxPayloadBytes: Int
    let maxBufferedBytes: Int
    private(set) var buffered = Data()

    init(maxPayloadBytes: Int, receiveChunkBytes: Int = QUICFrameLimits.receiveChunkBytes) {
        self.maxPayloadBytes = maxPayloadBytes
        self.maxBufferedBytes = 4 + maxPayloadBytes + receiveChunkBytes
    }

    init(channel: TransportChannel) {
        self.init(maxPayloadBytes: channel.maxPayloadBytes)
    }

    var bufferedByteCount: Int { buffered.count }

    /// Appends one received chunk and returns every complete payload, in
    /// order. Throws — leaving the assembler unusable — on any violation.
    mutating func append(_ data: Data) throws -> [Data] {
        guard buffered.count + data.count <= maxBufferedBytes else { throw Failure.bufferOverflow }
        buffered.append(data)
        var frames: [Data] = []
        var cursor = buffered.startIndex
        while buffered.distance(from: cursor, to: buffered.endIndex) >= 4 {
            let header = buffered[cursor..<buffered.index(cursor, offsetBy: 4)]
            let declared = header.reduce(0) { ($0 << 8) | Int($1) }
            guard declared > 0 else { throw Failure.emptyFrame }
            guard declared <= maxPayloadBytes else {
                throw Failure.frameTooLarge(declared: declared, limit: maxPayloadBytes)
            }
            guard buffered.distance(from: cursor, to: buffered.endIndex) >= 4 + declared else { break }
            let start = buffered.index(cursor, offsetBy: 4)
            let end = buffered.index(start, offsetBy: declared)
            frames.append(Data(buffered[start..<end]))
            cursor = end
        }
        if cursor != buffered.startIndex {
            buffered.removeSubrange(buffered.startIndex..<cursor)
        }
        return frames
    }

    /// End of stream: anything still buffered is a truncated frame.
    func finish() throws {
        guard buffered.isEmpty else { throw Failure.truncatedAtEndOfStream }
    }

    /// Frames one payload for any MeowDisplay channel (the unchanged TCP
    /// framing, reused per QUIC stream).
    static func frame(_ payload: Data) -> Data {
        var header = UInt32(payload.count).bigEndian
        var frame = Data(bytes: &header, count: 4)
        frame.append(payload)
        return frame
    }
}

// MARK: - Per-group channel bookkeeping

/// Which side opened a QUIC stream, as seen by the side validating it.
enum QUICStreamInitiator: Sendable {
    case sender
    case receiver
}

/// Enforces the stream topology of ONE QUIC connection: at most three
/// streams, each channel exactly once, every stream sender-initiated.
/// Value type — the owning group keeps it under its own lock/isolation.
struct QUICChannelRegistry: Equatable {
    static let maxStreams = TransportChannel.allCases.count

    private(set) var openedStreams = 0
    private(set) var channels: Set<UInt8> = []

    /// A new stream arrived (before its preface is read). Too many streams
    /// or a receiver-initiated stream fails the whole connection.
    mutating func beginStream(initiatedBy initiator: QUICStreamInitiator) -> QUICApplicationError? {
        guard initiator == .sender else { return .protocolViolation }
        guard openedStreams < Self.maxStreams else { return .protocolViolation }
        openedStreams += 1
        return nil
    }

    /// The stream's preface named `channel`. A second stream for the same
    /// channel is rejected — the first keeps its ownership.
    mutating func register(_ channel: TransportChannel) -> QUICApplicationError? {
        guard !channels.contains(channel.rawValue) else { return .duplicateChannel }
        channels.insert(channel.rawValue)
        return nil
    }

    func has(_ channel: TransportChannel) -> Bool { channels.contains(channel.rawValue) }
}

/// What a QUIC Video stream may carry besides Annex-B access units: only
/// the two media-state messages the Mac orders with the frames they
/// describe. Anything else on Video is a protocol violation.
enum QUICVideoChannelPolicy {
    static let allowedJSONTypes: Set<String> = [WireMessage.videoState, WireMessage.streamCodecState]

    static func isAllowedJSON(_ payload: Data) -> Bool {
        guard let obj = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let type = obj["type"] as? String else { return false }
        return allowedJSONTypes.contains(type)
    }

    /// Mirrors `ReceiverFramePipeline`'s legacy JSON heuristic exactly.
    static func looksLikeJSON(_ payload: Data) -> Bool {
        payload.count < 32_768 && payload.first == UInt8(ascii: "{") && !payload.contains(0x00)
    }
}

// MARK: - Authenticated capability

/// A peer's QUIC capability, read ONLY from the authenticated application
/// handshake (`hello` on the Mac, `welcome` on receivers). Absence of the
/// fields — every pre-pv-22 peer — means TCP only; overall `pv` is never
/// used as a proxy once an explicit capability exists.
struct QUICPeerCapability: Equatable, Sendable {
    let transports: [String]
    let quicVersion: Int?

    init(transports: [String]?, quicVersion: Int?) {
        self.transports = transports ?? []
        self.quicVersion = quicVersion
    }

    init(message: [String: Any]) {
        self.init(transports: message["transports"] as? [String], quicVersion: message["qv"] as? Int)
    }

    /// The peer lists QUIC with exactly our application framing version.
    var supportsCompatibleQUIC: Bool {
        transports.contains(QUICTransport.transportName) && quicVersion == QUICTransport.applicationVersion
    }

    /// The peer announced QUIC with a framing version this build cannot speak.
    var announcesIncompatibleQUIC: Bool {
        transports.contains(QUICTransport.transportName) && quicVersion != QUICTransport.applicationVersion
    }

    /// Fields this build adds to its own hello/welcome when its QUIC
    /// listener/dialer is available — additive, ignored by older peers.
    static func advertisedFields(quicAvailable: Bool) -> [String: Any] {
        guard quicAvailable else { return ["transports": [QUICTransport.tcpTransportName]] }
        return ["transports": [QUICTransport.tcpTransportName, QUICTransport.transportName],
                "qv": QUICTransport.applicationVersion]
    }
}

/// Bonjour `_meowdisp-q._udp` TXT fields — a reachability/capability HINT.
/// It may justify ATTEMPTING a QUIC dial to a local peer; pinning is still
/// what authenticates it, and it never marks a peer as trusted or as
/// capable in persisted state.
struct QUICDiscoveryHint: Equatable, Sendable {
    let peerID: String
    let quicVersion: Int

    init?(txt: [String: String]) {
        guard let id = txt["id"], !id.isEmpty,
              let qvText = txt["qv"], let qv = Int(qvText) else { return nil }
        self.peerID = id
        self.quicVersion = qv
    }

    var isCompatible: Bool { quicVersion == QUICTransport.applicationVersion }

    static func txtFields(installID: String, protocolVersion: Int) -> [String: String] {
        ["id": installID, "pv": String(protocolVersion), "qv": String(QUICTransport.applicationVersion)]
    }
}
