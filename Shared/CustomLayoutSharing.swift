// Portable share codes for Custom layouts, and the editor's display-only
// Preview session. Foundation + CryptoKit only (hostless-testable).

import CryptoKit
import Foundation

/// A Custom layout as text: `MDL<version>-<body>.<check>`, where `body` is
/// the zlib-compressed JSON payload in URL-safe base64 and `check` is the
/// first 4 bytes of its SHA-256. Generated and read entirely on-device.
///
/// The payload holds only what defines the layout — name, both
/// arrangements (positions, sizes, palette styles, one-tap shortcuts) and
/// Two-Hand Assist — never trust data, keys, device or peer IDs, Remote
/// Access details, permissions or history. Importing validates, sanitizes
/// and summarizes; it never executes anything.
enum CustomLayoutShareCode {
    static let currentVersion = 1
    static let maximumCodeLength = 60_000
    static let maximumPayloadBytes = 256 * 1024
    static let maximumPlacements = 64
    static let maximumNameLength = 40

    /// Everything a share code carries — deliberately a separate type from
    /// `CustomControlLayout` so its local `id` never leaves the device.
    struct Payload: Codable, Equatable {
        var name: String
        var landscape: CustomControlArrangement
        var portrait: CustomControlArrangement
        var twoHandAssist: Bool
        var assistActionIDs: [String]
        /// Definitions of the user-made Function actions the layout places
        /// (built-in actions travel by id). Omitted when there are none.
        var functionActions: [ShortcutItem]?
    }

    enum ShareCodeError: Error, Equatable {
        case notAShareCode
        case unsupportedVersion(Int)
        case corrupted
        case tooLarge
    }

    struct ImportSummary: Equatable {
        enum Warning: Equatable {
            /// Controls from a newer MeowDisplay this version doesn't know.
            case skippedControls(Int)
            /// Function Tray actions this version doesn't have.
            case unknownActions(Int)
        }

        /// Ready to add — with a fresh local id.
        var layout: CustomControlLayout
        var landscapeControls: Int
        var portraitControls: Int
        var shortcutCount: Int
        var twoHandAssist: Bool
        var warnings: [Warning]
    }

    /// - Parameter functionItems: the Function actions the layout's
    ///   profile defines; only user-made ones the layout places are carried.
    static func encode(_ layout: CustomControlLayout, functionItems: [ShortcutItem] = []) throws -> String {
        let placed = Set((layout.landscape.placements + layout.portrait.placements).compactMap { placement -> String? in
            if case .function(let id) = placement.kind, !FunctionTrayProfile.isBuiltIn(id) { return id }
            return nil
        })
        let actions = functionItems.filter { placed.contains($0.id) }
        let payload = Payload(name: layout.name, landscape: layout.landscape, portrait: layout.portrait,
                              twoHandAssist: layout.twoHandAssist, assistActionIDs: layout.assistActionIDs,
                              functionActions: actions.isEmpty ? nil : actions)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let json = try encoder.encode(payload)
        let compressed = try (json as NSData).compressed(using: .zlib) as Data
        return "MDL\(currentVersion)-" + base64URL(compressed) + "." + checksum(json)
    }

    static func decode(_ text: String) -> Result<ImportSummary, ShareCodeError> {
        let code = text.filter { !$0.isWhitespace }
        guard code.count <= maximumCodeLength else { return .failure(.tooLarge) }
        guard code.hasPrefix("MDL"), let dash = code.firstIndex(of: "-") else { return .failure(.notAShareCode) }
        guard let version = Int(code[code.index(code.startIndex, offsetBy: 3)..<dash]) else {
            return .failure(.notAShareCode)
        }
        guard version == currentVersion else { return .failure(.unsupportedVersion(version)) }
        let rest = code[code.index(after: dash)...]
        guard let dot = rest.lastIndex(of: ".") else { return .failure(.corrupted) }
        guard let compressed = data(base64URL: String(rest[..<dot])),
              let json = try? (compressed as NSData).decompressed(using: .zlib) as Data else {
            return .failure(.corrupted)
        }
        guard json.count <= maximumPayloadBytes else { return .failure(.tooLarge) }
        guard checksum(json) == rest[rest.index(after: dot)...] else { return .failure(.corrupted) }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: json) else { return .failure(.corrupted) }
        let rawCount = rawPlacementCount(json)
        return .success(summary(for: payload, rawPlacementCount: rawCount))
    }

    // MARK: Sanitizing

    private static func summary(for payload: Payload, rawPlacementCount: Int?) -> ImportSummary {
        // Carried custom actions become layout-owned one-tap buttons with
        // fresh ids — never merged into, or overwriting, local profiles.
        var definitions: [String: ShortcutItem] = [:]
        for action in (payload.functionActions ?? []).prefix(maximumPlacements) where action.action.isValid {
            var item = action
            item.id = UUID().uuidString
            definitions[action.id] = item
        }
        func adopt(_ arrangement: CustomControlArrangement) -> CustomControlArrangement {
            var result = arrangement
            result.placements = arrangement.placements.map { placement in
                guard case .function(let id) = placement.kind, let item = definitions[id] else { return placement }
                var adopted = placement
                adopted.kind = .shortcut(item)
                return adopted
            }
            return result
        }
        let landscape = sanitized(adopt(payload.landscape))
        let portrait = sanitized(adopt(payload.portrait))
        let trimmedName = payload.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let layout = CustomControlLayout(
            id: UUID().uuidString,
            name: trimmedName.isEmpty ? String(localized: "Imported Layout") : String(trimmedName.prefix(maximumNameLength)),
            landscape: landscape, portrait: portrait,
            twoHandAssist: payload.twoHandAssist,
            assistActionIDs: payload.assistActionIDs.filter(FunctionTrayProfile.isBuiltIn).prefix(8)
                .map { String($0.prefix(40)) })
        let all = landscape.placements + portrait.placements
        let known = Set(FunctionTrayProfile.canonical().items.map(\.id))
        let unknown = all.filter { if case .function(let id) = $0.kind { return !known.contains(id) } else { return false } }
        var warnings: [ImportSummary.Warning] = []
        if let rawPlacementCount, rawPlacementCount > all.count {
            warnings.append(.skippedControls(rawPlacementCount - all.count))
        }
        if !unknown.isEmpty { warnings.append(.unknownActions(unknown.count)) }
        let shortcuts = all.filter { if case .shortcut = $0.kind { return true } else { return false } }.count
        return ImportSummary(layout: layout, landscapeControls: landscape.placements.count,
                             portraitControls: portrait.placements.count, shortcutCount: shortcuts,
                             twoHandAssist: payload.twoHandAssist, warnings: warnings)
    }

    private static func sanitized(_ arrangement: CustomControlArrangement) -> CustomControlArrangement {
        var seen = Set<String>()
        let placements = arrangement.placements.prefix(maximumPlacements).compactMap { placement -> CustomControlPlacement? in
            let id = seen.insert(placement.id).inserted && !placement.id.isEmpty && placement.id.count <= 64
                ? placement.id : UUID().uuidString
            var kind = placement.kind
            if case .shortcut(var item) = kind {
                guard item.action.isValid else { return nil }
                item.title = String(item.title.prefix(maximumNameLength))
                item.displayKey = String(item.displayKey.prefix(24))
                item.systemImage = item.systemImage.map { String($0.prefix(60)) }
                kind = .shortcut(item)
            }
            var palette = placement.palette
            if var style = palette {
                style.spacing = style.spacing.isFinite
                    ? min(max(style.spacing, PalettePresentation.spacingRange.lowerBound),
                          PalettePresentation.spacingRange.upperBound) : 1
                style.directionDegrees = style.directionDegrees.flatMap { $0.isFinite ? min(max($0, -180), 180) : nil }
                palette = style
            }
            // The initializer re-clamps position and size.
            return CustomControlPlacement(id: id, kind: kind, x: placement.x, y: placement.y,
                                          size: placement.size, palette: palette)
        }
        return CustomControlArrangement(corner: arrangement.corner, placements: Array(placements))
    }

    private static func rawPlacementCount(_ json: Data) -> Int? {
        guard let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any] else { return nil }
        let count = { (key: String) -> Int in
            ((object[key] as? [String: Any])?["placements"] as? [Any])?.count ?? 0
        }
        return min(count("landscape"), maximumPlacements) + min(count("portrait"), maximumPlacements)
    }

    // MARK: Encoding helpers

    private static func checksum(_ data: Data) -> String {
        SHA256.hash(data: data).prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func data(base64URL text: String) -> Data? {
        guard text.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }), text.allSatisfy(\.isASCII) else {
            return nil
        }
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        return Data(base64Encoded: base64)
    }
}

extension ReceiverControlPreferences {
    enum CustomLayoutImportResult: Equatable {
        case imported(id: String)
        case limitReached
    }

    /// Adds an imported layout as a new layout — never overwriting one —
    /// within `CustomControlLayout.maximumCount`. A clashing name gets a
    /// number.
    mutating func importCustomLayout(_ layout: CustomControlLayout) -> CustomLayoutImportResult {
        guard canCreateCustomLayout else { return .limitReached }
        var imported = layout
        imported.id = UUID().uuidString
        let names = Set(customLayouts.map(\.name))
        if names.contains(imported.name) {
            var number = 2
            while names.contains("\(imported.name) \(number)") { number += 1 }
            imported.name = "\(imported.name) \(number)"
        }
        customLayouts.append(imported)
        return .imported(id: imported.id)
    }
}

// MARK: - Editor Preview

/// The Custom editor's Preview: the real chord state machine driving the
/// real layout geometry, with every would-be Mac command turned into a
/// display-only note. It has no way to reach a receiver or the wire.
struct CustomLayoutPreviewSession: Equatable {
    /// What Preview shows instead of sending.
    enum Feedback: Equatable {
        /// The keys that a tap would send, e.g. `⌘C`.
        case wouldSend(String)
        /// A non-keyboard action, e.g. Show Desktop.
        case wouldPerform(String)
    }

    private(set) var interaction = ControlInteractionState()
    private(set) var feedback: Feedback?

    /// Tap-to-latch, exactly like the live modifier buttons.
    mutating func tapModifier(_ modifier: ControlModifier) {
        _ = interaction.tap(modifier)
    }

    /// A helper modifier on the Two-Hand Assist side.
    mutating func tapAssistModifier(_ modifier: ControlModifier) {
        _ = interaction.toggleAssistModifier(modifier)
    }

    mutating func tapPaletteAction(_ action: ShortcutItem) {
        let chord = interaction.activeChord
        let effects = interaction.finish(with: action)
        guard effects.contains(.execute(action)) else { return }
        switch action.action {
        case .keyboardShortcut:
            feedback = .wouldSend(chord.hudText(for: action.displayKey))
        case .receiverGesture:
            feedback = .wouldPerform(action.title)
        case .sequence:
            feedback = .wouldSend(action.keysDescription)
        }
    }

    /// A one-tap control (Function action or custom shortcut).
    mutating func tapAction(_ item: ShortcutItem) {
        switch item.action {
        case .keyboardShortcut(let shortcut):
            let keys = shortcut.usages.map(appGestureCommandKeyLabel(for:)).joined(separator: "+")
            feedback = .wouldSend(shortcut.modifiers.symbols + keys)
        case .receiverGesture:
            feedback = .wouldPerform(item.title)
        case .sequence:
            feedback = .wouldSend(item.keysDescription)
        }
    }

    mutating func reset() {
        _ = interaction.resetAll()
        feedback = nil
    }
}

// MARK: - Import flow

/// Paste → Validate → review → Import, as state. The flow only finishes —
/// and the screen only closes — after a successful import (or a cancel,
/// which the view handles); every other step keeps the code editable.
struct CustomLayoutImportFlow: Equatable {
    enum Stage: Equatable {
        case entering
        case reviewing(CustomLayoutShareCode.ImportSummary)
        case failed(CustomLayoutShareCode.ShareCodeError)
        case limitReached(CustomLayoutShareCode.ImportSummary)
        case imported(id: String)
    }

    private(set) var code = ""
    private(set) var stage = Stage.entering

    var isFinished: Bool {
        if case .imported = stage { return true }
        return false
    }

    var canValidate: Bool { !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    mutating func edit(_ text: String) {
        guard text != code else { return }
        code = text
        stage = .entering
    }

    /// Paste from Clipboard: take the pasted text and validate it at once.
    mutating func paste(_ text: String?) {
        edit(text ?? "")
        if canValidate { validate() }
    }

    mutating func validate() {
        guard canValidate else { stage = .entering; return }
        switch CustomLayoutShareCode.decode(code) {
        case .success(let summary): stage = .reviewing(summary)
        case .failure(let error): stage = .failed(error)
        }
    }

    mutating func importLayout(into preferences: inout ReceiverControlPreferences) {
        let summary: CustomLayoutShareCode.ImportSummary
        switch stage {
        case .reviewing(let reviewed), .limitReached(let reviewed): summary = reviewed
        default: return
        }
        switch preferences.importCustomLayout(summary.layout) {
        case .imported(let id): stage = .imported(id: id)
        case .limitReached: stage = .limitReached(summary)
        }
    }
}
