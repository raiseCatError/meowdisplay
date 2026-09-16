import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// A paired peer's local-LAN wake hint: the MAC address and broadcast
/// address needed to send it a standard Wake-on-LAN magic packet. This is
/// learned opportunistically over an already-authenticated session (see
/// `WireMessage.wakeInfo`) and is a network hint only — exactly like
/// `RemoteEndpointStore`, it can never grant or imply trust. Only the
/// pinned-mutual-TLS identity check does that.
struct WakeMetadata: Codable, Equatable {
    var version = WakeMetadata.schemaVersion
    var macAddress: String
    var interfaceName: String
    var ipv4: String?
    var subnetMask: String?
    var broadcastAddress: String?
    var updatedAt: Date

    static let schemaVersion = 1
}

/// Versioned, per-peer persistence for `WakeMetadata`, mirroring
/// `RemoteEndpointStore`'s pattern exactly: keyed by stable peer install ID,
/// never by the network address itself, and discarding anything from an
/// incompatible schema rather than guessing at its shape.
enum WakeMetadataStore {
    private static let defaultsKey = "wakeMetadataHints.v1"

    private static func load() -> [String: WakeMetadata] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([String: WakeMetadata].self, from: data)
        else { return [:] }
        return decoded.filter { $0.value.version == WakeMetadata.schemaVersion }
    }

    private static func save(_ hints: [String: WakeMetadata]) {
        guard let data = try? JSONEncoder().encode(hints) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }

    static func metadata(forPeerID peerID: String) -> WakeMetadata? {
        load()[peerID]
    }

    static func setMetadata(_ metadata: WakeMetadata, forPeerID peerID: String) {
        var hints = load()
        hints[peerID] = metadata
        save(hints)
    }

    static func removeMetadata(forPeerID peerID: String) {
        var hints = load()
        hints.removeValue(forKey: peerID)
        save(hints)
    }
}

/// Standard Wake-on-LAN magic packet: 6 bytes of 0xFF followed by the
/// target MAC address repeated 16 times, sent as a UDP broadcast. This is
/// LAN-local only — it is never routed over Remote/Tailscale, and this type
/// never touches an arbitrary caller-supplied host: every call site here
/// takes its target from `WakeMetadata` learned for an already-paired peer.
enum WakeOnLAN {
    enum SendError: Error, Equatable {
        case invalidMACAddress
        case invalidBroadcastAddress
        case socketCreationFailed
        case sendFailed(Int32)
    }

    static func magicPacket(macAddress: String) -> Data? {
        let hex = macAddress.split(whereSeparator: { $0 == ":" || $0 == "-" })
        guard hex.count == 6 else { return nil }
        var bytes: [UInt8] = []
        for part in hex {
            guard let byte = UInt8(part, radix: 16) else { return nil }
            bytes.append(byte)
        }
        var packet = Data(repeating: 0xFF, count: 6)
        for _ in 0..<16 { packet.append(contentsOf: bytes) }
        return packet
    }

    /// Sends the magic packet as a UDP broadcast. Synchronous and brief (one
    /// `sendto`) — safe to call from a button action off the main thread.
    @discardableResult
    static func send(macAddress: String, broadcastAddress: String,
                     port: UInt16 = 9) -> Result<Void, SendError> {
        guard let packet = magicPacket(macAddress: macAddress) else {
            return .failure(.invalidMACAddress)
        }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        guard broadcastAddress.withCString({ inet_pton(AF_INET, $0, &addr.sin_addr) }) == 1 else {
            return .failure(.invalidBroadcastAddress)
        }

        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return .failure(.socketCreationFailed) }
        defer { close(fd) }

        var broadcastEnable: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &broadcastEnable, socklen_t(MemoryLayout<Int32>.size))

        let result = withUnsafePointer(to: &addr) { addrPtr -> Int in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                packet.withUnsafeBytes { rawBuf in
                    sendto(fd, rawBuf.baseAddress, rawBuf.count, 0, sockaddrPtr,
                          socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        guard result >= 0 else { return .failure(.sendFailed(errno)) }
        return .success(())
    }
}
