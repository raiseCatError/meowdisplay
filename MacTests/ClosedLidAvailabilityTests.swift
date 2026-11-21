import XCTest

final class ClosedLidActionGateTests: XCTestCase {
    @MainActor
    func testSystemTerminationDiscardsOrdinaryQuitWithoutCancellingTheAction() async {
        let gate = ClosedLidActionGate()
        XCTAssertTrue(gate.begin())
        XCTAssertTrue(gate.deferQuitIfPending { XCTFail("A superseded ordinary Quit must not prompt or reply again") })
        gate.discardDeferredQuit()
        XCTAssertTrue(gate.pending, "Discarding a continuation does not cancel authorization")
        XCTAssertFalse(gate.begin())
        gate.finish()
        XCTAssertFalse(gate.pending)
    }
    @MainActor
    func testQuitWaitsForActionCompletionAndRunsOnlyOnce() async {
        let gate = ClosedLidActionGate()
        var replies = 0
        var ownershipRecorded = false
        XCTAssertTrue(gate.begin())
        XCTAssertFalse(gate.begin(), "A second privileged operation must not start")
        XCTAssertTrue(gate.deferQuitIfPending {
            XCTAssertTrue(ownershipRecorded, "Quit must follow write read-back and ownership recording")
            XCTAssertFalse(gate.pending)
            replies += 1
        })
        XCTAssertTrue(gate.deferQuitIfPending { XCTFail("Repeated Quit must not enqueue another reply") })
        XCTAssertEqual(replies, 0)
        ownershipRecorded = true
        gate.finish()
        gate.finish()
        XCTAssertEqual(replies, 1)
    }

    @MainActor
    func testIdleQuitDoesNotDeferAndCancelledActionCanFinishWithoutOwnership() async {
        let gate = ClosedLidActionGate()
        XCTAssertFalse(gate.deferQuitIfPending { XCTFail("Idle quit runs on its normal path") })
        XCTAssertTrue(gate.begin())
        var finished = false
        XCTAssertTrue(gate.deferQuitIfPending { finished = true })
        // Cancellation/failure also settles the writer; no ownership is needed to quit.
        gate.finish()
        XCTAssertTrue(finished)
        XCTAssertTrue(gate.begin(), "A completed operation must not leave the gate stuck")
        gate.finish()
    }
}

// Fakes only: no test reads or changes the real Mac's power settings.

private final class FakeSleepSetting: SleepDisabledReading, SleepDisabledWriting {
    /// nil = unreadable.
    var value: Bool? = false
    var writeResult: SleepSettingWriteResult = .success
    /// When false, a "successful" write doesn't change the value.
    var writeApplies = true
    /// Makes the read right after a write fail.
    var failReadAfterWrite = false
    private(set) var writes: [Bool] = []
    private var justWrote = false

    func readSleepDisabled() -> Bool? {
        if justWrote && failReadAfterWrite { justWrote = false; return nil }
        justWrote = false
        return value
    }

    func setSleepDisabled(_ disabled: Bool) -> SleepSettingWriteResult {
        writes.append(disabled)
        justWrote = true
        if writeResult == .success && writeApplies { value = disabled }
        return writeResult
    }
}

private struct FakeUtilities: PowerUtilityDetecting {
    var names: [String] = []
    func runningPowerUtilities() -> [String] { names }
}

private final class MemoryOwnershipStore: ClosedLidOwnershipStore {
    var record: ClosedLidOwnershipRecord?
}

final class ClosedLidAvailabilityTests: XCTestCase {
    private var setting: FakeSleepSetting!
    private var store: MemoryOwnershipStore!
    private var boot: String? = "boot-A"

    override func setUp() {
        setting = FakeSleepSetting()
        store = MemoryOwnershipStore()
        boot = "boot-A"
    }

    private func model(utilities: [String] = []) -> ClosedLidAvailabilityModel {
        ClosedLidAvailabilityModel(reader: setting, writer: setting,
                                   utilities: FakeUtilities(names: utilities), store: store,
                                   now: { Date(timeIntervalSince1970: 1_000) },
                                   bootSession: { [unowned self] in self.boot })
    }

    // MARK: Reading and ownership

    func testRefreshOffWhenSleepEnabled() {
        let m = model()
        m.refresh()
        XCTAssertEqual(m.state, .off)
        XCTAssertFalse(m.state.preventsSleep)
    }

    func testExternallyDisabledSleepShowsActiveButNotOwned() {
        setting.value = true
        let m = model()
        m.refresh()
        XCTAssertEqual(m.state, .onExternally)
        XCTAssertTrue(m.state.preventsSleep, "must not show Off while the Mac can't sleep")
        XCTAssertFalse(m.ownsSetting)
    }

    func testUnreadableValueIsUnknownAndNeverWrites() {
        setting.value = nil
        let m = model()
        m.enable()
        XCTAssertEqual(m.state, .unknown)
        XCTAssertEqual(m.notice, .readFailed)
        m.disable(confirmedDespiteUtilities: true)
        XCTAssertTrue(setting.writes.isEmpty)
    }

    // MARK: Enable

    func testEnableFromOffWritesAndClaimsOwnership() {
        let m = model()
        m.enable()
        XCTAssertEqual(setting.writes, [true])
        XCTAssertEqual(m.state, .onByMEOW)
        XCTAssertEqual(store.record, ClosedLidOwnershipRecord(enabledAt: Date(timeIntervalSince1970: 1_000),
                                                              priorSleepDisabled: false, bootSessionUUID: "boot-A"))
    }

    func testEnableWhenAlreadyOnExternallyDoesNotWriteOrClaim() {
        setting.value = true
        let m = model()
        m.enable()
        XCTAssertTrue(setting.writes.isEmpty)
        XCTAssertNil(store.record)
        XCTAssertEqual(m.state, .onExternally)
        XCTAssertEqual(m.notice, .alreadyOnExternally)
    }

    func testEnableIsIdempotentWhenAlreadyOwned() {
        let m = model()
        m.enable()
        m.enable()
        XCTAssertEqual(setting.writes, [true])
    }

    func testCancelledAuthorizationChangesNothing() {
        setting.writeResult = .cancelled
        let m = model()
        m.enable()
        XCTAssertEqual(m.state, .off)
        XCTAssertNil(store.record)
        XCTAssertEqual(m.notice, .authorizationCancelled)
    }

    func testFailedWriteReportsAndDoesNotClaim() {
        setting.writeResult = .failed("denied")
        let m = model()
        m.enable()
        XCTAssertEqual(m.state, .off)
        XCTAssertNil(store.record)
        XCTAssertEqual(m.notice, .writeFailed("denied"))
    }

    func testSuccessfulWriteThatDidNotApplyIsReported() {
        setting.writeApplies = false
        let m = model()
        m.enable()
        XCTAssertEqual(m.state, .off)
        XCTAssertNil(store.record)
        XCTAssertEqual(m.notice, .notApplied)
    }

    func testUnverifiableWriteIsNotClaimedAndLaterShowsExternal() {
        setting.failReadAfterWrite = true
        let m = model()
        m.enable()
        XCTAssertNil(store.record, "ownership needs a verified read")
        XCTAssertEqual(m.notice, .readFailed)
        m.refresh()
        XCTAssertEqual(m.state, .onExternally, "never restored blindly")
    }

    // MARK: Disable / restore

    func testDisableRestoresOwnedSetting() {
        let m = model()
        m.enable()
        m.disable()
        XCTAssertEqual(setting.writes, [true, false])
        XCTAssertEqual(m.state, .off)
        XCTAssertNil(store.record)
    }

    func testDisableNeverTouchesExternalSetting() {
        setting.value = true
        let m = model()
        m.disable(confirmedDespiteUtilities: true)
        XCTAssertTrue(setting.writes.isEmpty)
        XCTAssertEqual(m.state, .onExternally)
        XCTAssertEqual(setting.value, true)
    }

    func testDisableWithPowerUtilityRunningAsksFirst() {
        let m = model(utilities: ["Amphetamine"])
        m.enable()
        m.disable()
        XCTAssertEqual(setting.writes, [true], "no restore without confirmation")
        XCTAssertEqual(m.notice, .confirmRestoreWithUtilities(["Amphetamine"]))
        XCTAssertEqual(m.state, .onByMEOW)
        m.disable(confirmedDespiteUtilities: true)
        XCTAssertEqual(setting.writes, [true, false])
        XCTAssertEqual(m.state, .off)
    }

    func testCancelledRestoreKeepsOwnership() {
        let m = model()
        m.enable()
        setting.writeResult = .cancelled
        m.disable()
        XCTAssertEqual(m.state, .onByMEOW)
        XCTAssertNotNil(store.record)
        XCTAssertEqual(m.notice, .authorizationCancelled)
    }

    func testRestoreThatDidNotApplyKeepsOwnership() {
        let m = model()
        m.enable()
        setting.writeApplies = false
        m.disable()
        XCTAssertEqual(m.state, .onByMEOW)
        XCTAssertNotNil(store.record)
        XCTAssertEqual(m.notice, .notApplied)
    }

    func testRestoreFailsClosedWhenValueBecomesUnreadable() {
        let m = model()
        m.enable()
        setting.value = nil
        m.disable(confirmedDespiteUtilities: true)
        XCTAssertEqual(setting.writes, [true])
        XCTAssertNotNil(store.record)
        XCTAssertEqual(m.notice, .readFailed)
    }

    // MARK: External changes, relaunch, crash recovery

    func testExternalRestoreWhileOwnedDropsClaimWithoutWriting() {
        let m = model()
        m.enable()
        setting.value = false // e.g. `sudo pmset -a disablesleep 0` or a restart reset it
        m.refresh()
        XCTAssertEqual(m.state, .off)
        XCTAssertNil(store.record)
        XCTAssertEqual(m.notice, .restoredOutsideMEOW)
        // Then another tool turns it on again: MEOW must not consider it its own.
        setting.value = true
        m.refresh()
        XCTAssertEqual(m.state, .onExternally)
        m.disable(confirmedDespiteUtilities: true)
        XCTAssertEqual(setting.writes, [true])
    }

    func testRelaunchAfterCrashRestoresOwnedStateFromRecord() {
        model().enable()
        // New process: fresh model, same persisted record and OS value.
        let relaunched = model()
        relaunched.refresh()
        XCTAssertEqual(relaunched.state, .onByMEOW)
        relaunched.disable()
        XCTAssertEqual(setting.value, false)
        XCTAssertNil(store.record)
    }

    func testRefreshIgnoredWhileAuthorizing() {
        // Re-entry: the writer triggers a refresh mid-write; the model stays consistent.
        final class ReentrantWriter: SleepDisabledWriting {
            weak var model: ClosedLidAvailabilityModel?
            let setting: FakeSleepSetting
            init(setting: FakeSleepSetting) { self.setting = setting }
            func setSleepDisabled(_ disabled: Bool) -> SleepSettingWriteResult {
                model?.refresh()
                XCTAssertEqual(model?.state, .authorizing)
                return setting.setSleepDisabled(disabled)
            }
        }
        let writer = ReentrantWriter(setting: setting)
        let m = ClosedLidAvailabilityModel(reader: setting, writer: writer,
                                           utilities: FakeUtilities(), store: store, bootSession: { "boot-A" })
        writer.model = m
        m.enable()
        XCTAssertEqual(m.state, .onByMEOW)
    }

    func testUserDefaultsStoreRoundTrip() throws {
        let suite = "ClosedLidTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let s = UserDefaultsClosedLidOwnershipStore(defaults: defaults)
        XCTAssertNil(s.record)
        let r = ClosedLidOwnershipRecord(enabledAt: Date(timeIntervalSince1970: 5), priorSleepDisabled: false)
        s.record = r
        XCTAssertEqual(UserDefaultsClosedLidOwnershipStore(defaults: defaults).record, r)
        s.record = nil
        XCTAssertNil(defaults.data(forKey: UserDefaultsClosedLidOwnershipStore.key))
    }

    // MARK: pmset parsing and the write command

    func testParsesPmsetOutput() {
        let on = "System-wide power settings:\n SleepDisabled\t\t1\nCurrently in use:\n sleep 1\n"
        let off = "System-wide power settings:\n SleepDisabled\t\t0\n"
        XCTAssertEqual(PmsetSettingsParser.sleepDisabled(fromPmsetOutput: on), true)
        XCTAssertEqual(PmsetSettingsParser.sleepDisabled(fromPmsetOutput: off), false)
    }

    func testMissingLineOnNormalOutputMeansNeverSet() {
        // pmset prints SleepDisabled only once it has been stored.
        XCTAssertEqual(PmsetSettingsParser.sleepDisabled(fromPmsetOutput: "Currently in use:\n sleep 1\n"), false)
        XCTAssertEqual(PmsetSettingsParser.sleepDisabled(fromPmsetOutput:
            "System-wide power settings:\nCurrently in use:\n standby 1\n"), false)
    }

    func testMissingOrMalformedPmsetValueIsUnreadable() {
        XCTAssertNil(PmsetSettingsParser.sleepDisabled(fromPmsetOutput: ""))
        XCTAssertNil(PmsetSettingsParser.sleepDisabled(fromPmsetOutput: "pmset: unexpected output\n"))
        XCTAssertNil(PmsetSettingsParser.sleepDisabled(fromPmsetOutput: " SleepDisabled\t\tmaybe\n"))
        XCTAssertNil(PmsetSettingsParser.sleepDisabled(fromPmsetOutput: " SleepDisabledX 1\n"))
    }

    func testWriteCommandIsFixedAndScoped() {
        let on = AdministratorPromptSleepDisabledWriter.script(disabled: true)
        let off = AdministratorPromptSleepDisabledWriter.script(disabled: false)
        XCTAssertTrue(on.hasPrefix("do shell script \"/usr/bin/pmset -a disablesleep 1\""))
        XCTAssertTrue(off.hasPrefix("do shell script \"/usr/bin/pmset -a disablesleep 0\""))
        XCTAssertTrue(on.hasSuffix("with administrator privileges"))
        for s in [on, off] {
            XCTAssertFalse(s.contains(";"))
            XCTAssertFalse(s.contains("&&"))
            XCTAssertFalse(s.contains("sudo"))
        }
    }

    // MARK: Review follow-ups

    func testARecordFromBeforeARestartIsNotTrusted() {
        model().enable()
        boot = "boot-B"   // restarted; something may have set 1 since
        let m = model()
        m.refresh()
        XCTAssertEqual(m.state, .onExternally, "never claims a value it can't vouch for")
        XCTAssertNil(store.record)
        m.disable(confirmedDespiteUtilities: true)
        XCTAssertEqual(setting.writes, [true], "and never clears it without an explicit request")
    }

    func testALegacyRecordWithoutABootSessionStillCounts() {
        setting.value = true
        store.record = ClosedLidOwnershipRecord(enabledAt: Date(), priorSleepDisabled: false)
        let m = model()
        m.refresh()
        XCTAssertEqual(m.state, .onByMEOW)
    }

    func testExternalRestoreNeedsAnExplicitConfirmation() {
        setting.value = true
        let m = model()
        m.requestExternalRestore()
        XCTAssertEqual(m.notice, .confirmExternalRestore)
        XCTAssertTrue(setting.writes.isEmpty, "asking writes nothing")
        m.restoreExternalAfterConfirmation()
        XCTAssertEqual(setting.writes, [false])
        XCTAssertEqual(m.state, .off)
        XCTAssertNil(m.notice)
    }

    func testExternalRestoreCancelledOrNotApplicable() {
        setting.value = true
        setting.writeResult = .cancelled
        let m = model()
        m.restoreExternalAfterConfirmation()
        XCTAssertEqual(m.state, .onExternally)
        XCTAssertEqual(m.notice, .authorizationCancelled)
        // Not for a value MEOW owns (that's `disable`) or one that is off.
        let owned = model()
        setting.writeResult = .success
        setting.value = false
        owned.enable()
        owned.requestExternalRestore()
        XCTAssertNil(owned.notice)
        let writes = setting.writes
        owned.restoreExternalAfterConfirmation()
        XCTAssertEqual(setting.writes, writes)
    }

    func testAStaleRestoreConfirmationIsCleared() {
        let m = model(utilities: ["Amphetamine"])
        m.enable()
        m.disable()
        XCTAssertEqual(m.notice, .confirmRestoreWithUtilities(["Amphetamine"]))
        setting.value = false  // someone else turned sleep back on
        m.refresh()
        XCTAssertNotEqual(m.notice, .confirmRestoreWithUtilities(["Amphetamine"]))
    }

    func testOsascriptResultMapping() {
        XCTAssertEqual(AdministratorPromptSleepDisabledWriter.result(status: 0, stderr: ""), .success)
        XCTAssertEqual(AdministratorPromptSleepDisabledWriter.result(
            status: 1, stderr: "0:120: execution error: User canceled. (-128)\n"), .cancelled)
        XCTAssertEqual(AdministratorPromptSleepDisabledWriter.result(status: 1, stderr: "  boom \n"), .failed("boom"))
        XCTAssertEqual(AdministratorPromptSleepDisabledWriter.result(status: 1, stderr: ""),
                       .failed("macOS refused the change."))
    }

    func testBootSessionIsReadable() {
        XCTAssertNotNil(BootSession.current(), "read-only sysctl")
    }
}
