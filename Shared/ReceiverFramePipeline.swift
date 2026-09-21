// ReceiverFramePipeline — RC-3 Stage C3.
//
// The sole authoritative owner of the high-frequency receive/frame-assembly
// cluster that used to live as plain `queue`-confined stored properties on
// `StreamReceiver`: the raw receive `buffer`, SPS/PPS/VPS, the rebuilt
// `formatDesc`, and the receive generation that gates every packet against
// a stale/superseded connection. It owns the ordered path from
// `NWConnection.receive` through length-prefixed deframing and Annex-B
// parsing up to (and stopping at) the presentation-ready `CMSampleBuffer`
// boundary — `CMSampleBufferCreateReady` is where this actor's job ends.
// VideoToolbox decode (C4), `AVSampleBufferDisplayLayer` presentation (D)
// and audio decode/scheduling (E) all stay on `StreamReceiver`, still
// confined to its own `queue`; this actor never touches any of them
// directly, only via `OutputEffects`.
//
// Ingress ordering: `NWConnection.receive` delivers one chunk at a time and
// only resumes once `.receive` is called again. This actor never re-arms
// it until the current chunk's `Task` has finished awaiting into the
// actor (`beginReceiving` -> one `Task` -> `beginReceiving` again), so
// there is never more than one packet in flight and wire arrival order is
// preserved without an `AsyncStream` or a Task-per-packet racing another.
//
// Reset/adoption ordering: `ReceiverPipelineActor.adopt()` sequences this
// actor's own reset (`beginAdoption`) and receive-loop start
// (`finishAdoption`) inside ONE `Task`'s two sequential `await`s — never
// two independent sibling Tasks, whose relative execution order this
// actor's mailbox would not guarantee (two Tasks created back-to-back can
// still enter an actor in either order). `beginAdoption` additionally never
// regresses `generation` backwards (a monotonic ratchet): even if a slow,
// superseded adoption's `Task` happens to land after a newer one's, it can
// never resurrect an older generation's state over the newer one already
// in play. `finishAdoption` only starts receiving if its generation still
// matches exactly — a stale adoption's `Task` landing late simply no-ops.
//
import Foundation
import Network
import CoreMedia
import VideoToolbox
import CoreGraphics

/// Synchronous, lock-protected mirror of the state that must cross the
/// actor boundary WITHOUT an `await`: the active receive generation
/// together with the liveness timestamp (pipeline -> host; read as ONE
/// atomic pair by `ReceiverPipelineActor`'s watchdog timer, which runs
/// synchronously on its own queue and cannot suspend — see `snapshot()`)
/// and `renderingPaused` (host -> pipeline; checked before building a
/// sample buffer, so a backgrounded receiver never pays for the
/// memory-copy work of a sample it would immediately discard). Same idiom
/// as `ReconnectContext` (`ReceiverPipelineActor.swift`): an `NSLock`-
/// protected snapshot, never an unsynchronized `@Sendable` getter closure
/// reading another isolation domain's state directly.
///
/// `generation` and `lastDataReceived` are read together, under one lock
/// acquisition, deliberately: reading them via two independent calls would
/// let a `recordAdoption` land in between and hand the watchdog a
/// "torn" pair — a fresh generation paired with a stale timestamp from
/// the connection it just superseded, which would misjudge a brand-new,
/// healthy connection as silent. `recordDataReceived` alone only ever
/// pushes the timestamp forward, so it carries no such risk and needs no
/// matching generation update.
final class FramePipelineSyncState: @unchecked Sendable {
    private let lock = NSLock()
    private var generation = 0
    private var lastDataReceived = Date()
    private var renderingPaused = false

    /// Called once per accepted adoption — updates both fields together so
    /// they can never be observed torn relative to each other.
    func recordAdoption(generation: Int, at date: Date) {
        lock.lock(); defer { lock.unlock() }
        self.generation = generation
        self.lastDataReceived = date
    }

    /// Called whenever fresh proof-of-life arrives — a packet on the wire
    /// (from `ReceiverFramePipeline.ingest`) or the connection reaching
    /// `.ready` (from `StreamReceiver.onConnectionReadyHostWork`). Never
    /// regresses `generation`; only ever moves the timestamp forward.
    func recordDataReceived(_ date: Date) {
        lock.lock(); defer { lock.unlock() }
        lastDataReceived = date
    }

    func snapshot() -> (generation: Int, lastDataReceived: Date) {
        lock.lock(); defer { lock.unlock() }
        return (generation, lastDataReceived)
    }

    func setRenderingPaused(_ value: Bool) {
        lock.lock(); defer { lock.unlock() }
        renderingPaused = value
    }

    func isRenderingPaused() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return renderingPaused
    }
}

/// Hands a non-`Sendable` Core Media value across the actor boundary — same
/// idiom as `MediaSampleBox` (`Mac/AudioCaptureEncoder.swift`). Safe here
/// because each value is produced once, for exactly one output call, and
/// nothing else touches it concurrently afterward.
struct FrameMediaBox<Value>: @unchecked Sendable {
    let value: Value

    init(_ value: Value) { self.value = value }
}

actor ReceiverFramePipeline {

    /// The narrow, purpose-built output surface this actor calls out to for
    /// everything downstream of its own state — never a dumping ground for
    /// unrelated `ReceiverPipelineActor`/`StreamReceiver` concerns. Every
    /// closure is responsible for hopping onto the host's own `queue` (or
    /// `MainActor`) before touching queue-/MainActor-confined state, exactly
    /// like `ReceiverPipelineActor.HostControlEffects`/`UIEffects`.
    struct OutputEffects: Sendable {
        /// Raw control/telemetry JSON this actor recognized as NOT a video
        /// payload (ping/pong, cursor, display/video/codec state, welcome,
        /// etc.) — forwarded verbatim. `StreamReceiver.
        /// handleVideoChannelJSON` still owns every one of its effects;
        /// this actor only additionally, redundantly notices `videoState`/
        /// `streamCodecState` itself (see `applyControlStateIfNeeded`) so
        /// its OWN codec/format-description state resets in the same
        /// synchronous pass that saw the message, never via a round trip
        /// back through the host that could race the next packet.
        var controlMessage: @Sendable (Data) -> Void
        /// Raw `AudioMediaFrame`-encoded payload. Decode/scheduling (E)
        /// stays entirely host-side — not migrated in this stage.
        var audioPayload: @Sendable (Data) -> Void
        /// A fresh parameter-set-derived format description was just built
        /// (SPS/PPS, or VPS/SPS/PPS for HEVC). The host must flush the
        /// display layer before any sample built from it is presented —
        /// see `StreamReceiver.makeFramePipelineOutputEffects`.
        var codecConfigurationChanged: @Sendable (FrameMediaBox<CMVideoFormatDescription>, CGSize) -> Void
        /// A presentation-ready sample buffer, built up to (and stopping
        /// at) `CMSampleBufferCreateReady`. Decode/presentation (C4/D) and
        /// all per-frame telemetry stay entirely host-side.
        var presentationFrame: @Sendable (FrameMediaBox<CMSampleBuffer>, _ captureMs: Double?, _ sendMs: Double?) -> Void
        /// The live connection's `receive` reported an error. Treated
        /// exactly like EOF by the host — see the original `receive error`
        /// handling this replaces.
        var connectionFailed: @Sendable (NWError) -> Void
        /// The peer closed the connection (`isComplete`).
        var connectionClosedByPeer: @Sendable () -> Void
    }

    // MARK: - State moved together from StreamReceiver (C3)

    private var buffer = Data()
    private var sps: Data?
    private var pps: Data?
    private var vps: Data?
    private var formatDesc: CMVideoFormatDescription?
    /// Mirrors `StreamReceiver.receivedStreamCodec` for hot-path NALU
    /// classification only — this actor's own, independently-parsed copy
    /// (see `applyControlStateIfNeeded`), never the authoritative source
    /// for UI/control effects. That stays host-owned, exactly as before.
    private var codec: StreamCodec = .h264
    /// Mirrors `StreamReceiver.receivedVideoEnabled` — this actor's own
    /// change-gate for `videoState` messages (see `applyControlStateIfNeeded`),
    /// so a re-confirmed, unchanged "enabled" state does not discard a
    /// still-valid format description. Never the authoritative source for
    /// UI/control effects; that stays host-owned, exactly as before.
    private var videoEnabled = true
    /// The generation of the session this actor currently believes it
    /// owns — `ReceiverPipelineActor`'s `sessionState.generation` at the
    /// moment of the accepted adoption, stamped by `beginAdoption` and
    /// checked before every packet touches `buffer`/codec state. A
    /// distinct counter from `videoGeneration` (still host-owned,
    /// decode-level) and from `ReceiverPipelineActor.sessionState.
    /// generation` itself — the three are deliberately never merged.
    private var generation = 0

    // MARK: - Dependencies

    /// Injected rather than self-constructed so `StreamReceiver` can hold
    /// the SAME instance directly — see `StreamReceiver.
    /// framePipelineSyncState` — letting `makePipelineHostEffects()`'s
    /// `getReceiveLiveness` capture this Sendable owner on its own instead
    /// of reaching through the lazily-constructed actor. Defaults to a
    /// fresh instance for call sites (tests) that don't need to share it.
    nonisolated let syncState: FramePipelineSyncState
    nonisolated let outputEffects: OutputEffects

    init(outputEffects: OutputEffects, syncState: FramePipelineSyncState = FramePipelineSyncState()) {
        self.outputEffects = outputEffects
        self.syncState = syncState
    }

    // MARK: - Reset / adoption seam

    /// Clears the frame-assembly cluster and adopts `generation` as this
    /// actor's own — called by `ReceiverPipelineActor.adopt()`, awaited,
    /// strictly before `finishAdoption` (see the file header). Never
    /// regresses `generation` backwards: a superseded adoption's `Task`
    /// landing after a newer one's must not resurrect older state.
    func beginAdoption(generation: Int) {
        guard generation >= self.generation else { return }
        buffer.removeAll(keepingCapacity: true)
        formatDesc = nil
        sps = nil
        pps = nil
        vps = nil
        // Matches `StreamReceiver.beginAdoptionHostWork`'s own
        // `receivedVideoEnabled = true` reset at adoption time — a fresh
        // connection starts assuming video is enabled, exactly like the
        // legacy host-owned property did. `codec` deliberately does NOT
        // reset here, matching `receivedStreamCodec`'s own persistence
        // across reconnects (the last-negotiated codec is still the right
        // guess until told otherwise).
        videoEnabled = true
        self.generation = generation
        syncState.recordAdoption(generation: generation, at: Date())
    }

    /// Drains any already-read `initialData` (a newcomer connection proved
    /// itself with data already in hand) and starts the ordered receive
    /// loop. Only takes effect if `generation` still matches exactly —
    /// this generation may already have been superseded by the time this
    /// runs, in which case it no-ops (the newer generation's own
    /// `finishAdoption` owns starting its receive loop).
    func finishAdoption(connection: NWConnection, generation: Int, initialData: Data?) {
        guard generation == self.generation else { return }
        if let initialData, !initialData.isEmpty {
            buffer.append(initialData)
            drainFrames()
        }
        beginReceiving(on: connection, generation: generation)
    }

    // MARK: - Ordered ingress

    private func beginReceiving(on connection: NWConnection, generation: Int) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 18) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            Task {
                await self.handleReceiveCompletion(
                    on: connection, data: data, isComplete: isComplete, error: error, generation: generation)
            }
        }
    }

    private func handleReceiveCompletion(
        on connection: NWConnection, data: Data?, isComplete: Bool, error: NWError?, generation: Int
    ) async {
        ingest(data, generation: generation)
        guard generation == self.generation else { return }
        if let error {
            outputEffects.connectionFailed(error)
            return
        }
        if isComplete {
            outputEffects.connectionClosedByPeer()
            return
        }
        beginReceiving(on: connection, generation: generation)
    }

    /// The generation-gated entry point every inbound chunk goes through —
    /// the real `NWConnection` path above, and tests, both call this
    /// directly, so there is exactly one place that decides whether a
    /// chunk is stale.
    func ingest(_ data: Data?, generation: Int) {
        guard generation == self.generation else { return }
        guard let data, !data.isEmpty else { return }
        syncState.recordDataReceived(Date())
        buffer.append(data)
        drainFrames()
    }

    // MARK: - Deframe + Annex-B parse (unchanged wire contract)

    private func drainFrames() {
        // Cursor-based drain so we only compact the buffer once per batch.
        var cursor = buffer.startIndex
        while buffer.distance(from: cursor, to: buffer.endIndex) >= 4 {
            let len = buffer[cursor..<buffer.index(cursor, offsetBy: 4)]
                .withUnsafeBytes { Int(UInt32(bigEndian: $0.loadUnaligned(as: UInt32.self))) }
            guard buffer.distance(from: cursor, to: buffer.endIndex) >= 4 + len else { break }
            let start = buffer.index(cursor, offsetBy: 4)
            let end = buffer.index(start, offsetBy: len)
            let payload = Data(buffer[start..<end])
            if AudioMediaFrame.isAudioFrame(payload) {
                outputEffects.audioPayload(payload)
            } else {
                handleAnnexB(payload)
            }
            cursor = end
        }
        buffer.removeSubrange(buffer.startIndex..<cursor)
    }

    private func handleAnnexB(_ data: Data) {
        // Pure JSON payload = control message (pong, cursor sprite etc.).
        // Video frames also begin with '{' (telemetry prefix) but always
        // contain start codes — the null bytes make them unambiguous even
        // against multi-KB JSON (cursor sprites are base64, NUL-free).
        if data.count < 32_768, data.first == UInt8(ascii: "{"), !data.contains(0x00) {
            applyControlStateIfNeeded(data)
            outputEffects.controlMessage(data)
            return
        }

        // Split on 4-byte start codes (our sender only emits 00 00 00 01).
        // Bytes before the FIRST start code are the telemetry prefix
        // ({"cap":…,"snd":…} stamped by the Mac).
        var nalus: [Data] = []
        var metaPrefix: Data?
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let bytes = raw.bindMemory(to: UInt8.self)
            var naluStart: Int? = nil
            var firstSC: Int? = nil
            var i = 0
            while i + 4 <= bytes.count {
                if bytes[i] == 0, bytes[i+1] == 0, bytes[i+2] == 0, bytes[i+3] == 1 {
                    if firstSC == nil { firstSC = i }
                    if let s = naluStart, s < i { nalus.append(Data(bytes[s..<i])) }
                    naluStart = i + 4
                    i += 4
                } else {
                    i += 1
                }
            }
            if let s = naluStart, s < bytes.count { nalus.append(Data(bytes[s...])) }
            if let f = firstSC, f > 0 { metaPrefix = Data(bytes[0..<f]) }
        }

        var captureMs: Double?
        var sendMs: Double?
        if let metaPrefix,
           let meta = try? JSONSerialization.jsonObject(with: metaPrefix) as? [String: Any] {
            captureMs = meta["cap"] as? Double
            sendMs = meta["snd"] as? Double
        }

        var vclNALUs: [Data] = []
        // Codec-aware NAL classification — `codec` is the AUTHORITATIVE
        // source for THIS actor's own parsing (mirrored from the same
        // `streamCodecState` message the host also parses in full), never
        // inferred from the NAL bytes themselves.
        if codec == .hevc {
            for nalu in nalus {
                guard let first = nalu.first else { continue }
                switch HEVCNALUnitType.classify(firstByte: first) {
                case .vps:
                    if vps != nalu { vps = nalu; formatDesc = nil }
                case .sps:
                    if sps != nalu { sps = nalu; formatDesc = nil }
                case .pps:
                    if pps != nalu { pps = nalu; formatDesc = nil }
                case .seiPrefix, .seiSuffix: break     // skip
                case .other: vclNALUs.append(nalu)     // slice data
                }
            }
            if formatDesc == nil, let vps, let sps, let pps {
                buildHEVCFormatDescription(vps: vps, sps: sps, pps: pps)
            }
        } else {
            for nalu in nalus {
                guard let first = nalu.first else { continue }
                switch first & 0x1F {
                case 7:                                  // SPS (stream may change
                    if sps != nalu {                     //  size on rotation)
                        sps = nalu
                        formatDesc = nil
                    }
                case 8:                                  // PPS
                    if pps != nalu {
                        pps = nalu
                        formatDesc = nil
                    }
                case 6: break                            // SEI — skip
                default: vclNALUs.append(nalu)           // slice data
                }
            }
            if formatDesc == nil, let sps, let pps {
                buildFormatDescription(sps: sps, pps: pps)
            }
        }
        guard !vclNALUs.isEmpty else { return }
        // Backgrounded linger: hardware decode is off-limits there, so drop
        // frames at the door instead of paying for a sample buffer nothing
        // will present. `setRenderingPaused(false)` re-syncs with a keyframe.
        guard !syncState.isRenderingPaused() else { return }
        guard let sample = buildSampleBuffer(vclNALUs) else { return }
        outputEffects.presentationFrame(FrameMediaBox(sample), captureMs, sendMs)
    }

    /// This actor's own minimal, redundant look at control messages that
    /// affect ITS state (codec identity, parameter sets). `StreamReceiver.
    /// handleVideoChannelJSON` independently parses the SAME raw bytes
    /// (delivered via `OutputEffects.controlMessage`) for every other
    /// effect (UI publish, `sendControl`, decoder/display reset) — the
    /// duplication is deliberate: it is the only race-free way to keep
    /// this actor's own parameter-set state in lockstep with a message
    /// that arrives interleaved with the very frames it invalidates,
    /// without an out-of-band round trip through the host that could lose
    /// the race against the next already-in-flight packet.
    private func applyControlStateIfNeeded(_ data: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        // Change-gated exactly like `StreamReceiver.handleVideoChannelJSON`'s
        // `videoState`/`streamCodecState` cases: the sender deliberately
        // re-sends these as no-op state reconfirmation (hello/reconnect,
        // resize, live FPS changes, encoder recovery) during normal
        // operation, and a repeat must not discard a still-valid format
        // description.
        if let update = VideoStateUpdate(message: obj) {
            let changed = update.enabled != videoEnabled
            videoEnabled = update.enabled
            // Mirrors `changed || !update.enabled`: an actual transition
            // OR a (re-)confirmed disabled state both invalidate frame/
            // codec state; a repeated "still enabled" does not.
            if changed || !update.enabled {
                formatDesc = nil
                sps = nil
                pps = nil
                vps = nil
            }
            return
        }
        if let update = StreamCodecStateUpdate(message: obj), update.codec != codec {
            codec = update.codec
            formatDesc = nil
            sps = nil
            pps = nil
            vps = nil
        }
    }

    // MARK: - Format description construction

    private func buildFormatDescription(sps: Data, pps: Data) {
        sps.withUnsafeBytes { spsBuf in
            pps.withUnsafeBytes { ppsBuf in
                let ptrs: [UnsafePointer<UInt8>] = [
                    spsBuf.bindMemory(to: UInt8.self).baseAddress!,
                    ppsBuf.bindMemory(to: UInt8.self).baseAddress!
                ]
                let sizes = [sps.count, pps.count]
                var desc: CMVideoFormatDescription?
                let status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: 2,
                    parameterSetPointers: ptrs,
                    parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &desc
                )
                guard status == noErr, let desc else {
                    Log.info("format description FAILED: \(status)")
                    return
                }
                formatDesc = desc
                let dims = CMVideoFormatDescriptionGetDimensions(desc)
                Log.info("format description built: \(dims.width)x\(dims.height)")
                outputEffects.codecConfigurationChanged(
                    FrameMediaBox(desc), CGSize(width: Int(dims.width), height: Int(dims.height)))
            }
        }
    }

    private func buildHEVCFormatDescription(vps: Data, sps: Data, pps: Data) {
        vps.withUnsafeBytes { vpsBuf in
            sps.withUnsafeBytes { spsBuf in
                pps.withUnsafeBytes { ppsBuf in
                    let ptrs: [UnsafePointer<UInt8>] = [
                        vpsBuf.bindMemory(to: UInt8.self).baseAddress!,
                        spsBuf.bindMemory(to: UInt8.self).baseAddress!,
                        ppsBuf.bindMemory(to: UInt8.self).baseAddress!
                    ]
                    let sizes = [vps.count, sps.count, pps.count]
                    var desc: CMVideoFormatDescription?
                    let status = CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                        allocator: kCFAllocatorDefault,
                        parameterSetCount: 3,
                        parameterSetPointers: ptrs,
                        parameterSetSizes: sizes,
                        nalUnitHeaderLength: 4,
                        extensions: nil,
                        formatDescriptionOut: &desc
                    )
                    guard status == noErr, let desc else {
                        Log.info("HEVC format description FAILED: \(status)")
                        return
                    }
                    formatDesc = desc
                    let dims = CMVideoFormatDescriptionGetDimensions(desc)
                    Log.info("format description built (HEVC): \(dims.width)x\(dims.height)")
                    outputEffects.codecConfigurationChanged(
                        FrameMediaBox(desc), CGSize(width: Int(dims.width), height: Int(dims.height)))
                }
            }
        }
    }

    // MARK: - Presentation-ready CMSampleBuffer boundary

    /// Builds one AVCC-framed sample buffer from one wire frame's VCL
    /// NALUs. Stops here: decode (`VTDecompressionSession`, C4) and
    /// presentation (`AVSampleBufferDisplayLayer`, D) are entirely
    /// host-side — see `StreamReceiver.presentDecodedSample`.
    private func buildSampleBuffer(_ nalus: [Data]) -> CMSampleBuffer? {
        guard let formatDesc else { return nil }

        // Build one AVCC buffer: each NALU prefixed with 4-byte big-endian length.
        var avcc = Data(capacity: nalus.reduce(0) { $0 + $1.count + 4 })
        for nalu in nalus {
            var len = UInt32(nalu.count).bigEndian
            avcc.append(Data(bytes: &len, count: 4))
            avcc.append(nalu)
        }

        // Allocate a block buffer that OWNS its memory and copy the bytes in —
        // referencing a transient Swift buffer here is a use-after-free.
        var blockBuffer: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault,
                memoryBlock: nil,                   // let CoreMedia allocate
                blockLength: avcc.count,
                blockAllocator: kCFAllocatorDefault,
                customBlockSource: nil, offsetToData: 0,
                dataLength: avcc.count, flags: 0,
                blockBufferOut: &blockBuffer) == noErr,
              let blockBuffer else { return nil }
        let copyStatus = avcc.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(
                with: raw.baseAddress!, blockBuffer: blockBuffer,
                offsetIntoDestination: 0, dataLength: avcc.count)
        }
        guard copyStatus == noErr else { return nil }

        var sample: CMSampleBuffer?
        var sizeArr = [avcc.count]
        CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDesc,
            sampleCount: 1,
            sampleTimingEntryCount: 0, sampleTimingArray: nil,
            sampleSizeEntryCount: 1, sampleSizeArray: &sizeArr,
            sampleBufferOut: &sample)
        return sample
    }
}
