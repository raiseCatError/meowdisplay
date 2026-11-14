import AppKit
import Foundation

// Closed-Lid Availability: optionally turns on macOS's global `SleepDisabled`
// power setting (`pmset -a disablesleep 1`) so a MacBook stays awake with its
// lid closed and no external display.
//
// This is NOT an app-owned IOKit assertion (that is Keep Mac Available). It is
// one global, persistent, root-only switch with no ownership token: it outlives
// MEOW quitting or crashing, and another app or an administrator can flip it
// at any time. So MEOW:
//   - reads the real value before every change and never trusts its own memory;
//   - claims ownership only when it changed the value from 0 to 1 itself;
//   - never claims, overwrites or clears a value someone else set;
//   - restores (writes 0) only when it still holds its ownership record, the
//     value is still 1, and nothing it can see suggests another tool now relies
//     on it — otherwise it asks the person first (fails closed);
//   - writes only through a per-change macOS administrator prompt. No helper,
//     no sudoers entry, no stored credentials.
// See CLOSED_LID.md.

/// Reads the effective global `SleepDisabled` value. nil = could not read.
protocol SleepDisabledReading {
    func readSleepDisabled() -> Bool?
}

enum SleepSettingWriteResult: Equatable {
    case success
    /// The person dismissed the administrator prompt.
    case cancelled
    case failed(String)
}

/// Writes the global value. Implementations must ask for authorization per call.
protocol SleepDisabledWriting {
    func setSleepDisabled(_ disabled: Bool) -> SleepSettingWriteResult
}

/// Names of running apps known to manage Mac sleep (informational only: a
/// running app is not proof that it controls `SleepDisabled`).
protocol PowerUtilityDetecting {
    func runningPowerUtilities() -> [String]
}

/// MEOW's record that it turned `SleepDisabled` on. It is the only evidence of
/// ownership available, because the OS setting carries none.
struct ClosedLidOwnershipRecord: Codable, Equatable {
    var enabledAt: Date
    /// What MEOW read immediately before writing. MEOW only claims ownership
    /// when this was false, so restoring always means writing false.
    var priorSleepDisabled: Bool
}

protocol ClosedLidOwnershipStore: AnyObject {
    var record: ClosedLidOwnershipRecord? { get set }
}

final class UserDefaultsClosedLidOwnershipStore: ClosedLidOwnershipStore {
    static let key = "closedLidAvailability.ownership"
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    var record: ClosedLidOwnershipRecord? {
        get { defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode(ClosedLidOwnershipRecord.self, from: $0) } }
        set {
            if let newValue, let data = try? JSONEncoder().encode(newValue) { defaults.set(data, forKey: Self.key) }
            else { defaults.removeObject(forKey: Self.key) }
        }
    }
}

/// What the settings row shows. One value, derived from the OS reading plus
/// MEOW's ownership record.
enum ClosedLidState: Equatable {
    /// SleepDisabled is 0: normal sleep.
    case off
    /// SleepDisabled is 1 and MEOW turned it on.
    case onByMEOW
    /// SleepDisabled is 1 and MEOW did not turn it on (another app, an
    /// administrator, or a MEOW record that was lost). MEOW leaves it alone.
    case onExternally
    /// Waiting for the administrator prompt.
    case authorizing
    /// The value could not be read. MEOW changes nothing.
    case unknown

    /// Whether the Mac is actually prevented from sleeping (for the toggle).
    var preventsSleep: Bool { self == .onByMEOW || self == .onExternally }
}

/// A one-off message under the row. Cleared by the next successful action.
enum ClosedLidNotice: Equatable {
    case authorizationCancelled
    case writeFailed(String)
    case readFailed
    /// The write reported success but the value did not change.
    case notApplied
    /// MEOW had turned it on, but it is now off: someone else restored sleep.
    case restoredOutsideMEOW
    /// It was already on when MEOW tried to turn it on; MEOW did not take over.
    case alreadyOnExternally
    /// Restoring would also undo sleep prevention another tool may rely on.
    case confirmRestoreWithUtilities([String])
}

/// The state machine. Pure apart from the injected seams; never polls.
final class ClosedLidAvailabilityModel {
    private let reader: SleepDisabledReading
    private let writer: SleepDisabledWriting
    private let utilities: PowerUtilityDetecting
    private let store: ClosedLidOwnershipStore
    private let now: () -> Date

    private(set) var state: ClosedLidState = .unknown
    private(set) var notice: ClosedLidNotice?

    init(reader: SleepDisabledReading,
         writer: SleepDisabledWriting,
         utilities: PowerUtilityDetecting,
         store: ClosedLidOwnershipStore,
         now: @escaping () -> Date = Date.init) {
        self.reader = reader
        self.writer = writer
        self.utilities = utilities
        self.store = store
        self.now = now
    }

    /// Whether MEOW holds an ownership record (it turned the setting on).
    var ownsSetting: Bool { store.record != nil }

    /// Re-read the OS value and reconcile it with the ownership record. Call at
    /// launch, when Settings appears, on app activation and after wake.
    func refresh() {
        guard state != .authorizing else { return }
        guard let value = reader.readSleepDisabled() else {
            state = .unknown
            return
        }
        switch (value, store.record != nil) {
        case (false, false):
            state = .off
        case (false, true):
            // MEOW turned it on, and something else turned it off. Nothing to
            // restore; drop the record so MEOW never writes for a stale claim.
            store.record = nil
            state = .off
            notice = .restoredOutsideMEOW
        case (true, true):
            state = .onByMEOW
        case (true, false):
            state = .onExternally
        }
    }

    /// Turn sleep prevention on. Claims ownership only when MEOW changed 0 → 1.
    func enable() {
        refresh()
        switch state {
        case .unknown:
            notice = .readFailed
            return
        case .onByMEOW, .authorizing:
            return
        case .onExternally:
            notice = .alreadyOnExternally
            return
        case .off:
            break
        }
        state = .authorizing
        let result = writer.setSleepDisabled(true)
        state = .unknown
        switch result {
        case .cancelled:
            notice = .authorizationCancelled
            refresh()
        case .failed(let message):
            notice = .writeFailed(message)
            refresh()
        case .success:
            guard let after = reader.readSleepDisabled() else {
                // Unverifiable: don't claim it. Next refresh shows it as
                // external if it did apply, so MEOW never restores it blindly.
                notice = .readFailed
                return
            }
            if after {
                store.record = ClosedLidOwnershipRecord(enabledAt: now(), priorSleepDisabled: false)
                notice = nil
                state = .onByMEOW
            } else {
                notice = .notApplied
                state = .off
            }
        }
    }

    /// Restore normal sleep. Only acts on a setting MEOW owns. With
    /// `confirmedDespiteUtilities` false, stops and asks when another power
    /// utility is running, because the global value can't tell whose it is.
    func disable(confirmedDespiteUtilities: Bool = false) {
        refresh()
        guard state == .onByMEOW, store.record != nil else {
            // .off: nothing to do (refresh already reported a restore made
            // elsewhere). .onExternally: not MEOW's to clear. .unknown: fail closed.
            if state == .unknown { notice = .readFailed }
            return
        }
        let others = utilities.runningPowerUtilities()
        if !others.isEmpty && !confirmedDespiteUtilities {
            notice = .confirmRestoreWithUtilities(others)
            return
        }
        state = .authorizing
        let result = writer.setSleepDisabled(false)
        state = .unknown
        switch result {
        case .cancelled:
            notice = .authorizationCancelled
            refresh()
        case .failed(let message):
            notice = .writeFailed(message)
            refresh()
        case .success:
            guard let after = reader.readSleepDisabled() else {
                notice = .readFailed
                return
            }
            if after {
                notice = .notApplied
                state = .onByMEOW
            } else {
                store.record = nil
                notice = nil
                state = .off
            }
        }
    }

    func clearNotice() { notice = nil }
}

// MARK: - Live implementations

/// Parses `pmset -g` output. Exposed for tests.
enum PmsetSettingsParser {
    /// Returns the `SleepDisabled` value, or nil when the line is absent or
    /// malformed (treated as unreadable: MEOW then changes nothing).
    static func sleepDisabled(fromPmsetOutput output: String) -> Bool? {
        for line in output.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard fields.count >= 2, fields[0] == "SleepDisabled" else { continue }
            switch fields[1] {
            case "1": return true
            case "0": return false
            default: return nil
            }
        }
        return nil
    }
}

/// Runs `/usr/bin/pmset -g` (read-only, no privileges) with fixed arguments.
struct PmsetSleepDisabledReader: SleepDisabledReading {
    func readSleepDisabled() -> Bool? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-g"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, let text = String(data: data, encoding: .utf8) else { return nil }
        return PmsetSettingsParser.sleepDisabled(fromPmsetOutput: text)
    }
}

/// Changes the value through the standard macOS administrator prompt, once per
/// change. The command is a constant: nothing user-supplied is interpolated.
/// Must run on the main thread (NSAppleScript is not thread-safe).
struct AdministratorPromptSleepDisabledWriter: SleepDisabledWriting {
    static func script(disabled: Bool) -> String {
        let value = disabled ? "1" : "0"
        let reason = disabled
            ? "MEOW wants to turn off sleep so this Mac stays awake with its lid closed."
            : "MEOW wants to restore normal sleep on this Mac."
        return "do shell script \"/usr/bin/pmset -a disablesleep \(value)\" with prompt \"\(reason)\" with administrator privileges"
    }

    func setSleepDisabled(_ disabled: Bool) -> SleepSettingWriteResult {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let script = NSAppleScript(source: Self.script(disabled: disabled)) else {
            return .failed("Couldn't prepare the request.")
        }
        var error: NSDictionary?
        script.executeAndReturnError(&error)
        guard let error else { return .success }
        if (error[NSAppleScript.errorNumber] as? Int) == -128 { return .cancelled }
        return .failed((error[NSAppleScript.errorMessage] as? String) ?? "macOS refused the change.")
    }
}

/// Checks running apps against a short list of known sleep utilities.
struct RunningPowerUtilityDetector: PowerUtilityDetecting {
    /// bundle identifier → display name. Amphetamine's Power Protect helper
    /// can change `SleepDisabled`; the others normally hold assertions only.
    static let known: [String: String] = [
        "com.if.Amphetamine": "Amphetamine",
        "info.marcel-dierkes.KeepingYouAwake": "KeepingYouAwake",
        "com.sindresorhus.Lungo": "Lungo",
        "com.lightheadsw.caffeine": "Caffeine",
        "com.intelliscapesolutions.caffeine": "Caffeine",
    ]

    func runningPowerUtilities() -> [String] {
        let ids = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        return Self.known.filter { ids.contains($0.key) }.map(\.value).sorted()
    }
}
