import Foundation
import Darwin

/// Read-only inspection of this Mac's Wake-for-Network-Access setting and
/// its primary LAN interface — the foundation for proving ordinary
/// Wake-on-LAN works before any Tailscale wake relay is built. Every shell
/// invocation here is a single fixed, hardcoded command (`pmset -g` to
/// read, `pmset sleepnow` to sleep) — never a caller-supplied string — and
/// neither needs or requests elevated privileges.
enum WakeForNetworkAccessStatus: String {
    case enabled = "Enabled"
    case disabled = "Disabled"
    case unknown = "Unsupported / Unknown"
}

enum WakeInspector {
    /// Parses `pmset -g` output for the `womp` (Wake on Magic Packet) line.
    /// Read-only: never invoked with `-a` or any writing subcommand.
    static func wakeForNetworkAccessStatus() -> WakeForNetworkAccessStatus {
        guard let output = runReadOnly("/usr/bin/pmset", args: ["-g"]) else { return .unknown }
        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("womp") else { continue }
            if trimmed.hasSuffix("1") { return .enabled }
            if trimmed.hasSuffix("0") { return .disabled }
        }
        return .unknown
    }

    /// Puts the Mac to sleep via the same command-line entry point System
    /// Settings' "Sleep Now" affordance uses — no IOKit privilege escalation,
    /// no custom power-management state changes.
    static func sleepNow() {
        _ = runReadOnly("/usr/bin/pmset", args: ["sleepnow"])
    }

    /// This Mac's own current wake metadata (Wake-on-LAN packets target the
    /// primary LAN interface's hardware address). `nil` if no non-loopback,
    /// non-tunnel, IPv4-carrying interface is up — e.g. offline or USB-only.
    static func currentInterfaceWakeMetadata() -> WakeMetadata? {
        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0, let firstAddr = ifaddrPtr else { return nil }
        defer { freeifaddrs(ifaddrPtr) }

        // Pass 1: find the primary interface name via its IPv4 entry.
        var ipv4: String?
        var subnetMask: String?
        var broadcast: String?
        var interfaceName: String?
        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let flags = Int32(ptr.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0,
                  let addr = ptr.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET)
            else { continue }
            let name = String(cString: ptr.pointee.ifa_name)
            guard !ConnectionRoute.isTunnelInterface(name), !name.hasPrefix("bridge") else { continue }
            interfaceName = name
            ipv4 = ipString(from: addr)
            if let mask = ptr.pointee.ifa_netmask { subnetMask = ipString(from: mask) }
            if flags & IFF_BROADCAST != 0, let bcast = ptr.pointee.ifa_dstaddr {
                broadcast = ipString(from: bcast)
            }
            break
        }
        guard let interfaceName else { return nil }

        // Pass 2: that interface's hardware (MAC) address is a separate
        // AF_LINK entry under the same name.
        var macAddress: String?
        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let name = String(cString: ptr.pointee.ifa_name)
            guard name == interfaceName, let addr = ptr.pointee.ifa_addr,
                  addr.pointee.sa_family == UInt8(AF_LINK) else { continue }
            macAddress = addr.withMemoryRebound(to: sockaddr_dl.self, capacity: 1) { sdlPtr -> String? in
                let sdl = sdlPtr.pointee
                guard sdl.sdl_alen == 6 else { return nil }
                let start = Int(sdl.sdl_nlen)
                let bytes = withUnsafeBytes(of: sdl.sdl_data) { raw -> [UInt8] in
                    (start..<(start + 6)).map { raw[$0] }
                }
                return bytes.map { String(format: "%02x", $0) }.joined(separator: ":")
            }
            break
        }
        guard let macAddress else { return nil }

        var broadcastAddress = broadcast
        if broadcastAddress == nil, let ipv4, let subnetMask {
            broadcastAddress = Self.computedBroadcast(ipv4: ipv4, subnetMask: subnetMask)
        }

        return WakeMetadata(macAddress: macAddress, interfaceName: interfaceName,
                            ipv4: ipv4, subnetMask: subnetMask,
                            broadcastAddress: broadcastAddress, updatedAt: Date())
    }

    static func computedBroadcast(ipv4: String, subnetMask: String) -> String? {
        let ipParts = ipv4.split(separator: ".").compactMap { UInt8($0) }
        let maskParts = subnetMask.split(separator: ".").compactMap { UInt8($0) }
        guard ipParts.count == 4, maskParts.count == 4 else { return nil }
        let broadcastParts = (0..<4).map { ipParts[$0] | ~maskParts[$0] }
        return broadcastParts.map(String.init).joined(separator: ".")
    }

    private static func ipString(from addr: UnsafeMutablePointer<sockaddr>) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let result = getnameinfo(addr, socklen_t(addr.pointee.sa_len), &buffer, socklen_t(buffer.count),
                                 nil, 0, NI_NUMERICHOST)
        guard result == 0 else { return nil }
        let nullTerminatorIndex = buffer.firstIndex(of: 0) ?? buffer.count
        return String(decoding: buffer[..<nullTerminatorIndex].map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// The one and only place a subprocess is launched from this file — a
    /// fixed executable path and a fixed, non-caller-supplied argument list.
    private static func runReadOnly(_ executable: String, args: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }
}
