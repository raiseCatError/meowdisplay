import Foundation
import Network

/// Tailscale peer discovery for Remote Access, through Tailscale's own
/// documented CLI (`tailscale status --json`) — no API keys, no private
/// APIs, no settings changes. It only runs when the user asks (Settings →
/// Remote Access), and what it finds is a routing suggestion the user picks
/// and saves: an address never grants trust. Every connection still needs
/// the existing pinned pairing, and a different key at the address fails.
struct TailscaleStatus: Equatable {
    struct Node: Equatable, Identifiable {
        var id: String { dnsName ?? ipv4 ?? hostName }
        let hostName: String
        /// MagicDNS name without the trailing dot, e.g. `macbook.tail1234.ts.net`.
        let dnsName: String?
        let os: String
        let ipv4: String?
        let ipv6: String?
        let online: Bool

        /// The address to save: the MagicDNS name survives IP changes; else the IPv4 address.
        var preferredHost: String? { dnsName ?? ipv4 ?? ipv6 }
    }

    /// `BackendState == "Running"`: signed in and connected.
    let running: Bool
    let selfNode: Node?
    let peers: [Node]

    /// Bounded parse of the CLI's JSON; unknown fields are ignored, malformed nodes dropped.
    static func parse(_ data: Data) -> TailscaleStatus? {
        guard data.count <= maximumOutputBytes,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let running = (object["BackendState"] as? String) == "Running"
        let selfNode = (object["Self"] as? [String: Any]).flatMap(node)
        let peerObjects = (object["Peer"] as? [String: Any])?.values.compactMap { $0 as? [String: Any] } ?? []
        let peers = peerObjects.prefix(maximumPeers).compactMap(node).sorted { lhs, rhs in
            if lhs.online != rhs.online { return lhs.online }
            return lhs.hostName.localizedCaseInsensitiveCompare(rhs.hostName) == .orderedAscending
        }
        return TailscaleStatus(running: running, selfNode: selfNode, peers: peers)
    }

    private static func node(_ o: [String: Any]) -> Node? {
        // Tailscale IPs are always literals: anything else is dropped.
        let ips = ((o["TailscaleIPs"] as? [String]) ?? []).filter { IPv4Address($0) != nil || IPv6Address($0) != nil }
        let ipv4 = ips.first { !$0.contains(":") }
        let ipv6 = ips.first { $0.contains(":") }
        var dns = (o["DNSName"] as? String)?.trimmingCharacters(in: .whitespaces)
        if dns?.hasSuffix(".") == true { dns?.removeLast() }
        if let candidate = dns, candidate.isEmpty || candidate.count > 253 || !isHostName(candidate) { dns = nil }
        guard dns != nil || ipv4 != nil || ipv6 != nil else { return nil }
        let host = String((o["HostName"] as? String ?? "").prefix(80))
        return Node(hostName: host.isEmpty ? (dns ?? ipv4 ?? "") : host, dnsName: dns,
                    os: String((o["OS"] as? String ?? "").prefix(20)), ipv4: ipv4, ipv6: ipv6,
                    online: o["Online"] as? Bool ?? false)
    }

    private static func isHostName(_ value: String) -> Bool {
        value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == ".") }
    }

    /// Peers that could be [deviceName] (a paired iPhone, iPad, Android or Mac),
    /// best first: a name match, then any phone/tablet/Mac peer. Online first within each.
    func candidates(forDeviceNamed deviceName: String) -> [Node] {
        let wanted = Self.normalized(deviceName)
        let receiverOS: Set<String> = ["ios", "android", "macos", "ipados"]
        let eligible = peers.filter { receiverOS.contains($0.os.lowercased()) || $0.os.isEmpty }
        func score(_ node: Node) -> Int {
            let names = [node.hostName, node.dnsName?.components(separatedBy: ".").first ?? ""].map(Self.normalized)
            if !wanted.isEmpty, names.contains(wanted) { return 2 }
            if !wanted.isEmpty, names.contains(where: { !$0.isEmpty && ($0.contains(wanted) || wanted.contains($0)) }) { return 1 }
            return 0
        }
        return eligible.enumerated().sorted { a, b in
            let (sa, sb) = (score(a.element), score(b.element))
            return sa != sb ? sa > sb : a.offset < b.offset
        }.map(\.element)
    }

    /// "Moto G (5S) Plus" and "moto-g-5s-plus" compare equal.
    static func normalized(_ name: String) -> String {
        name.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    static let maximumOutputBytes = 4 << 20
    static let maximumPeers = 500
}

/// Finds and runs the Tailscale CLI: the one inside the Mac app (App Store or
/// standalone), or a Homebrew/manual install. Bounded: 3 s, 4 MB of output.
enum TailscaleCLI {
    static let candidatePaths = [
        "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
        "/opt/homebrew/bin/tailscale",
        "/usr/local/bin/tailscale",
    ]

    enum Outcome: Equatable {
        case status(TailscaleStatus)
        case notInstalled
        /// Installed but signed out, stopped, or its output wasn't readable.
        case unavailable
    }

    static func executable(fileManager: FileManager = .default) -> String? {
        candidatePaths.first { fileManager.isExecutableFile(atPath: $0) }
    }

    static func status(timeout: TimeInterval = 3) async -> Outcome {
        guard let path = executable() else { return .notInstalled }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: run(path, timeout: timeout))
            }
        }
    }

    private static func run(_ path: String, timeout: TimeInterval) -> Outcome {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["status", "--json"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        do { try process.run() } catch { return .unavailable }
        var data = Data()
        let reader = DispatchQueue(label: "tailscale.status.read")
        reader.async {
            while let chunk = try? output.fileHandleForReading.read(upToCount: 64 << 10), !chunk.isEmpty {
                if data.count + chunk.count > TailscaleStatus.maximumOutputBytes { process.terminate(); break }
                data.append(chunk)
            }
        }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            return .unavailable
        }
        reader.sync {}
        guard let status = TailscaleStatus.parse(data), status.running else { return .unavailable }
        return .status(status)
    }
}
