import Foundation
#if os(macOS)
import Darwin
import IOKit
import SystemConfiguration
#endif

/// The platform's host-to-host cable interface check: the Thunderbolt IP
/// lookup on macOS, nothing anywhere else (an iPhone/iPad or Android
/// receiver is never on a Thunderbolt IP link in this product).
enum HostToHostCableInterfaces {
    static var current: HostToHostCableInterfaceChecking {
        #if os(macOS)
        return ThunderboltIPInterfaces()
        #else
        return NoHostToHostCableInterfaces()
        #endif
    }
}

#if os(macOS)
/// Is an interface one end of a Thunderbolt IP (host-to-host) link?
///
/// True for an interface whose IOKit provider chain contains an
/// `AppleThunderboltIPPort` (the "Thunderbolt 1/2" ports, `en1`/`en2` on most
/// Macs), and for a bridge (`bridge0`, "Thunderbolt Bridge") whose members,
/// as SystemConfiguration's preferences list them, are all such ports. Anything else, and any lookup that fails, is false:
/// the caller then keeps the plain route label rather than guessing.
/// A bridge that also holds an ordinary Ethernet port is false, since it can
/// join a switched LAN.
struct ThunderboltIPInterfaces: HostToHostCableInterfaceChecking {
    func isHostToHostCableInterface(_ name: String) -> Bool {
        if Self.isThunderboltIPPort(name) { return true }
        guard name.hasPrefix("bridge"),
              let members = Self.bridgeMembers(of: name), !members.isEmpty else { return false }
        return members.allSatisfy(Self.isThunderboltIPPort)
    }

    /// Walks a few providers up from the interface's IOKit object, looking
    /// for the Thunderbolt IP port driver (its direct provider on current
    /// macOS; a couple of levels of slack for a future intermediate class).
    static func isThunderboltIPPort(_ bsdName: String) -> Bool {
        guard !bsdName.isEmpty, bsdName.count < Int(IFNAMSIZ),
              let matching = IOBSDNameMatching(kIOMainPortDefault, 0, bsdName) else { return false }
        var entry = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard entry != IO_OBJECT_NULL else { return false }
        for _ in 0..<4 {
            var parent: io_registry_entry_t = IO_OBJECT_NULL
            let result = IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent)
            IOObjectRelease(entry)
            guard result == KERN_SUCCESS, parent != IO_OBJECT_NULL else { return false }
            if IOObjectConformsTo(parent, "AppleThunderboltIPPort") != 0 {
                IOObjectRelease(parent)
                return true
            }
            entry = parent
        }
        IOObjectRelease(entry)
        return false
    }

    /// At most this many members are read from one bridge; a larger list is
    /// treated as unexpected (not a cable).
    static let maxBridgeMembers = 8

    /// The member interface names of a bridge, from the public SystemConfiguration
    /// preferences (read-only, no authorization). Nil when anything is missing.
    static func bridgeMembers(of name: String) -> [String]? {
        guard let prefs = SCPreferencesCreate(nil, "MeowDisplay route label" as CFString, nil) else { return nil }
        // "VirtualNetworkInterfaces" is not a documented key (the bridge
        // accessors themselves are not public API). A missing or changed key
        // only makes this answer nil, so the route reads "LAN".
        return bridgeMembers(of: name, virtualNetworkInterfaces: SCPreferencesGetValue(prefs, "VirtualNetworkInterfaces" as CFString))
    }

    /// Parses `VirtualNetworkInterfaces` → `Bridge` → `<name>` → `Interfaces`.
    /// Every step is optional; any surprise (wrong type, empty or oversized
    /// list, an entry that is not an interface name) is nil.
    static func bridgeMembers(of name: String, virtualNetworkInterfaces: Any?) -> [String]? {
        guard let virtual = virtualNetworkInterfaces as? [String: Any],
              let bridges = virtual["Bridge"] as? [String: Any],
              let bridge = bridges[name] as? [String: Any],
              let interfaces = bridge["Interfaces"] as? [Any],
              !interfaces.isEmpty, interfaces.count <= maxBridgeMembers else { return nil }
        var members: [String] = []
        for entry in interfaces {
            guard let member = entry as? String, !member.isEmpty, member.utf8.count < Int(IFNAMSIZ),
                  member.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return nil }
            members.append(member)
        }
        return members
    }
}
#endif
