import CoreGraphics
import Foundation
import XCTest

/// The Mac side of display arrangement editing (Mac/DisplayArrangementService.swift), entirely
/// through fakes: the control gate, the stale-catalog check, the Mac owner's prompt, the
/// for-session apply, Keep -> permanent, every revert path, and macOS not taking the origins.
/// Nothing here touches the real display arrangement.
final class DisplayArrangementServiceTests: XCTestCase {

    // MARK: Fakes

    /// Displays in memory; `configure` moves them (optionally "snapping" like macOS).
    private final class FakeConfigurator: DisplayOriginConfigurator {
        var displays: [OverviewDisplay]
        private(set) var calls: [(origins: [UInt32: CGPoint], scope: DisplayConfigurationScope)] = []
        /// The next `configure` reports an error and changes nothing.
        var failNext = false
        /// The next `configure` lands every display this many points right of where asked.
        var snapNextBy: CGFloat?

        init(displays: [OverviewDisplay]) {
            self.displays = displays
        }

        func currentDisplays() -> [OverviewDisplay] { displays }

        func configure(origins: [UInt32: CGPoint], scope: DisplayConfigurationScope) -> Bool {
            calls.append((origins, scope))
            if failNext {
                failNext = false
                return false
            }
            let offset = snapNextBy ?? 0
            snapNextBy = nil
            for (id, origin) in origins {
                guard let index = displays.firstIndex(where: { $0.id == id }) else { continue }
                displays[index].frame.origin = CGPoint(x: origin.x + offset, y: origin.y)
            }
            return true
        }

        func origin(of id: UInt32) -> CGPoint? { displays.first { $0.id == id }?.frame.origin }
    }

    private final class FakeConfirmer: DisplayArrangementConfirming, @unchecked Sendable {
        private(set) var requests: [DisplayArrangementConfirmationRequest] = []
        private var decides: [@Sendable (DisplayArrangementDecision) -> Void] = []
        private(set) var dismissed: [UInt64] = []

        func requestConfirmation(_ request: DisplayArrangementConfirmationRequest,
                                 decide: @escaping @Sendable (DisplayArrangementDecision) -> Void) {
            requests.append(request)
            decides.append(decide)
        }

        func dismissConfirmation(token: UInt64) { dismissed.append(token) }

        /// The Mac owner answers the latest prompt.
        func answer(_ decision: DisplayArrangementDecision) { decides.last?(decision) }
    }

    private final class FakeScheduler: DisplayArrangementScheduling {
        final class Work: DisplayArrangementTimer {
            let seconds: Int
            let block: @Sendable () -> Void
            private(set) var cancelled = false
            init(seconds: Int, block: @escaping @Sendable () -> Void) {
                self.seconds = seconds
                self.block = block
            }
            func cancel() { cancelled = true }
        }

        private(set) var scheduled: [Work] = []

        func schedule(after seconds: Int, _ work: @escaping @Sendable () -> Void) -> DisplayArrangementTimer {
            let item = Work(seconds: seconds, block: work)
            scheduled.append(item)
            return item
        }

        /// Lets every live timer of `seconds` run out.
        func elapse(_ seconds: Int) {
            for item in scheduled where item.seconds == seconds && !item.cancelled {
                item.cancel()
                item.block()
            }
        }

        var live: [Work] { scheduled.filter { !$0.cancelled } }
    }

    private final class Recorder {
        var sent: [[String: Any]] = []
        var control = true

        var states: [String] { sent.compactMap { $0["state"] as? String } }
        var last: [String: Any]? { sent.last }
    }

    // MARK: Setup

    /// Main display 1 at 0,0 and display 2 to its right, both 1000x600.
    private let initial = [
        OverviewDisplay(id: 1, frame: CGRect(x: 0, y: 0, width: 1000, height: 600), isMain: true),
        OverviewDisplay(id: 2, frame: CGRect(x: 1000, y: 0, width: 1000, height: 600)),
    ]

    private struct Harness {
        let service: DisplayArrangementService
        let configurator: FakeConfigurator
        let confirmer: FakeConfirmer
        let scheduler: FakeScheduler
        let recorder: Recorder
    }

    private func makeHarness(exclusivity: DisplayArrangementExclusivity = DisplayArrangementExclusivity()) -> Harness {
        let configurator = FakeConfigurator(displays: initial)
        let confirmer = FakeConfirmer()
        let scheduler = FakeScheduler()
        let recorder = Recorder()
        let service = DisplayArrangementService(configurator: configurator, confirmer: confirmer, scheduler: scheduler,
                                                exclusivity: exclusivity, deviceName: "Test iPhone",
                                                perform: { work in work() })
        service.sendMessage = { message in recorder.sent.append(message) }
        return Harness(service: service, configurator: configurator, confirmer: confirmer, scheduler: scheduler,
                       recorder: recorder)
    }

    /// Display 2 moved to the main display's left, from the initial arrangement.
    private func requestMessage(req: Int = 1, origins: [UInt32: CGPoint] = [2: CGPoint(x: -1000, y: 0)]) -> [String: Any] {
        let edit = DisplayArrangementEdit(displays: initial)
        let base = edit.original.map { DisplayArrangeRequestMessage.BaseDisplay(id: $0.id, frame: $0.frame) }
        return DisplayArrangeRequestMessage(req: req, origins: origins, base: base).wire
    }

    private func send(_ h: Harness, _ type: String, _ message: [String: Any], granted: Bool = true) {
        let recorder = h.recorder
        h.service.handle(type: type, message: message, inputGranted: granted, controlStillAllowed: { recorder.control })
    }

    private func request(_ h: Harness, req: Int = 1, origins: [UInt32: CGPoint] = [2: CGPoint(x: -1000, y: 0)],
                         granted: Bool = true) {
        send(h, WireMessage.displayArrangeRequest, requestMessage(req: req, origins: origins), granted: granted)
    }

    private func keep(_ h: Harness, req: Int = 1, granted: Bool = true) {
        send(h, WireMessage.displayArrangeKeep, ["type": WireMessage.displayArrangeKeep, "req": req], granted: granted)
    }

    private func revert(_ h: Harness, req: Int = 1) {
        send(h, WireMessage.displayArrangeRevert, ["type": WireMessage.displayArrangeRevert, "req": req])
    }

    /// Request, the owner allows: applied for this session.
    private func applied() -> Harness {
        let h = makeHarness()
        request(h)
        h.confirmer.answer(.allow)
        return h
    }

    private let left = CGPoint(x: -1000, y: 0)
    private let right = CGPoint(x: 1000, y: 0)

    // MARK: Gate and checks

    func testARequestWithoutControlIsDeniedAndNothingIsAskedOrConfigured() {
        let h = makeHarness()
        request(h, granted: false)
        XCTAssertEqual(h.recorder.states, ["denied"])
        XCTAssertEqual(h.recorder.last?["reason"] as? String, DisplayArrangeReason.control)
        XCTAssertTrue(h.confirmer.requests.isEmpty)
        XCTAssertTrue(h.configurator.calls.isEmpty)
        XCTAssertFalse(h.service.isBusy)
    }

    func testARequestFromAStaleCatalogIsRejected() {
        let h = makeHarness()
        // The display moved on the Mac after the receiver's catalog was listed.
        h.configurator.displays[1].frame.origin = CGPoint(x: 0, y: 600)
        request(h)
        XCTAssertEqual(h.recorder.states, ["denied"])
        XCTAssertEqual(h.recorder.last?["reason"] as? String, DisplayArrangeReason.stale)
        XCTAssertTrue(h.confirmer.requests.isEmpty)
        XCTAssertTrue(h.configurator.calls.isEmpty)
    }

    func testADisplayAddedSinceTheCatalogMakesItStale() {
        let h = makeHarness()
        h.configurator.displays.append(OverviewDisplay(id: 3, frame: CGRect(x: 0, y: 600, width: 1000, height: 600)))
        request(h)
        XCTAssertEqual(h.recorder.last?["reason"] as? String, DisplayArrangeReason.stale)
        XCTAssertTrue(h.configurator.calls.isEmpty)
    }

    func testAnInvalidArrangementIsDeniedWithItsReason() {
        let h = makeHarness()
        request(h, origins: [2: CGPoint(x: 500, y: 0)])
        XCTAssertEqual(h.recorder.states, ["denied"])
        XCTAssertEqual(h.recorder.last?["reason"] as? String, "overlap")
        XCTAssertTrue(h.confirmer.requests.isEmpty)
        XCTAssertTrue(h.configurator.calls.isEmpty)
    }

    func testAMalformedRequestIsDenied() {
        let h = makeHarness()
        send(h, WireMessage.displayArrangeRequest, ["type": WireMessage.displayArrangeRequest, "req": 4, "origins": "x"])
        XCTAssertEqual(h.recorder.states, ["denied"])
        XCTAssertEqual(h.recorder.last?["req"] as? Int, 4)
        XCTAssertEqual(h.recorder.last?["reason"] as? String, DisplayArrangeReason.malformed)
        XCTAssertTrue(h.configurator.calls.isEmpty)
    }

    // MARK: The Mac owner's prompt

    func testNothingIsConfiguredBeforeTheMacOwnerAnswers() {
        let h = makeHarness()
        request(h)
        XCTAssertEqual(h.recorder.states, ["awaitingMacConfirm"])
        XCTAssertEqual(h.confirmer.requests.count, 1)
        XCTAssertTrue(h.configurator.calls.isEmpty)
        // Keep or a second request can't skip the prompt either.
        keep(h)
        XCTAssertTrue(h.configurator.calls.isEmpty)
        XCTAssertTrue(h.service.isBusy)
    }

    func testThePromptDescribesTheMoveWithTheMacsOwnData() throws {
        let h = makeHarness()
        request(h)
        let prompt = try XCTUnwrap(h.confirmer.requests.first)
        XCTAssertEqual(prompt.deviceName, "Test iPhone")
        XCTAssertEqual(prompt.changes, [.init(id: 2, before: CGRect(x: 1000, y: 0, width: 1000, height: 600), after: left)])
        let lines = DisplayArrangementSummary.lines(for: prompt) { _ in "Studio Display" }
        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines[0].hasPrefix("Studio Display"))
    }

    func testTheMacOwnerSayingNoChangesNothing() {
        let h = makeHarness()
        request(h)
        h.confirmer.answer(.deny)
        XCTAssertEqual(h.recorder.states, ["awaitingMacConfirm", "denied"])
        XCTAssertEqual(h.recorder.last?["reason"] as? String, DisplayArrangeReason.declined)
        XCTAssertTrue(h.configurator.calls.isEmpty)
        XCTAssertFalse(h.service.isBusy)
    }

    func testNoAnswerWithinSixtySecondsIsDontAllow() throws {
        let h = makeHarness()
        request(h)
        XCTAssertEqual(h.scheduler.live.map(\.seconds), [DisplayArrangeWire.confirmSeconds])
        h.scheduler.elapse(DisplayArrangeWire.confirmSeconds)
        XCTAssertEqual(h.recorder.states, ["awaitingMacConfirm", "denied"])
        XCTAssertEqual(h.recorder.last?["reason"] as? String, DisplayArrangeReason.timeout)
        XCTAssertEqual(h.confirmer.dismissed, [try XCTUnwrap(h.confirmer.requests.first).token])
        // A late click changes nothing.
        h.confirmer.answer(.allow)
        XCTAssertTrue(h.configurator.calls.isEmpty)
    }

    func testControlEndingWhileThePromptIsUpDeniesIt() {
        let h = makeHarness()
        request(h)
        h.recorder.control = false
        h.confirmer.answer(.allow)
        XCTAssertEqual(h.recorder.last?["state"] as? String, "denied")
        XCTAssertEqual(h.recorder.last?["reason"] as? String, DisplayArrangeReason.control)
        XCTAssertTrue(h.configurator.calls.isEmpty)
    }

    func testDisplaysChangingWhileThePromptIsUpMakeItStale() {
        let h = makeHarness()
        request(h)
        h.configurator.displays[1].frame.origin = CGPoint(x: 0, y: 600)
        h.confirmer.answer(.allow)
        XCTAssertEqual(h.recorder.last?["reason"] as? String, DisplayArrangeReason.stale)
        XCTAssertTrue(h.configurator.calls.isEmpty)
    }

    func testResizingAtTheSameOriginInvalidatesTheMacPrompt() {
        let h = makeHarness()
        request(h)
        h.configurator.displays[1].frame.size = CGSize(width: 600, height: 1000)
        h.confirmer.answer(.allow)
        XCTAssertEqual(h.recorder.last?["reason"] as? String, DisplayArrangeReason.stale)
        XCTAssertTrue(h.configurator.calls.isEmpty)
    }

    func testResizingDuringThePreviewRequiresANewArrangement() {
        let h = applied()
        h.configurator.displays[1].frame.size = CGSize(width: 600, height: 1000)
        keep(h)
        XCTAssertEqual(h.recorder.last?["reason"] as? String, DisplayArrangeReason.displaysChanged)
        XCTAssertFalse(h.configurator.calls.contains { $0.scope == .permanently })
    }

    func testRevertBeforeTheOwnerAnswersWithdrawsTheRequest() throws {
        let h = makeHarness()
        request(h)
        revert(h)
        XCTAssertEqual(h.recorder.states, ["awaitingMacConfirm", "denied"])
        XCTAssertEqual(h.recorder.last?["reason"] as? String, DisplayArrangeReason.requested)
        XCTAssertEqual(h.confirmer.dismissed, [try XCTUnwrap(h.confirmer.requests.first).token])
        h.confirmer.answer(.allow)
        XCTAssertTrue(h.configurator.calls.isEmpty)
    }

    func testTheSessionEndingWhileThePromptIsUpDismissesIt() throws {
        let h = makeHarness()
        request(h)
        let sentBefore = h.recorder.sent.count
        h.service.sessionEnded()
        XCTAssertEqual(h.confirmer.dismissed, [try XCTUnwrap(h.confirmer.requests.first).token])
        XCTAssertEqual(h.recorder.sent.count, sentBefore, "the receiver is gone: nothing is sent")
        h.confirmer.answer(.allow)
        XCTAssertTrue(h.configurator.calls.isEmpty)
        XCTAssertFalse(h.service.isBusy)
    }

    // MARK: Apply, keep, revert

    func testAllowAppliesForThisSessionThenKeepSavesItPermanently() throws {
        let h = applied()
        XCTAssertEqual(h.configurator.calls.count, 1)
        XCTAssertEqual(h.configurator.calls[0].origins, [2: left])
        XCTAssertEqual(h.configurator.calls[0].scope, .forSession)
        XCTAssertEqual(h.recorder.states, ["awaitingMacConfirm", "applied"])
        XCTAssertEqual(h.recorder.last?["revertIn"] as? Int, DisplayArrangeWire.revertSeconds)
        XCTAssertEqual(h.scheduler.live.map(\.seconds), [DisplayArrangeWire.revertSeconds])

        keep(h)
        XCTAssertEqual(h.configurator.calls.count, 2)
        XCTAssertEqual(h.configurator.calls[1].origins, [2: left])
        XCTAssertEqual(h.configurator.calls[1].scope, .permanently)
        XCTAssertEqual(h.recorder.states, ["awaitingMacConfirm", "applied", "kept"])
        XCTAssertEqual(h.configurator.origin(of: 2), left)
        // The revert timer is gone.
        XCTAssertTrue(h.scheduler.live.isEmpty)
        h.scheduler.elapse(DisplayArrangeWire.revertSeconds)
        XCTAssertEqual(h.configurator.calls.count, 2)
        XCTAssertFalse(h.service.isBusy)
    }

    func testNoKeepWithinFifteenSecondsReverts() {
        let h = applied()
        h.scheduler.elapse(DisplayArrangeWire.revertSeconds)
        XCTAssertEqual(h.configurator.calls.count, 2)
        XCTAssertEqual(h.configurator.calls[1].origins, [2: right])
        XCTAssertEqual(h.configurator.calls[1].scope, .forSession)
        XCTAssertEqual(h.configurator.origin(of: 2), right)
        XCTAssertEqual(h.recorder.states, ["awaitingMacConfirm", "applied", "reverted"])
        XCTAssertEqual(h.recorder.last?["reason"] as? String, DisplayArrangeReason.timeout)
        // A late Keep saves nothing.
        keep(h)
        XCTAssertEqual(h.configurator.calls.count, 2)
    }

    func testRevertPutsThePreviousArrangementBack() {
        let h = applied()
        revert(h)
        XCTAssertEqual(h.configurator.calls.last?.origins, [2: right])
        XCTAssertEqual(h.configurator.calls.last?.scope, .forSession)
        XCTAssertEqual(h.configurator.origin(of: 2), right)
        XCTAssertEqual(h.recorder.states.last, "reverted")
        XCTAssertEqual(h.recorder.last?["reason"] as? String, DisplayArrangeReason.requested)
        XCTAssertFalse(h.configurator.calls.contains { $0.scope == .permanently })
    }

    func testDisconnectingRevertsWithoutSendingAnything() {
        let h = applied()
        let sentBefore = h.recorder.sent.count
        h.service.sessionEnded()
        XCTAssertEqual(h.configurator.calls.last?.origins, [2: right])
        XCTAssertEqual(h.configurator.calls.last?.scope, .forSession)
        XCTAssertEqual(h.configurator.origin(of: 2), right)
        XCTAssertEqual(h.recorder.sent.count, sentBefore)
        XCTAssertFalse(h.service.isBusy)
        XCTAssertFalse(h.configurator.calls.contains { $0.scope == .permanently })
        // The timer firing later does nothing more.
        h.scheduler.elapse(DisplayArrangeWire.revertSeconds)
        XCTAssertEqual(h.configurator.calls.count, 2)
    }

    // MARK: Restored arrangement reported to the owner (saved Extend arrangement)

    func testDisconnectingReportsTheRestoredOrigins() {
        let h = applied()
        var restored: [[UInt32: CGPoint]] = []
        h.service.onArrangementRestored = { restored.append($0) }
        h.service.sessionEnded()
        XCTAssertEqual(restored, [[1: .zero, 2: right]])
    }

    func testTimeoutAndRevertReportTheRestoredOrigins() {
        for undo in [{ (h: Harness) in h.scheduler.elapse(DisplayArrangeWire.revertSeconds) },
                     { (h: Harness) in self.revert(h) }] {
            let h = applied()
            var restored: [[UInt32: CGPoint]] = []
            h.service.onArrangementRestored = { restored.append($0) }
            undo(h)
            XCTAssertEqual(restored, [[1: .zero, 2: right]])
        }
    }

    func testAFailedRevertReportsWhereTheDisplaysReallyAre() {
        let h = applied()
        var restored: [[UInt32: CGPoint]] = []
        h.service.onArrangementRestored = { restored.append($0) }
        h.configurator.failNext = true
        revert(h)
        XCTAssertEqual(restored, [[1: .zero, 2: left]])
    }

    func testKeepAndAnUnansweredPromptReportNothing() {
        let kept = applied()
        var restored: [[UInt32: CGPoint]] = []
        kept.service.onArrangementRestored = { restored.append($0) }
        keep(kept)
        kept.service.sessionEnded()

        let asking = makeHarness()
        asking.service.onArrangementRestored = { restored.append($0) }
        request(asking)
        asking.service.sessionEnded()
        XCTAssertTrue(restored.isEmpty)
    }

    func testKeepWithoutControlReverts() {
        let h = applied()
        keep(h, granted: false)
        XCTAssertEqual(h.recorder.states.last, "reverted")
        XCTAssertEqual(h.recorder.last?["reason"] as? String, DisplayArrangeReason.control)
        XCTAssertEqual(h.configurator.origin(of: 2), right)
        XCTAssertFalse(h.configurator.calls.contains { $0.scope == .permanently })
    }

    func testKeepAfterTheDisplaysChangedReverts() {
        let h = applied()
        h.configurator.displays[1].frame.origin = CGPoint(x: 0, y: 600)
        keep(h)
        XCTAssertEqual(h.recorder.last?["reason"] as? String, DisplayArrangeReason.displaysChanged)
        XCTAssertFalse(h.configurator.calls.contains { $0.scope == .permanently })
    }

    func testKeepForAnotherRequestIsIgnored() {
        let h = applied()
        keep(h, req: 99)
        XCTAssertEqual(h.configurator.calls.count, 1)
        XCTAssertEqual(h.recorder.states.last, "applied")
    }

    // MARK: One at a time

    func testASecondRequestWhileOneIsPendingIsBusy() {
        let h = makeHarness()
        request(h, req: 1)
        request(h, req: 2)
        XCTAssertEqual(h.recorder.states, ["awaitingMacConfirm", "denied"])
        XCTAssertEqual(h.recorder.last?["req"] as? Int, 2)
        XCTAssertEqual(h.recorder.last?["reason"] as? String, DisplayArrangeReason.busy)
        XCTAssertEqual(h.confirmer.requests.count, 1)
        // The first one goes on.
        h.confirmer.answer(.allow)
        XCTAssertEqual(h.recorder.states.last, "applied")
        XCTAssertEqual(h.recorder.last?["req"] as? Int, 1)
    }

    func testAnotherSessionsPendingRequestMakesThisOneBusy() {
        let shared = DisplayArrangementExclusivity()
        let first = makeHarness(exclusivity: shared)
        let second = makeHarness(exclusivity: shared)
        request(first)
        request(second)
        XCTAssertEqual(second.recorder.last?["reason"] as? String, DisplayArrangeReason.busy)
        XCTAssertTrue(second.confirmer.requests.isEmpty)
        // Once the first is over, the second may ask.
        first.confirmer.answer(.deny)
        request(second, req: 2)
        XCTAssertEqual(second.recorder.states.last, "awaitingMacConfirm")
    }

    func testANewRequestIsAcceptedAfterTheLastOneEnded() {
        let h = applied()
        keep(h)
        h.configurator.displays = initial
        request(h, req: 2)
        XCTAssertEqual(h.recorder.states.last, "awaitingMacConfirm")
    }

    // MARK: macOS not taking it

    func testMacOSSnappingTheOriginsIsReportedAsFailedAndUndone() {
        let h = makeHarness()
        request(h)
        h.configurator.snapNextBy = 7
        h.confirmer.answer(.allow)
        XCTAssertEqual(h.recorder.states, ["awaitingMacConfirm", "failed"])
        XCTAssertEqual(h.recorder.last?["reason"] as? String, DisplayArrangeReason.notApplied)
        XCTAssertEqual(h.configurator.origin(of: 2), right, "the previous origin is restored")
        XCTAssertEqual(h.configurator.calls.last?.scope, .forSession)
        XCTAssertFalse(h.service.isBusy)
    }

    func testAConfigurationErrorIsReportedAsFailed() {
        let h = makeHarness()
        request(h)
        h.configurator.failNext = true
        h.confirmer.answer(.allow)
        XCTAssertEqual(h.recorder.states, ["awaitingMacConfirm", "failed"])
        XCTAssertEqual(h.recorder.last?["reason"] as? String, DisplayArrangeReason.configurationError)
        XCTAssertEqual(h.configurator.origin(of: 2), right)
    }

    func testMacOSNotSavingOnKeepPutsThePreviousArrangementBackEverywhere() {
        let h = applied()
        h.configurator.snapNextBy = 7
        keep(h)
        XCTAssertEqual(h.recorder.states.last, "failed")
        XCTAssertEqual(h.configurator.origin(of: 2), right)
        XCTAssertEqual(h.configurator.calls.last?.scope, .permanently, "the saved arrangement is put back too")
    }

    // MARK: Prompt text

    func testPlacesAreDescribedRelativeToTheMainDisplay() {
        let main = CGRect(x: 0, y: 0, width: 1000, height: 600)
        XCTAssertTrue(DisplayArrangementSummary.place(CGRect(x: -1000, y: 0, width: 1000, height: 600), relativeTo: main)
            .contains("(-1000, 0)"))
        let places = [CGRect(x: -1000, y: 0, width: 1000, height: 600), CGRect(x: 1000, y: 0, width: 1000, height: 600),
                      CGRect(x: 0, y: -600, width: 1000, height: 600), CGRect(x: 0, y: 600, width: 1000, height: 600)]
            .map { DisplayArrangementSummary.place($0, relativeTo: main) }
        XCTAssertEqual(Set(places).count, 4, "left, right, above and below read differently")
    }

    func testALongListEndsWithHowManyMore() {
        let changes = (2...7).map { id in
            DisplayArrangementConfirmationRequest.Change(id: UInt32(id), before: CGRect(x: 1000, y: 0, width: 10, height: 10),
                                                         after: CGPoint(x: -10, y: 0))
        }
        let request = DisplayArrangementConfirmationRequest(token: 1, deviceName: "iPad", changes: changes,
                                                            mainFrame: CGRect(x: 0, y: 0, width: 1000, height: 600))
        XCTAssertEqual(DisplayArrangementSummary.lines(for: request) { _ in "D" }.count, 5)
    }
}
