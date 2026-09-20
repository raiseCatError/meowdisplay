import XCTest
import Network
import CoreMedia

/// Covers the C3 invariants `ReceiverFramePipeline` (`Shared/
/// ReceiverFramePipeline.swift`) must hold: generation-gated ingress,
/// deterministic reset/adoption ordering, packet/fragment ordering through
/// `drainFrames`, and codec parameter-set/format-description transitions.
/// Exercises the actor directly via its `ingest`/`beginAdoption`/
/// `finishAdoption` entry points — no live `NWConnection` involved, so
/// there is nothing here that needs the app host.
final class ReceiverFramePipelineTests: XCTestCase {

    // MARK: - Recorder

    /// Plain lock-protected recorder, not an actor: every `OutputEffects`
    /// closure below is called SYNCHRONOUSLY, inline, from inside the
    /// actor's own (non-async) processing of one `ingest`/`beginAdoption`/
    /// `finishAdoption` call — by the time a test's `await
    /// pipeline.ingest(...)` returns, everything it produced has already
    /// been recorded here. No `Task`/polling/`yield` needed to observe it.
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _controlMessages: [Data] = []
        private var _audioPayloads: [Data] = []
        private var _codecConfigurations: [(desc: CMVideoFormatDescription, size: CGSize)] = []
        private var _presentationFrameCount = 0
        private var _connectionFailures = 0
        private var _connectionClosedCount = 0

        func recordControlMessage(_ data: Data) { lock.lock(); _controlMessages.append(data); lock.unlock() }
        func recordAudioPayload(_ data: Data) { lock.lock(); _audioPayloads.append(data); lock.unlock() }
        func recordCodecConfiguration(_ desc: CMVideoFormatDescription, _ size: CGSize) {
            lock.lock(); _codecConfigurations.append((desc, size)); lock.unlock()
        }
        func recordPresentationFrame() { lock.lock(); _presentationFrameCount += 1; lock.unlock() }
        func recordConnectionFailed() { lock.lock(); _connectionFailures += 1; lock.unlock() }
        func recordConnectionClosed() { lock.lock(); _connectionClosedCount += 1; lock.unlock() }

        var controlMessages: [Data] { lock.lock(); defer { lock.unlock() }; return _controlMessages }
        var audioPayloads: [Data] { lock.lock(); defer { lock.unlock() }; return _audioPayloads }
        var codecConfigurations: [(desc: CMVideoFormatDescription, size: CGSize)] {
            lock.lock(); defer { lock.unlock() }; return _codecConfigurations
        }
        var presentationFrameCount: Int { lock.lock(); defer { lock.unlock() }; return _presentationFrameCount }
        var connectionFailureCount: Int { lock.lock(); defer { lock.unlock() }; return _connectionFailures }
        var connectionClosedCount: Int { lock.lock(); defer { lock.unlock() }; return _connectionClosedCount }
    }

    private func makePipeline() -> (ReceiverFramePipeline, Recorder) {
        let recorder = Recorder()
        let effects = ReceiverFramePipeline.OutputEffects(
            controlMessage: { data in recorder.recordControlMessage(data) },
            audioPayload: { data in recorder.recordAudioPayload(data) },
            codecConfigurationChanged: { box, size in recorder.recordCodecConfiguration(box.value, size) },
            presentationFrame: { _, _, _ in recorder.recordPresentationFrame() },
            connectionFailed: { _ in recorder.recordConnectionFailed() },
            connectionClosedByPeer: { recorder.recordConnectionClosed() })
        return (ReceiverFramePipeline(outputEffects: effects), recorder)
    }

    // MARK: - Wire fixtures

    /// A well-known minimal valid H.264 elementary stream's SPS/PPS/IDR
    /// (baseline profile, tiny gray frame) — small enough to hand-write,
    /// but real enough for `CMVideoFormatDescriptionCreateFromH264
    /// ParameterSets` to actually succeed, so format-description tests
    /// exercise the real CoreMedia call, not just its failure path.
    private let sps = Data([0x67, 0x42, 0x00, 0x0A, 0xF8, 0x41, 0xA2])
    private let pps = Data([0x68, 0xCE, 0x3C, 0x80])
    private let idr = Data([0x65, 0x88, 0x84, 0x00, 0x10, 0xFF, 0xFE, 0xF6, 0xF0, 0xA4, 0xFC, 0xB2])

    /// Concatenates NALUs with start codes, the Annex-B payload shape
    /// `drainFrames` hands to `handleAnnexB`.
    private func annexB(_ nalus: [Data]) -> Data {
        var out = Data()
        for nalu in nalus {
            out.append(contentsOf: [0, 0, 0, 1] as [UInt8])
            out.append(nalu)
        }
        return out
    }

    /// Wraps one payload in the wire's 4-byte-big-endian-length frame —
    /// what `drainFrames` deframes back out of `buffer`.
    private func framed(_ payload: Data) -> Data {
        var len = UInt32(payload.count).bigEndian
        var out = Data(bytes: &len, count: 4)
        out.append(payload)
        return out
    }

    private func jsonControlMessage(_ fields: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: fields)
    }

    // MARK: - 1/3. Generation acceptance + stale rejection

    func testGenerationNPayloadAcceptedAndStaleGenerationRejected() async {
        let (pipeline, recorder) = makePipeline()
        await pipeline.beginAdoption(generation: 1)

        // A stale (pre-adoption) generation's payload must never reach any
        // output — asserted via a control message, which otherwise
        // unconditionally forwards.
        await pipeline.ingest(framed(jsonControlMessage(["type": "ping"])), generation: 0)
        XCTAssertEqual(recorder.controlMessages.count, 0, "generation 0 predates adoption and must be dropped")

        // The current generation's payload is processed normally.
        await pipeline.ingest(framed(jsonControlMessage(["type": "ping"])), generation: 1)
        XCTAssertEqual(recorder.controlMessages.count, 1, "generation 1 is current and must be forwarded")
    }

    func testGenerationDoesNotRegressAfterANewerAdoptionLandsFirst() async {
        let (pipeline, recorder) = makePipeline()
        // Simulates a slow, superseded adoption's `beginAdoption` landing
        // AFTER a newer one already took over (the exact race two
        // independent sibling Tasks could produce — see the actor's file
        // header). The monotonic `>=` guard must keep generation 5 current.
        await pipeline.beginAdoption(generation: 5)
        await pipeline.beginAdoption(generation: 3)

        await pipeline.ingest(framed(jsonControlMessage(["type": "ping"])), generation: 3)
        XCTAssertEqual(recorder.controlMessages.count, 0, "the older, superseded generation must still be rejected")

        await pipeline.ingest(framed(jsonControlMessage(["type": "ping"])), generation: 5)
        XCTAssertEqual(recorder.controlMessages.count, 1, "the newer generation must remain current")
    }

    // MARK: - 2/7. Reset on a new generation

    func testNewGenerationResetClearsPriorCodecState() async {
        let (pipeline, recorder) = makePipeline()
        await pipeline.beginAdoption(generation: 1)
        await pipeline.ingest(framed(annexB([sps, pps, idr])), generation: 1)
        XCTAssertEqual(recorder.codecConfigurations.count, 1, "sanity: SPS/PPS must build a format description")
        XCTAssertEqual(recorder.presentationFrameCount, 1, "sanity: the IDR alongside it must produce one frame")

        // A fresh generation must wipe the previously-built formatDesc/SPS/
        // PPS — an IDR with no fresh parameter sets must NOT produce a
        // frame (there is nothing to build a sample buffer against).
        await pipeline.beginAdoption(generation: 2)
        await pipeline.ingest(framed(annexB([idr])), generation: 2)
        XCTAssertEqual(recorder.presentationFrameCount, 1, "reset must clear formatDesc; a bare IDR cannot decode without it")

        // Resending the parameter sets on the new generation rebuilds it.
        await pipeline.ingest(framed(annexB([sps, pps, idr])), generation: 2)
        XCTAssertEqual(recorder.codecConfigurations.count, 2)
        XCTAssertEqual(recorder.presentationFrameCount, 2)
    }

    // MARK: - 4. Packet ordering preserved

    func testPacketOrderingPreservedAcrossSeparateIngestCalls() async {
        let (pipeline, recorder) = makePipeline()
        await pipeline.beginAdoption(generation: 1)

        // Three distinguishable control messages, delivered as three
        // separate `ingest` calls (three separate wire arrivals) — must be
        // forwarded in the exact order received.
        for i in 0..<3 {
            await pipeline.ingest(framed(jsonControlMessage(["type": "ping", "seq": i])), generation: 1)
        }

        let messages = recorder.controlMessages
        XCTAssertEqual(messages.count, 3)
        for (i, message) in messages.enumerated() {
            let obj = try! JSONSerialization.jsonObject(with: message) as! [String: Any]
            XCTAssertEqual(obj["seq"] as? Int, i, "control messages must be forwarded in wire arrival order")
        }
    }

    // MARK: - 5. Fragmented frame assembly

    func testFragmentedFrameAssemblyAcrossIngestCalls() async {
        let (pipeline, recorder) = makePipeline()
        await pipeline.beginAdoption(generation: 1)

        let wholePacket = framed(annexB([sps, pps, idr]))
        // Split the SAME wire packet's bytes across two `ingest` calls, as
        // a real TCP delivery boundary could — `buffer` must reassemble it
        // before draining.
        let splitPoint = wholePacket.count / 2
        let firstHalf = wholePacket[wholePacket.startIndex..<splitPoint]
        let secondHalf = wholePacket[splitPoint...]

        await pipeline.ingest(Data(firstHalf), generation: 1)
        XCTAssertEqual(recorder.presentationFrameCount, 0, "an incomplete frame must not be drained yet")

        await pipeline.ingest(Data(secondHalf), generation: 1)
        XCTAssertEqual(recorder.presentationFrameCount, 1, "the frame completes once both fragments have arrived")
    }

    func testTwoFramesDeliveredInOneChunkBothDrain() async {
        let (pipeline, recorder) = makePipeline()
        await pipeline.beginAdoption(generation: 1)

        var combined = framed(annexB([sps, pps, idr]))
        combined.append(framed(annexB([idr])))
        await pipeline.ingest(combined, generation: 1)

        XCTAssertEqual(recorder.codecConfigurations.count, 1, "only the first frame carries fresh parameter sets")
        XCTAssertEqual(recorder.presentationFrameCount, 2, "both frames in the one chunk must be drained")
    }

    // MARK: - 6. Codec parameter-set / format-description transitions

    func testSPSPPSUpdateRebuildsFormatDescription() async {
        let (pipeline, recorder) = makePipeline()
        await pipeline.beginAdoption(generation: 1)

        await pipeline.ingest(framed(annexB([sps, pps, idr])), generation: 1)
        XCTAssertEqual(recorder.codecConfigurations.count, 1)
        let firstSize = recorder.codecConfigurations[0].size
        XCTAssertGreaterThan(firstSize.width, 0)
        XCTAssertGreaterThan(firstSize.height, 0)

        // The SAME parameter sets again must NOT rebuild — only a genuine
        // change (or a reset) invalidates `formatDesc`.
        await pipeline.ingest(framed(annexB([sps, pps, idr])), generation: 1)
        XCTAssertEqual(recorder.codecConfigurations.count, 1, "unchanged SPS/PPS must not rebuild the format description")
        XCTAssertEqual(recorder.presentationFrameCount, 2, "but each IDR still produces its own presentation frame")
    }

    func testStreamCodecStateMessageSwitchesHEVCClassification() async {
        let (pipeline, recorder) = makePipeline()
        await pipeline.beginAdoption(generation: 1)

        // Build up H.264 format state, then switch the actor's own codec
        // mirror to HEVC via the same control message the host parses in
        // full (see `applyControlStateIfNeeded`).
        await pipeline.ingest(framed(annexB([sps, pps, idr])), generation: 1)
        XCTAssertEqual(recorder.codecConfigurations.count, 1)

        await pipeline.ingest(framed(jsonControlMessage(["type": "streamCodecState", "codec": "hevc", "reason": "test"])), generation: 1)
        XCTAssertEqual(recorder.controlMessages.count, 1, "the raw message is still forwarded for the host's own effects")

        // The same H.264-shaped SPS/PPS bytes, reinterpreted under HEVC's
        // NAL-type bit layout, must not just silently rebuild an H.264
        // format description again — the actor's own classification must
        // have actually switched.
        await pipeline.ingest(framed(annexB([sps, pps, idr])), generation: 1)
        XCTAssertEqual(recorder.codecConfigurations.count, 1,
                       "H.264-shaped bytes misclassified under HEVC rules must not produce a NEW valid format description")
    }

    // MARK: - Regression: videoState/streamCodecState must be change-gated
    //
    // The sender deliberately re-sends both message types as no-op state
    // reconfirmation during normal operation (hello/reconnect, resize, live
    // FPS changes, encoder reconfiguration/recovery) — a repeat must not
    // discard an already-valid format description. Mirrors `StreamReceiver.
    // handleVideoChannelJSON`'s exact `changed || !update.enabled` (video)
    // and `update.codec != receivedStreamCodec` (codec) gating.

    func testRepeatedNoOpH264StreamCodecStateRetainsExistingFormatDescription() async {
        let (pipeline, recorder) = makePipeline()
        await pipeline.beginAdoption(generation: 1)

        await pipeline.ingest(framed(annexB([sps, pps, idr])), generation: 1)
        XCTAssertEqual(recorder.codecConfigurations.count, 1, "sanity: SPS/PPS must build a format description")

        // The sender re-confirms the ALREADY-active codec (h264, the
        // actor's default) — a no-op per `update.codec != receivedStreamCodec`.
        await pipeline.ingest(framed(jsonControlMessage(["type": "streamCodecState", "codec": "h264", "reason": "reconfirm"])), generation: 1)
        XCTAssertEqual(recorder.controlMessages.count, 1)

        // A bare IDR (no fresh SPS/PPS) must still decode: the existing
        // format description must NOT have been discarded by the repeat.
        await pipeline.ingest(framed(annexB([idr])), generation: 1)
        XCTAssertEqual(recorder.presentationFrameCount, 2,
                       "a repeated, unchanged streamCodecState must not discard existing H.264 parameter/format state")
        XCTAssertEqual(recorder.codecConfigurations.count, 1, "no rebuild should have been needed")
    }

    func testActualCodecChangeH264ToHEVCClearsExistingFormatDescription() async {
        let (pipeline, recorder) = makePipeline()
        await pipeline.beginAdoption(generation: 1)

        await pipeline.ingest(framed(annexB([sps, pps, idr])), generation: 1)
        XCTAssertEqual(recorder.codecConfigurations.count, 1)

        // A REAL codec change must still reset, unconditionally.
        await pipeline.ingest(framed(jsonControlMessage(["type": "streamCodecState", "codec": "hevc", "reason": "fallback"])), generation: 1)

        // A bare IDR now falls under HEVC's NAL-type classification (never
        // matching H.264's SPS/PPS `& 0x1F` cases) with no fresh HEVC
        // parameter sets, and the prior H.264 format description is gone —
        // no frame can be produced.
        await pipeline.ingest(framed(annexB([idr])), generation: 1)
        XCTAssertEqual(recorder.presentationFrameCount, 1,
                       "unchanged from the one frame already produced before the switch — the bare IDR after it "
                       + "must not decode, since an actual codec change must discard the prior codec's format state")
    }

    func testCodecRoundTripHEVCBackToH264StillProducesFrames() async {
        let (pipeline, recorder) = makePipeline()
        await pipeline.beginAdoption(generation: 1)

        // H.264 -> HEVC (real change) -> H.264 (real change back). Each
        // hop is a genuine transition per `update.codec != codec`, so both
        // must reset; the round trip must not leave the actor stuck.
        await pipeline.ingest(framed(jsonControlMessage(["type": "streamCodecState", "codec": "hevc", "reason": "test"])), generation: 1)
        await pipeline.ingest(framed(jsonControlMessage(["type": "streamCodecState", "codec": "h264", "reason": "test"])), generation: 1)

        await pipeline.ingest(framed(annexB([sps, pps, idr])), generation: 1)
        XCTAssertEqual(recorder.codecConfigurations.count, 1, "fresh H.264 SPS/PPS must build cleanly after the round trip")
        XCTAssertEqual(recorder.presentationFrameCount, 1)
    }

    func testRepeatedVideoStateWithUnchangedEnabledDoesNotInvalidateFormatDescription() async {
        let (pipeline, recorder) = makePipeline()
        await pipeline.beginAdoption(generation: 1)

        await pipeline.ingest(framed(annexB([sps, pps, idr])), generation: 1)
        XCTAssertEqual(recorder.codecConfigurations.count, 1)

        // The actor's `videoEnabled` mirror defaults to `true` (matching
        // `StreamReceiver.receivedVideoEnabled`) — re-confirming "enabled"
        // is a no-op per `changed || !update.enabled`.
        await pipeline.ingest(framed(jsonControlMessage(["type": "videoState", "enabled": true])), generation: 1)

        await pipeline.ingest(framed(annexB([idr])), generation: 1)
        XCTAssertEqual(recorder.presentationFrameCount, 2,
                       "a repeated, unchanged videoState must not discard existing format/parameter-set state")
        XCTAssertEqual(recorder.codecConfigurations.count, 1, "no rebuild should have been needed")
    }

    func testVideoStateActualDisableResetsFormatDescription() async {
        let (pipeline, recorder) = makePipeline()
        await pipeline.beginAdoption(generation: 1)

        await pipeline.ingest(framed(annexB([sps, pps, idr])), generation: 1)
        XCTAssertEqual(recorder.codecConfigurations.count, 1)

        // enabled -> disabled is a real transition — legacy always resets.
        await pipeline.ingest(framed(jsonControlMessage(["type": "videoState", "enabled": false])), generation: 1)

        await pipeline.ingest(framed(annexB([idr])), generation: 1)
        XCTAssertEqual(recorder.presentationFrameCount, 1,
                       "unchanged from the one frame already produced before the disable — the bare IDR after it "
                       + "must not decode, since an enabled -> disabled transition must discard the format description")
    }

    func testVideoStateRepeatedDisabledStillResetsPerLegacySemantics() async {
        let (pipeline, recorder) = makePipeline()
        await pipeline.beginAdoption(generation: 1)

        await pipeline.ingest(framed(jsonControlMessage(["type": "videoState", "enabled": false])), generation: 1)
        // Rebuild format state while nominally still "disabled" (the reset
        // itself does not prevent frames arriving/decoding once fresh
        // SPS/PPS show up again).
        await pipeline.ingest(framed(annexB([sps, pps, idr])), generation: 1)
        XCTAssertEqual(recorder.codecConfigurations.count, 1)

        // disabled -> disabled is UNCHANGED, but legacy's `!update.enabled`
        // clause resets regardless of `changed` — this is the one case
        // that resets even without a transition.
        await pipeline.ingest(framed(jsonControlMessage(["type": "videoState", "enabled": false])), generation: 1)

        await pipeline.ingest(framed(annexB([idr])), generation: 1)
        XCTAssertEqual(recorder.presentationFrameCount, 1,
                       "unchanged from the one frame already produced before the repeated 'disabled' reset — "
                       + "a bare IDR after it must not decode, matching legacy's changed || !update.enabled")
    }

    // MARK: - 7. Reset clears prior frame/codec state correctly

    func testResetClearsBufferedPartialFrameFromThePriorGeneration() async {
        let (pipeline, recorder) = makePipeline()
        await pipeline.beginAdoption(generation: 1)

        // Half of a framed packet is buffered but incomplete...
        let wholePacket = framed(annexB([sps, pps, idr]))
        let splitPoint = wholePacket.count / 2
        await pipeline.ingest(Data(wholePacket[wholePacket.startIndex..<splitPoint]), generation: 1)
        XCTAssertEqual(recorder.presentationFrameCount, 0)

        // ...then a new generation resets the buffer entirely.
        await pipeline.beginAdoption(generation: 2)

        // The old generation's second half must be rejected outright
        // (stale generation)...
        await pipeline.ingest(Data(wholePacket[splitPoint...]), generation: 1)
        XCTAssertEqual(recorder.presentationFrameCount, 0)

        // ...and even on the NEW generation, that stale half-fragment must
        // not have silently completed a frame from leftover buffer bytes:
        // a fresh, complete, well-formed packet must be needed.
        await pipeline.ingest(wholePacket, generation: 2)
        XCTAssertEqual(recorder.presentationFrameCount, 1, "the new generation must assemble its own frame cleanly")
    }

    // MARK: - Audio payload demuxing stays untouched (not migrated in C3)

    func testAudioMediaFramePayloadIsForwardedNotParsed() async {
        let (pipeline, recorder) = makePipeline()
        await pipeline.beginAdoption(generation: 1)

        // `AudioMediaFrame.marker` (0x01), per `AudioMediaFrame.
        // isAudioFrame` — the actor only demuxes by this marker and
        // forwards the raw payload; decode/scheduling (E) stays host-side.
        let audioPayload = Data([0x01, 0x00, 0x01, 0x02, 0x03])
        await pipeline.ingest(framed(audioPayload), generation: 1)

        XCTAssertEqual(recorder.audioPayloads.count, 1)
        XCTAssertEqual(recorder.audioPayloads.first, audioPayload)
        XCTAssertEqual(recorder.controlMessages.count, 0)
        XCTAssertEqual(recorder.presentationFrameCount, 0)
    }
}
