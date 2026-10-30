import AppKit
import Foundation

/// One-click setup of the two shortcuts `StageManagerSwitch` runs. Uses only Apple's supported
/// path: MeowDisplay writes each shortcut file (the system's Set Stage Manager action), signs it
/// with `shortcuts sign`, and opens it, so Shortcuts asks the owner to Add Shortcut. Nothing is
/// imported silently, the Shortcuts library is never edited, and a shortcut is never run to check
/// it. Only missing shortcuts are offered, so there are no duplicates; others are never touched.
enum StageManagerShortcutInstaller {
    /// The Shortcuts action behind "Set Stage Manager" (shown as "Set Multitasking Mode" on newer
    /// macOS): ActionKit's WFSetStageManagerIntent, operation "set" plus the state.
    static let actionIdentifier = "is.workflow.actions.stagemanager.set"
    static let names = [StageManagerSwitch.offShortcut, StageManagerSwitch.onShortcut]

    enum InstallError: Error, Equatable {
        case write
        case sign(Int32)
        case open
    }

    /// An unsigned shortcut file (binary property list) with the one action.
    static func unsignedFile(on: Bool) -> Data {
        let shortcut: [String: Any] = [
            "WFWorkflowActions": [[
                "WFWorkflowActionIdentifier": actionIdentifier,
                "WFWorkflowActionParameters": ["operation": "set", "state": on],
            ]],
            "WFWorkflowClientVersion": "2700.0.0",
            "WFWorkflowMinimumClientVersion": 900,
            "WFWorkflowMinimumClientVersionString": "900",
            "WFWorkflowIcon": ["WFWorkflowIconGlyphNumber": 59511, "WFWorkflowIconStartColor": 463140863],
            "WFWorkflowImportQuestions": [Any](),
            "WFWorkflowInputContentItemClasses": [Any](),
            "WFWorkflowOutputContentItemClasses": [Any](),
            "WFWorkflowTypes": [Any](),
            "WFQuickActionSurfaces": [Any](),
            "WFWorkflowHasShortcutInputVariables": false,
            "WFWorkflowHasOutputFallback": false,
        ]
        return (try? PropertyListSerialization.data(fromPropertyList: shortcut, format: .binary, options: 0)) ?? Data()
    }

    /// From `shortcuts list`: which of the two exist by exact name, and numbered copies of them
    /// ("MeowDisplay Stage Manager Off 1") that Shortcuts makes when a name is taken.
    static func inventory(listOutput: String) -> (present: Set<String>, copies: [String]) {
        let lines = listOutput.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        let present = Set(lines.filter { names.contains($0) })
        let copies = lines.filter { line in
            names.contains { name in
                line.hasPrefix(name + " ") && Int(line.dropFirst(name.count + 1)) != nil
            }
        }
        return (present, copies.sorted())
    }

    /// The ones still to add, Off first.
    static func missing(present: Set<String>) -> [String] { names.filter { !present.contains($0) } }

    /// Where the prepared files go (this app's own folder; the `shortcuts` tool can write there).
    static var folder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let app = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "MeowDisplay"
        return base.appendingPathComponent(app, isDirectory: true).appendingPathComponent("Shortcuts", isDirectory: true)
    }

    /// Writes and signs each named shortcut. Blocks (signing asks Apple's servers): call off the
    /// main thread. Returns the signed files, named so Shortcuts uses the exact names.
    static func prepare(_ wanted: [String], in folder: URL = folder) -> Result<[URL], InstallError> {
        let fm = FileManager.default
        let unsigned = folder.appendingPathComponent("unsigned", isDirectory: true)
        do { try fm.createDirectory(at: unsigned, withIntermediateDirectories: true) } catch { return .failure(.write) }
        var out: [URL] = []
        for name in wanted {
            let input = unsigned.appendingPathComponent(name + ".shortcut")
            let signed = folder.appendingPathComponent(name + ".shortcut")
            do { try unsignedFile(on: name == StageManagerSwitch.onShortcut).write(to: input) } catch { return .failure(.write) }
            try? fm.removeItem(at: signed)
            let r = StageManagerSwitch.runShortcuts(["sign", "--mode", "anyone", "--input", input.path, "--output", signed.path])
            guard r.status == 0, fm.fileExists(atPath: signed.path) else {
                Log.info("stage manager setup: signing \(name) failed (\(r.status))")
                return .failure(.sign(r.status))
            }
            out.append(signed)
        }
        return .success(out)
    }

    /// Opens prepared files in Shortcuts, which asks the owner to Add Shortcut (one at a time).
    @MainActor
    static func open(_ files: [URL]) -> Bool {
        var ok = true
        for (i, file) in files.enumerated() {
            if i == 0 { ok = NSWorkspace.shared.open(file) && ok } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 1.5) { _ = NSWorkspace.shared.open(file) }
            }
        }
        Log.info("stage manager setup: opened \(files.count) shortcut(s) in Shortcuts for the owner to add")
        return ok
    }

    /// Opens one existing shortcut in the Shortcuts editor (to look at or delete it).
    static func view(_ name: String) {
        DispatchQueue.global(qos: .userInitiated).async { _ = StageManagerSwitch.runShortcuts(["view", name]) }
    }

    /// Removes the prepared files once both shortcuts exist.
    static func cleanUp(folder: URL = folder) { try? FileManager.default.removeItem(at: folder) }
}
