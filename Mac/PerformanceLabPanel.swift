// Performance Lab (#123): the panel (Settings → System → Streaming
// Diagnostics → Performance Lab…) and the one-command start.
//
// Thin UI over PerformanceLabRunController (tested). Device names appear
// in the session picker only; nothing from the UI reaches a run bundle
// except the scenario, trial count and the sanitized variant label.
//
// One-command start for an already-running QA build (tools/perf-lab
// `start`): the tool writes `performanceLabStartRequest` into this app's
// defaults and posts the Darwin notification below. A cold launch can pass
// `-performanceLabScenario <id>` instead. Either way the panel opens with
// the run at its first operator step; nothing starts streaming, opens the
// fixture or touches input without the operator. Ignored unless Streaming
// Diagnostics are on.

import AppKit
import SwiftUI
import notify

@MainActor
final class PerformanceLabPanelModel: ObservableObject {
    static let shared = PerformanceLabPanelModel()

    @Published var scenarioID = PerformanceLabScenarioCatalog.all[0].id
    @Published var trials = PerformanceLabRunPlan.defaultTrials
    @Published var variant = ""
    @Published var outputParent: URL? = PerformanceLabBundle.defaultParentFolder()
    @Published var sessionID: String?
    @Published var message: String?
    @Published private(set) var run: PerformanceLabRunController?
    @Published private(set) var selfTestFolder: URL?

    private var timer: Timer?
    private var commit: String?

    var scenario: PerformanceLabScenario? { PerformanceLabScenarioCatalog.scenario(id: scenarioID) }

    func sessions() -> [DeviceSession] {
        SenderController.shared.sessions.filter { !$0.failed }
    }

    private func recorder() -> StreamDiagnosticsRecorder? {
        let live = sessions()
        return (live.first { $0.id == sessionID } ?? live.first)?.sender.diagnostics
    }

    func start() {
        message = nil
        do {
            let plan = try PerformanceLabRunPlan.make(scenarioID: scenarioID, trials: trials, variant: variant)
            start(plan, commit: commit ?? UserDefaults.standard.string(forKey: "performanceLabCommit"))
        } catch PerformanceLabRunPlan.ValidationError.tooFewTrials(let minimum) {
            message = "A run needs at least \(minimum) trials."
        } catch {
            message = "This scenario cannot be started."
        }
    }

    func start(_ request: PerformanceLabStartRequest) {
        scenarioID = request.plan.scenario.id
        trials = request.plan.trials
        variant = request.plan.variant ?? ""
        commit = request.commit
        start(request.plan, commit: request.commit)
    }

    private func start(_ plan: PerformanceLabRunPlan, commit: String?) {
        guard run?.isRunning != true else { return }
        guard StreamDiagnosticsSwitch.shared.isEnabled else {
            message = "Turn on Streaming Diagnostics first."
            return
        }
        guard let parent = outputParent else {
            message = "Choose a folder for the run bundle."
            return
        }
        let controller = PerformanceLabRunController(dependencies: .init(
            recorder: { [weak self] in self?.recorder() },
            diagnosticsEnabled: { StreamDiagnosticsSwitch.shared.isEnabled },
            nowMs: { StreamDiagnosticsClock.nowMs() },
            now: { Date() },
            build: .current(deviceClass: .mac),
            commit: commit,
            outputParent: parent,
            fixture: { PerformanceLabFixtureWindow.shared.isOpen ? PerformanceLabFixtureWindow.shared : nil }))
        run = controller
        controller.start(plan)
        timer?.invalidate()
        // Common run-loop modes: the timer keeps firing while a menu is held
        // open or a modal panel runs, so no window is missed (the recorder
        // keeps only the last completed one).
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let run = self.run else { return }
                run.tick()
                if !run.isRunning {
                    self.timer?.invalidate()
                    self.timer = nil
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func runSelfTest() {
        guard let parent = outputParent else { return }
        do {
            selfTestFolder = try PerformanceLabSyntheticRun.run(under: parent)
            message = nil
        } catch {
            message = "The self-test could not write its bundle."
        }
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url { outputParent = url }
    }
}

struct PerformanceLabPanel: View {
    @ObservedObject var model: PerformanceLabPanelModel

    var body: some View {
        Form {
            Section("Scenario") {
                Picker("Scenario", selection: $model.scenarioID) {
                    ForEach(PerformanceLabScenarioCatalog.all) { Text(verbatim: $0.caption).tag($0.id) }
                }
                if let scenario = model.scenario {
                    Text(verbatim: scenario.purpose).font(.caption).foregroundStyle(.secondary)
                    Text(verbatim: "Warm-up \(Int(scenario.warmUpSeconds)) s, then \(Int(scenario.measuredSeconds)) s measured per trial.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Stepper(value: $model.trials, in: PerformanceLabRunPlan.minimumTrials...PerformanceLabRunPlan.maximumTrials) {
                    Text(verbatim: "Trials: \(model.trials)")
                }
                TextField("Variant label (optional, e.g. beta-on)", text: $model.variant)
                let sessions = model.sessions()
                if sessions.count > 1 {
                    Picker("Session", selection: $model.sessionID) {
                        ForEach(sessions) { Text(verbatim: $0.name).tag(Optional($0.id)) }
                    }
                }
                HStack {
                    Text(verbatim: model.outputParent?.path ?? "No folder").font(.caption).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Choose…") { model.chooseFolder() }.controlSize(.small)
                }
            }
            Section("Fixture") {
                Button("Open Fixture Window") {
                    if let scenario = model.scenario { PerformanceLabFixtureWindow.shared.open(scenario.workload) }
                }
                Text("Opens a window that draws the scenario's test pattern with a frame ID. Move it onto the streamed display.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Run") {
                if let run = model.run {
                    PerformanceLabRunView(run: run)
                }
                if model.run?.isRunning != true {
                    Button("Start Run") { model.start() }
                }
                if let message = model.message {
                    Text(verbatim: message).foregroundStyle(.red)
                }
            }
            Section("Self-test (SYNTHETIC)") {
                Button("Run Synthetic Self-Test") { model.runSelfTest() }
                if let folder = model.selfTestFolder {
                    Button("Show SYNTHETIC Bundle in Finder") { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
                }
                Text("Feeds a scripted event stream through the real recorder and run controller. It checks the harness, not performance.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Text("Run bundles hold aggregate numbers and fixed text only: no device names, window titles, addresses or screen content. They stay on this Mac. Analyse them with tools/perf-lab.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 520, minHeight: 560)
    }
}

private struct PerformanceLabRunView: View {
    @ObservedObject var run: PerformanceLabRunController

    var body: some View {
        switch run.phase {
        case .idle:
            EmptyView()
        case .waitingForOperator(let trial, let steps):
            Text(verbatim: trial.map { "Before trial \($0):" } ?? "Set up:").bold()
            ForEach(Array(steps.enumerated()), id: \.offset) { Text(verbatim: "• \($0.element)") }
            HStack {
                Button("Ready") { run.operatorReady() }.keyboardShortcut(.defaultAction)
                Button("Cancel Run") { run.cancel() }
            }
        case .warmingUp(let trial, let remaining):
            Text(verbatim: "Trial \(trial): warming up, \(remaining) s")
            Button("Cancel Run") { run.cancel() }
        case .measuring(let trial, let windows, let total):
            Text(verbatim: "Trial \(trial): measuring, window \(windows) of \(total)")
            ProgressView(value: Double(windows), total: Double(max(total, 1)))
            ForEach(Array(run.prompts.enumerated()), id: \.offset) { Text(verbatim: $0.element).bold() }
            Button("Cancel Run") { run.cancel() }
        case .finished(let folder):
            Text(verbatim: "Done: \(run.completedTrials.count) trials written.")
            trialStatuses
            Button("Show Bundle in Finder") { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
        case .failed:
            Text("The run bundle could not be written.").foregroundStyle(.red)
        case .cancelled(let folder):
            Text("Cancelled. Trials so far were kept and marked.")
            if let folder {
                Button("Show Bundle in Finder") { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
            }
        }
    }

    private var trialStatuses: some View {
        ForEach(run.completedTrials, id: \.trialIndex) { trial in
            Text(verbatim: "Trial \(trial.trialIndex): \(trial.status.rawValue)"
                 + (trial.issues.isEmpty ? "" : " (\(trial.issues.map(\.rawValue).joined(separator: ", ")))"))
                .font(.caption)
        }
    }
}

@MainActor
enum PerformanceLabPanelWindow {
    private static var window: NSWindow?

    static func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 680),
                             styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            w.title = "Performance Lab"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: PerformanceLabPanel(model: .shared))
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

@MainActor
enum PerformanceLabRemoteStart {
    static let notificationName = "com.raisecaterror.meowdisplay.performance-lab.start"
    static let requestKey = "performanceLabStartRequest"
    static let scenarioArgument = "performanceLabScenario"
    static let trialsArgument = "performanceLabTrials"
    private static var token: Int32 = NOTIFY_TOKEN_INVALID

    /// Called once at launch.
    static func install() {
        let arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        if let scenario = arguments[scenarioArgument] as? String {
            let trials = (arguments[trialsArgument] as? String).flatMap(Int.init) ?? PerformanceLabRunPlan.defaultTrials
            handle("scenario=\(scenario);trials=\(trials)")
        }
        guard token == NOTIFY_TOKEN_INVALID else { return }
        notify_register_dispatch(notificationName, &token, DispatchQueue.main) { _ in
            MainActor.assumeIsolated {
                CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication)
                guard let raw = UserDefaults.standard.string(forKey: requestKey) else { return }
                UserDefaults.standard.removeObject(forKey: requestKey)
                handle(raw)
            }
        }
    }

    private static func handle(_ raw: String) {
        guard StreamDiagnosticsSwitch.shared.isEnabled else {
            Log.info("performance lab: start request ignored, streaming diagnostics are off")
            return
        }
        guard let request = PerformanceLabStartRequest.parse(raw) else {
            Log.info("performance lab: start request rejected (unknown scenario or bad fields)")
            return
        }
        PerformanceLabPanelWindow.show()
        PerformanceLabPanelModel.shared.start(request)
    }
}
