// Performance Lab (#123): the fixture's workloads, as a pure, versioned,
// deterministic schedule. The Mac fixture window only draws what `plan(at:)`
// says; everything that decides what a frame contains lives here and is
// tested (`PerformanceLabWorkloadTests`).
//
// A workload is a cycle of segments that repeats for as long as the fixture
// is open. Time is seconds since the fixture started. A frame ID is the
// number of frames the fixture has actually changed (drawn), so a "still"
// segment keeps its ID: a static screen stays static, strip included.
//
// No user content: text is generated from a fixed syllable table and seed.
// Pure Foundation: compiled into every app target and into MacTests.

import Foundation

enum PerformanceLabSegmentKind: String, Codable, CaseIterable, Sendable {
    /// Full-frame counter: a new frame at every display refresh.
    case counter
    /// Nothing changes (drawn once at the segment start).
    case still
    /// Fine generated text scrolling at a fixed speed.
    case scrollingText
    /// Full-frame changing pattern: every cell changes every frame.
    case highMotion
    /// A small cursor-sized target moving on a fixed path over a still page.
    case cursorTarget
}

struct PerformanceLabSegment: Codable, Equatable, Sendable {
    var kind: PerformanceLabSegmentKind
    var seconds: Double
}

enum PerformanceLabWorkloadID: String, Codable, CaseIterable, Sendable {
    case frameCounter = "frame-counter"
    case staticToMotion = "static-to-motion"
    case scrollingText = "scrolling-text"
    case highMotion = "high-motion"
    case cursorTarget = "cursor-target"
    case idle = "idle"
}

/// What one fixture frame shows. Equal plans draw identical pixels.
struct PerformanceLabFramePlan: Equatable, Sendable {
    /// 0, 1, 2, … over the fixture's lifetime (the ID carries it modulo 16).
    var segmentOrdinal: Int
    var kind: PerformanceLabSegmentKind
    /// Whether this kind redraws every frame. A still segment draws once.
    var animates: Bool
    /// Text scrolled so far, in points (scrollingText).
    var scrollOffsetPoints: Double
    /// Target centre, 0...1 in the content area (cursorTarget).
    var targetX: Double
    var targetY: Double
}

struct PerformanceLabWorkload: Codable, Equatable, Sendable {
    var id: PerformanceLabWorkloadID
    /// Bump when anything that changes the pixels changes.
    var version: Int
    var seed: UInt64
    var cycle: [PerformanceLabSegment]

    static let seed: UInt64 = 0x4D65_6F77_4C61_6231
    /// Scrolling speed, points per second.
    static let scrollPointsPerSecond = 120.0
    /// Seconds per lap of the cursor target's path.
    static let targetLapSeconds = 4.0

    var cycleSeconds: Double { cycle.reduce(0) { $0 + $1.seconds } }

    static let catalog: [PerformanceLabWorkload] = [
        .init(id: .frameCounter, version: 1, seed: seed, cycle: [.init(kind: .counter, seconds: 60)]),
        .init(id: .staticToMotion, version: 1, seed: seed, cycle: [.init(kind: .still, seconds: 4), .init(kind: .highMotion, seconds: 4)]),
        .init(id: .scrollingText, version: 1, seed: seed, cycle: [.init(kind: .scrollingText, seconds: 60)]),
        .init(id: .highMotion, version: 1, seed: seed, cycle: [.init(kind: .highMotion, seconds: 60)]),
        .init(id: .cursorTarget, version: 1, seed: seed, cycle: [.init(kind: .cursorTarget, seconds: 60)]),
        .init(id: .idle, version: 1, seed: seed, cycle: [.init(kind: .still, seconds: 60)]),
    ]

    static func workload(_ id: PerformanceLabWorkloadID) -> PerformanceLabWorkload {
        catalog.first { $0.id == id }!
    }

    /// A compact, stable description of the schedule ("id@version:kind/seconds,…").
    var signature: String {
        "\(id.rawValue)@\(version):" + cycle.map { "\($0.kind.rawValue)/\(Int($0.seconds))" }.joined(separator: ",")
    }

    /// The plan at `seconds` since the fixture started. Deterministic.
    func plan(atSeconds seconds: Double) -> PerformanceLabFramePlan {
        let t = max(0, seconds)
        let cycleLength = cycleSeconds
        let lap = cycleLength > 0 ? (t / cycleLength).rounded(.down) : 0
        var inCycle = t - lap * cycleLength
        var index = 0
        while index < cycle.count - 1, inCycle >= cycle[index].seconds {
            inCycle -= cycle[index].seconds
            index += 1
        }
        let segment = cycle[index]
        let ordinal = Int(lap) * cycle.count + index
        let phase = (t / Self.targetLapSeconds).truncatingRemainder(dividingBy: 1) * 2 * Double.pi
        return PerformanceLabFramePlan(
            segmentOrdinal: ordinal,
            kind: segment.kind,
            animates: segment.kind != .still,
            scrollOffsetPoints: segment.kind == .scrollingText ? inCycle * Self.scrollPointsPerSecond : 0,
            // A Lissajous path that covers the area without leaving it.
            targetX: segment.kind == .cursorTarget ? 0.5 + 0.4 * sin(phase) : 0.5,
            targetY: segment.kind == .cursorTarget ? 0.5 + 0.4 * sin(2 * phase + Double.pi / 4) : 0.5)
    }

    // MARK: Deterministic content

    /// Colour index (0..<palette) of cell `cell` in high-motion frame `frameID`.
    static func motionCell(frameID: UInt32, cell: Int, palette: Int) -> Int {
        var rng = PerformanceLabRandom(seed: seed ^ (UInt64(frameID) << 20) ^ UInt64(cell))
        return Int(rng.next() % UInt64(max(1, palette)))
    }

    private static let syllables = [
        "ka", "lo", "mi", "ne", "su", "ta", "ri", "po", "fe", "du", "an", "el", "or", "is", "um", "ve",
        "zo", "ba", "chi", "ren", "tal", "mos", "pir", "len", "dor", "sa", "qu", "ex", "ny", "gra",
    ]

    /// `count` lines of pseudo-words from the fixed seed: fine text with
    /// ascenders, descenders and punctuation, no real content.
    static func textLines(count: Int, wordsPerLine: Int = 12) -> [String] {
        var rng = PerformanceLabRandom(seed: seed)
        var lines: [String] = []
        lines.reserveCapacity(count)
        for lineIndex in 0..<count {
            var words: [String] = []
            for w in 0..<wordsPerLine {
                let n = 1 + Int(rng.next() % 3)
                var word = (0..<n).map { _ in syllables[Int(rng.next() % UInt64(syllables.count))] }.joined()
                if w == 0 { word = word.prefix(1).uppercased() + word.dropFirst() }
                words.append(word)
            }
            let end = [".", ",", ";", ":", "?"][Int(rng.next() % 5)]
            lines.append(String(format: "%04d  ", lineIndex) + words.joined(separator: " ") + end)
        }
        return lines
    }
}

/// SplitMix64: tiny, fast and identical on every platform.
struct PerformanceLabRandom: Sendable {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
