// Where a Known Devices row's Connect should dial (issue #128).
// Foundation only, so the hostless Mac test target covers it
// (MacTests/KnownDeviceTargetPolicyTests.swift).

import Foundation

enum KnownDeviceTargetPolicy {
    enum Route<WiFi> {
        case usb(udid: String)
        case wifi(WiFi)
    }

    /// The reachable route for a paired peer that has no live session.
    ///
    /// The USB install-id map is remembered forever (it only shrinks on
    /// Forget), so a cable that was used once is not evidence that one is
    /// plugged in now. Offering USB for an unplugged device made Connect dial
    /// usbmux, which answers "no device", and the session then redialled the
    /// missing cable indefinitely without ever appearing in the UI, while its
    /// USB claim kept Wi-Fi attempts from both ends out. USB counts only for a
    /// mapped UDID that is attached right now; several attached ones resolve
    /// the same way every time.
    static func resolve<WiFi>(
        peerID: String,
        installIDByUDID: [String: String],
        attachedUDIDs: Set<String>,
        discovered: [WiFi],
        txtID: (WiFi) -> String?
    ) -> Route<WiFi>? {
        let attached = installIDByUDID
            .filter { $0.value == peerID && attachedUDIDs.contains($0.key) }
            .keys.sorted()
        if let udid = attached.first { return .usb(udid: udid) }
        if let result = discovered.first(where: { txtID($0) == peerID }) { return .wifi(result) }
        return nil
    }
}
