// Streaming diagnostics (#123) for colour accuracy (#241): bounded
// observability of the colour metadata that actually exists in the pipeline.
//
// Read-only. Nothing here converts, tags or corrects a colour, and nothing
// changes a capture, encoder, decoder or render configuration. It reports
// what the operating system attached to a pixel buffer or a format
// description and what the stream's own SPS VUI says, and lists where those
// differ. It does not say which one is right and makes no claim of colour
// accuracy.
//
// Sampling happens once per stream generation or format change, never per
// frame, and only while diagnostics are on. The per-frame cost of a hook is
// the on/off flag, then (when on) one lock and a key comparison.
//
// Every exported value is a closed enum, a number or a bool: there is no
// free-form string field (`StreamDiagnosticsColourTests` walks the encoded JSON
// against the export allowlist). The SPS parser is pure over `Data`.
//
// Compiled into every app target and MacTests.

import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation

// MARK: - Closed enums with an escape hatch

/// A closed set of named values plus `.other(code)` for anything unlisted.
/// Encodes as `{"kind": "<name>"}` or `{"kind": "other", "code": N}`.
protocol ColourEnum: Codable, Equatable, Sendable {
    static var named: [(kind: String, value: Self)] { get }
    static func unlisted(_ code: Int) -> Self
    var unlistedCode: Int? { get }
}

private enum ColourCodingKeys: String, CodingKey { case kind, code }

extension ColourEnum {
    var kind: String {
        if unlistedCode != nil { return "other" }
        return Self.named.first { $0.value == self }?.kind ?? "other"
    }

    /// Short text for the developer view: `bt709`, `other(7)`.
    var label: String { unlistedCode.map { "other(\($0))" } ?? kind }

    func encodeColour(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: ColourCodingKeys.self)
        try c.encode(kind, forKey: .kind)
        try c.encodeIfPresent(unlistedCode, forKey: .code)
    }

    static func decodeColour(from decoder: Decoder) throws -> Self {
        let c = try decoder.container(keyedBy: ColourCodingKeys.self)
        let kind = try c.decode(String.self, forKey: .kind)
        if kind == "other" { return unlisted(try c.decode(Int.self, forKey: .code)) }
        guard let hit = named.first(where: { $0.kind == kind }) else {
            throw DecodingError.dataCorruptedError(forKey: .kind, in: c, debugDescription: "unknown colour kind")
        }
        return hit.value
    }
}

/// `.other(-1)` marks an attachment value this table does not list (the code
/// is not an H.273 code point).
private let unlistedAttachment = -1

private func attachmentString(_ value: Any?) -> String? {
    value as? String
}

/// Colour primaries (ITU-T H.273 table 2, plus the CoreVideo-only `p22`).
enum ColourPrimaries: ColourEnum {
    case absent, unspecified
    case bt709, bt470m, bt470bg, smpte170m, smpte240m, genericFilm, bt2020, smpte428, dciP3, displayP3, ebu3213, p22
    case other(Int)

    static let named: [(kind: String, value: ColourPrimaries)] = [
        ("absent", .absent), ("unspecified", .unspecified), ("bt709", .bt709), ("bt470m", .bt470m),
        ("bt470bg", .bt470bg), ("smpte170m", .smpte170m), ("smpte240m", .smpte240m), ("genericFilm", .genericFilm),
        ("bt2020", .bt2020), ("smpte428", .smpte428), ("dciP3", .dciP3), ("displayP3", .displayP3),
        ("ebu3213", .ebu3213), ("p22", .p22),
    ]
    static func unlisted(_ code: Int) -> ColourPrimaries { .other(code) }
    var unlistedCode: Int? { if case .other(let c) = self { return c }; return nil }

    init(from decoder: Decoder) throws { self = try Self.decodeColour(from: decoder) }
    func encode(to encoder: Encoder) throws { try encodeColour(to: encoder) }

    /// From the `colour_primaries` byte of a VUI.
    init(h273 code: Int) {
        switch code {
        case 1: self = .bt709
        case 2: self = .unspecified
        case 4: self = .bt470m
        case 5: self = .bt470bg
        case 6: self = .smpte170m
        case 7: self = .smpte240m
        case 8: self = .genericFilm
        case 9: self = .bt2020
        case 10: self = .smpte428
        case 11: self = .dciP3
        case 12: self = .displayP3
        case 22: self = .ebu3213
        default: self = .other(code)
        }
    }

    /// From a CoreVideo / CoreMedia attachment value (a CFString); nil = absent.
    init(attachment value: Any?) {
        guard let s = attachmentString(value) else { self = .absent; return }
        let table: [(String, ColourPrimaries)] = [
            (kCVImageBufferColorPrimaries_ITU_R_709_2 as String, .bt709),
            (kCVImageBufferColorPrimaries_EBU_3213 as String, .ebu3213),
            (kCVImageBufferColorPrimaries_SMPTE_C as String, .smpte170m),
            (kCVImageBufferColorPrimaries_P22 as String, .p22),
            (kCVImageBufferColorPrimaries_DCI_P3 as String, .dciP3),
            (kCVImageBufferColorPrimaries_P3_D65 as String, .displayP3),
            (kCVImageBufferColorPrimaries_ITU_R_2020 as String, .bt2020),
        ]
        self = table.first { $0.0 == s }?.1 ?? .other(unlistedAttachment)
    }

    /// False for `absent` and `unspecified`: the stage says nothing here.
    var isLabelled: Bool {
        switch self {
        case .absent, .unspecified: return false
        default: return true
        }
    }
}

/// Transfer characteristics (ITU-T H.273 table 3, plus CoreVideo's `useGamma`).
enum ColourTransfer: ColourEnum {
    case absent, unspecified
    case bt709, gamma22, gamma28, smpte170m, smpte240m, linear, srgb, bt2020Ten, bt2020Twelve, pq, smpte428, hlg, useGamma
    case other(Int)

    static let named: [(kind: String, value: ColourTransfer)] = [
        ("absent", .absent), ("unspecified", .unspecified), ("bt709", .bt709), ("gamma22", .gamma22),
        ("gamma28", .gamma28), ("smpte170m", .smpte170m), ("smpte240m", .smpte240m), ("linear", .linear),
        ("srgb", .srgb), ("bt2020Ten", .bt2020Ten), ("bt2020Twelve", .bt2020Twelve), ("pq", .pq),
        ("smpte428", .smpte428), ("hlg", .hlg), ("useGamma", .useGamma),
    ]
    static func unlisted(_ code: Int) -> ColourTransfer { .other(code) }
    var unlistedCode: Int? { if case .other(let c) = self { return c }; return nil }

    init(from decoder: Decoder) throws { self = try Self.decodeColour(from: decoder) }
    func encode(to encoder: Encoder) throws { try encodeColour(to: encoder) }

    init(h273 code: Int) {
        switch code {
        case 1: self = .bt709
        case 2: self = .unspecified
        case 4: self = .gamma22
        case 5: self = .gamma28
        case 6: self = .smpte170m
        case 7: self = .smpte240m
        case 8: self = .linear
        case 13: self = .srgb
        case 14: self = .bt2020Ten
        case 15: self = .bt2020Twelve
        case 16: self = .pq
        case 17: self = .smpte428
        case 18: self = .hlg
        default: self = .other(code)
        }
    }

    init(attachment value: Any?) {
        guard let s = attachmentString(value) else { self = .absent; return }
        let table: [(String, ColourTransfer)] = [
            (kCVImageBufferTransferFunction_ITU_R_709_2 as String, .bt709),
            (kCVImageBufferTransferFunction_SMPTE_240M_1995 as String, .smpte240m),
            (kCVImageBufferTransferFunction_UseGamma as String, .useGamma),
            (kCVImageBufferTransferFunction_sRGB as String, .srgb),
            (kCVImageBufferTransferFunction_ITU_R_2020 as String, .bt2020Ten),
            (kCVImageBufferTransferFunction_SMPTE_ST_428_1 as String, .smpte428),
            (kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String, .pq),
            (kCVImageBufferTransferFunction_ITU_R_2100_HLG as String, .hlg),
            (kCVImageBufferTransferFunction_Linear as String, .linear),
        ]
        self = table.first { $0.0 == s }?.1 ?? .other(unlistedAttachment)
    }

    var isLabelled: Bool {
        switch self {
        case .absent, .unspecified: return false
        default: return true
        }
    }

    /// Curves the standards define identically (BT.709, SMPTE 170M, BT.2020
    /// 10/12-bit) compare as one: this tool does not call that a difference.
    var comparisonKey: String {
        switch self {
        case .smpte170m, .bt2020Ten, .bt2020Twelve: return ColourTransfer.bt709.label
        default: return label
        }
    }
}

/// YCbCr matrix coefficients (ITU-T H.273 table 4).
enum ColourMatrix: ColourEnum {
    case absent, unspecified
    case identity, bt709, fcc, bt470bg, smpte170m, smpte240m, ycgco, bt2020Ncl, bt2020Cl
    case other(Int)

    static let named: [(kind: String, value: ColourMatrix)] = [
        ("absent", .absent), ("unspecified", .unspecified), ("identity", .identity), ("bt709", .bt709),
        ("fcc", .fcc), ("bt470bg", .bt470bg), ("smpte170m", .smpte170m), ("smpte240m", .smpte240m),
        ("ycgco", .ycgco), ("bt2020Ncl", .bt2020Ncl), ("bt2020Cl", .bt2020Cl),
    ]
    static func unlisted(_ code: Int) -> ColourMatrix { .other(code) }
    var unlistedCode: Int? { if case .other(let c) = self { return c }; return nil }

    init(from decoder: Decoder) throws { self = try Self.decodeColour(from: decoder) }
    func encode(to encoder: Encoder) throws { try encodeColour(to: encoder) }

    init(h273 code: Int) {
        switch code {
        case 0: self = .identity
        case 1: self = .bt709
        case 2: self = .unspecified
        case 4: self = .fcc
        case 5: self = .bt470bg
        case 6: self = .smpte170m
        case 7: self = .smpte240m
        case 8: self = .ycgco
        case 9: self = .bt2020Ncl
        case 10: self = .bt2020Cl
        default: self = .other(code)
        }
    }

    init(attachment value: Any?) {
        guard let s = attachmentString(value) else { self = .absent; return }
        let table: [(String, ColourMatrix)] = [
            (kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String, .bt709),
            (kCVImageBufferYCbCrMatrix_ITU_R_601_4 as String, .smpte170m),
            (kCVImageBufferYCbCrMatrix_SMPTE_240M_1995 as String, .smpte240m),
            (kCVImageBufferYCbCrMatrix_ITU_R_2020 as String, .bt2020Ncl),
        ]
        self = table.first { $0.0 == s }?.1 ?? .other(unlistedAttachment)
    }

    var isLabelled: Bool {
        switch self {
        case .absent, .unspecified: return false
        default: return true
        }
    }

    /// BT.470 BG and SMPTE 170M share the same Kr/Kb: both are "601".
    var comparisonKey: String {
        self == .bt470bg ? ColourMatrix.smpte170m.label : label
    }
}

/// Sample range as the stage declares or implies it.
enum ColourRange: String, Codable, Equatable, Sendable {
    /// Not stated (no flag, no key).
    case unknown
    case limited
    case full
    /// RGB pixels: the range belongs to the YCbCr conversion, not the buffer.
    case notApplicable
}

/// Pixel format FourCC of a pixel buffer.
enum ColourPixelFormat: ColourEnum {
    case absent
    /// '420v' (the app's default capture format).
    case nv12VideoRange
    /// '420f'.
    case nv12FullRange
    /// 'BGRA' (the Window View composite, and the `pixfmt bgra` capture option).
    case bgra
    /// 'x420'.
    case p010VideoRange
    /// 'xf20'.
    case p010FullRange
    /// Any other FourCC, as its numeric value.
    case other(Int)

    static let named: [(kind: String, value: ColourPixelFormat)] = [
        ("absent", .absent), ("nv12VideoRange", .nv12VideoRange), ("nv12FullRange", .nv12FullRange),
        ("bgra", .bgra), ("p010VideoRange", .p010VideoRange), ("p010FullRange", .p010FullRange),
    ]
    static func unlisted(_ code: Int) -> ColourPixelFormat { .other(code) }
    var unlistedCode: Int? { if case .other(let c) = self { return c }; return nil }

    init(from decoder: Decoder) throws { self = try Self.decodeColour(from: decoder) }
    func encode(to encoder: Encoder) throws { try encodeColour(to: encoder) }

    init(fourCC: OSType) {
        switch fourCC {
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange: self = .nv12VideoRange
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange: self = .nv12FullRange
        case kCVPixelFormatType_32BGRA: self = .bgra
        case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange: self = .p010VideoRange
        case kCVPixelFormatType_420YpCbCr10BiPlanarFullRange: self = .p010FullRange
        default: self = .other(Int(fourCC))
        }
    }

    var bitDepth: Int? {
        switch self {
        case .nv12VideoRange, .nv12FullRange, .bgra: return 8
        case .p010VideoRange, .p010FullRange: return 10
        default: return nil
        }
    }

    var range: ColourRange {
        switch self {
        case .nv12VideoRange, .p010VideoRange: return .limited
        case .nv12FullRange, .p010FullRange: return .full
        case .bgra: return .notApplicable
        default: return .unknown
        }
    }
}

/// Model of a `CGColorSpace` attached to a pixel buffer.
enum ColourSpaceModel: String, Codable, Equatable, Sendable {
    case absent, monochrome, rgb, cmyk, lab, other

    init(_ model: CGColorSpaceModel) {
        switch model {
        case .monochrome: self = .monochrome
        case .rgb: self = .rgb
        case .cmyk: self = .cmyk
        case .lab: self = .lab
        default: self = .other
        }
    }
}

/// Well-known `CGColorSpace` names. `unnamed` = a colour space with no
/// registered name (for example one built from an ICC profile).
enum ColourSpaceName: String, Codable, Equatable, Sendable {
    case absent, unnamed, unlisted
    case srgb, displayP3, extendedSRGB, linearSRGB, extendedLinearSRGB, extendedDisplayP3, itur709, itur2020, adobeRGB1998

    init(_ space: CGColorSpace) {
        guard let name = space.name as String? else { self = .unnamed; return }
        let table: [(String, ColourSpaceName)] = [
            (CGColorSpace.sRGB as String, .srgb),
            (CGColorSpace.displayP3 as String, .displayP3),
            (CGColorSpace.extendedSRGB as String, .extendedSRGB),
            (CGColorSpace.linearSRGB as String, .linearSRGB),
            (CGColorSpace.extendedLinearSRGB as String, .extendedLinearSRGB),
            (CGColorSpace.extendedDisplayP3 as String, .extendedDisplayP3),
            (CGColorSpace.itur_709 as String, .itur709),
            (CGColorSpace.itur_2020 as String, .itur2020),
            (CGColorSpace.adobeRGB1998 as String, .adobeRGB1998),
        ]
        self = table.first { $0.0 == name }?.1 ?? .unlisted
    }
}

// MARK: - Metadata value

/// The colour description of one pipeline stage. Every field is a closed
/// enum, a bool or a number.
struct ColourMetadata: Codable, Equatable, Sendable {
    var primaries: ColourPrimaries = .absent
    var transfer: ColourTransfer = .absent
    var matrix: ColourMatrix = .absent
    var range: ColourRange = .unknown
    /// Pixel buffers only.
    var format: ColourPixelFormat = .absent
    var bitDepth: Int?
    /// Whether an ICC profile is attached (never its content).
    var iccPresent: Bool?
    /// Pixel buffers only: the attached `CGColorSpace`'s model and name.
    var spaceModel: ColourSpaceModel = .absent
    var space: ColourSpaceName = .absent

    /// What a pixel buffer carries: the pixel format and its attachments.
    static func from(pixelBuffer: CVPixelBuffer) -> ColourMetadata {
        func attachment(_ key: CFString) -> Any? {
            CVBufferCopyAttachment(pixelBuffer, key, nil)
        }
        let format = ColourPixelFormat(fourCC: CVPixelBufferGetPixelFormatType(pixelBuffer))
        var model = ColourSpaceModel.absent
        var space = ColourSpaceName.absent
        if let raw = attachment(kCVImageBufferCGColorSpaceKey), CFGetTypeID(raw as CFTypeRef) == CGColorSpace.typeID {
            let cs = raw as! CGColorSpace  // type checked just above
            model = ColourSpaceModel(cs.model)
            space = ColourSpaceName(cs)
        }
        return ColourMetadata(
            primaries: ColourPrimaries(attachment: attachment(kCVImageBufferColorPrimariesKey)),
            transfer: ColourTransfer(attachment: attachment(kCVImageBufferTransferFunctionKey)),
            matrix: ColourMatrix(attachment: attachment(kCVImageBufferYCbCrMatrixKey)),
            range: format.range,
            format: format,
            bitDepth: format.bitDepth,
            iccPresent: attachment(kCVImageBufferICCProfileKey) != nil,
            spaceModel: model,
            space: space)
    }

    /// What a format description's extensions carry.
    static func from(formatDescription desc: CMFormatDescription) -> ColourMetadata {
        func ext(_ key: CFString) -> Any? { CMFormatDescriptionGetExtension(desc, extensionKey: key) }
        var range = ColourRange.unknown
        if let flag = ext(kCMFormatDescriptionExtension_FullRangeVideo) as? Bool {
            range = flag ? .full : .limited
        }
        let depth = (ext(kCMFormatDescriptionExtension_BitsPerComponent) as? NSNumber)?.intValue
        return ColourMetadata(
            primaries: ColourPrimaries(attachment: ext(kCMFormatDescriptionExtension_ColorPrimaries)),
            transfer: ColourTransfer(attachment: ext(kCMFormatDescriptionExtension_TransferFunction)),
            matrix: ColourMatrix(attachment: ext(kCMFormatDescriptionExtension_YCbCrMatrix)),
            range: range,
            format: .absent,
            bitDepth: depth,
            iccPresent: ext(kCMFormatDescriptionExtension_ICCProfile) != nil,
            spaceModel: .absent,
            space: .absent)
    }
}

// MARK: - SPS VUI parser (pure over Data)

enum ColourUnparsedReason: String, Codable, Equatable, Sendable {
    case empty
    case tooLarge
    case notAnSPS
    case truncated
    case invalidValue
    case exceedsBound
    case unsupportedLayer
    case unsupportedCodec
    /// A format description without an SPS (set by the extraction layer).
    case noParameterSet
}

/// The colour-relevant part of an SPS and its VUI. `nil` codes were not
/// coded in the stream (the syntax element was not present).
struct ColourVUI: Codable, Equatable, Sendable {
    var codec: DiagnosticsCodec
    var hasVUI: Bool
    var videoSignalTypePresent: Bool
    var colourDescPresent: Bool
    var fullRange: Bool?
    var primariesCode: Int?
    var transferCode: Int?
    var matrixCode: Int?
    var chromaFormatIdc: Int
    var bitDepth: Int

    var metadata: ColourMetadata {
        ColourMetadata(
            primaries: primariesCode.map(ColourPrimaries.init(h273:)) ?? .absent,
            transfer: transferCode.map(ColourTransfer.init(h273:)) ?? .absent,
            matrix: matrixCode.map(ColourMatrix.init(h273:)) ?? .absent,
            range: fullRange.map { $0 ? ColourRange.full : .limited } ?? .unknown,
            format: .absent,
            bitDepth: bitDepth,
            iccPresent: nil,
            spaceModel: .absent,
            space: .absent)
    }
}

/// Parses `vui_parameters` colour fields out of an H.264 or HEVC SPS NAL.
///
/// Defensive by construction: input is capped, every read is bounds-checked,
/// every loop count has a ceiling, and anything unexpected is an
/// `.unparsed(reason)`, never a crash and never a guess. It accepts the NAL
/// with or without an Annex B start code. Scaling lists, the HEVC
/// profile/tier/level block and short-term reference picture sets are
/// walked, not assumed absent.
enum ColourSPSParser {
    /// Real SPS units are a few dozen bytes; anything bigger is not one.
    static let maxInputBytes = 4096

    enum Outcome: Equatable, Sendable {
        case parsed(ColourVUI)
        case unparsed(ColourUnparsedReason)
    }

    static func parse(_ data: Data, codec: DiagnosticsCodec) -> Outcome {
        guard codec == .h264 || codec == .hevc else { return .unparsed(.unsupportedCodec) }
        guard !data.isEmpty else { return .unparsed(.empty) }
        guard data.count <= maxInputBytes else { return .unparsed(.tooLarge) }
        var bytes = Array(data)
        if bytes.count >= 4, bytes[0] == 0, bytes[1] == 0, bytes[2] == 0, bytes[3] == 1 {
            bytes.removeFirst(4)
        } else if bytes.count >= 3, bytes[0] == 0, bytes[1] == 0, bytes[2] == 1 {
            bytes.removeFirst(3)
        }
        do {
            switch codec {
            case .h264: return .parsed(try parseH264(bytes))
            default: return .parsed(try parseHEVC(bytes))
            }
        } catch let failure as Failure {
            return .unparsed(failure.reason)
        } catch {
            return .unparsed(.invalidValue)
        }
    }

    private struct Failure: Error { let reason: ColourUnparsedReason }

    // MARK: Bit reader

    private struct BitReader {
        let bytes: [UInt8]
        private(set) var position = 0
        init(_ bytes: [UInt8]) { self.bytes = bytes }

        mutating func bit() throws -> Int {
            guard position < bytes.count * 8 else { throw Failure(reason: .truncated) }
            let b = Int(bytes[position >> 3] >> (7 - UInt8(position & 7))) & 1
            position += 1
            return b
        }

        mutating func flag() throws -> Bool { try bit() == 1 }

        /// `n` bits, 0...32.
        mutating func bits(_ n: Int) throws -> UInt32 {
            guard n >= 0, n <= 32 else { throw Failure(reason: .invalidValue) }
            var v: UInt64 = 0
            for _ in 0..<n { v = (v << 1) | UInt64(try bit()) }
            return UInt32(v)
        }

        mutating func skip(_ n: Int) throws {
            guard n >= 0 else { throw Failure(reason: .invalidValue) }
            guard position + n <= bytes.count * 8 else { throw Failure(reason: .truncated) }
            position += n
        }

        /// Unsigned Exp-Golomb. At most 31 leading zeros (value below 2^32 - 1).
        mutating func ue() throws -> UInt64 {
            var zeros = 0
            while try bit() == 0 {
                zeros += 1
                if zeros > 31 { throw Failure(reason: .invalidValue) }
            }
            let suffix = zeros > 0 ? UInt64(try bits(zeros)) : 0
            return (UInt64(1) << UInt64(zeros)) - 1 + suffix
        }

        /// `ue(v)` that must not exceed `max`.
        mutating func ue(max: Int) throws -> Int {
            let v = try ue()
            guard v <= UInt64(max) else { throw Failure(reason: .exceedsBound) }
            return Int(v)
        }

        /// Signed Exp-Golomb.
        mutating func se() throws -> Int {
            let k = try ue()
            let magnitude = Int((k + 1) / 2)
            return k % 2 == 1 ? magnitude : -magnitude
        }
    }

    /// Removes emulation prevention bytes: 00 00 03 -> 00 00.
    static func removeEmulationPrevention(_ bytes: ArraySlice<UInt8>) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var zeros = 0
        for b in bytes {
            if zeros >= 2, b == 3 {
                zeros = 0
                continue
            }
            out.append(b)
            zeros = b == 0 ? zeros + 1 : 0
        }
        return out
    }

    // MARK: H.264

    private static let h264HighProfiles: Set<Int> = [100, 110, 122, 244, 44, 83, 86, 118, 128, 138, 139, 134, 135]

    private static func parseH264(_ bytes: [UInt8]) throws -> ColourVUI {
        guard bytes.count >= 2 else { throw Failure(reason: .truncated) }
        guard bytes[0] & 0x80 == 0, bytes[0] & 0x1F == 7 else { throw Failure(reason: .notAnSPS) }
        var r = BitReader(removeEmulationPrevention(bytes[1...]))
        let profile = Int(try r.bits(8))
        try r.skip(16)                                   // constraint flags, level_idc
        _ = try r.ue(max: 31)                            // seq_parameter_set_id
        var chroma = 1
        var depth = 8
        if h264HighProfiles.contains(profile) {
            chroma = try r.ue(max: 3)
            if chroma == 3 { try r.skip(1) }             // separate_colour_plane_flag
            depth = 8 + (try r.ue(max: 6))               // bit_depth_luma_minus8
            _ = try r.ue(max: 6)                         // bit_depth_chroma_minus8
            try r.skip(1)                                // qpprime_y_zero_transform_bypass_flag
            if try r.flag() {                            // seq_scaling_matrix_present_flag
                for i in 0..<(chroma != 3 ? 8 : 12) {
                    if try r.flag() { try skipH264ScalingList(&r, size: i < 6 ? 16 : 64) }
                }
            }
        }
        _ = try r.ue(max: 12)                            // log2_max_frame_num_minus4
        let pocType = try r.ue(max: 2)
        if pocType == 0 {
            _ = try r.ue(max: 12)                        // log2_max_pic_order_cnt_lsb_minus4
        } else if pocType == 1 {
            try r.skip(1)                                // delta_pic_order_always_zero_flag
            _ = try r.se()
            _ = try r.se()
            let cycle = try r.ue(max: 255)
            for _ in 0..<cycle { _ = try r.se() }
        }
        _ = try r.ue()                                   // max_num_ref_frames
        try r.skip(1)                                    // gaps_in_frame_num_value_allowed_flag
        _ = try r.ue()                                   // pic_width_in_mbs_minus1
        _ = try r.ue()                                   // pic_height_in_map_units_minus1
        if try r.bit() == 0 { try r.skip(1) }            // frame_mbs_only_flag, mb_adaptive_frame_field_flag
        try r.skip(1)                                    // direct_8x8_inference_flag
        if try r.flag() { for _ in 0..<4 { _ = try r.ue() } }   // frame_cropping
        guard try r.flag() else {                        // vui_parameters_present_flag
            return emptyVUI(.h264, vui: false, chroma: chroma, depth: depth)
        }
        return try parseVUI(&r, codec: .h264, chroma: chroma, depth: depth)
    }

    private static func skipH264ScalingList(_ r: inout BitReader, size: Int) throws {
        var last = 8
        var next = 8
        for _ in 0..<size {
            if next != 0 {
                let delta = try r.se()
                guard delta >= -128, delta <= 127 else { throw Failure(reason: .invalidValue) }
                next = (last + delta + 256) % 256
            }
            last = next == 0 ? last : next
        }
    }

    // MARK: HEVC

    private static func parseHEVC(_ bytes: [UInt8]) throws -> ColourVUI {
        guard bytes.count >= 3 else { throw Failure(reason: .truncated) }
        guard bytes[0] & 0x80 == 0, (bytes[0] >> 1) & 0x3F == 33 else { throw Failure(reason: .notAnSPS) }
        let layerID = (Int(bytes[0] & 1) << 5) | Int(bytes[1] >> 3)
        guard layerID == 0 else { throw Failure(reason: .unsupportedLayer) }
        guard bytes[1] & 7 != 0 else { throw Failure(reason: .invalidValue) }   // nuh_temporal_id_plus1
        var r = BitReader(removeEmulationPrevention(bytes[2...]))
        try r.skip(4)                                    // sps_video_parameter_set_id
        let maxSubLayersMinus1 = Int(try r.bits(3))
        guard maxSubLayersMinus1 <= 6 else { throw Failure(reason: .invalidValue) }
        try r.skip(1)                                    // sps_temporal_id_nesting_flag
        try skipProfileTierLevel(&r, maxSubLayersMinus1: maxSubLayersMinus1)
        _ = try r.ue(max: 15)                            // sps_seq_parameter_set_id
        let chroma = try r.ue(max: 3)
        if chroma == 3 { try r.skip(1) }                 // separate_colour_plane_flag
        _ = try r.ue()                                   // pic_width_in_luma_samples
        _ = try r.ue()                                   // pic_height_in_luma_samples
        if try r.flag() { for _ in 0..<4 { _ = try r.ue() } }   // conformance_window
        let depth = 8 + (try r.ue(max: 8))               // bit_depth_luma_minus8
        _ = try r.ue(max: 8)                             // bit_depth_chroma_minus8
        let log2MaxPocLsb = 4 + (try r.ue(max: 12))
        let orderingInfoPresent = try r.flag()
        for _ in (orderingInfoPresent ? 0 : maxSubLayersMinus1)...maxSubLayersMinus1 {
            _ = try r.ue()                               // sps_max_dec_pic_buffering_minus1
            _ = try r.ue()                               // sps_max_num_reorder_pics
            _ = try r.ue()                               // sps_max_latency_increase_plus1
        }
        for _ in 0..<6 { _ = try r.ue() }                // coding / transform block sizes, hierarchy depths
        if try r.flag() {                                // scaling_list_enabled_flag
            if try r.flag() { try skipHEVCScalingListData(&r) }
        }
        try r.skip(2)                                    // amp_enabled_flag, sample_adaptive_offset_enabled_flag
        if try r.flag() {                                // pcm_enabled_flag
            try r.skip(8)                                // pcm sample bit depths
            _ = try r.ue()
            _ = try r.ue()
            try r.skip(1)                                // pcm_loop_filter_disabled_flag
        }
        let setCount = try r.ue(max: 64)                 // num_short_term_ref_pic_sets
        var sets: [(s0: [Int], s1: [Int])] = []
        for i in 0..<setCount { sets.append(try parseShortTermRefPicSet(&r, index: i, previous: sets)) }
        if try r.flag() {                                // long_term_ref_pics_present_flag
            let n = try r.ue(max: 32)
            for _ in 0..<n { try r.skip(log2MaxPocLsb + 1) }   // lt_ref_pic_poc_lsb_sps, used_by_curr_pic_lt_sps_flag
        }
        try r.skip(2)                                    // sps_temporal_mvp_enabled_flag, strong_intra_smoothing_enabled_flag
        guard try r.flag() else {                        // vui_parameters_present_flag
            return emptyVUI(.hevc, vui: false, chroma: chroma, depth: depth)
        }
        return try parseVUI(&r, codec: .hevc, chroma: chroma, depth: depth)
    }

    private static func skipProfileTierLevel(_ r: inout BitReader, maxSubLayersMinus1: Int) throws {
        try r.skip(88)                                   // general profile space/tier/idc, compat flags, constraint flags
        try r.skip(8)                                    // general_level_idc
        var profilePresent: [Bool] = []
        var levelPresent: [Bool] = []
        for _ in 0..<maxSubLayersMinus1 {
            profilePresent.append(try r.flag())
            levelPresent.append(try r.flag())
        }
        if maxSubLayersMinus1 > 0 {
            for _ in maxSubLayersMinus1..<8 { try r.skip(2) }   // reserved_zero_2bits
        }
        for i in 0..<maxSubLayersMinus1 {
            if profilePresent[i] { try r.skip(88) }
            if levelPresent[i] { try r.skip(8) }
        }
    }

    private static func skipHEVCScalingListData(_ r: inout BitReader) throws {
        for sizeID in 0..<4 {
            var matrixID = 0
            while matrixID < 6 {
                if try r.flag() {                        // scaling_list_pred_mode_flag
                    let coefficients = min(64, 1 << (4 + (sizeID << 1)))
                    if sizeID > 1 { _ = try r.se() }     // scaling_list_dc_coef_minus8
                    for _ in 0..<coefficients {
                        let delta = try r.se()
                        guard delta >= -255, delta <= 255 else { throw Failure(reason: .invalidValue) }
                    }
                } else {
                    _ = try r.ue()                       // scaling_list_pred_matrix_id_delta
                }
                matrixID += sizeID == 3 ? 3 : 1
            }
        }
    }

    /// Returns DeltaPocS0 / DeltaPocS1 of the set (7.4.8). Only the counts
    /// matter for skipping, but an inter-predicted set's flag count depends on
    /// the reference set's size, so the derivation is carried out in full.
    private static func parseShortTermRefPicSet(_ r: inout BitReader, index: Int,
                                                previous: [(s0: [Int], s1: [Int])]) throws -> (s0: [Int], s1: [Int]) {
        var inter = false
        if index != 0 { inter = try r.flag() }           // inter_ref_pic_set_prediction_flag
        guard inter else {
            let negatives = try r.ue(max: 16)
            let positives = try r.ue(max: 16)
            var s0: [Int] = []
            var s1: [Int] = []
            var poc = 0
            for _ in 0..<negatives {
                poc -= (try r.ue(max: 32767)) + 1
                s0.append(poc)
                try r.skip(1)                            // used_by_curr_pic_s0_flag
            }
            poc = 0
            for _ in 0..<positives {
                poc += (try r.ue(max: 32767)) + 1
                s1.append(poc)
                try r.skip(1)                            // used_by_curr_pic_s1_flag
            }
            return (s0, s1)
        }
        // In an SPS the reference set is always the previous one (delta_idx_minus1 is slice-header only).
        let ref = previous[index - 1]
        let sign = try r.bit()                           // delta_rps_sign
        let deltaRps = (1 - 2 * sign) * ((try r.ue(max: 32767)) + 1)
        let numDelta = ref.s0.count + ref.s1.count
        var useDelta: [Bool] = []
        for _ in 0...numDelta {
            var use = true
            if !(try r.flag()) { use = try r.flag() }    // used_by_curr_pic_flag, else use_delta_flag
            useDelta.append(use)
        }
        var s0: [Int] = []
        var s1: [Int] = []
        for j in stride(from: ref.s1.count - 1, through: 0, by: -1) {
            let d = ref.s1[j] + deltaRps
            if d < 0, useDelta[ref.s0.count + j] { s0.append(d) }
        }
        if deltaRps < 0, useDelta[numDelta] { s0.append(deltaRps) }
        for j in 0..<ref.s0.count {
            let d = ref.s0[j] + deltaRps
            if d < 0, useDelta[j] { s0.append(d) }
        }
        for j in stride(from: ref.s0.count - 1, through: 0, by: -1) {
            let d = ref.s0[j] + deltaRps
            if d > 0, useDelta[j] { s1.append(d) }
        }
        if deltaRps > 0, useDelta[numDelta] { s1.append(deltaRps) }
        for j in 0..<ref.s1.count {
            let d = ref.s1[j] + deltaRps
            if d > 0, useDelta[ref.s0.count + j] { s1.append(d) }
        }
        guard s0.count <= 16, s1.count <= 16 else { throw Failure(reason: .exceedsBound) }
        return (s0, s1)
    }

    // MARK: VUI (same leading syntax in both codecs)

    private static func emptyVUI(_ codec: DiagnosticsCodec, vui: Bool, chroma: Int, depth: Int) -> ColourVUI {
        ColourVUI(codec: codec, hasVUI: vui, videoSignalTypePresent: false, colourDescPresent: false,
                  fullRange: nil, primariesCode: nil, transferCode: nil, matrixCode: nil,
                  chromaFormatIdc: chroma, bitDepth: depth)
    }

    private static func parseVUI(_ r: inout BitReader, codec: DiagnosticsCodec, chroma: Int, depth: Int) throws -> ColourVUI {
        if try r.flag() {                                // aspect_ratio_info_present_flag
            if try r.bits(8) == 255 { try r.skip(32) }   // Extended_SAR: sar_width, sar_height
        }
        if try r.flag() { try r.skip(1) }                // overscan_info_present_flag, overscan_appropriate_flag
        var result = emptyVUI(codec, vui: true, chroma: chroma, depth: depth)
        guard try r.flag() else { return result }        // video_signal_type_present_flag
        result.videoSignalTypePresent = true
        try r.skip(3)                                    // video_format
        result.fullRange = try r.flag()                  // video_full_range_flag
        guard try r.flag() else { return result }        // colour_description_present_flag
        result.colourDescPresent = true
        result.primariesCode = Int(try r.bits(8))
        result.transferCode = Int(try r.bits(8))
        result.matrixCode = Int(try r.bits(8))
        return result
    }
}

// MARK: - Extraction from a format description

enum ColourFormatDescriptionReader {
    /// The SPS NAL of a video format description and the codec it belongs to,
    /// read through the codec-specific parameter-set API (the same source the
    /// Mac sender uses to put parameter sets on the wire).
    static func spsNAL(from desc: CMFormatDescription) -> (data: Data, codec: DiagnosticsCodec)? {
        guard CMFormatDescriptionGetMediaType(desc) == kCMMediaType_Video else { return nil }
        let subtype = CMFormatDescriptionGetMediaSubType(desc)
        let codec: DiagnosticsCodec
        switch subtype {
        case kCMVideoCodecType_H264: codec = .h264
        case kCMVideoCodecType_HEVC: codec = .hevc
        default: return nil
        }
        var count = 0
        func fetch(_ index: Int, count out: UnsafeMutablePointer<Int>?) -> Data? {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            let status: OSStatus = codec == .hevc
                ? CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                    desc, parameterSetIndex: index, parameterSetPointerOut: &pointer, parameterSetSizeOut: &size,
                    parameterSetCountOut: out, nalUnitHeaderLengthOut: nil)
                : CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                    desc, parameterSetIndex: index, parameterSetPointerOut: &pointer, parameterSetSizeOut: &size,
                    parameterSetCountOut: out, nalUnitHeaderLengthOut: nil)
            guard status == noErr, let pointer, size > 0, size <= ColourSPSParser.maxInputBytes else { return nil }
            return Data(bytes: pointer, count: size)
        }
        guard let first = fetch(0, count: &count) else { return nil }
        for index in 0..<min(max(count, 1), 8) {
            guard let nal = index == 0 ? first : fetch(index, count: nil), let header = nal.first else { continue }
            let isSPS = codec == .hevc ? (header >> 1) & 0x3F == 33 : header & 0x1F == 7
            if isSPS { return (nal, codec) }
        }
        return nil
    }
}

// MARK: - Stage records and consistency

/// Where in the pipeline a sample was taken.
enum ColourStage: String, Codable, CaseIterable, Sendable {
    /// Mirror / Extend: the ScreenCaptureKit buffer handed to the encoder.
    case capture
    /// Window View: the composited buffer handed to the encoder.
    case composited
    /// Encoder output format description (extensions).
    case encoderFormat
    /// SPS VUI parsed from the encoder output's parameter set.
    case encoderVUI
    /// Receiver: format description built from the received parameter sets.
    case receiverFormat
    /// Receiver: SPS VUI parsed from the received parameter set.
    case receiverVUI

    var isSource: Bool { self == .capture || self == .composited }
}

struct ColourStageRecord: Codable, Equatable, Sendable {
    var stage: ColourStage
    var metadata: ColourMetadata
    /// VUI stages only, when the parse succeeded.
    var vui: ColourVUI?
    /// VUI stages only, when it did not.
    var unparsed: ColourUnparsedReason?

    static func pixelBuffer(_ stage: ColourStage, _ pixelBuffer: CVPixelBuffer) -> ColourStageRecord {
        .init(stage: stage, metadata: .from(pixelBuffer: pixelBuffer), vui: nil, unparsed: nil)
    }

    static func formatDescription(_ stage: ColourStage, _ desc: CMFormatDescription) -> ColourStageRecord {
        .init(stage: stage, metadata: .from(formatDescription: desc), vui: nil, unparsed: nil)
    }

    static func vui(_ stage: ColourStage, _ outcome: ColourSPSParser.Outcome) -> ColourStageRecord {
        switch outcome {
        case .parsed(let vui): return .init(stage: stage, metadata: vui.metadata, vui: vui, unparsed: nil)
        case .unparsed(let reason): return .init(stage: stage, metadata: ColourMetadata(), vui: nil, unparsed: reason)
        }
    }

    /// The SPS VUI of a format description's parameter set.
    static func vui(_ stage: ColourStage, from desc: CMFormatDescription) -> ColourStageRecord {
        guard let sps = ColourFormatDescriptionReader.spsNAL(from: desc) else {
            return .vui(stage, .unparsed(.noParameterSet))
        }
        return .vui(stage, ColourSPSParser.parse(sps.data, codec: sps.codec))
    }

    /// True when `metadata` was actually read (a VUI stage that failed to parse has nothing to compare).
    var isComparable: Bool { unparsed == nil }
}

enum ColourField: String, Codable, Sendable {
    case primaries, transfer, matrix, range, bitDepth
}

/// How two stages relate on one field. No verdict on which is right.
enum ColourRelation: String, Codable, Sendable {
    /// Both state a value and the values differ.
    case differ
    /// Only the second stage states a value.
    case firstUnlabelled
    /// Only the first stage states a value.
    case secondUnlabelled
}

struct ColourMismatch: Codable, Equatable, Sendable {
    var first: ColourStage
    var second: ColourStage
    var field: ColourField
    var relation: ColourRelation
}

enum ColourAgreement: String, Codable, Sendable {
    /// Fewer than two comparable stages were sampled.
    case noData
    case agree
    case differ
}

struct ColourConsistency: Codable, Equatable, Sendable {
    var agreement: ColourAgreement
    /// How many stage pairs had both ends sampled.
    var comparisons: Int
    var mismatches: [ColourMismatch]

    static let empty = ColourConsistency(agreement: .noData, comparisons: 0, mismatches: [])

    /// Pairs compared on the sender: source buffer against the encoder's
    /// format description, that against its SPS VUI, and the buffer against
    /// the VUI. On the receiver: its format description against its VUI.
    static func evaluate(_ records: [ColourStage: ColourStageRecord]) -> ColourConsistency {
        let source: ColourStage = records[.composited] != nil ? .composited : .capture
        let pairs: [(ColourStage, ColourStage)] = [
            (source, .encoderFormat), (.encoderFormat, .encoderVUI), (source, .encoderVUI),
            (.receiverFormat, .receiverVUI),
        ]
        var comparisons = 0
        var mismatches: [ColourMismatch] = []
        for (a, b) in pairs {
            guard let ra = records[a], let rb = records[b], ra.isComparable, rb.isComparable else { continue }
            comparisons += 1
            mismatches += compare(ra, rb)
        }
        let agreement: ColourAgreement = comparisons == 0 ? .noData : (mismatches.isEmpty ? .agree : .differ)
        return ColourConsistency(agreement: agreement, comparisons: comparisons, mismatches: mismatches)
    }

    private static func relation(_ firstLabelled: Bool, _ secondLabelled: Bool, equal: Bool) -> ColourRelation? {
        switch (firstLabelled, secondLabelled) {
        case (true, true): return equal ? nil : .differ
        case (true, false): return .secondUnlabelled
        case (false, true): return .firstUnlabelled
        case (false, false): return nil
        }
    }

    static func compare(_ a: ColourStageRecord, _ b: ColourStageRecord) -> [ColourMismatch] {
        var out: [ColourMismatch] = []
        func add(_ field: ColourField, _ relation: ColourRelation?) {
            if let relation { out.append(.init(first: a.stage, second: b.stage, field: field, relation: relation)) }
        }
        let ma = a.metadata, mb = b.metadata
        add(.primaries, relation(ma.primaries.isLabelled, mb.primaries.isLabelled, equal: ma.primaries == mb.primaries))
        add(.transfer, relation(ma.transfer.isLabelled, mb.transfer.isLabelled,
                                equal: ma.transfer.comparisonKey == mb.transfer.comparisonKey))
        add(.matrix, relation(ma.matrix.isLabelled, mb.matrix.isLabelled,
                              equal: ma.matrix.comparisonKey == mb.matrix.comparisonKey))
        // Range is reported only when both stages state one and they differ: an absent
        // flag has a documented default (video range), and RGB pixels have no range of their own.
        let rangeStated: (ColourRange) -> Bool = { $0 == .limited || $0 == .full }
        if rangeStated(ma.range), rangeStated(mb.range), ma.range != mb.range { add(.range, .differ) }
        if let da = ma.bitDepth, let db = mb.bitDepth, da != db {
            add(.bitDepth, .differ)
        }
        return out
    }
}

/// The `colour` section of a session's snapshot and export.
struct StreamDiagnosticsColourSection: Codable, Equatable, Sendable {
    /// In `ColourStage` order; only stages that have been sampled.
    var stages: [ColourStageRecord]
    var consistency: ColourConsistency
    /// Extractions performed since the session reset (not frames).
    var sampleCount: Int

    func record(_ stage: ColourStage) -> ColourStageRecord? {
        stages.first { $0.stage == stage }
    }
}

// MARK: - Store (owned by the recorder)

struct ColourSampleKey: Equatable, Sendable {
    var generation: UInt64
    var format: UInt32
}

/// Latest colour record per stage, with a per-stage key so a stage is
/// extracted once per generation / format and never per frame.
final class DiagnosticsColourStore: @unchecked Sendable {
    private let lock = NSLock()
    private var records: [ColourStage: ColourStageRecord] = [:]
    private var keys: [ColourStage: ColourSampleKey] = [:]
    private var samples = 0

    /// True if `stage` has not yet been sampled for `key` (and records the claim).
    func claim(_ stage: ColourStage, key: ColourSampleKey) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard keys[stage] != key else { return false }
        keys[stage] = key
        return true
    }

    /// Stores `new`; `clearing` drops stages that no longer apply (a
    /// Window View composite replaces a Mirror capture sample, and the other way round).
    func store(_ new: [ColourStageRecord], clearing: [ColourStage] = []) {
        lock.lock(); defer { lock.unlock() }
        for stage in clearing { records[stage] = nil; keys[stage] = nil }
        for record in new { records[record.stage] = record }
        samples += 1
    }

    func clear() {
        lock.lock(); defer { lock.unlock() }
        records = [:]
        keys = [:]
        samples = 0
    }

    func section() -> StreamDiagnosticsColourSection? {
        lock.lock(); defer { lock.unlock() }
        guard !records.isEmpty else { return nil }
        return StreamDiagnosticsColourSection(
            stages: ColourStage.allCases.compactMap { records[$0] },
            consistency: .evaluate(records),
            sampleCount: samples)
    }
}

// MARK: - Recorder hooks (read-only; each is a no-op while diagnostics are off)

extension StreamDiagnosticsRecorder {
    /// Sender, on `queue`: the buffer being handed to the encoder. Extracted
    /// once per capture generation / pixel format, so the per-frame cost is
    /// the flag, one lock and a key comparison.
    func sampleColourSubmitted(_ pixelBuffer: CVPixelBuffer, windowComposite: Bool, generation: UInt64) {
        guard isEnabled else { return }
        let stage: ColourStage = windowComposite ? .composited : .capture
        let key = ColourSampleKey(generation: generation, format: CVPixelBufferGetPixelFormatType(pixelBuffer))
        guard colourStore.claim(stage, key: key) else { return }
        colourStore.store([.pixelBuffer(stage, pixelBuffer)], clearing: [windowComposite ? .capture : .composited])
        increment(.colourSamples, at: StreamDiagnosticsClock.nowMs())
    }

    /// Sender, VideoToolbox output thread, keyframes only: the encoder's
    /// output format description and the SPS VUI inside it. Extracted when
    /// the generation or the format description changes.
    func sampleColourEncoderOutput(_ desc: CMFormatDescription, generation: UInt64) {
        sampleColour(desc, generation: generation, format: .encoderFormat, vui: .encoderVUI)
    }

    /// Receiver: the format description just built from the received
    /// parameter sets (a format change; once per SPS/PPS change).
    func sampleColourReceiverFormat(_ desc: CMFormatDescription) {
        sampleColour(desc, generation: 0, format: .receiverFormat, vui: .receiverVUI)
    }

    private func sampleColour(_ desc: CMFormatDescription, generation: UInt64, format: ColourStage, vui: ColourStage) {
        guard isEnabled else { return }
        let key = ColourSampleKey(generation: generation, format: UInt32(truncatingIfNeeded: CFHash(desc)))
        guard colourStore.claim(format, key: key) else { return }
        colourStore.store([.formatDescription(format, desc), .vui(vui, from: desc)])
        increment(.colourSamples, at: StreamDiagnosticsClock.nowMs())
    }

    /// The colour section as of now, nil until something was sampled.
    var colourSection: StreamDiagnosticsColourSection? { colourStore.section() }
}

// MARK: - Developer-view text

/// What the developer view shows, as pure functions (tested in MacTests).
enum StreamDiagnosticsColourPresentation {
    static let heading = "Colour metadata"
    static let footnote = "Read-only: what the system attached or the stream declares. Not a colour accuracy check. Sampled once per stream generation or format change."

    static func title(_ stage: ColourStage) -> String {
        switch stage {
        case .capture: return "Capture buffer (Mirror/Extend)"
        case .composited: return "Composited buffer (Window View)"
        case .encoderFormat: return "Encoder output format description"
        case .encoderVUI: return "Encoder SPS VUI"
        case .receiverFormat: return "Receiver format description"
        case .receiverVUI: return "Receiver SPS VUI"
        }
    }

    static func line(_ record: ColourStageRecord) -> String {
        if let reason = record.unparsed {
            return "\(title(record.stage)): not parsed (\(reason.rawValue))"
        }
        let m = record.metadata
        var parts = ["primaries \(m.primaries.label)", "transfer \(m.transfer.label)", "matrix \(m.matrix.label)",
                     "range \(m.range.rawValue)"]
        if m.format != .absent { parts.append("format \(m.format.label)") }
        if let depth = m.bitDepth { parts.append("\(depth)-bit") }
        if let vui = record.vui {
            if !vui.hasVUI {
                parts.append("no VUI")
            } else if !vui.videoSignalTypePresent {
                parts.append("VUI without video signal type")
            } else if !vui.colourDescPresent {
                parts.append("VUI without colour description")
            }
        }
        if m.spaceModel != .absent { parts.append("space \(m.space.rawValue)/\(m.spaceModel.rawValue)") }
        if m.iccPresent == true { parts.append("ICC profile attached") }
        return "\(title(record.stage)): " + parts.joined(separator: " · ")
    }

    static func mismatchLine(_ m: ColourMismatch) -> String {
        let how: String
        switch m.relation {
        case .differ: how = "differ"
        case .firstUnlabelled: return "\(m.field.rawValue): only \(title(m.second)) states it (\(title(m.first)) does not)"
        case .secondUnlabelled: return "\(m.field.rawValue): only \(title(m.first)) states it (\(title(m.second)) does not)"
        }
        return "\(m.field.rawValue): \(title(m.first)) and \(title(m.second)) \(how)"
    }

    static func agreementLine(_ c: ColourConsistency) -> String {
        switch c.agreement {
        case .noData: return "Stages: not enough sampled to compare"
        case .agree: return "Stages: agree (\(c.comparisons) comparison\(c.comparisons == 1 ? "" : "s"))"
        case .differ: return "Stages: differ (\(c.mismatches.count) difference\(c.mismatches.count == 1 ? "" : "s") in \(c.comparisons) comparison\(c.comparisons == 1 ? "" : "s"))"
        }
    }

    /// Empty when nothing has been sampled yet.
    static func lines(_ section: StreamDiagnosticsColourSection?) -> [String] {
        guard let section else { return [] }
        return section.stages.map(line) + [agreementLine(section.consistency)] + section.consistency.mismatches.map(mismatchLine)
    }
}
