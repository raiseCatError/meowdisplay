import AppKit
import ApplicationServices

/// Add to Current Stage: macOS's own Stage Manager action on the side strip. Each strip item is an
/// accessibility button of the system's WindowManager that lists the windows it holds
/// (`AXWindowsIDs`) and offers `AXAddToStage` — what a person does by adding that item to the
/// stage. MeowDisplay performs it on the one item holding the exact window (never by position),
/// then checks the window left the strip. The whole item joins the stage (its other windows too).
enum StageStripAccess {
    enum Result: String, Sendable, CaseIterable {
        case added, notInStrip, ambiguous, accessibility, failed
    }

    static let addAction = "AXAddToStage"

    /// Which strip item holds `windowID`: its index, or why none can be used.
    static func target(windowID: CGWindowID, groups: [[CGWindowID]]) -> Swift.Result<Int, StageStripAccess.ResultError> {
        let hits = groups.indices.filter { groups[$0].contains(windowID) }
        if hits.isEmpty { return .failure(.init(result: .notInStrip)) }
        if hits.count > 1 { return .failure(.init(result: .ambiguous)) }
        return .success(hits[0])
    }
    struct ResultError: Error, Equatable { let result: Result }

    /// Window ids in Stage Manager's strip right now (empty when it's off or unreadable).
    static func stripWindowIDs() -> Set<CGWindowID> { Set(items().flatMap(\.ids)) }

    /// Adds the strip item holding `windowID` to the current stage. Blocks up to 2 s: call off
    /// the main thread and the engine queue.
    static func addToStage(windowID: CGWindowID) -> Result {
        guard AXIsProcessTrusted() else { return .accessibility }
        let all = items()
        switch target(windowID: windowID, groups: all.map(\.ids)) {
        case .failure(let e):
            Log.info("stage strip: add window \(windowID): \(e.result.rawValue)")
            return e.result
        case .success(let i):
            let item = all[i].element
            var names: CFArray?
            AXUIElementCopyActionNames(item, &names)
            guard ((names as? [String]) ?? []).contains(addAction),
                  AXUIElementPerformAction(item, addAction as CFString) == .success else {
                Log.info("stage strip: add window \(windowID): action unavailable")
                return .failed
            }
            for _ in 0..<20 {
                usleep(100_000)
                if !stripWindowIDs().contains(windowID) {
                    Log.info("stage strip: window \(windowID) added to the current stage (\(all[i].ids.count) window(s) in its item)")
                    return .added
                }
            }
            Log.info("stage strip: window \(windowID) still in the strip after Add to Stage")
            return .failed
        }
    }

    private struct Item { let element: AXUIElement; let ids: [CGWindowID] }

    private static func items() -> [Item] {
        guard let wm = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.WindowManager").first else { return [] }
        var out: [Item] = []
        func walk(_ e: AXUIElement, depth: Int) {
            guard depth < 6 else { return }
            if value(e, kAXRoleAttribute) as? String == kAXButtonRole,
               let ids = value(e, "AXWindowsIDs") as? [NSNumber] {
                out.append(Item(element: e, ids: ids.map { CGWindowID($0.uint32Value) }))
                return
            }
            for child in (value(e, kAXChildrenAttribute) as? [AXUIElement]) ?? [] { walk(child, depth: depth + 1) }
        }
        walk(AXUIElementCreateApplication(wm.processIdentifier), depth: 0)
        return out
    }

    private static func value(_ e: AXUIElement, _ name: String) -> AnyObject? {
        var v: AnyObject?
        return AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success ? v : nil
    }
}
