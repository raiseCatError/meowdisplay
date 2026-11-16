import Foundation
#if os(macOS)
import Darwin
import IOKit
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
/// Macs), and for a bridge (`bridge0`, "Thunderbolt Bridge") whose members
/// are all such ports. Anything else, and any lookup that fails, is false:
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

    // `SIOCGDRVSPEC` / `BRDGGIFS`, the read-only query `ifconfig bridgeN`
    // uses. Neither the request structs nor the bridge command are in the
    // public SDK headers, so their layouts are written out here:
    //   struct ifdrv     { char name[16]; unsigned long cmd; size_t len; void *data; }  // 40 bytes
    //   struct ifbifconf { uint32_t len; void *buf; }   // #pragma pack(4): 12 bytes
    //   struct ifbreq    { char name[16]; ... }         // #pragma pack(4): 80 bytes
    // A layout mismatch makes the kernel refuse the request (or report no
    // members), which reads as "not a cable" — never as a false "cable".
    private static let ifdrvSize = 40
    private static let ifbifconfSize = 12
    private static let ifbreqSize = 80
    private static let bridgeGetMembers: UInt64 = 6   // BRDGGIFS
    /// `_IOWR('i', 123, struct ifdrv)`.
    private static let getDriverSpecific = UInt(0xC000_0000) | (UInt(ifdrvSize) << 16) | (UInt(UInt8(ascii: "i")) << 8) | 123

    /// The member interface names of a bridge, or nil when the query fails.
    static func bridgeMembers(of name: String) -> [String]? {
        let nameBytes = Array(name.utf8)
        guard !nameBytes.isEmpty, nameBytes.count < Int(IFNAMSIZ) else { return nil }
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        let capacity = 16
        var members = [UInt8](repeating: 0, count: ifbreqSize * capacity)
        var conf = [UInt8](repeating: 0, count: ifbifconfSize)
        var request = [UInt8](repeating: 0, count: ifdrvSize)
        let status: Int32 = members.withUnsafeMutableBytes { membersBuffer -> Int32 in
            conf.withUnsafeMutableBytes { confBuffer -> Int32 in
                request.withUnsafeMutableBytes { requestBuffer -> Int32 in
                    guard let membersBase = membersBuffer.baseAddress,
                          let confBase = confBuffer.baseAddress,
                          let requestBase = requestBuffer.baseAddress else { return -1 }
                    confBuffer.storeBytes(of: UInt32(membersBuffer.count), toByteOffset: 0, as: UInt32.self)
                    confBuffer.storeBytes(of: UInt64(UInt(bitPattern: membersBase)), toByteOffset: 4, as: UInt64.self)
                    for (index, byte) in nameBytes.enumerated() { requestBuffer[index] = byte }
                    requestBuffer.storeBytes(of: bridgeGetMembers, toByteOffset: 16, as: UInt64.self)
                    requestBuffer.storeBytes(of: UInt64(ifbifconfSize), toByteOffset: 24, as: UInt64.self)
                    requestBuffer.storeBytes(of: UInt64(UInt(bitPattern: confBase)), toByteOffset: 32, as: UInt64.self)
                    return ioctl(fd, getDriverSpecific, requestBase)
                }
            }
        }
        guard status == 0 else { return nil }
        let used = Int(conf.withUnsafeBytes { $0.load(fromByteOffset: 0, as: UInt32.self) })
        guard used >= 0, used <= members.count, used % ifbreqSize == 0 else { return nil }
        return stride(from: 0, to: used, by: ifbreqSize).compactMap { offset in
            let raw = members[offset..<(offset + Int(IFNAMSIZ))].prefix { $0 != 0 }
            return raw.isEmpty ? nil : String(decoding: raw, as: UTF8.self)
        }
    }
}
#endif
