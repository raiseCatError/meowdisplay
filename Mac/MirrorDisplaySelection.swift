import AppKit
import ScreenCaptureKit

/// A stable, reboot/reconnect-safe identity for a physical/virtual display,
/// for persisting the user's explicit Mirror-mode display choice. Raw
/// `CGDirectDisplayID` values are NOT persisted as the durable choice — they
/// can change across sleep/wake, lid close/open, and monitor or virtual
/// display reconnects (see `DisplayArrangement.swift`'s identical lesson for
/// the Extend-mode virtual display). `CGDisplayCreateUUIDFromDisplayID`
/// provides a UUID that survives those events for the same physical output.
enum MirrorDisplayIdentity {
    static func uuidString(for displayID: CGDirectDisplayID) -> String? {
        guard let cfUUID = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() else {
            return nil
        }
        return CFUUIDCreateString(nil, cfUUID) as String?
    }

    /// Resolves a persisted identity against the displays ScreenCaptureKit
    /// can currently capture. `nil` means either no preference was set or
    /// the previously-chosen display is no longer present — both cases fall
    /// back to Automatic (today: the first display SCShareableContent
    /// enumerates) at the call site, which is logged there.
    static func resolve(persistentID: String, in displays: [SCDisplay]) -> SCDisplay? {
        displays.first { uuidString(for: $0.displayID) == persistentID }
    }
}

/// One selectable entry in the Mirror Display picker: enough information to
/// label it usefully and to persist/resolve the choice. Built by combining
/// ScreenCaptureKit's capturable-display list (for the actual capture
/// source) with `NSScreen` (for a human-readable name and HiDPI status) —
/// see `TestPatternWindow.swift` for the same displayID-to-NSScreen match.
struct MirrorDisplayCandidate: Identifiable, Equatable {
    let displayID: CGDirectDisplayID
    /// The persistable identity — `nil` for a display macOS can't vend a
    /// UUID for (rare; some virtual displays), in which case a selection of
    /// it can't be made durable and the picker should say so.
    let persistentID: String?
    let name: String
    let logicalSize: CGSize
    let pixelSize: CGSize
    let isMain: Bool
    /// Best-effort only: there is no public API that reliably distinguishes
    /// a physical output from a virtual one, so this is a name-based guess
    /// (never a fabricated vendor name) and must be presented as a hint, not
    /// a fact.
    let likelyVirtual: Bool

    var id: String { persistentID ?? "id:\(displayID)" }

    var isHiDPI: Bool { pixelSize.width > logicalSize.width }

    var label: String {
        isMain ? "\(name) (Main)" : name
    }

    var detail: String {
        var parts = ["\(Int(logicalSize.width))×\(Int(logicalSize.height)) logical"]
        parts.append("\(Int(pixelSize.width))×\(Int(pixelSize.height)) backing")
        if isHiDPI { parts.append("HiDPI") }
        if likelyVirtual { parts.append("possibly virtual") }
        return parts.joined(separator: " · ")
    }

    /// Enumerates the Mac's currently capturable displays. Requires Screen
    /// Recording permission — returns an empty list rather than throwing
    /// when SCShareableContent can't be fetched, so a picker can show
    /// "no displays found" instead of crashing.
    static func listCandidates() async -> [MirrorDisplayCandidate] {
        guard let content = try? await SCShareableContent.current else { return [] }
        let mainID = CGMainDisplayID()
        return content.displays.map { display in
            let screen = NSScreen.screens.first {
                ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID)
                    == display.displayID
            }
            let mode = CGDisplayCopyDisplayMode(display.displayID)
            let pixelSize = CGSize(width: mode?.pixelWidth ?? display.width,
                                   height: mode?.pixelHeight ?? display.height)
            let logicalSize = screen?.frame.size
                ?? CGSize(width: display.width, height: display.height)
            let name = screen?.localizedName ?? "Display \(display.displayID)"
            let likelyVirtual = name.localizedCaseInsensitiveContains("virtual")
                || name.localizedCaseInsensitiveContains("betterdisplay")
            return MirrorDisplayCandidate(
                displayID: display.displayID,
                persistentID: MirrorDisplayIdentity.uuidString(for: display.displayID),
                name: name, logicalSize: logicalSize, pixelSize: pixelSize,
                isMain: display.displayID == mainID, likelyVirtual: likelyVirtual)
        }
    }
}
