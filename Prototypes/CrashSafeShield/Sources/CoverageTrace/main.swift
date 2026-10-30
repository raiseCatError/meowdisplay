import CoreGraphics
import Foundation

// Window-layer coverage tracer. Every few milliseconds: re-read the active displays and the
// on-screen window list; a display counts as covered when a window owned by one of --owners,
// at the shielding level or above, with full alpha, contains its whole bounds. Writes one JSON
// summary with every interval in which some display was not covered after the first full cover.
// This proves what the window server shows, not what a panel physically emits.

func value(_ name: String) -> String? {
    let a = CommandLine.arguments
    guard let i = a.firstIndex(of: name), i + 1 < a.count else { return nil }
    return a[i + 1]
}

let out = value("--out") ?? "trace.json"
let seconds = Double(value("--seconds") ?? "10") ?? 10
let owners = Set((value("--owners") ?? "ShieldKeeper,FakeSender").split(separator: ",").map(String.init))
let interval = (Double(value("--interval-ms") ?? "4") ?? 4) / 1000
let shielding = Int(CGShieldingWindowLevel())

func displays() -> [CGRect] {
    var count: UInt32 = 0
    CGGetActiveDisplayList(0, nil, &count)
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    CGGetActiveDisplayList(count, &ids, &count)
    return ids.prefix(Int(count)).map { CGDisplayBounds($0) }
}

struct Sample { let ms: Int64; let covered: Bool; let by: [String] }

let start = Date()
var samples = 0
var transitions: [[String: Any]] = []
var firstFull: Int64?
var gaps: [[String: Any]] = []
var gapStart: Int64?
var lastState: (Bool, [String])?

while Date().timeIntervalSince(start) < seconds {
    let now = Int64(Date().timeIntervalSince1970 * 1000)
    let list = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]) ?? []
    var coveringWindows: [(owner: String, rect: CGRect)] = []
    for w in list {
        guard let owner = w[kCGWindowOwnerName as String] as? String, owners.contains(owner),
              let layer = w[kCGWindowLayer as String] as? Int, layer >= shielding,
              (w[kCGWindowAlpha as String] as? Double ?? 0) > 0.99,
              let b = w[kCGWindowBounds as String] as? [String: Any],
              let rect = CGRect(dictionaryRepresentation: b as CFDictionary) else { continue }
        coveringWindows.append((owner, rect))
    }
    let screens = displays()
    var by = Set<String>()
    var all = !screens.isEmpty
    for screen in screens {
        let hits = coveringWindows.filter { $0.rect.contains(screen) }
        if hits.isEmpty { all = false }
        hits.forEach { by.insert($0.owner) }
    }
    let state = (all, by.sorted())
    if lastState == nil || lastState!.0 != state.0 || lastState!.1 != state.1 {
        transitions.append(["ms": now, "allCovered": all, "by": by.sorted(), "displays": screens.count])
        lastState = state
    }
    if all, firstFull == nil { firstFull = now }
    if firstFull != nil {
        if !all, gapStart == nil { gapStart = now }
        if all, let g = gapStart { gaps.append(["startMs": g, "endMs": now, "lengthMs": now - g]); gapStart = nil }
    }
    samples += 1
    Thread.sleep(forTimeInterval: interval)
}
if let g = gapStart { gaps.append(["startMs": g, "endMs": NSNull(), "openAtEnd": true]) }

let summary: [String: Any] = [
    "samples": samples, "seconds": seconds, "owners": owners.sorted(),
    "firstFullCoverMs": firstFull as Any? ?? NSNull(), "gaps": gaps, "transitions": transitions,
]
let data = try! JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys])
FileManager.default.createFile(atPath: out, contents: data)
print("trace: \(samples) samples, first full cover \(firstFull.map(String.init) ?? "never"), gaps \(gaps.count)")
