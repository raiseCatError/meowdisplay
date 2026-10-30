import AppKit
import SwiftUI

/// Single, stable owner for every security-relevant confirmation (pairing
/// SAS, Forget Device). Neither surface is a `.sheet`/`.confirmationDialog`
/// attached to a Settings page view — those are transient (a MenuBarExtra
/// popover that only exists while open, or a MacSettingsWindow that may not
/// have been created yet), so a modifier hung off one can silently own a
/// pending confirmation with nothing on screen. These are real,
/// independently-alive AppKit objects instead, driven directly by the model
/// (`PairingPromptModel`) or the controller call site (`requestForget`),
/// never by whichever settings view instance happens to exist.
@MainActor
enum SecurityPresentationCoordinator {
    // MARK: - Pairing (SAS confirmation)

    private static var pairingPanel: NSPanel?
    // Held here, not just as `panel.delegate`, since NSWindow does not
    // retain its delegate — letting this drop would silently stop the
    // window-close-as-rejection wiring below.
    private static var pairingPanelDelegate: PairingPanelWindowDelegate?

    static func presentPairing(prompt: PairingPromptModel) {
        guard let pending = prompt.pending else { return }
        Log.info("uiDebug: pairing presentation requested peerID=\(pending.peerID)")
        // Never activated or made key: a prompt that grants something must not take the
        // keyboard from what the person at this Mac is typing (ConsentInputPolicy).

        let panel: NSPanel
        if let existing = pairingPanel {
            panel = existing
        } else {
            panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 380, height: 240),
                styleMask: [.titled, .closable, .nonactivatingPanel],
                backing: .buffered, defer: false)
            panel.title = String(localized: "Pairing Request")
            panel.isFloatingPanel = true
            panel.level = .modalPanel
            // A security decision must stay visible even if the user clicks
            // elsewhere — it may only close through explicit accept/reject
            // or the model's own timeout, never by losing focus.
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            pairingPanel = panel
            Log.info("uiDebug: pairing panel created id=\(ObjectIdentifier(panel))")
        }
        // The traffic-light close button is an explicit rejection of
        // whatever confirmation is pending when it's clicked — never a
        // no-op that leaves an invisible `pending` behind to reject the
        // next Pair attempt as a duplicate. Our own `orderOut` (below, once
        // the model resolves) does not trigger this delegate call, only an
        // actual `close()` from the window controls does, so a user close
        // and a programmatic dismiss can never be confused for each other.
        let delegate = PairingPanelWindowDelegate(prompt: prompt)
        pairingPanelDelegate = delegate
        panel.delegate = delegate
        panel.contentView = NSHostingView(rootView: PairingPanelView(prompt: prompt, onResolved: {
            Log.info("uiDebug: pairing panel closed reason=resolved")
            panel.orderOut(nil)
        }))
        panel.center()
        panel.orderFrontRegardless()
        Log.info("uiDebug: pairing panel orderedFront visible=\(panel.isVisible) keyWindow=\(panel.isKeyWindow)")
    }

    // MARK: - Input control request ("<Device Name> wants to control this Mac")

    private static var inputControlPanel: NSPanel?
    private static var inputControlPanelDelegate: InputControlPanelWindowDelegate?

    static func presentInputControlRequest(prompt: InputControlRequestPromptModel) {
        guard prompt.pending != nil else { return }
        // Never activated or made key: a prompt that grants something must not take the
        // keyboard from what the person at this Mac is typing (ConsentInputPolicy).

        let panel: NSPanel
        if let existing = inputControlPanel {
            panel = existing
        } else {
            panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 380, height: 1),
                styleMask: [.titled, .closable, .nonactivatingPanel],
                backing: .buffered, defer: false)
            panel.title = String(localized: "Control Request")
            panel.isFloatingPanel = true
            panel.level = .modalPanel
            // Same rationale as the pairing panel: a security decision must
            // stay visible until explicit action or timeout, never dismiss
            // itself on a focus change.
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            inputControlPanel = panel
        }
        let delegate = InputControlPanelWindowDelegate(prompt: prompt)
        inputControlPanelDelegate = delegate
        panel.delegate = delegate
        let hostingController = NSHostingController(rootView: InputControlRequestPanelView(prompt: prompt, onResolved: {
            panel.orderOut(nil)
        }))
        // A hardcoded `contentRect` clipped the real explanatory copy (see
        // milestone bugfix). `.preferredContentSize` instead sizes the
        // panel to the SwiftUI content's actual ideal size — computed from
        // the view's own fixed wrap width below — and re-sizes it again on
        // every future call (a fresh `NSHostingController` each time a new
        // request is presented), so a longer/shorter device name never
        // truncates or leaves the panel oddly oversized.
        hostingController.sizingOptions = [.preferredContentSize]
        panel.contentViewController = hostingController
        panel.center()
        panel.orderFrontRegardless()
    }

    // MARK: - Remote Finder ("<Device Name> wants to browse your approved folders")

    private struct FilesConsentRequest {
        let sessionID: String
        let name: String
        /// nil: browsing at all; otherwise the extra capabilities asked for.
        let capabilities: Set<FilesCapability>?
        /// False while any device has control of this Mac: a grant that outlives the session
        /// could then be clicked by that device itself.
        let alwaysAllowed: Bool
        var decide: (FilesConsentDecision) -> Void
    }

    private static var filesConsentPanel: NSPanel?
    private static var filesConsentPanelDelegate: FilesConsentPanelWindowDelegate?
    /// The request on screen (answered exactly once), then the ones waiting their turn.
    /// A new request never replaces the one on screen, so a click can't land on a
    /// different device's question.
    private static var filesConsentShown: FilesConsentRequest?
    private static var filesConsentQueue: [FilesConsentRequest] = []

    /// Asks the Mac owner whether this session may browse the approved folders. Closing the
    /// panel is Not Now. Doesn't activate the app, so the owner's front app keeps focus.
    static func presentFilesConsent(name: String, sessionID: String, capabilities: Set<FilesCapability>? = nil,
                                    alwaysAllowed: Bool, decide: @escaping (FilesConsentDecision) -> Void) {
        // The same session asking again (a new connection): its newest answer target wins.
        if filesConsentShown?.sessionID == sessionID {
            filesConsentShown?.decide = decide
            return
        }
        if let i = filesConsentQueue.firstIndex(where: { $0.sessionID == sessionID }) {
            filesConsentQueue[i].decide = decide
            return
        }
        filesConsentQueue.append(FilesConsentRequest(sessionID: sessionID, name: name, capabilities: capabilities,
                                                     alwaysAllowed: alwaysAllowed, decide: decide))
        showNextFilesConsent()
    }

    /// The session ended or its connection changed: its question no longer stands.
    static func dismissFilesConsent(sessionID: String) {
        filesConsentQueue.removeAll { $0.sessionID == sessionID }
        guard filesConsentShown?.sessionID == sessionID else { return }
        filesConsentShown = nil
        closeFilesConsentPanel()
        showNextFilesConsent()
    }

    fileprivate static func answerFilesConsent(_ decision: FilesConsentDecision) {
        guard let shown = filesConsentShown else { return }
        filesConsentShown = nil
        closeFilesConsentPanel()
        shown.decide(decision)
        // The next device's question comes as a new panel, a moment later.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { showNextFilesConsent() }
    }

    private static func closeFilesConsentPanel() {
        guard let panel = filesConsentPanel else { return }
        filesConsentPanel = nil
        panel.delegate = nil
        filesConsentPanelDelegate = nil
        panel.orderOut(nil)
        panel.close()
    }

    private static func showNextFilesConsent() {
        guard filesConsentShown == nil, !filesConsentQueue.isEmpty else { return }
        let request = filesConsentQueue.removeFirst()
        filesConsentShown = request
        // A fresh panel per question.
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 1),
            styleMask: [.titled, .closable, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.title = String(localized: "Files Request")
        panel.isFloatingPanel = true
        panel.level = .modalPanel
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        filesConsentPanel = panel
        let delegate = FilesConsentPanelWindowDelegate()
        filesConsentPanelDelegate = delegate
        panel.delegate = delegate
        let hostingController = NSHostingController(rootView: FilesConsentPanelView(
            name: request.name, capabilities: request.capabilities, alwaysAllowed: request.alwaysAllowed) { decision in
            answerFilesConsent(decision)
        })
        hostingController.sizingOptions = [.preferredContentSize]
        panel.contentViewController = hostingController
        panel.center()
        panel.orderFrontRegardless()
    }

    // MARK: - Session request ("<Device Name> wants to use this Mac as a display source")

    private static var sessionApprovalPanel: NSPanel?
    private static var sessionApprovalPanelDelegate: SessionApprovalPanelWindowDelegate?

    static func presentSessionApproval(prompt: SessionApprovalPromptModel) {
        guard prompt.current != nil else { return }
        // Never activated or made key: a prompt that grants something must not take the
        // keyboard from what the person at this Mac is typing (ConsentInputPolicy).

        let panel: NSPanel
        if let existing = sessionApprovalPanel {
            panel = existing
        } else {
            panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 380, height: 1),
                styleMask: [.titled, .closable, .nonactivatingPanel],
                backing: .buffered, defer: false)
            panel.title = String(localized: "Display Request")
            panel.isFloatingPanel = true
            panel.level = .modalPanel
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            sessionApprovalPanel = panel
        }
        let delegate = SessionApprovalPanelWindowDelegate(prompt: prompt)
        sessionApprovalPanelDelegate = delegate
        panel.delegate = delegate
        let hostingController = NSHostingController(rootView: SessionApprovalPanelView(prompt: prompt, onResolved: {
            panel.orderOut(nil)
        }))
        hostingController.sizingOptions = [.preferredContentSize]
        panel.contentViewController = hostingController
        panel.center()
        panel.orderFrontRegardless()
    }

    // MARK: - Forget Device

    // Guards against a double-presentation if requestForget is somehow
    // invoked twice for overlapping confirmations (e.g. two rows racing).
    private static var forgetAlertActive = false

    static func presentForget(_ request: ForgetConfirmation, controller: SenderController) {
        Log.info("uiDebug: forget presentation requested peerID=\(request.peerID)")
        guard !forgetAlertActive else {
            Log.info("uiDebug: forget presentation skipped reason=alreadyPresenting")
            return
        }
        forgetAlertActive = true
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = String(localized: "Forget \(request.name)?", comment: "Confirmation alert title; request.name is the paired device's name.")
        alert.informativeText = String(localized: "This removes trust, connection hints, and wake metadata for this device. It must be re-paired to connect again.")
        alert.alertStyle = .warning
        alert.addButton(withTitle: String(localized: "Forget Device", comment: "Destructive button: removes a paired device's trust."))
        alert.addButton(withTitle: String(localized: "Cancel"))
        Log.info("uiDebug: forget panel visible=true")
        // NSAlert.runModal is synchronous and does not require Dock
        // presence — it works in accessory (menu-bar-only) apps exactly
        // like it does in regular ones, unlike a SwiftUI sheet/dialog
        // attached to a MenuBarExtra popover.
        let response = alert.runModal()
        forgetAlertActive = false
        if response == .alertFirstButtonReturn {
            controller.confirmForget(request)
        } else {
            controller.cancelForget(request)
        }
    }
}

/// Treats the user closing the pairing panel via its window controls as an
/// explicit rejection of the pending confirmation (see the invariant in
/// `SecurityPresentationCoordinator.presentPairing`).
@MainActor
private final class PairingPanelWindowDelegate: NSObject, NSWindowDelegate {
    private weak var prompt: PairingPromptModel?

    init(prompt: PairingPromptModel) {
        self.prompt = prompt
    }

    func windowWillClose(_ notification: Notification) {
        Log.info("uiDebug: pairing panel closed reason=windowClosed")
        prompt?.windowClosedByUser()
    }
}

/// The pairing panel's content. Observes the shared `PairingPromptModel`
/// directly rather than receiving a snapshot, so it always reflects the
/// live pending confirmation and disappears the instant it resolves —
/// whether by user action here, a duplicate-request rejection, or timeout.
private struct PairingPanelView: View {
    @ObservedObject var prompt: PairingPromptModel
    let onResolved: () -> Void
    @State private var armed = false

    var body: some View {
        Group {
            if let pending = prompt.pending {
                VStack(spacing: 16) {
                    switch pending.classification {
                    case .newPeer:
                        Text("Pair with \(pending.peerName)?").font(.headline)
                    case .rePairSameKey:
                        Text("\(pending.peerName) is already paired with this Mac.")
                            .font(.headline)
                        Text("The device is requesting to pair again.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    case .identityChanged:
                        Text("This device's cryptographic identity has changed.")
                            .font(.headline)
                        Text("Re-pair only if you trust \(pending.peerName) — its saved key no longer matches.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    Text(pending.sas).font(.system(.title, design: .monospaced)).bold()
                    VStack(spacing: 2) {
                        Text(PairingCopy.sasTitle).font(.subheadline.weight(.semibold))
                        Text(PairingCopy.sasHelper).font(.caption).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    HStack {
                        Button("Cancel", role: .cancel) { prompt.decide(accept: false) }
                            .keyboardShortcut(.cancelAction)
                        Button(pending.classification == .newPeer ? "Codes Match" : "Re-pair") {
                            if ConsentGrant.allowed() { prompt.decide(accept: true) }
                        }
                        .disabled(prompt.isAuthenticating || !armed)
                    }
                }
                .padding(24)
            } else if let confirmed = prompt.confirmedLocally {
                VStack(spacing: 12) {
                    ProgressView()
                    Text(PairingCopy.waitingTitle).font(.headline)
                    Text(PairingCopy.waitingHelper(
                        otherDevice: PairingCopy.otherDevice(localIsMac: true, peerName: confirmed.peerName)))
                        .font(.subheadline).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    if !prompt.isCommitting {
                        Button("Cancel", role: .cancel) { prompt.cancelWaiting() }
                    }
                }
                .padding(24)
            } else {
                Color.clear.frame(width: 1, height: 1)
            }
        }
        .frame(minWidth: 360)
        // Stays open while waiting for the other device; closes only when the
        // attempt has neither a pending SAS nor a local confirmation.
        .modifier(ArmsAfterDelay(armed: $armed, key: prompt.pending?.id))
        .onChange(of: prompt.pending == nil && prompt.confirmedLocally == nil) { _, ended in
            if ended { onResolved() }
        }
    }
}

/// Treats the user closing the input-control-request panel via its window
/// controls as an explicit "Not Now" (spec: "Dismissal of the prompt ==
/// Not Now") — mirrors `PairingPanelWindowDelegate` exactly.
@MainActor
private final class InputControlPanelWindowDelegate: NSObject, NSWindowDelegate {
    private weak var prompt: InputControlRequestPromptModel?

    init(prompt: InputControlRequestPromptModel) {
        self.prompt = prompt
    }

    func windowWillClose(_ notification: Notification) {
        prompt?.windowClosedByUser()
    }
}

/// "<Device Name> wants to control this Mac" — Not Now / Allow for This
/// Session / Never Allow Requests are equal-weight choices; "Always Allow
/// This Device" is deliberately set apart (extra spacing + a distinct
/// tinted style) so it reads as a separate, higher-impact decision rather
/// than a fourth equivalent button — see the milestone spec's requirement
/// that it never be the easy/default click.
private struct InputControlRequestPanelView: View {
    @ObservedObject var prompt: InputControlRequestPromptModel
    let onResolved: () -> Void
    @State private var armed = false

    var body: some View {
        Group {
            if let pending = prompt.pending {
                VStack(spacing: 20) {
                    VStack(spacing: 6) {
                        Text("\(pending.name) wants to control this Mac")
                            .font(.headline)
                            .fixedSize(horizontal: false, vertical: true)
                            .multilineTextAlignment(.center)
                        Text("It can move the pointer, type, and use touch/scroll input until you turn this off.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .multilineTextAlignment(.center)
                    }
                    VStack(spacing: 8) {
                        Button("Allow for This Session") { if ConsentGrant.allowed() { prompt.decide(.allowSession) } }
                            .disabled(!armed)
                        HStack(spacing: 8) {
                            Button("Not Now") { prompt.decide(.notNow) }
                                .keyboardShortcut(.cancelAction)
                            Button("Never Allow Requests") { prompt.decide(.neverAllowRequests) }
                        }
                    }
                    Divider()
                    VStack(spacing: 4) {
                        Button("Always Allow This Device") { if ConsentGrant.allowed() { prompt.decide(.alwaysAllowDevice) } }
                            .foregroundStyle(.orange)
                            .disabled(!armed)
                        Text("Skips this prompt for future requests from this device. Change anytime in Settings.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .multilineTextAlignment(.center)
                    }
                }
                .padding(24)
                // A fixed wrap width, not `.frame(minWidth:)`: without an
                // explicit width, SwiftUI reports each `Text`'s ideal
                // (unwrapped, single-line) size to the hosting panel below,
                // which then clipped the real explanatory copy to a
                // narrower fixed `contentRect` instead of wrapping it. This
                // width is also what `NSHostingController.sizingOptions`
                // reads back to size the panel's actual window.
                .frame(width: 340)
            } else {
                Color.clear.frame(width: 1, height: 1)
            }
        }
        .modifier(ArmsAfterDelay(armed: $armed, key: prompt.pending?.generation))
        .onChange(of: prompt.pending) { _, newValue in
            if newValue == nil { onResolved() }
        }
    }
}

/// Closing the session-request panel is Reject for This Session.
@MainActor
private final class SessionApprovalPanelWindowDelegate: NSObject, NSWindowDelegate {
    private weak var prompt: SessionApprovalPromptModel?

    init(prompt: SessionApprovalPromptModel) {
        self.prompt = prompt
    }

    func windowWillClose(_ notification: Notification) {
        prompt?.windowClosedByUser()
    }
}

/// A paired receiver asked this Mac to start sharing. Allow & Extend / Allow
/// & Mirror approve this request only; Allow Permanently skips this prompt
/// for future requests from the device (never input, never a mode); the
/// reject choices are set apart below.
private struct SessionApprovalPanelView: View {
    @ObservedObject var prompt: SessionApprovalPromptModel
    @State private var armed = false
    let onResolved: () -> Void

    var body: some View {
        Group {
            if let pending = prompt.current {
                VStack(spacing: 20) {
                    VStack(spacing: 6) {
                        Text("\(pending.peerName) wants to use this Mac as a display source")
                            .font(.headline)
                            .fixedSize(horizontal: false, vertical: true)
                            .multilineTextAlignment(.center)
                        Text("Remote input stays off until you allow it.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .multilineTextAlignment(.center)
                    }
                    VStack(spacing: 8) {
                        HStack(spacing: 8) {
                            Button("Allow & Mirror") { if ConsentGrant.allowed() { prompt.decide(.allowMirror, for: pending.id) } }
                                .disabled(!armed)
                            Button("Allow & Extend") { if ConsentGrant.allowed() { prompt.decide(.allowExtend, for: pending.id) } }
                                .disabled(!armed)
                        }
                        Button("Allow Permanently") { if ConsentGrant.allowed() { prompt.decide(.allowPermanently, for: pending.id) } }
                            .disabled(!armed)
                        Text("Future requests from this device connect automatically. Change anytime in Settings.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .multilineTextAlignment(.center)
                    }
                    Divider()
                    HStack(spacing: 8) {
                        Button("Reject for This Session") { prompt.decide(.rejectForSession, for: pending.id) }
                            .keyboardShortcut(.cancelAction)
                        Button("Reject Permanently") { prompt.decide(.rejectPermanently, for: pending.id) }
                            .foregroundStyle(.red)
                    }
                }
                .padding(24)
                .frame(width: 360)
            } else {
                Color.clear.frame(width: 1, height: 1)
            }
        }
        .modifier(ArmsAfterDelay(armed: $armed, key: prompt.current?.id))
        .onChange(of: prompt.current) { _, newValue in
            if newValue == nil { onResolved() }
        }
    }
}

/// Closing the Remote Finder panel with its window controls is Not Now.
@MainActor
private final class FilesConsentPanelWindowDelegate: NSObject, NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        SecurityPresentationCoordinator.answerFilesConsent(.deny)
    }
}

/// "<Device Name> wants to browse your approved folders": Allow for This Session / Not Now.
private struct FilesConsentPanelView: View {
    let name: String
    let capabilities: Set<FilesCapability>?
    let alwaysAllowed: Bool
    let decide: (FilesConsentDecision) -> Void
    /// The buttons wake up a moment after the panel appears, so a click meant for whatever
    /// was under the pointer can't answer it.
    @State private var armed = false
    /// Second step for the broad choice: its scope and risk, confirmed separately.
    @State private var confirmingAll = false

    private var title: String {
        guard let caps = capabilities else { return String(localized: "\(name) wants to browse your files") }
        let what = caps.sorted().map { Self.verb($0) }.joined(separator: ", ")
        return String(localized: "\(name) wants to \(what)")
    }

    static func verb(_ c: FilesCapability) -> String {
        switch c {
        case .browse: return String(localized: "browse files")
        case .download: return String(localized: "save copies of files")
        case .upload: return String(localized: "add files and folders")
        case .modify: return String(localized: "rename, move and copy files")
        case .delete: return String(localized: "move files to the Trash")
        }
    }

    var body: some View {
        VStack(spacing: 18) {
            if confirmingAll {
                VStack(spacing: 6) {
                    Text("Allow \(name) to read all your accessible files?")
                        .font(.headline).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                    Text("From now on it can browse, preview and save copies of everything in your home folder and on connected drives that macOS lets MeowDisplay read — without asking again, until you change it in Settings ▸ Devices. ~/Library, other users' files and protected locations stay out of reach, and macOS may still ask you before MeowDisplay reads Desktop, Documents, Downloads or a drive. It can't change or delete anything unless you allow that separately.")
                        .font(.subheadline).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 8) {
                    Button("Back") { confirmingAll = false }.keyboardShortcut(.cancelAction)
                    Button("Allow All Accessible Files") { if ConsentGrant.allowed() { decide(.alwaysAllAccessible) } }.disabled(!armed)
                }
            } else {
                VStack(spacing: 6) {
                    Text(title)
                        .font(.headline)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.center)
                    Text(capabilities == nil
                         ? "It can see the files in the folders you approved in MeowDisplay Settings, preview them and save copies on the device. It can't change anything. Opening a file on this Mac also needs control."
                         : "Only in the folders it may browse. Replaced and deleted items go to the Trash.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.center)
                    if !alwaysAllowed {
                        Text("Always Allow isn't available while a device controls this Mac.")
                            .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                }
                VStack(spacing: 8) {
                    HStack(spacing: 8) {
                        Button("Not Now") { decide(.deny) }
                            .keyboardShortcut(.cancelAction)
                        Button("Allow This Session") { if ConsentGrant.allowed() { decide(.session) } }
                            .disabled(!armed)
                    }
                    if capabilities == nil {
                        HStack(spacing: 8) {
                            Button("Always Allow Approved Folders") { if ConsentGrant.allowed() { decide(.alwaysSelectedFolders) } }
                                .disabled(!armed || !alwaysAllowed)
                            Button("All Files…") { confirmingAll = true }
                                .disabled(!armed || !alwaysAllowed)
                        }
                    } else {
                        Button("Always Allow for This Device") { if ConsentGrant.allowed() { decide(.alwaysSelectedFolders) } }
                            .disabled(!armed || !alwaysAllowed)
                    }
                }
            }
        }
        .padding(24)
        .frame(width: 420)
        .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { armed = true } }
        .onChange(of: confirmingAll) { _, _ in
            armed = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { armed = true }
        }
    }
}


/// Grant buttons answer only to the person at this Mac (ConsentInputPolicy): a press made by
/// input a device injected is ignored and logged.
@MainActor
enum ConsentGrant {
    static func allowed() -> Bool {
        let pid = NSApp.currentEvent?.cgEvent?.getIntegerValueField(.eventSourceUnixProcessID)
        guard ConsentInputPolicy.acceptsGrant(sourcePID: pid) else {
            Log.info("SECURITY: a grant button was pressed by injected input; ignored")
            NSSound.beep()
            return false
        }
        return true
    }
}

/// Grant buttons wake up `ConsentInputPolicy.armDelay` after a prompt appears, and again after
/// it changes to another request, so a click or key meant for something else can't answer it.
struct ArmsAfterDelay<Key: Equatable>: ViewModifier {
    @Binding var armed: Bool
    let key: Key

    func body(content: Content) -> some View {
        content
            .onAppear { arm() }
            .onChange(of: key) { _, _ in
                armed = false
                arm()
            }
    }

    private func arm() {
        DispatchQueue.main.asyncAfter(deadline: .now() + ConsentInputPolicy.armDelay) { armed = true }
    }
}
