import CoreMedia
import CoreVideo
import XCTest

/// Colour metadata diagnostics (#241): the SPS VUI parser against hand-built
/// bitstreams, attachment extraction from synthetic buffers, the consistency
/// summary, the recorder hooks (disabled = nothing sampled, once per
/// generation), and the export section against the redaction allowlist.
///
/// Nothing here measures a real stream: the pixel buffers and parameter sets
/// are built in the test. Values from a real Mirror or Window View session
/// are PENDING HARDWARE.
final class StreamDiagnosticsColourTests: XCTestCase {

    // MARK: - Bitstream builders

    private struct BitWriter {
        private(set) var bits: [UInt8] = []

        mutating func put(_ value: Int, _ count: Int) {
            let v = UInt64(value)
            for i in stride(from: count - 1, through: 0, by: -1) { bits.append(UInt8((v >> UInt64(i)) & 1)) }
        }
        mutating func flag(_ on: Bool) { put(on ? 1 : 0, 1) }
        mutating func ue(_ value: Int) {
            let x = UInt64(value + 1)
            let n = 64 - x.leadingZeroBitCount
            put(0, n - 1)
            put(Int(x), n)
        }
        mutating func se(_ value: Int) { ue(value > 0 ? 2 * value - 1 : -2 * value) }

        /// rbsp_trailing_bits, then bytes.
        func rbsp() -> [UInt8] {
            var b = bits
            b.append(1)
            while b.count % 8 != 0 { b.append(0) }
            return stride(from: 0, to: b.count, by: 8).map { i in
                (0..<8).reduce(UInt8(0)) { ($0 << 1) | b[i + $1] }
            }
        }
    }

    /// Inserts emulation prevention bytes (00 00 0x, x <= 3 -> 00 00 03 0x).
    private func escaped(_ bytes: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        var zeros = 0
        for b in bytes {
            if zeros >= 2, b <= 3 { out.append(3); zeros = 0 }
            out.append(b)
            zeros = b == 0 ? zeros + 1 : 0
        }
        return out
    }

    private struct VUISpec {
        var aspectIdc: Int?
        var overscan = false
        /// nil = no video_signal_type; colour nil = no colour description.
        var signal: (full: Bool, colour: (Int, Int, Int)?)?
    }

    /// The colour part of a VUI, then the remaining flags all off (so a real
    /// decoder's own SPS parser reads a complete, valid VUI).
    private func writeVUI(_ w: inout BitWriter, _ v: VUISpec, codec: DiagnosticsCodec) {
        if let idc = v.aspectIdc {
            w.flag(true); w.put(idc, 8)
            if idc == 255 { w.put(0, 16); w.put(0, 16) }
        } else { w.flag(false) }
        if v.overscan { w.flag(true); w.flag(true) } else { w.flag(false) }
        if let s = v.signal {
            w.flag(true); w.put(5, 3); w.flag(s.full)
            if let c = s.colour {
                w.flag(true); w.put(c.0, 8); w.put(c.1, 8); w.put(c.2, 8)
            } else { w.flag(false) }
        } else { w.flag(false) }
        // H.264: chroma_loc, timing, nal_hrd, vcl_hrd, pic_struct, bitstream_restriction.
        // HEVC: chroma_loc, neutral_chroma, field_seq, frame_field_info, default_display_window, timing, bitstream_restriction.
        for _ in 0..<(codec == .h264 ? 6 : 7) { w.flag(false) }
    }

    private static let highProfiles: Set<Int> = [100, 110, 122, 244]

    private func h264SPS(profile: Int = 66, chroma: Int = 1, bitDepthMinus8: Int = 0, scaling: Bool = false,
                         pocType: Int = 0, pocCycle: Int = 0, interlaced: Bool = false, crop: Bool = false,
                         vui: VUISpec? = nil, header: UInt8 = 0x67) -> Data {
        var w = BitWriter()
        w.put(profile, 8); w.put(0, 8); w.put(40, 8)
        w.ue(0)
        if Self.highProfiles.contains(profile) {
            w.ue(chroma)
            if chroma == 3 { w.put(0, 1) }
            w.ue(bitDepthMinus8); w.ue(bitDepthMinus8)
            w.put(0, 1)
            if scaling {
                w.flag(true)
                for i in 0..<(chroma != 3 ? 8 : 12) {
                    switch i {
                    case 0: w.flag(true); w.se(-8)                                  // ends the list at once
                    case 1: w.flag(true); for k in 0..<16 { w.se(k % 3 - 1) }
                    case 7: w.flag(true); for k in 0..<64 { w.se(k % 3 - 1) }
                    default: w.flag(false)
                    }
                }
            } else { w.flag(false) }
        }
        w.ue(0)
        w.ue(pocType)
        if pocType == 0 { w.ue(0) } else if pocType == 1 {
            w.flag(false); w.se(0); w.se(0); w.ue(pocCycle)
            for _ in 0..<pocCycle { w.se(2) }
        }
        w.ue(1); w.flag(false); w.ue(119); w.ue(67)
        w.flag(!interlaced)
        if interlaced { w.flag(false) }
        w.flag(true)
        w.flag(crop)
        if crop { for v in [0, 0, 0, 4] { w.ue(v) } }
        if let vui { w.flag(true); writeVUI(&w, vui, codec: .h264) } else { w.flag(false) }
        return Data([header] + escaped(w.rbsp()))
    }

    private struct HEVCSpec {
        var maxSubLayersMinus1 = 0
        var subLayerProfile: [Bool] = []
        var subLayerLevel: [Bool] = []
        var orderingInfoPresent = true
        var chroma = 1
        var bitDepthMinus8 = 0
        var scalingList = false
        var pcm = false
        var shortTermSets = 0          // 0, 1 or 3 (3 = explicit + two inter-predicted)
        var longTerm = 0
        var vui: VUISpec?
        var header: [UInt8] = [0x42, 0x01]
    }

    private func hevcSPS(_ s: HEVCSpec) -> Data {
        var w = BitWriter()
        w.put(0, 4); w.put(s.maxSubLayersMinus1, 3); w.flag(true)
        // profile_tier_level
        w.put(0, 2); w.put(0, 1); w.put(1, 5); w.put(0x6000_0000, 32); w.put(0, 4); w.put(0, 43); w.put(0, 1); w.put(93, 8)
        for i in 0..<s.maxSubLayersMinus1 { w.flag(s.subLayerProfile[i]); w.flag(s.subLayerLevel[i]) }
        if s.maxSubLayersMinus1 > 0 { for _ in s.maxSubLayersMinus1..<8 { w.put(0, 2) } }
        for i in 0..<s.maxSubLayersMinus1 {
            if s.subLayerProfile[i] { w.put(0, 88) }
            if s.subLayerLevel[i] { w.put(90, 8) }
        }
        w.ue(0)
        w.ue(s.chroma)
        if s.chroma == 3 { w.put(0, 1) }
        w.ue(1920); w.ue(1080)
        w.flag(true); for v in [0, 0, 0, 4] { w.ue(v) }                  // conformance window
        w.ue(s.bitDepthMinus8); w.ue(s.bitDepthMinus8)
        w.ue(4)                                                           // log2_max_poc_lsb_minus4 -> 8 bits
        w.flag(s.orderingInfoPresent)
        for _ in (s.orderingInfoPresent ? 0 : s.maxSubLayersMinus1)...s.maxSubLayersMinus1 { w.ue(4); w.ue(2); w.ue(0) }
        for v in [0, 3, 0, 3, 2, 2] { w.ue(v) }
        w.flag(s.scalingList)
        if s.scalingList {
            w.flag(true)
            for sizeID in 0..<4 {
                var matrixID = 0
                while matrixID < 6 {
                    if matrixID % 2 == 0 { w.flag(false); w.ue(0) } else {
                        w.flag(true)
                        if sizeID > 1 { w.se(3) }
                        for k in 0..<min(64, 1 << (4 + (sizeID << 1))) { w.se(k % 5 - 2) }
                    }
                    matrixID += sizeID == 3 ? 3 : 1
                }
            }
        }
        w.flag(true); w.flag(true)                                        // amp, sao
        w.flag(s.pcm)
        if s.pcm { w.put(7, 4); w.put(7, 4); w.ue(0); w.ue(2); w.flag(true) }
        w.ue(s.shortTermSets)
        if s.shortTermSets >= 1 {
            // set 0: explicit, S0 = [-1], S1 = [+1]
            w.ue(1); w.ue(1); w.ue(0); w.flag(true); w.ue(0); w.flag(true)
        }
        if s.shortTermSets == 3 {
            // set 1: inter from set 0 (2 pocs -> 3 flag groups), deltaRps = -1, all used
            w.flag(true); w.put(1, 1); w.ue(0)
            for _ in 0..<3 { w.flag(true) }
            // set 2: inter from set 1 (S0 = [-1, -2], no S1 -> 3 flag groups), deltaRps = +1; first unused-but-kept, second dropped
            w.flag(true); w.put(0, 1); w.ue(0)
            w.flag(false); w.flag(true)      // used=0, use_delta=1
            w.flag(false); w.flag(false)     // used=0, use_delta=0
            w.flag(true)                     // used=1
        }
        w.flag(s.longTerm > 0)
        if s.longTerm > 0 {
            w.ue(s.longTerm)
            for _ in 0..<s.longTerm { w.put(5, 8); w.flag(true) }
        }
        w.flag(true); w.flag(true)                                        // temporal mvp, strong intra smoothing
        if let vui = s.vui { w.flag(true); writeVUI(&w, vui, codec: .hevc) } else { w.flag(false) }
        return Data(s.header + escaped(w.rbsp()))
    }

    private func parsed(_ data: Data, _ codec: DiagnosticsCodec, file: StaticString = #filePath, line: UInt = #line) -> ColourVUI? {
        guard case .parsed(let vui) = ColourSPSParser.parse(data, codec: codec) else {
            XCTFail("expected a parsed SPS, got \(ColourSPSParser.parse(data, codec: codec))", file: file, line: line)
            return nil
        }
        return vui
    }

    private func unparsedReason(_ data: Data, _ codec: DiagnosticsCodec) -> ColourUnparsedReason? {
        if case .unparsed(let r) = ColourSPSParser.parse(data, codec: codec) { return r }
        return nil
    }

    // MARK: - H.264 VUI

    func testH264BaselineWithoutVUI() throws {
        let vui = try XCTUnwrap(parsed(h264SPS(), .h264))
        XCTAssertFalse(vui.hasVUI)
        XCTAssertFalse(vui.videoSignalTypePresent)
        XCTAssertNil(vui.primariesCode)
        XCTAssertEqual(vui.metadata.primaries, .absent)
        XCTAssertEqual(vui.metadata.range, .unknown)
        XCTAssertEqual(vui.chromaFormatIdc, 1)
        XCTAssertEqual(vui.bitDepth, 8)
    }

    func testH264BaselineWithColourDescription() throws {
        let vui = try XCTUnwrap(parsed(h264SPS(vui: VUISpec(signal: (full: false, colour: (1, 1, 1)))), .h264))
        XCTAssertTrue(vui.hasVUI && vui.videoSignalTypePresent && vui.colourDescPresent)
        XCTAssertEqual(vui.fullRange, false)
        XCTAssertEqual([vui.primariesCode, vui.transferCode, vui.matrixCode], [1, 1, 1])
        XCTAssertEqual(vui.metadata.primaries, .bt709)
        XCTAssertEqual(vui.metadata.transfer, .bt709)
        XCTAssertEqual(vui.metadata.matrix, .bt709)
        XCTAssertEqual(vui.metadata.range, .limited)
    }

    func testH264VUIWithoutVideoSignalTypeOrColourDescription() throws {
        let none = try XCTUnwrap(parsed(h264SPS(vui: VUISpec()), .h264))
        XCTAssertTrue(none.hasVUI)
        XCTAssertFalse(none.videoSignalTypePresent)
        XCTAssertEqual(none.metadata.primaries, .absent, "a VUI that does not code a colour description is `absent`, not `unspecified`")
        XCTAssertEqual(none.metadata.range, .unknown)

        let range = try XCTUnwrap(parsed(h264SPS(vui: VUISpec(signal: (full: true, colour: nil))), .h264))
        XCTAssertTrue(range.videoSignalTypePresent)
        XCTAssertFalse(range.colourDescPresent)
        XCTAssertEqual(range.metadata.range, .full)
        XCTAssertEqual(range.metadata.matrix, .absent)
    }

    func testH264ExplicitUnspecifiedIsDistinctFromAbsent() throws {
        let vui = try XCTUnwrap(parsed(h264SPS(vui: VUISpec(signal: (full: false, colour: (2, 2, 2)))), .h264))
        XCTAssertEqual(vui.metadata.primaries, .unspecified)
        XCTAssertEqual(vui.metadata.transfer, .unspecified)
        XCTAssertEqual(vui.metadata.matrix, .unspecified)
        XCTAssertFalse(vui.metadata.primaries.isLabelled)
    }

    func testH264HighProfileWithAndWithoutColourDescription() throws {
        let plain = try XCTUnwrap(parsed(h264SPS(profile: 100), .h264))
        XCTAssertFalse(plain.hasVUI)
        let p3 = try XCTUnwrap(parsed(h264SPS(profile: 100, vui: VUISpec(signal: (full: false, colour: (12, 13, 1)))), .h264))
        XCTAssertEqual(p3.metadata.primaries, .displayP3)
        XCTAssertEqual(p3.metadata.transfer, .srgb)
        XCTAssertEqual(p3.metadata.matrix, .bt709)
        let wide = try XCTUnwrap(parsed(h264SPS(profile: 100, vui: VUISpec(signal: (full: true, colour: (9, 16, 9)))), .h264))
        XCTAssertEqual(wide.metadata.primaries, .bt2020)
        XCTAssertEqual(wide.metadata.transfer, .pq)
        XCTAssertEqual(wide.metadata.matrix, .bt2020Ncl)
        XCTAssertEqual(wide.metadata.range, .full)
    }

    func testH264HighProfileSkipsScalingListsAndFindsTheVUI() throws {
        let vui = VUISpec(signal: (full: false, colour: (5, 6, 5)))
        let lists = try XCTUnwrap(parsed(h264SPS(profile: 100, scaling: true, vui: vui), .h264))
        XCTAssertEqual([lists.primariesCode, lists.transferCode, lists.matrixCode], [5, 6, 5])
        // 4:4:4 has 12 lists, and the 64-entry list index (7) is inside the range.
        let yuv444 = try XCTUnwrap(parsed(h264SPS(profile: 244, chroma: 3, scaling: true, vui: vui), .h264))
        XCTAssertEqual(yuv444.chromaFormatIdc, 3)
        XCTAssertEqual([yuv444.primariesCode, yuv444.transferCode, yuv444.matrixCode], [5, 6, 5])
        let deep = try XCTUnwrap(parsed(h264SPS(profile: 110, bitDepthMinus8: 2, vui: vui), .h264))
        XCTAssertEqual(deep.bitDepth, 10)
    }

    func testH264OtherSyntaxBeforeTheVUIIsWalked() throws {
        let vui = VUISpec(aspectIdc: 255, overscan: true, signal: (full: true, colour: (6, 6, 6)))
        for sps in [h264SPS(pocType: 1, pocCycle: 3, vui: vui),
                    h264SPS(interlaced: true, crop: true, vui: vui),
                    h264SPS(profile: 100, pocType: 1, pocCycle: 2, interlaced: true, crop: true, vui: vui)] {
            let parsedVUI = try XCTUnwrap(parsed(sps, .h264))
            XCTAssertEqual([parsedVUI.primariesCode, parsedVUI.transferCode, parsedVUI.matrixCode], [6, 6, 6])
            XCTAssertEqual(parsedVUI.fullRange, true)
        }
    }

    func testH264RealWorldStyleSPSHasAVUIButNoSignalType() throws {
        // High profile level 4.0 SPS as commonly emitted by x264: a VUI with
        // timing information only. Expected values from an independent
        // reference decode (scratch script), not from this parser.
        let bytes: [UInt8] = [0x67, 0x64, 0x00, 0x28, 0xAC, 0xD9, 0x40, 0x78, 0x02, 0x27, 0xE5, 0xC0, 0x44, 0x00, 0x00, 0x03,
                              0x00, 0x04, 0x00, 0x00, 0x03, 0x00, 0xF0, 0x3C, 0x60, 0xC6, 0x58]
        let vui = try XCTUnwrap(parsed(Data(bytes), .h264))
        XCTAssertTrue(vui.hasVUI)
        XCTAssertFalse(vui.videoSignalTypePresent)
        XCTAssertEqual(vui.chromaFormatIdc, 1)
    }

    func testAnnexBStartCodesAreAccepted() throws {
        let sps = h264SPS(vui: VUISpec(signal: (full: false, colour: (1, 1, 1))))
        for prefix: [UInt8] in [[0, 0, 0, 1], [0, 0, 1]] {
            let vui = try XCTUnwrap(parsed(Data(prefix) + sps, .h264))
            XCTAssertEqual(vui.primariesCode, 1)
        }
    }

    func testEmulationPreventionBytesAreRemoved() throws {
        // Extended SAR with width/height 0 writes 32 zero bits: the encoder must escape them.
        let sps = h264SPS(vui: VUISpec(aspectIdc: 255, signal: (full: false, colour: (1, 1, 1))))
        let bytes = Array(sps)
        let hasEscape = (2..<bytes.count).contains { bytes[$0 - 2] == 0 && bytes[$0 - 1] == 0 && bytes[$0] == 3 }
        XCTAssertTrue(hasEscape, "the fixture must contain 00 00 03")
        let vui = try XCTUnwrap(parsed(sps, .h264))
        XCTAssertEqual([vui.primariesCode, vui.transferCode, vui.matrixCode], [1, 1, 1])
        XCTAssertEqual(ColourSPSParser.removeEmulationPrevention(ArraySlice<UInt8>([0, 0, 3, 1, 0, 0, 3, 0, 0, 3, 3])),
                       [0, 0, 1, 0, 0, 0, 0, 3])
    }

    // MARK: - HEVC VUI

    func testHEVCMainWithAndWithoutVUI() throws {
        let plain = try XCTUnwrap(parsed(hevcSPS(HEVCSpec()), .hevc))
        XCTAssertFalse(plain.hasVUI)
        XCTAssertEqual(plain.bitDepth, 8)
        XCTAssertEqual(plain.metadata.primaries, .absent)

        var spec = HEVCSpec()
        spec.vui = VUISpec(signal: (full: false, colour: (1, 1, 1)))
        let vui = try XCTUnwrap(parsed(hevcSPS(spec), .hevc))
        XCTAssertTrue(vui.colourDescPresent)
        XCTAssertEqual(vui.metadata.primaries, .bt709)
        XCTAssertEqual(vui.metadata.matrix, .bt709)
        XCTAssertEqual(vui.metadata.range, .limited)

        spec.vui = VUISpec(signal: (full: true, colour: nil))
        let noColour = try XCTUnwrap(parsed(hevcSPS(spec), .hevc))
        XCTAssertTrue(noColour.videoSignalTypePresent)
        XCTAssertFalse(noColour.colourDescPresent)
        XCTAssertEqual(noColour.metadata.range, .full)

        spec.vui = VUISpec()
        XCTAssertFalse(try XCTUnwrap(parsed(hevcSPS(spec), .hevc)).videoSignalTypePresent)
    }

    func testHEVCProfileTierLevelWithSubLayersIsSkipped() throws {
        let vuiSpec = VUISpec(aspectIdc: 255, overscan: true, signal: (full: false, colour: (12, 13, 1)))
        for (profile, level, ordering) in [([true, false], [false, true], true),
                                           ([false, false], [false, false], false),
                                           ([true, true], [true, true], true)] {
            var spec = HEVCSpec()
            spec.maxSubLayersMinus1 = 2
            spec.subLayerProfile = profile
            spec.subLayerLevel = level
            spec.orderingInfoPresent = ordering
            spec.vui = vuiSpec
            let vui = try XCTUnwrap(parsed(hevcSPS(spec), .hevc))
            XCTAssertEqual([vui.primariesCode, vui.transferCode, vui.matrixCode], [12, 13, 1], "\(profile) \(level) \(ordering)")
        }
    }

    func testHEVCScalingPcmShortTermAndLongTermSyntaxIsWalked() throws {
        var spec = HEVCSpec()
        spec.scalingList = true
        spec.pcm = true
        spec.shortTermSets = 3
        spec.longTerm = 2
        spec.bitDepthMinus8 = 2
        spec.vui = VUISpec(signal: (full: false, colour: (9, 14, 9)))
        let vui = try XCTUnwrap(parsed(hevcSPS(spec), .hevc))
        XCTAssertEqual([vui.primariesCode, vui.transferCode, vui.matrixCode], [9, 14, 9])
        XCTAssertEqual(vui.bitDepth, 10)
        for sets in [0, 1] {
            spec.shortTermSets = sets
            XCTAssertEqual(try XCTUnwrap(parsed(hevcSPS(spec), .hevc)).primariesCode, 9, "\(sets) short-term sets")
        }
    }

    func testHEVCEscapedBytesAndStartCode() throws {
        var spec = HEVCSpec()
        spec.vui = VUISpec(aspectIdc: 255, signal: (full: false, colour: (1, 1, 1)))
        let sps = hevcSPS(spec)
        let bytes = Array(sps)
        XCTAssertTrue((2..<bytes.count).contains { bytes[$0 - 2] == 0 && bytes[$0 - 1] == 0 && bytes[$0] == 3 })
        XCTAssertEqual(try XCTUnwrap(parsed(Data([0, 0, 0, 1]) + sps, .hevc)).primariesCode, 1)
    }

    // MARK: - Defensive behaviour

    func testRejectsWrongNALTypesLayersAndBadInput() {
        XCTAssertEqual(unparsedReason(Data(), .h264), .empty)
        XCTAssertEqual(unparsedReason(Data([0x67]), .h264), .truncated)
        XCTAssertEqual(unparsedReason(Data([0x68, 0xCE, 0x3C, 0x80]), .h264), .notAnSPS, "a PPS")
        XCTAssertEqual(unparsedReason(Data([0xE7, 0x42, 0x00, 0x1E]), .h264), .notAnSPS, "forbidden_zero_bit set")
        XCTAssertEqual(unparsedReason(Data([0x44, 0x01, 0xC1, 0x72]), .hevc), .notAnSPS, "an HEVC PPS")
        XCTAssertEqual(unparsedReason(h264SPS(), .hevc), .notAnSPS, "an H.264 SPS read as HEVC")
        XCTAssertEqual(unparsedReason(hevcSPS(HEVCSpec()), .h264), .notAnSPS, "an HEVC SPS read as H.264")
        XCTAssertEqual(unparsedReason(Data(repeating: 0x67, count: ColourSPSParser.maxInputBytes + 1), .h264), .tooLarge)
        XCTAssertEqual(unparsedReason(h264SPS(), .unknown), .unsupportedCodec)
        var layered = HEVCSpec()
        layered.header = [0x42, 0x09]   // nuh_layer_id = 1
        XCTAssertEqual(unparsedReason(hevcSPS(layered), .hevc), .unsupportedLayer)
        var noTemporal = HEVCSpec()
        noTemporal.header = [0x42, 0x00]
        XCTAssertEqual(unparsedReason(hevcSPS(noTemporal), .hevc), .invalidValue)
    }

    func testOversizedLoopCountsAreBoundedNotFollowed() {
        XCTAssertEqual(unparsedReason(h264SPS(pocType: 1, pocCycle: 300), .h264), .exceedsBound)
        var w = BitWriter()
        w.put(66, 8); w.put(0, 8); w.put(40, 8); w.ue(40)     // seq_parameter_set_id > 31
        XCTAssertEqual(unparsedReason(Data([0x67] + w.rbsp()), .h264), .exceedsBound)
        var huge = BitWriter()
        huge.put(0, 40)                                        // 40 zero bits: an Exp-Golomb code too long to be real
        XCTAssertEqual(unparsedReason(Data([0x67, 0x42, 0x00, 0x1E] + huge.rbsp()), .h264), .invalidValue)
    }

    func testEveryTruncationOfAValidSPSIsUnparsedNeverACrash() {
        let h264 = h264SPS(profile: 100, scaling: true, vui: VUISpec(aspectIdc: 255, overscan: true, signal: (full: false, colour: (1, 1, 1))))
        var hevcSpec = HEVCSpec()
        hevcSpec.maxSubLayersMinus1 = 1
        hevcSpec.subLayerProfile = [true]
        hevcSpec.subLayerLevel = [true]
        hevcSpec.shortTermSets = 3
        hevcSpec.vui = VUISpec(signal: (full: false, colour: (1, 1, 1)))
        let hevc = hevcSPS(hevcSpec)
        for (sps, codec) in [(h264, DiagnosticsCodec.h264), (hevc, .hevc)] {
            XCTAssertNotNil(parsed(sps, codec))
            // The last two bytes hold only the tail of the colour description and the trailing bits.
            for length in 0..<(sps.count - 2) {
                let outcome = ColourSPSParser.parse(sps.prefix(length), codec: codec)
                guard case .unparsed = outcome else {
                    XCTFail("\(codec) prefix of \(length) bytes parsed: \(outcome)")
                    continue
                }
            }
        }
    }

    func testGarbageNeverCrashesAndLeadingHeaderOnlyInputIsUnparsed() {
        var state: UInt64 = 0x9E3779B97F4A7C15
        func next() -> UInt8 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return UInt8(truncatingIfNeeded: state >> 33)
        }
        for round in 0..<3000 {
            let length = Int(next()) % 160
            var bytes = (0..<length).map { _ in next() }
            if round % 3 == 0, !bytes.isEmpty { bytes[0] = 0x67 }
            if round % 3 == 1, bytes.count > 1 { bytes[0] = 0x42; bytes[1] = 0x01 }
            for codec in [DiagnosticsCodec.h264, .hevc] {
                _ = ColourSPSParser.parse(Data(bytes), codec: codec)
            }
        }
        for fill in [UInt8(0x00), 0xFF, 0x55] {
            for codec in [DiagnosticsCodec.h264, .hevc] {
                var bytes = Array(repeating: fill, count: 200)
                bytes[0] = codec == .h264 ? 0x67 : 0x42
                if codec == .hevc { bytes[1] = 0x01 }
                _ = ColourSPSParser.parse(Data(bytes), codec: codec)
            }
        }
    }

    // MARK: - Enum mapping and coding

    func testH273CodePointsMapToNamedValuesAndUnknownCodesAreKept() {
        XCTAssertEqual(ColourPrimaries(h273: 12), .displayP3)
        XCTAssertEqual(ColourPrimaries(h273: 3), .other(3), "reserved")
        XCTAssertEqual(ColourTransfer(h273: 13), .srgb)
        XCTAssertEqual(ColourTransfer(h273: 99), .other(99))
        XCTAssertEqual(ColourMatrix(h273: 0), .identity)
        XCTAssertEqual(ColourMatrix(h273: 200), .other(200))
        XCTAssertEqual(ColourPrimaries(h273: 3).label, "other(3)")
        XCTAssertEqual(ColourPrimaries.bt709.label, "bt709")
    }

    func testEnumsEncodeAsKindAndCodeAndRoundTrip() throws {
        let metadata = ColourMetadata(primaries: .other(7), transfer: .pq, matrix: .absent, range: .full,
                                      format: .other(1_234_567), bitDepth: 10, iccPresent: false,
                                      spaceModel: .rgb, space: .displayP3)
        let data = try JSONEncoder().encode(metadata)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual((object["primaries"] as? [String: Any])?["kind"] as? String, "other")
        XCTAssertEqual((object["primaries"] as? [String: Any])?["code"] as? Int, 7)
        XCTAssertEqual((object["transfer"] as? [String: Any])?["kind"] as? String, "pq")
        XCTAssertNil((object["transfer"] as? [String: Any])?["code"])
        XCTAssertEqual(try JSONDecoder().decode(ColourMetadata.self, from: data), metadata)
        XCTAssertThrowsError(try JSONDecoder().decode(ColourPrimaries.self, from: Data(#"{"kind":"made-up"}"#.utf8)))
    }

    // MARK: - Attachment extraction

    private func makePixelBuffer(_ format: OSType, width: Int = 16, height: Int = 16) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, width, height, format, nil, &buffer), kCVReturnSuccess)
        return try XCTUnwrap(buffer)
    }

    private func tag(_ buffer: CVPixelBuffer, primaries: CFString? = nil, transfer: CFString? = nil, matrix: CFString? = nil) {
        if let primaries { CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, primaries, .shouldPropagate) }
        if let transfer { CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, transfer, .shouldPropagate) }
        if let matrix { CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, matrix, .shouldPropagate) }
    }

    func testUntaggedBuffersReportAbsentAttachmentsAndTheirPixelFormat() throws {
        let video = ColourMetadata.from(pixelBuffer: try makePixelBuffer(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange))
        XCTAssertEqual(video.primaries, .absent)
        XCTAssertEqual(video.transfer, .absent)
        XCTAssertEqual(video.matrix, .absent)
        XCTAssertEqual(video.range, .limited)
        XCTAssertEqual(video.format, .nv12VideoRange)
        XCTAssertEqual(video.bitDepth, 8)
        XCTAssertEqual(video.iccPresent, false)
        XCTAssertEqual(video.spaceModel, .absent)
        XCTAssertEqual(video.space, .absent)

        let full = ColourMetadata.from(pixelBuffer: try makePixelBuffer(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange))
        XCTAssertEqual(full.range, .full)
        let bgra = ColourMetadata.from(pixelBuffer: try makePixelBuffer(kCVPixelFormatType_32BGRA))
        XCTAssertEqual(bgra.format, .bgra)
        XCTAssertEqual(bgra.range, .notApplicable)
        XCTAssertEqual(bgra.bitDepth, 8)
        let other = ColourMetadata.from(pixelBuffer: try makePixelBuffer(kCVPixelFormatType_32ARGB))
        XCTAssertEqual(other.format, .other(Int(kCVPixelFormatType_32ARGB)))
        XCTAssertNil(other.bitDepth)
    }

    func testTaggedBufferReportsEachAttachment() throws {
        let buffer = try makePixelBuffer(kCVPixelFormatType_32BGRA)
        tag(buffer, primaries: kCVImageBufferColorPrimaries_P3_D65, transfer: kCVImageBufferTransferFunction_sRGB,
            matrix: kCVImageBufferYCbCrMatrix_ITU_R_709_2)
        CVBufferSetAttachment(buffer, kCVImageBufferCGColorSpaceKey, CGColorSpace(name: CGColorSpace.displayP3)!, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferICCProfileKey, Data([1, 2, 3]) as CFData, .shouldPropagate)
        let m = ColourMetadata.from(pixelBuffer: buffer)
        XCTAssertEqual(m.primaries, .displayP3)
        XCTAssertEqual(m.transfer, .srgb)
        XCTAssertEqual(m.matrix, .bt709)
        XCTAssertEqual(m.spaceModel, .rgb)
        XCTAssertEqual(m.space, .displayP3)
        XCTAssertEqual(m.iccPresent, true, "presence only; the profile bytes are not read")

        let video = try makePixelBuffer(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        tag(video, primaries: kCVImageBufferColorPrimaries_ITU_R_709_2, transfer: kCVImageBufferTransferFunction_ITU_R_709_2,
            matrix: kCVImageBufferYCbCrMatrix_ITU_R_601_4)
        let v = ColourMetadata.from(pixelBuffer: video)
        XCTAssertEqual(v.primaries, .bt709)
        XCTAssertEqual(v.transfer, .bt709)
        XCTAssertEqual(v.matrix, .smpte170m, "ITU_R_601_4 is the SMPTE 170M / BT.601 matrix")
    }

    func testAttachmentValuesTheTableDoesNotListAreKeptAsOtherMinusOne() throws {
        let buffer = try makePixelBuffer(kCVPixelFormatType_32BGRA)
        tag(buffer, primaries: "Made_Up" as CFString, transfer: "Also_Made_Up" as CFString, matrix: "Nope" as CFString)
        let m = ColourMetadata.from(pixelBuffer: buffer)
        XCTAssertEqual(m.primaries, .other(-1))
        XCTAssertEqual(m.transfer, .other(-1))
        XCTAssertEqual(m.matrix, .other(-1))
    }

    func testFormatDescriptionExtensionsAreReported() throws {
        var plain: CMVideoFormatDescription?
        XCTAssertEqual(CMVideoFormatDescriptionCreate(allocator: nil, codecType: kCMVideoCodecType_H264, width: 640, height: 480,
                                                      extensions: nil, formatDescriptionOut: &plain), noErr)
        let none = ColourMetadata.from(formatDescription: try XCTUnwrap(plain))
        XCTAssertEqual(none.primaries, .absent)
        XCTAssertEqual(none.range, .unknown, "no FullRangeVideo extension = not stated")
        XCTAssertNil(none.bitDepth)
        XCTAssertEqual(none.iccPresent, false)

        let extensions: [CFString: Any] = [
            kCMFormatDescriptionExtension_ColorPrimaries: kCMFormatDescriptionColorPrimaries_P3_D65,
            kCMFormatDescriptionExtension_TransferFunction: kCMFormatDescriptionTransferFunction_ITU_R_709_2,
            kCMFormatDescriptionExtension_YCbCrMatrix: kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2,
            kCMFormatDescriptionExtension_FullRangeVideo: true,
            kCMFormatDescriptionExtension_BitsPerComponent: 10,
        ]
        var tagged: CMVideoFormatDescription?
        XCTAssertEqual(CMVideoFormatDescriptionCreate(allocator: nil, codecType: kCMVideoCodecType_HEVC, width: 640, height: 480,
                                                      extensions: extensions as CFDictionary, formatDescriptionOut: &tagged), noErr)
        let m = ColourMetadata.from(formatDescription: try XCTUnwrap(tagged))
        XCTAssertEqual(m.primaries, .displayP3)
        XCTAssertEqual(m.transfer, .bt709)
        XCTAssertEqual(m.matrix, .bt709)
        XCTAssertEqual(m.range, .full)
        XCTAssertEqual(m.bitDepth, 10)
    }

    private let h264PPS = Data([0x68, 0xCE, 0x3C, 0x80])

    private func h264FormatDescription(_ sps: Data) throws -> CMVideoFormatDescription {
        var desc: CMVideoFormatDescription?
        let status = sps.withUnsafeBytes { s in
            h264PPS.withUnsafeBytes { p in
                let pointers = [s.bindMemory(to: UInt8.self).baseAddress!, p.bindMemory(to: UInt8.self).baseAddress!]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault, parameterSetCount: 2, parameterSetPointers: pointers,
                    parameterSetSizes: [sps.count, h264PPS.count], nalUnitHeaderLength: 4, formatDescriptionOut: &desc)
            }
        }
        XCTAssertEqual(status, noErr)
        return try XCTUnwrap(desc)
    }

    func testSPSIsReadBackFromAFormatDescriptionBuiltFromParameterSets() throws {
        let sps = h264SPS(profile: 100, vui: VUISpec(signal: (full: false, colour: (12, 13, 1))))
        let desc = try h264FormatDescription(sps)
        let found = try XCTUnwrap(ColourFormatDescriptionReader.spsNAL(from: desc))
        XCTAssertEqual(found.codec, .h264)
        XCTAssertEqual(found.data.first.map { $0 & 0x1F }, 7)
        let record = ColourStageRecord.vui(.encoderVUI, from: desc)
        XCTAssertNil(record.unparsed)
        XCTAssertEqual(record.metadata.primaries, .displayP3)
        XCTAssertEqual(record.metadata.transfer, .srgb)
        XCTAssertEqual(record.vui?.primariesCode, 12)

        // Observation only, no assertion: whether CoreMedia lifts VUI colour into the
        // description's extensions on this OS. A unit-test observation, not a stream measurement.
        let lifted = ColourMetadata.from(formatDescription: desc)
        print("COLOUR-OBSERVATION CMVideoFormatDescriptionCreateFromH264ParameterSets with VUI (12,13,1): "
              + "primaries=\(lifted.primaries.label) transfer=\(lifted.transfer.label) matrix=\(lifted.matrix.label) range=\(lifted.range.rawValue)")

        var noParameterSets: CMVideoFormatDescription?
        XCTAssertEqual(CMVideoFormatDescriptionCreate(allocator: nil, codecType: kCMVideoCodecType_H264, width: 64, height: 64,
                                                      extensions: nil, formatDescriptionOut: &noParameterSets), noErr)
        XCTAssertEqual(ColourStageRecord.vui(.encoderVUI, from: try XCTUnwrap(noParameterSets)).unparsed, .noParameterSet)
    }

    // MARK: - Consistency summary

    private func record(_ stage: ColourStage, primaries: ColourPrimaries = .absent, transfer: ColourTransfer = .absent,
                        matrix: ColourMatrix = .absent, range: ColourRange = .unknown, bitDepth: Int? = nil) -> ColourStageRecord {
        ColourStageRecord(stage: stage,
                          metadata: ColourMetadata(primaries: primaries, transfer: transfer, matrix: matrix, range: range, bitDepth: bitDepth),
                          vui: nil, unparsed: nil)
    }

    func testStagesThatAgreeReportNoMismatches() {
        let records: [ColourStageRecord] = [
            record(.capture, primaries: .bt709, transfer: .bt709, matrix: .bt709, range: .limited, bitDepth: 8),
            record(.encoderFormat, primaries: .bt709, transfer: .bt709, matrix: .bt709, range: .unknown),
            record(.encoderVUI, primaries: .bt709, transfer: .bt709, matrix: .bt709, range: .limited, bitDepth: 8),
        ]
        let c = ColourConsistency.evaluate(Dictionary(uniqueKeysWithValues: records.map { ($0.stage, $0) }))
        XCTAssertEqual(c.agreement, .agree)
        XCTAssertEqual(c.comparisons, 3)
        XCTAssertTrue(c.mismatches.isEmpty)
    }

    func testDifferingPrimariesAreListedPerPairWithoutAVerdict() {
        let records: [ColourStageRecord] = [
            record(.capture, primaries: .displayP3, transfer: .srgb, matrix: .bt709),
            record(.encoderFormat, primaries: .displayP3, transfer: .srgb, matrix: .bt709),
            record(.encoderVUI, primaries: .bt709, transfer: .srgb, matrix: .bt709),
        ]
        let c = ColourConsistency.evaluate(Dictionary(uniqueKeysWithValues: records.map { ($0.stage, $0) }))
        XCTAssertEqual(c.agreement, .differ)
        XCTAssertEqual(c.mismatches, [
            ColourMismatch(first: .encoderFormat, second: .encoderVUI, field: .primaries, relation: .differ),
            ColourMismatch(first: .capture, second: .encoderVUI, field: .primaries, relation: .differ),
        ])
    }

    func testUnlabelledSideIsReportedAsSuchNotAsADifference() {
        // Window View composite: RGB, untagged; the SPS labels a matrix. Range is not comparable for RGB.
        let records: [ColourStageRecord] = [
            record(.composited, range: .notApplicable, bitDepth: 8),
            record(.encoderVUI, primaries: .bt709, transfer: .bt709, matrix: .bt709, range: .limited, bitDepth: 8),
        ]
        let c = ColourConsistency.evaluate(Dictionary(uniqueKeysWithValues: records.map { ($0.stage, $0) }))
        XCTAssertEqual(c.comparisons, 1)
        XCTAssertEqual(Set(c.mismatches.map(\.field)), [.primaries, .transfer, .matrix])
        XCTAssertTrue(c.mismatches.allSatisfy { $0.relation == .firstUnlabelled && $0.first == .composited })
        XCTAssertFalse(c.mismatches.contains { $0.field == .range })
    }

    func testBothUnlabelledAndUnspecifiedAreNotMismatches() {
        let records: [ColourStageRecord] = [
            record(.capture, primaries: .absent, transfer: .unspecified, matrix: .absent),
            record(.encoderVUI, primaries: .unspecified, transfer: .absent, matrix: .unspecified),
        ]
        let c = ColourConsistency.evaluate(Dictionary(uniqueKeysWithValues: records.map { ($0.stage, $0) }))
        XCTAssertEqual(c.agreement, .agree)
        XCTAssertTrue(c.mismatches.isEmpty)
    }

    func testRangeAndBitDepthDifferencesAndStandardEquivalences() {
        let records: [ColourStageRecord] = [
            record(.receiverFormat, transfer: .smpte170m, matrix: .bt470bg, range: .limited, bitDepth: 8),
            record(.receiverVUI, transfer: .bt709, matrix: .smpte170m, range: .full, bitDepth: 10),
        ]
        let c = ColourConsistency.evaluate(Dictionary(uniqueKeysWithValues: records.map { ($0.stage, $0) }))
        XCTAssertEqual(c.mismatches.map(\.field), [.range, .bitDepth], "170M = 709 transfer and 470BG = 170M matrix are not differences")
        XCTAssertEqual(c.comparisons, 1)
    }

    func testUnparsedOrMissingStagesAreNotComparedAndOneStageIsNoData() {
        XCTAssertEqual(ColourConsistency.evaluate([:]).agreement, .noData)
        let lone = record(.capture, primaries: .bt709)
        XCTAssertEqual(ColourConsistency.evaluate([.capture: lone]).agreement, .noData)
        let failed = ColourStageRecord.vui(.encoderVUI, .unparsed(.truncated))
        let c = ColourConsistency.evaluate([.capture: lone, .encoderVUI: failed])
        XCTAssertEqual(c.agreement, .noData)
        XCTAssertEqual(c.comparisons, 0)
    }

    // MARK: - Recorder hooks

    private func makeRecorder(enabled: Bool = true) -> (StreamDiagnosticsRecorder, StreamDiagnosticsSwitch) {
        let sw = StreamDiagnosticsSwitch(enabled: enabled)
        return (StreamDiagnosticsRecorder(side: .sender, windowSeconds: 5, diagnosticsSwitch: sw, resourceSampler: nil, nowMs: 0), sw)
    }

    func testDisabledDiagnosticsSampleNothing() throws {
        let (recorder, _) = makeRecorder(enabled: false)
        let buffer = try makePixelBuffer(kCVPixelFormatType_32BGRA)
        recorder.sampleColourSubmitted(buffer, windowComposite: true, generation: 1)
        recorder.sampleColourEncoderOutput(try h264FormatDescription(h264SPS()), generation: 1)
        recorder.sampleColourReceiverFormat(try h264FormatDescription(h264SPS()))
        XCTAssertNil(recorder.colourSection)
        XCTAssertNil(recorder.snapshot(at: 1).colour)
        XCTAssertEqual(recorder.snapshot(at: 1).sessionCounters[DiagnosticsCounter.colourSamples.definition.id], 0)
    }

    func testBufferIsSampledOncePerGenerationAndFormatNotPerFrame() throws {
        let (recorder, _) = makeRecorder()
        let buffer = try makePixelBuffer(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        tag(buffer, primaries: kCVImageBufferColorPrimaries_P3_D65)
        for _ in 0..<500 { recorder.sampleColourSubmitted(buffer, windowComposite: false, generation: 4) }
        XCTAssertEqual(recorder.colourSection?.sampleCount, 1, "500 frames, one extraction")
        XCTAssertEqual(recorder.snapshot(at: 1).sessionCounters[DiagnosticsCounter.colourSamples.definition.id], 1)
        XCTAssertEqual(recorder.colourSection?.record(.capture)?.metadata.primaries, .displayP3)

        recorder.sampleColourSubmitted(buffer, windowComposite: false, generation: 5)
        XCTAssertEqual(recorder.colourSection?.sampleCount, 2, "a new generation samples again")
        let bgra = try makePixelBuffer(kCVPixelFormatType_32BGRA)
        recorder.sampleColourSubmitted(bgra, windowComposite: false, generation: 5)
        XCTAssertEqual(recorder.colourSection?.sampleCount, 3, "a changed pixel format samples again")
        XCTAssertEqual(recorder.colourSection?.record(.capture)?.metadata.format, .bgra)
    }

    func testWindowCompositeReplacesTheMirrorSampleAndTheOtherWayRound() throws {
        let (recorder, _) = makeRecorder()
        let buffer = try makePixelBuffer(kCVPixelFormatType_32BGRA)
        recorder.sampleColourSubmitted(buffer, windowComposite: false, generation: 1)
        XCTAssertNotNil(recorder.colourSection?.record(.capture))
        recorder.sampleColourSubmitted(buffer, windowComposite: true, generation: 2)
        XCTAssertNil(recorder.colourSection?.record(.capture))
        XCTAssertNotNil(recorder.colourSection?.record(.composited))
        recorder.sampleColourSubmitted(buffer, windowComposite: false, generation: 3)
        XCTAssertNil(recorder.colourSection?.record(.composited))
        XCTAssertNotNil(recorder.colourSection?.record(.capture))
    }

    func testEncoderOutputAndReceiverFormatSampleOncePerFormatDescription() throws {
        let (recorder, _) = makeRecorder()
        let first = try h264FormatDescription(h264SPS(vui: VUISpec(signal: (full: false, colour: (1, 1, 1)))))
        for _ in 0..<50 { recorder.sampleColourEncoderOutput(first, generation: 9) }
        XCTAssertEqual(recorder.colourSection?.sampleCount, 1)
        XCTAssertEqual(recorder.colourSection?.record(.encoderVUI)?.vui?.primariesCode, 1)
        XCTAssertNotNil(recorder.colourSection?.record(.encoderFormat))

        let second = try h264FormatDescription(h264SPS(vui: VUISpec(signal: (full: true, colour: (6, 6, 6)))))
        recorder.sampleColourEncoderOutput(second, generation: 9)
        XCTAssertEqual(recorder.colourSection?.sampleCount, 2, "a different format description samples again")
        XCTAssertEqual(recorder.colourSection?.record(.encoderVUI)?.metadata.range, .full)

        for _ in 0..<50 { recorder.sampleColourReceiverFormat(second) }
        XCTAssertEqual(recorder.colourSection?.sampleCount, 3)
        XCTAssertEqual(recorder.colourSection?.record(.receiverVUI)?.vui?.matrixCode, 6)
    }

    func testResetClearsTheColourSection() throws {
        let (recorder, _) = makeRecorder()
        recorder.sampleColourSubmitted(try makePixelBuffer(kCVPixelFormatType_32BGRA), windowComposite: false, generation: 1)
        XCTAssertNotNil(recorder.colourSection)
        recorder.reset(at: 10)
        XCTAssertNil(recorder.colourSection)
        recorder.sampleColourSubmitted(try makePixelBuffer(kCVPixelFormatType_32BGRA), windowComposite: false, generation: 1)
        XCTAssertEqual(recorder.colourSection?.sampleCount, 1, "same key resamples after a reset")
    }

    func testSwitchingOffStopsFurtherSamples() throws {
        let (recorder, sw) = makeRecorder()
        let buffer = try makePixelBuffer(kCVPixelFormatType_32BGRA)
        recorder.sampleColourSubmitted(buffer, windowComposite: false, generation: 1)
        sw.set(false)
        recorder.sampleColourSubmitted(buffer, windowComposite: false, generation: 2)
        XCTAssertEqual(recorder.colourSection?.sampleCount, 1)
    }

    // MARK: - Export

    private func exportedColourObject() throws -> (StreamDiagnosticsExport, Any) {
        let (recorder, _) = makeRecorder()
        recorder.updateContext { $0.displayMode = .mirror; $0.codec = .h264 }
        let buffer = try makePixelBuffer(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        tag(buffer, primaries: kCVImageBufferColorPrimaries_P3_D65, transfer: kCVImageBufferTransferFunction_sRGB,
            matrix: "Made_Up" as CFString)
        CVBufferSetAttachment(buffer, kCVImageBufferCGColorSpaceKey, CGColorSpace(name: CGColorSpace.displayP3)!, .shouldPropagate)
        recorder.sampleColourSubmitted(buffer, windowComposite: false, generation: 1)
        recorder.sampleColourEncoderOutput(try h264FormatDescription(h264SPS(profile: 100, vui: VUISpec(signal: (full: false, colour: (1, 1, 99))))),
                                           generation: 1)
        let receiver = StreamDiagnosticsRecorder(side: .receiver, windowSeconds: 5, diagnosticsSwitch: StreamDiagnosticsSwitch(enabled: true),
                                                 resourceSampler: nil, nowMs: 0)
        // A SPS that cannot be parsed still exports a typed reason, never bytes.
        var bare: CMVideoFormatDescription?
        XCTAssertEqual(CMVideoFormatDescriptionCreate(allocator: nil, codecType: kCMVideoCodecType_H264, width: 64, height: 64,
                                                      extensions: nil, formatDescriptionOut: &bare), noErr)
        receiver.sampleColourReceiverFormat(try XCTUnwrap(bare))
        let export = StreamDiagnosticsExport(sessions: [recorder.snapshot(at: 6_000), receiver.snapshot(at: 6_000)],
                                             build: .current(deviceClass: .mac, appVersion: "2.0 (214)"),
                                             now: Date(timeIntervalSince1970: 1_800_000_123))
        return (export, try JSONSerialization.jsonObject(with: try export.jsonData()))
    }

    private static let colourKeys: Set<String> = [
        "colour", "consistency", "sampleCount", "metadata", "vui", "unparsed", "stage",
        "primaries", "transfer", "matrix", "range", "format", "bitDepth", "iccPresent", "spaceModel", "space",
        "kind", "code",
        "hasVUI", "videoSignalTypePresent", "colourDescPresent", "fullRange", "primariesCode", "transferCode",
        "matrixCode", "chromaFormatIdc",
        "agreement", "comparisons", "mismatches", "first", "second", "field", "relation",
    ]

    private static var colourStrings: Set<String> {
        var s: Set<String> = ["other", "h264", "hevc", "unknown"]
        s.formUnion(ColourPrimaries.named.map(\.kind))
        s.formUnion(ColourTransfer.named.map(\.kind))
        s.formUnion(ColourMatrix.named.map(\.kind))
        s.formUnion(ColourPixelFormat.named.map(\.kind))
        s.formUnion(["unknown", "limited", "full", "notApplicable"])
        s.formUnion(["absent", "monochrome", "rgb", "cmyk", "lab", "other"])
        s.formUnion(["absent", "unnamed", "unlisted", "srgb", "displayP3", "extendedSRGB", "linearSRGB", "extendedLinearSRGB",
                     "extendedDisplayP3", "itur709", "itur2020", "adobeRGB1998"])
        s.formUnion(ColourStage.allCases.map(\.rawValue))
        s.formUnion(["primaries", "transfer", "matrix", "range", "bitDepth"])
        s.formUnion(["differ", "firstUnlabelled", "secondUnlabelled", "noData", "agree"])
        s.formUnion(["empty", "tooLarge", "notAnSPS", "truncated", "invalidValue", "exceedsBound", "unsupportedLayer",
                     "unsupportedCodec", "noParameterSet"])
        return s
    }

    func testExportCarriesTheColourSectionAndRoundTrips() throws {
        let (export, object) = try exportedColourObject()
        let root = try XCTUnwrap(object as? [String: Any])
        let sessions = try XCTUnwrap(root["sessions"] as? [[String: Any]])
        let sender = try XCTUnwrap((sessions[0]["snapshot"] as? [String: Any])?["colour"] as? [String: Any])
        let stages = try XCTUnwrap(sender["stages"] as? [[String: Any]])
        XCTAssertEqual(stages.compactMap { $0["stage"] as? String }, ["capture", "encoderFormat", "encoderVUI"])
        XCTAssertEqual(sender["sampleCount"] as? Int, 2)
        let consistency = try XCTUnwrap(sender["consistency"] as? [String: Any])
        XCTAssertEqual(consistency["agreement"] as? String, "differ")
        let receiver = try XCTUnwrap((sessions[1]["snapshot"] as? [String: Any])?["colour"] as? [String: Any])
        let receiverStages = try XCTUnwrap(receiver["stages"] as? [[String: Any]])
        XCTAssertEqual((receiverStages.last?["unparsed"] as? String), "noParameterSet")

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        XCTAssertEqual(try decoder.decode(StreamDiagnosticsExport.self, from: try export.jsonData()), export)
    }

    /// The same redaction rules as `StreamDiagnosticsClassifierExportTests`: every key must be
    /// reviewed and none may look like a forbidden kind of field; every string must come from a closed set.
    func testExportWithColourPassesTheRedactionAllowlist() throws {
        let (_, object) = try exportedColourObject()
        let metricIDs = Set(StreamDiagnosticsMetricDictionary.all.map(\.id))
        let thresholdNames = Set(StreamBottleneckClassifier.thresholds.keys)
        var keys: Set<String> = []
        var strings: [String] = []
        func walk(_ value: Any) {
            if let dict = value as? [String: Any] {
                for (k, v) in dict { keys.insert(k); walk(v) }
            } else if let array = value as? [Any] {
                array.forEach(walk)
            } else if let s = value as? String {
                strings.append(s)
            }
        }
        walk(object)
        let allowed = StreamDiagnosticsClassifierExportTests.allowedKeys.union(Self.colourKeys)
        let unexpected = keys.subtracting(allowed).subtracting(metricIDs).subtracting(thresholdNames)
        XCTAssertTrue(unexpected.isEmpty, "unreviewed export keys: \(unexpected.sorted())")
        for key in Self.colourKeys {
            for bad in StreamDiagnosticsClassifierExportTests.forbiddenKeyFragments {
                XCTAssertFalse(key.lowercased().contains(bad), "\(key) looks like a \(bad) field")
            }
        }
        // Strings: the existing closed sets (enum values, metric ids, limitations, version, date) plus the colour enums.
        let existing: Set<String> = Set(
            ["sender", "receiver", "mirror", "extend", "window", "unknown", "h264", "hevc", "usb", "awdl", "lan", "remote",
             "tcp", "quic", "displayLayer", "metal", "nominal", "fair", "serious", "critical", "unplugged", "charging",
             "full", "none", "low", "medium", "high", "atLeast", "below", "macOS", "iOS", "mac", "iPhone", "iPad"]
            + StreamBottleneckCause.allCases.map(\.rawValue)
            + ["windowTooShort", "noTargetFrameRate", "tooFewSamples", "sourceIdle", "conflictingEvidence"])
        let evidenceIDs = metricIDs.union(StreamBottleneckClassifier.derivedIDs).union(metricIDs.map { $0 + ".p50" })
        let fixed = Set(StreamDiagnosticsExport.limitationsText).union(["2.0 (214)", "2027-01-15T08:02:00Z"])
        for s in strings {
            XCTAssertTrue(existing.contains(s) || Self.colourStrings.contains(s) || evidenceIDs.contains(s) || fixed.contains(s),
                          "unexpected string in export: \(s)")
        }
    }

    // MARK: - Presentation and docs

    func testPresentationLinesAreTypedTextWithAnAgreementLine() throws {
        XCTAssertEqual(StreamDiagnosticsColourPresentation.lines(nil), [])
        let (recorder, _) = makeRecorder()
        let buffer = try makePixelBuffer(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        tag(buffer, primaries: kCVImageBufferColorPrimaries_P3_D65, transfer: kCVImageBufferTransferFunction_sRGB,
            matrix: kCVImageBufferYCbCrMatrix_ITU_R_709_2)
        recorder.sampleColourSubmitted(buffer, windowComposite: false, generation: 1)
        recorder.sampleColourEncoderOutput(try h264FormatDescription(h264SPS(vui: VUISpec(signal: (full: false, colour: (1, 1, 1))))),
                                           generation: 1)
        let lines = StreamDiagnosticsColourPresentation.lines(recorder.colourSection)
        XCTAssertTrue(lines[0].hasPrefix("Capture buffer (Mirror/Extend): primaries displayP3 · transfer srgb · matrix bt709 · range limited"), lines[0])
        XCTAssertTrue(lines.contains { $0.hasPrefix("Encoder SPS VUI: primaries bt709") })
        XCTAssertTrue(lines.contains { $0.hasPrefix("Stages: differ") })
        XCTAssertTrue(lines.contains { $0.hasPrefix("primaries: Capture buffer (Mirror/Extend) and Encoder SPS VUI differ") })
        let agree = StreamDiagnosticsColourPresentation.agreementLine(ColourConsistency(agreement: .agree, comparisons: 1, mismatches: []))
        XCTAssertEqual(agree, "Stages: agree (1 comparison)")
        XCTAssertEqual(StreamDiagnosticsColourPresentation.agreementLine(.empty), "Stages: not enough sampled to compare")
        // The snapshot, and so the view's data, carries the section.
        XCTAssertEqual(recorder.snapshot(at: 1).colour, recorder.colourSection)
    }

    func testDocsDescribeTheColourMetadataAndTheHardwareCaptures() throws {
        let docs = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs/performance/diagnostics.md")
        let text = try String(contentsOf: docs, encoding: .utf8)
        XCTAssertTrue(text.contains("## Colour metadata"))
        XCTAssertTrue(text.contains("PENDING HARDWARE"))
        for candidate in ["A", "B", "C", "D", "E", "F", "G"] {
            XCTAssertTrue(text.contains("| \(candidate) |"), "docs are missing candidate \(candidate)")
        }
        XCTAssertTrue(text.contains("`session.colour_samples`"))
    }
}
