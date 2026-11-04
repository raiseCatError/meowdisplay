// Compiled into every app target. Pure, so the format is testable without a bundle.

import Foundation

/// The app version as Settings shows it: the marketing version with the
/// build number, e.g. "2.0 (214)", so a bug report names the exact build.
enum AppVersion {
    /// This bundle's version and build.
    static var current: String {
        let info = Bundle.main.infoDictionary
        return display(version: info?["CFBundleShortVersionString"] as? String,
                       build: info?["CFBundleVersion"] as? String)
    }

    /// `version (build)`; just the version when the build is missing or the
    /// same; "dev" when there is no version at all.
    static func display(version: String?, build: String?) -> String {
        let version = trimmed(version) ?? "dev"
        guard let build = trimmed(build), build != version else { return version }
        return "\(version) (\(build))"
    }

    private static func trimmed(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}
