import SwiftUI
import UIKit

/// The phone half of "send me your logs".
///
/// The Mac app has had a Logs button since it shipped; the phone wrote the same
/// kind of log to Documents and had no way to get it out, so WiFi reports got
/// diagnosed from the Mac's side plus inference. Every line the phone knows and
/// the Mac doesn't (whether the receiver ever sent its hello, whether the
/// listener restarted, whether the decoder was failing) lived here unreachable.
struct DiagnosticsLogView: View {
    /// Rendering a whole snapshot in one `Text` is what makes this screen
    /// stutter, and nobody scrolls 256 KB on a phone anyway. The shared file
    /// carries everything; the screen carries enough to read the last session.
    private static let displayedLines = 400
    private static let bottomAnchor = "bottom"

    @AppStorage("deviceName") private var deviceName = UIDevice.current.name
    @State private var snapshot: Snapshot = .loading
    @State private var copied = false

    private enum Snapshot {
        case loading
        /// `text` is the whole snapshot (what the copy button puts on the
        /// clipboard); `display` is the trimmed version the screen draws. Both
        /// are computed once at load, because the body re-evaluates on every
        /// unrelated state change and splitting 256 KB into lines per redraw is
        /// how a log screen ends up stuttering.
        case ready(url: URL, text: String, display: String)
        case failed
    }

    var body: some View {
        content
            .navigationTitle("Connection log")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if case let .ready(url, text, _) = snapshot {
                    ToolbarItem(placement: .primaryAction) {
                        ShareLink(item: url) { Image(systemName: "square.and.arrow.up") }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            UIPasteboard.general.string = text
                            copied = true
                        } label: {
                            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        }
                        .disabled(copied)
                    }
                }
            }
            .onAppear { load() }
            .task(id: copied) {
                guard copied else { return }
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                copied = false
            }
    }

    @ViewBuilder private var content: some View {
        switch snapshot {
        case .loading:
            ProgressView()
        case let .ready(_, _, display):
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        Text(display)
                            .font(.system(.footnote, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal)
                        // Newest entries are at the bottom and are the ones
                        // worth reading, so open there, not on the header.
                        Color.clear
                            .frame(height: 1)
                            .id(Self.bottomAnchor)
                    }
                }
                .onAppear { proxy.scrollTo(Self.bottomAnchor, anchor: .bottom) }
            }
        case .failed:
            VStack(spacing: 8) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text("The log could not be read.")
                Text("Restart MeowDisplay and try again.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding()
        }
    }

    private func displayText(from text: String) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count > Self.displayedLines else { return text }
        return "(showing the last \(Self.displayedLines) lines, the shared file has all of them)\n\n"
            + lines.suffix(Self.displayedLines).joined(separator: "\n")
    }

    private func load() {
        Log.snapshot(context: context) { result in
            Task { @MainActor in
                guard let (url, text) = result else {
                    snapshot = .failed
                    return
                }
                snapshot = .ready(url: url, text: text, display: displayText(from: text))
            }
        }
    }

    private var context: LogSnapshot.Context {
        let info = Bundle.main.infoDictionary
        return LogSnapshot.Context(
            appVersion: info?["CFBundleShortVersionString"] as? String ?? "dev",
            appBuild: info?["CFBundleVersion"] as? String ?? "0",
            model: hardwareModel(),
            systemVersion: UIDevice.current.systemVersion,
            deviceName: deviceName
        )
    }

    /// "iPhone15,3" rather than `UIDevice.model`'s "iPhone". iOS hides the
    /// marketing name from apps, and the generation is what decides whether a
    /// decoder or bandwidth theory is plausible at all.
    private func hardwareModel() -> String {
        var system = utsname()
        guard uname(&system) == 0 else { return "unknown" }
        return withUnsafeBytes(of: &system.machine) { raw in
            guard let base = raw.baseAddress else { return "unknown" }
            return String(cString: base.assumingMemoryBound(to: CChar.self))
        }
    }
}
