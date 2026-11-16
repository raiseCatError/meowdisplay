// Streaming diagnostics (#123): the versioned, redacted export.
//
// Privacy by construction: every field is a number, a bool, an enum, a
// metric id from the dictionary, or the app/OS version. Nothing from the
// session that could be free text (window titles, app names, paths, device
// or host names, addresses, SSIDs, pairing material, input, pixels) has a
// field to go into. `StreamDiagnosticsExportTests` walks the encoded JSON
// and fails on any key or string outside that set.
//
// Export is a user action only: it returns JSON data / writes one local file
// the user then shares. Nothing is uploaded.

import Foundation

enum DiagnosticsDeviceClass: String, Codable, Sendable { case mac, iPhone, iPad, unknown }

struct StreamDiagnosticsBuildInfo: Codable, Equatable, Sendable {
    /// `AppVersion.current`: marketing version and build number only.
    var appVersion: String
    var osMajor: Int
    var osMinor: Int
    var osPatch: Int
    var platform: Platform
    var deviceClass: DiagnosticsDeviceClass

    enum Platform: String, Codable, Sendable { case macOS, iOS, unknown }

    static func current(deviceClass: DiagnosticsDeviceClass, appVersion: String = AppVersion.current) -> Self {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        #if os(macOS)
        let platform = Platform.macOS
        #elseif os(iOS)
        let platform = Platform.iOS
        #else
        let platform = Platform.unknown
        #endif
        return .init(appVersion: sanitizedVersion(appVersion), osMajor: v.majorVersion, osMinor: v.minorVersion,
                     osPatch: v.patchVersion, platform: platform, deviceClass: deviceClass)
    }

    /// Keeps only what a version string is made of ("2.0 (214)", "dev").
    static func sanitizedVersion(_ raw: String) -> String {
        let allowed = CharacterSet(charactersIn: "0123456789.() -abcdefghijklmnopqrstuvwxyz")
        let filtered = String(raw.lowercased().unicodeScalars.filter { allowed.contains($0) }.prefix(32))
        return filtered.isEmpty ? "unknown" : filtered
    }
}

struct StreamDiagnosticsSessionExport: Codable, Equatable, Sendable {
    var snapshot: StreamDiagnosticsSnapshot
    var verdict: StreamDiagnosticsVerdict
}

struct StreamDiagnosticsExport: Codable, Equatable, Sendable {
    /// Bump on any breaking change to this structure.
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var metricDictionaryVersion: Int
    /// Rounded to the minute.
    var generatedAt: Date
    var build: StreamDiagnosticsBuildInfo
    var sessions: [StreamDiagnosticsSessionExport]
    var classifierThresholds: [String: Double]
    /// Fixed statements about what the numbers do not measure.
    var limitations: [String]

    static let limitationsText: [String] = [
        "AVSampleBufferDisplayLayer enqueue is counted as enqueued for presentation, not as presented.",
        "Only the experimental Metal path reports an observed presentation, and it changes timing itself.",
        "No metric measures capture-to-photon; that needs external measurement.",
        "Frame header cap is stamped at encoder submission, not at capture.",
        "Cross-device spans use a ping/pong clock offset; error is up to about half the best round trip.",
        "Byte counts are app payload, not bytes billed by a network.",
    ]

    init(sessions: [StreamDiagnosticsSnapshot], build: StreamDiagnosticsBuildInfo, now: Date = Date()) {
        schemaVersion = Self.currentSchemaVersion
        metricDictionaryVersion = StreamDiagnosticsMetricDictionary.version
        generatedAt = Date(timeIntervalSince1970: (now.timeIntervalSince1970 / 60).rounded(.down) * 60)
        self.build = build
        self.sessions = sessions.map { .init(snapshot: $0, verdict: StreamBottleneckClassifier.classify($0)) }
        classifierThresholds = StreamBottleneckClassifier.thresholds
        limitations = Self.limitationsText
    }

    func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return try encoder.encode(self)
    }

    /// Writes `meowdisplay-stream-diagnostics-<yyyyMMdd-HHmm>.json` into
    /// `directory` and returns its URL. The name carries no session data.
    func write(to directory: URL) throws -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd-HHmm"
        let url = directory.appendingPathComponent("meowdisplay-stream-diagnostics-\(formatter.string(from: generatedAt)).json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try jsonData().write(to: url, options: .atomic)
        return url
    }
}
