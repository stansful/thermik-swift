// SMCCodec.swift — Thermik (MIT). Type-driven SMC value decoding/encoding.
// ALWAYS dispatch on the key's reported data type (command 9) — never on CPU architecture.
// Merge of research/fans/code/Shared/SMCCodec.swift (encoders, fds, fixed point) and
// research/sensors/src/SMCClient.swift (attribute-aware integer endianness, ioft, 64-bit ints).
import Foundation

public enum SMCValue: Sendable, Equatable, CustomStringConvertible {
    case number(Double)
    case unsigned(UInt64)
    case signed(Int64)
    case bool(Bool)
    case string(String)
    case fanDescriptor(type: UInt8, zone: UInt8, location: UInt8, name: String)
    case bytes([UInt8])

    public var doubleValue: Double? {
        switch self {
        case .number(let d): return d
        case .unsigned(let u): return Double(u)
        case .signed(let s): return Double(s)
        case .bool(let b): return b ? 1 : 0
        default: return nil
        }
    }

    public var description: String {
        switch self {
        case .number(let d): return d.isFinite ? String(format: "%.4f", d) : "\(d)"
        case .unsigned(let u): return "\(u)"
        case .signed(let s): return "\(s)"
        case .bool(let b): return "\(b)"
        case .string(let s): return "\"\(s)\""
        case let .fanDescriptor(t, z, l, n): return "fds(type=\(t) zone=\(z) loc=\(l) name=\"\(n)\")"
        case .bytes(let b): return b.map { String(format: "%02x", $0) }.joined(separator: " ")
        }
    }
}

public enum SMCCodec {

    // MARK: Decoding

    public static func decode(_ b: [UInt8], as info: SMCKeyInfo) -> SMCValue {
        let le = info.integersAreLittleEndian
        switch info.type {
        case .flt where b.count >= 4:  return .number(Double(decodeFloat32LE(b)))
        case .ioft where b.count >= 8: return .number(Double(Int64(bitPattern: uint(b, 8, littleEndian: true))) / 65536.0)
        case .ui8 where b.count >= 1:  return .unsigned(UInt64(b[0]))
        case .ui16 where b.count >= 2: return .unsigned(uint(b, 2, littleEndian: le))
        case .ui32 where b.count >= 4: return .unsigned(uint(b, 4, littleEndian: le))
        case .ui64 where b.count >= 8: return .unsigned(uint(b, 8, littleEndian: le))
        case .si8 where b.count >= 1:  return .signed(Int64(Int8(bitPattern: b[0])))
        case .si16 where b.count >= 2: return .signed(Int64(Int16(bitPattern: UInt16(uint(b, 2, littleEndian: le)))))
        case .si32 where b.count >= 4: return .signed(Int64(Int32(bitPattern: UInt32(uint(b, 4, littleEndian: le)))))
        case .si64 where b.count >= 8: return .signed(Int64(bitPattern: uint(b, 8, littleEndian: le)))
        case .flag where b.count >= 1: return .bool(b[0] != 0)
        case .ch8:                     return .string(String(decoding: b.prefix { $0 != 0 }, as: UTF8.self))
        case .fds where b.count >= 4:
            let name = String(decoding: b.dropFirst(4).prefix { $0 != 0 }, as: UTF8.self).trimmingCharacters(in: .whitespaces)
            return .fanDescriptor(type: b[0], zone: b[1], location: b[2], name: name)
        default:
            if let fixed = decodeFixedPoint(b, type: info.type) { return .number(fixed) }
            return .bytes(b)
        }
    }

    /// Apple fixed point, 2 bytes big-endian: "fpXY" unsigned / "spXY" signed, Y = fraction bits (hex digit).
    /// sp78 → raw/256 (Intel temps), fpe2 → raw/4 (Intel fans), sp5a, sp4b, fp88, ...
    public static func decodeFixedPoint(_ bytes: [UInt8], type: SMCDataType) -> Double? {
        let chars = Array(type.description)
        guard bytes.count >= 2, chars.count == 4, chars[1] == "p", chars[2].hexDigitValue != nil,
              let fracBits = chars[3].hexDigitValue else { return nil }
        let raw = UInt16(uint(bytes, 2, littleEndian: false))
        switch chars[0] {
        case "f": return Double(raw) / Double(1 << fracBits)
        case "s": return Double(Int16(bitPattern: raw)) / Double(1 << fracBits)
        default: return nil
        }
    }

    @inline(__always)
    public static func decodeFloat32LE(_ b: [UInt8]) -> Float {
        Float(bitPattern: UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24)
    }

    @inline(__always)
    static func uint(_ b: [UInt8], _ n: Int, littleEndian: Bool) -> UInt64 {
        guard b.count >= n else { return 0 }
        var v: UInt64 = 0
        if littleEndian { for i in (0..<n).reversed() { v = (v << 8) | UInt64(b[i]) } }
        else { for i in 0..<n { v = (v << 8) | UInt64(b[i]) } }
        return v
    }

    // MARK: Encoding (pure; used only by the helper's ThermikSMCWriter)

    /// Encodes an RPM for F%dTg / F%dMn according to its type. Rejects non-finite/negative input.
    /// Does NOT clamp to [min, max] — that is policy (FanDescriptor.clamp).
    public static func encodeRPM(_ rpm: Double, as info: SMCKeyInfo, key: FourCC) throws -> [UInt8] {
        guard rpm.isFinite, rpm >= 0 else { throw SMCError.invalidValue("rpm \(rpm) for \(key)") }
        switch info.type {
        case .flt:
            guard info.size == 4 else { throw SMCError.sizeMismatch(key: key, expected: 4, actual: Int(info.size)) }
            return encodeFloat32LE(Float(rpm))
        case .fpe2:
            guard info.size == 2 else { throw SMCError.sizeMismatch(key: key, expected: 2, actual: Int(info.size)) }
            let raw = UInt16(min(rpm * 4.0, Double(UInt16.max)).rounded())     // 14.2 fixed point
            return [UInt8(raw >> 8), UInt8(raw & 0xFF)]                          // big-endian
        default:
            throw SMCError.typeMismatch(key: key, expected: [.flt, .fpe2], actual: info.type)
        }
    }

    public static func encodeFloat32LE(_ f: Float) -> [UInt8] {
        let bits = f.bitPattern
        return [UInt8(bits & 0xFF), UInt8((bits >> 8) & 0xFF), UInt8((bits >> 16) & 0xFF), UInt8((bits >> 24) & 0xFF)]
    }

    /// ui8 mode / flag keys (F%dMd, F%dmd, Ftst).
    public static func encodeUInt8(_ v: UInt8, as info: SMCKeyInfo, key: FourCC) throws -> [UInt8] {
        guard info.type == .ui8 || info.type == .flag || info.type == .hex else {
            throw SMCError.typeMismatch(key: key, expected: [.ui8, .flag], actual: info.type)
        }
        guard info.size == 1 else { throw SMCError.sizeMismatch(key: key, expected: 1, actual: Int(info.size)) }
        return [v]
    }

    /// Intel "FS! " (ui16 big-endian bitmask, bit n = fan n forced). Legacy key without attr 0x04 → BE.
    public static func encodeUInt16BE(_ v: UInt16, as info: SMCKeyInfo, key: FourCC) throws -> [UInt8] {
        guard info.type == .ui16 || info.type == .hex else {
            throw SMCError.typeMismatch(key: key, expected: [.ui16], actual: info.type)
        }
        guard info.size == 2 else { throw SMCError.sizeMismatch(key: key, expected: 2, actual: Int(info.size)) }
        return [UInt8(v >> 8), UInt8(v & 0xFF)]
    }
}

public extension SMCReading {
    func value(_ key: FourCC) throws -> SMCValue {
        let (info, bytes) = try readRaw(key)
        return SMCCodec.decode(bytes, as: info)
    }

    /// Numeric key as Double (flt, ioft, fpXY/spXY, integers, flag).
    func readNumber(_ key: FourCC) throws -> Double {
        let (info, bytes) = try readRaw(key)
        guard let d = SMCCodec.decode(bytes, as: info).doubleValue else {
            throw SMCError.typeMismatch(key: key, expected: [.flt, .fpe2, .ui8, .ui16, .ui32], actual: info.type)
        }
        return d
    }

    func readUInt8(_ key: FourCC) throws -> UInt8 {
        let (info, bytes) = try readRaw(key)
        guard info.size == 1, let b = bytes.first else { throw SMCError.sizeMismatch(key: key, expected: 1, actual: Int(info.size)) }
        return b
    }

    /// nil when missing / unreadable / non-numeric. Convenience for sensors.
    func double(_ key: FourCC) -> Double? { try? readNumber(key) }
}
