import Darwin
import Foundation
import Network

/// macOS Local Network privacy (TN3179) can block this Mac's OUTGOING connections to devices while
/// incoming ones (pairing, a device's connect request) still work: every dial to the device then
/// sits in "preparing" and the device waits on "Connecting". This tells the two apart without
/// sending anything: a UDP connection to an address on this Mac's own subnet reports
/// `.localNetworkDenied` when macOS blocks MeowDisplay. Checked after a dial times out.
enum LocalNetworkAccess {
    enum State: String, Sendable { case unknown, allowed, denied }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var current: State = .unknown
    nonisolated(unsafe) private static var lastCheck: TimeInterval = -.infinity
    /// Told on the main queue when the state changes (the pairing advertisement carries it).
    nonisolated(unsafe) static var onChange: (@Sendable (State) -> Void)?

    static var state: State { lock.withLock { current } }

    /// What a probe's path says. Pure, for tests.
    static func classify(status: NWPath.Status, reason: NWPath.UnsatisfiedReason) -> State {
        if status == .satisfied { return .allowed }
        return reason == .localNetworkDenied ? .denied : .unknown
    }

    /// An address on the subnet of `address`/`netmask` (IPv4, host order) that isn't `address`
    /// itself: the network's first host, else the second. Nil for a /31 or /32 or no subnet.
    static func probeAddress(address: UInt32, netmask: UInt32) -> UInt32? {
        let network = address & netmask
        let hosts = ~netmask
        guard netmask != 0, hosts >= 3 else { return nil }
        let first = network | 1
        return first != address ? first : network | 2
    }

    /// Checks at most every `minimumInterval` seconds; `done` gets the state (on a utility queue).
    static func check(minimumInterval: TimeInterval = 30, done: (@Sendable (State) -> Void)? = nil) {
        let now = ProcessInfo.processInfo.systemUptime
        let skip: State? = lock.withLock {
            if now - lastCheck < minimumInterval { return current }
            lastCheck = now
            return nil
        }
        if let skip { done?(skip); return }
        guard let target = subnetProbeTarget() else { done?(.unknown); return }
        let queue = DispatchQueue(label: "localNetworkAccess.probe")
        let params = NWParameters.udp
        let connection = NWConnection(host: NWEndpoint.Host(target), port: 9, using: params)
        let finished = OSAllocatedFlag()
        let finish: @Sendable (State) -> Void = { state in
            guard finished.set() else { return }
            connection.cancel()
            record(state)
            done?(state)
        }
        connection.stateUpdateHandler = { s in
            switch s {
            case .ready: finish(.allowed)
            case .waiting, .failed:
                if let path = connection.currentPath { finish(classify(status: path.status, reason: path.unsatisfiedReason)) }
            default: break
            }
        }
        connection.pathUpdateHandler = { path in
            if path.unsatisfiedReason == .localNetworkDenied { finish(.denied) }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 2) { finish(.unknown) }
    }

    private static func record(_ state: State) {
        guard state != .unknown else { return }
        let changed: Bool = lock.withLock {
            defer { current = state }
            return current != state
        }
        guard changed else { return }
        Log.info("localNetwork: \(state.rawValue)" + (state == .denied
            ? " — macOS is blocking outgoing connections to devices (System Settings ▸ Privacy & Security ▸ Local Network)" : ""))
        if let onChange { DispatchQueue.main.async { onChange(state) } }
    }

    /// The first active, non-loopback IPv4 interface's subnet, as a dotted address to probe.
    private static func subnetProbeTarget() -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            let flags = Int32(entry.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_LOOPBACK == 0,
                  let addr = entry.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  let mask = entry.pointee.ifa_netmask else { continue }
            let name = String(cString: entry.pointee.ifa_name)
            guard name.hasPrefix("en") || name.hasPrefix("bridge") else { continue }
            let a = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            let m = mask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            guard let probe = probeAddress(address: a, netmask: m) else { continue }
            return "\(probe >> 24).\((probe >> 16) & 0xff).\((probe >> 8) & 0xff).\(probe & 0xff)"
        }
        return nil
    }
}

/// Set once, from any thread.
private final class OSAllocatedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    /// True the first time only.
    func set() -> Bool { lock.withLock { defer { value = true }; return !value } }
}
