import Foundation

/// The physical route carrying an established OpenDisplay connection.
/// Discovery targets remain USB or Bonjour; AWDL and LAN are distinguished
/// only after Network.framework has selected the live path.
enum ConnectionRoute: String, Equatable {
    case usb = "USB"
    case awdl = "AWDL"
    case lan = "LAN"

    static func classify(
        isUSB: Bool,
        interfaceNames: [String],
        remoteEndpointDescription: String?
    ) -> ConnectionRoute {
        if isUSB { return .usb }

        let names = interfaceNames.map { $0.lowercased() }
        if remoteEndpointDescription.map(hasPeerToPeerScope) == true {
            return .awdl
        }

        // `availableInterfaces` can contain an ordinary LAN interface and
        // AWDL simultaneously. Without a scoped endpoint, classify AWDL only
        // when every non-loopback interface is peer-to-peer.
        let relevantNames = names.filter { !$0.hasPrefix("lo") }
        if !relevantNames.isEmpty,
           relevantNames.allSatisfy(isPeerToPeerInterface) {
            return .awdl
        }
        return .lan
    }

    static func isPeerToPeerInterface(_ name: String) -> Bool {
        let lowercased = name.lowercased()
        return lowercased.hasPrefix("awdl") || lowercased.hasPrefix("llw")
    }

    private static func hasPeerToPeerScope(_ endpoint: String) -> Bool {
        let lowercased = endpoint.lowercased()
        return lowercased.contains("%awdl") || lowercased.contains("%llw")
    }
}
