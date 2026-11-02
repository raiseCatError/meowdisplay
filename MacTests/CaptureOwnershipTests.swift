import XCTest

/// The rules `MacSender` relies on to keep its capture stream and capture
/// start/stop lifecycle under one owner (its `queue`): a capture start
/// suspends across ScreenCaptureKit and audio-encoder calls, and a `stop()`,
/// rebuild or newer start that lands during one of those suspensions must
/// win — the suspended start may not install or keep its stream afterwards.
final class CaptureOwnershipTests: XCTestCase {
    private final class FakeStream {}

    private func reserve(_ ownership: inout CaptureOwnership<FakeStream>,
                         file: StaticString = #filePath, line: UInt = #line)
        -> CaptureOwnership<FakeStream>.Reservation? {
        switch ownership.reserveStart() {
        case .success(let reservation):
            return reservation
        case .failure(let refusal):
            XCTFail("reserve refused: \(refusal)", file: file, line: line)
            return nil
        }
    }

    func testStartInstallsThenCommitsTheLiveStream() throws {
        var ownership = CaptureOwnership<FakeStream>()
        let ticket = try XCTUnwrap(reserve(&ownership)).ticket
        XCTAssertTrue(ownership.isStartInFlight)
        let stream = FakeStream()
        XCTAssertTrue(ownership.install(stream, for: ticket))
        XCTAssertTrue(ownership.stream === stream, "frames from the starting stream are accepted")
        XCTAssertNil(ownership.liveStream, "not live until it commits")
        XCTAssertTrue(ownership.commit(ticket))
        XCTAssertTrue(ownership.liveStream === stream)
        XCTAssertFalse(ownership.isStartInFlight)
    }

    // MARK: - stop() versus a suspended start

    func testStopDuringSuspendedStartRefusesItsCommit() throws {
        var ownership = CaptureOwnership<FakeStream>()
        let ticket = try XCTUnwrap(reserve(&ownership)).ticket
        let stream = FakeStream()
        XCTAssertTrue(ownership.install(stream, for: ticket))
        // stop() lands while the start is suspended in SCStream.startCapture().
        XCTAssertTrue(ownership.stop() === stream, "stop() takes the starting stream to stop it")
        XCTAssertNil(ownership.stream)
        XCTAssertFalse(ownership.isCurrent(ticket))
        XCTAssertFalse(ownership.commit(ticket), "the start resumes and must not keep its stream")
        XCTAssertNil(ownership.liveStream)
        let abandoned = ownership.abandon(ticket)
        XCTAssertFalse(abandoned.wasCurrent, "stop() already owns the teardown")
        XCTAssertNil(abandoned.installed)
    }

    func testStopBeforeInstallRefusesTheInstall() throws {
        var ownership = CaptureOwnership<FakeStream>()
        let ticket = try XCTUnwrap(reserve(&ownership)).ticket
        XCTAssertNil(ownership.stop())
        XCTAssertFalse(ownership.install(FakeStream(), for: ticket),
                       "a start suspended in the audio-encoder reset may not install after stop()")
        XCTAssertNil(ownership.stream)
    }

    func testNothingStartsAfterStopUntilResume() throws {
        var ownership = CaptureOwnership<FakeStream>()
        _ = ownership.stop()
        XCTAssertTrue(ownership.stopped)
        XCTAssertEqual(ownership.reserveStart().refusal, .stopped)
        ownership.resume()
        XCTAssertFalse(ownership.stopped)
        let ticket = try XCTUnwrap(reserve(&ownership)).ticket
        XCTAssertTrue(ownership.install(FakeStream(), for: ticket))
        XCTAssertTrue(ownership.commit(ticket))
    }

    func testStopReleasesTheLiveStream() throws {
        var ownership = CaptureOwnership<FakeStream>()
        let ticket = try XCTUnwrap(reserve(&ownership)).ticket
        let stream = FakeStream()
        XCTAssertTrue(ownership.install(stream, for: ticket))
        XCTAssertTrue(ownership.commit(ticket))
        XCTAssertTrue(ownership.stop() === stream)
        XCTAssertNil(ownership.liveStream)
        XCTAssertNil(ownership.stop(), "a second stop has nothing left to stop")
    }

    // MARK: - Rebuilds versus a suspended start

    func testRebuildDuringSuspendedStartRefusesItsCommit() throws {
        var ownership = CaptureOwnership<FakeStream>()
        let ticket = try XCTUnwrap(reserve(&ownership)).ticket
        let stale = FakeStream()
        XCTAssertTrue(ownership.install(stale, for: ticket))
        // Video Off / reconfigure / wake recovery / a stale Extend display.
        XCTAssertTrue(ownership.releaseStream() === stale)
        XCTAssertFalse(ownership.stopped, "a rebuild is not a stop")
        XCTAssertFalse(ownership.commit(ticket))
        // The rebuild's own start proceeds normally.
        let rebuilt = try XCTUnwrap(reserve(&ownership))
        XCTAssertNil(rebuilt.superseded)
        let fresh = FakeStream()
        XCTAssertTrue(ownership.install(fresh, for: rebuilt.ticket))
        XCTAssertTrue(ownership.commit(rebuilt.ticket))
        // The stale start's late failure path changes nothing.
        XCTAssertFalse(ownership.abandon(ticket).wasCurrent)
        XCTAssertTrue(ownership.liveStream === fresh)
    }

    func testRebuildBeforeInstallRefusesTheInstall() throws {
        var ownership = CaptureOwnership<FakeStream>()
        let ticket = try XCTUnwrap(reserve(&ownership)).ticket
        XCTAssertNil(ownership.releaseStream())
        XCTAssertFalse(ownership.install(FakeStream(), for: ticket))
        XCTAssertNil(ownership.stream)
    }

    // MARK: - Overlapping starts

    func testNewerStartSupersedesASuspendedOne() throws {
        var ownership = CaptureOwnership<FakeStream>()
        let older = try XCTUnwrap(reserve(&ownership)).ticket
        let olderStream = FakeStream()
        XCTAssertTrue(ownership.install(olderStream, for: older))

        let newer = try XCTUnwrap(reserve(&ownership))
        XCTAssertTrue(newer.superseded === olderStream, "the newer start stops the older one's stream")
        XCTAssertNil(ownership.stream, "the superseded stream's frames are no longer accepted")
        XCTAssertFalse(ownership.isCurrent(older))

        let newerStream = FakeStream()
        XCTAssertTrue(ownership.install(newerStream, for: newer.ticket))
        // The older start resumes from SCStream.startCapture() after the
        // newer one installed: it can neither commit nor take the stream.
        XCTAssertFalse(ownership.commit(older))
        XCTAssertFalse(ownership.abandon(older).wasCurrent)
        XCTAssertTrue(ownership.stream === newerStream)
        XCTAssertTrue(ownership.commit(newer.ticket))
        XCTAssertTrue(ownership.liveStream === newerStream)
    }

    func testSupersededStartCannotInstallLate() throws {
        var ownership = CaptureOwnership<FakeStream>()
        let older = try XCTUnwrap(reserve(&ownership)).ticket
        let newer = try XCTUnwrap(reserve(&ownership))
        XCTAssertNil(newer.superseded, "the older start had not installed anything yet")
        XCTAssertFalse(ownership.install(FakeStream(), for: older))
        XCTAssertTrue(ownership.isCurrent(newer.ticket))
    }

    func testNoStartWhileAStreamIsLive() throws {
        var ownership = CaptureOwnership<FakeStream>()
        let ticket = try XCTUnwrap(reserve(&ownership)).ticket
        let stream = FakeStream()
        XCTAssertTrue(ownership.install(stream, for: ticket))
        XCTAssertTrue(ownership.commit(ticket))
        XCTAssertEqual(ownership.reserveStart().refusal, .streamActive)
        XCTAssertTrue(ownership.liveStream === stream, "a refused start leaves the live stream alone")
    }

    // MARK: - Failed and refused starts

    func testFailedStartGivesUpTheSlot() throws {
        var ownership = CaptureOwnership<FakeStream>()
        let ticket = try XCTUnwrap(reserve(&ownership)).ticket
        let stream = FakeStream()
        XCTAssertTrue(ownership.install(stream, for: ticket))
        // SCStream.startCapture() threw, or the commit checks (session,
        // owner, pause, media wants) refused it.
        let abandoned = ownership.abandon(ticket)
        XCTAssertTrue(abandoned.wasCurrent)
        XCTAssertTrue(abandoned.installed === stream)
        XCTAssertNil(ownership.stream)
        XCTAssertFalse(ownership.isStartInFlight)
        XCTAssertFalse(ownership.commit(ticket))
        XCTAssertNotNil(reserve(&ownership), "the next start may proceed")
    }

    // MARK: - Late callbacks for a replaced stream

    func testReleaseOnlyClearsTheMatchingStream() throws {
        var ownership = CaptureOwnership<FakeStream>()
        let ticket = try XCTUnwrap(reserve(&ownership)).ticket
        let live = FakeStream()
        XCTAssertTrue(ownership.install(live, for: ticket))
        XCTAssertTrue(ownership.commit(ticket))
        XCTAssertFalse(ownership.release(FakeStream()), "a retired stream's late stop callback")
        XCTAssertTrue(ownership.liveStream === live)
        XCTAssertTrue(ownership.release(live))
        XCTAssertNil(ownership.stream)
        XCTAssertFalse(ownership.release(live))
    }

    func testUnexpectedStopOfTheStartingStreamRefusesItsCommit() throws {
        var ownership = CaptureOwnership<FakeStream>()
        let ticket = try XCTUnwrap(reserve(&ownership)).ticket
        let stream = FakeStream()
        XCTAssertTrue(ownership.install(stream, for: ticket))
        // SCK reports the stream dead before the start commits.
        XCTAssertTrue(ownership.release(stream))
        XCTAssertFalse(ownership.commit(ticket))
        XCTAssertNotNil(reserve(&ownership), "recovery may start again")
    }

    // MARK: - QueueOwnedFlag

    func testQueueOwnedFlagMirrorsTheLastWrite() {
        let flag = QueueOwnedFlag()
        XCTAssertFalse(flag.get())
        flag.set(true)
        XCTAssertTrue(flag.get())
        flag.set(false)
        XCTAssertFalse(flag.get())
    }
}

private extension Result {
    var refusal: Failure? {
        if case .failure(let failure) = self { return failure }
        return nil
    }
}
