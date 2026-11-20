import Foundation
import Network

extension ConnectionPathEvidence {
    /// Evidence from a live connection's path. `fallbackEndpoint` is the
    /// connection's own endpoint, used when the path has no remote endpoint.
    init(path: NWPath, fallbackEndpoint: NWEndpoint?, peerIsMac: Bool) {
        let remote = Self.remoteFacts(path.remoteEndpoint ?? fallbackEndpoint)
        self.init(
            interfaceNames: path.availableInterfaces.map(\.name),
            usesWiFi: path.usesInterfaceType(.wifi),
            usesCellular: path.usesInterfaceType(.cellular),
            usesLoopback: path.usesInterfaceType(.loopback),
            remoteIsLinkLocal: remote.isLinkLocal,
            remoteScopeInterface: remote.zone,
            peerIsMac: peerIsMac)
    }

    /// Whether `endpoint` is a link-local address, and the interface its
    /// scope names. Typed addresses are read directly; a `.name` host (an
    /// address Network.framework kept as text) is parsed.
    static func remoteFacts(_ endpoint: NWEndpoint?) -> (isLinkLocal: Bool, zone: String?) {
        guard case .hostPort(let host, _)? = endpoint else { return (false, nil) }
        switch host {
        case .ipv6(let address):
            return (address.isLinkLocal,
                    address.interface?.name ?? ConnectionPathDescription.scopeZone(inEndpointText: "\(address)"))
        case .ipv4(let address):
            return (address.isLinkLocal, address.interface?.name)
        case .name(let name, let interface):
            return (ConnectionPathDescription.isLinkLocalAddressText(name),
                    interface?.name ?? ConnectionPathDescription.scopeZone(inEndpointText: name))
        @unknown default:
            return (false, nil)
        }
    }
}
