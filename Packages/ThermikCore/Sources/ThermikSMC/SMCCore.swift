// SMCCore.swift — Thermik (MIT). READ-ONLY AppleSMC user-client access.
//
// Facts used (80-byte SMCKeyData_t layout, selector 2, commands 5/8/9, result codes, attribute bits) are
// public knowledge documented by Linux applesmc/macsmc, acidanthera/VirtualSMC (BSD-3), SMCKit/Stats (MIT).
// Independent implementation merged from research/fans/code/Shared/SMCCore.swift and
// research/sensors/src/SMCClient.swift. The WRITE command (6) is NOT in this module: it lives in
// ThermikSMCWriter, which only the root helper links (so the app binary contains no SMC write path).
import Foundation
import IOKit

// MARK: - FourCC

/// Four-character SMC key or type code packed big-endian into a UInt32 ("F0Ac" == 0x46304163).
public struct FourCC: Hashable, Sendable, Comparable, CustomStringConvertible, ExpressibleByStringLiteral {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    /// Pads with spaces / truncates to 4 ASCII bytes. "ui8" -> "ui8 ".
    public init(_ string: String) {
        var v: UInt32 = 0
        var n = 0
        for b in string.utf8.prefix(4) { v = (v << 8) | UInt32(b); n += 1 }
        while n < 4 { v = (v << 8) | 0x20; n += 1 }
        rawValue = v
    }
    public init(stringLiteral value: String) { self.init(value) }

    public var description: String {
        let bytes = [24, 16, 8, 0].map { UInt8((rawValue >> UInt32($0)) & 0xFF) }
        return String(decoding: bytes.map { (0x20...0x7E).contains($0) ? $0 : UInt8(ascii: "?") }, as: UTF8.self)
    }

    /// FourCC.fan("F%dTg", 1) -> "F1Tg". Fan indices 0...9 are one ASCII digit (SMC convention).
    public static func fan(_ template: String, _ index: Int) -> FourCC {
        precondition((0...9).contains(index), "SMC fan index out of range")
        return FourCC(template.replacingOccurrences(of: "%d", with: String(index)))
    }

    public static func < (a: FourCC, b: FourCC) -> Bool { a.description < b.description }
}

// MARK: - Types, attributes, key info

public struct SMCDataType: Hashable, Sendable, CustomStringConvertible {
    public let code: FourCC
    public init(_ code: FourCC) { self.code = code }
    public var description: String { code.description }

    public static let flt   = SMCDataType("flt ")   // IEEE-754 binary32, little-endian (Apple Silicon, T2)
    public static let ioft  = SMCDataType("ioft")   // signed 48.16 fixed point, little-endian (AS battery gauge)
    public static let fpe2  = SMCDataType("fpe2")   // unsigned 14.2 fixed point, big-endian (Intel fans)
    public static let sp78  = SMCDataType("sp78")   // signed 7.8 fixed point, big-endian (Intel temps)
    public static let ui8   = SMCDataType("ui8 ")
    public static let ui16  = SMCDataType("ui16")
    public static let ui32  = SMCDataType("ui32")
    public static let ui64  = SMCDataType("ui64")
    public static let si8   = SMCDataType("si8 ")
    public static let si16  = SMCDataType("si16")
    public static let si32  = SMCDataType("si32")
    public static let si64  = SMCDataType("si64")
    public static let flag  = SMCDataType("flag")
    public static let ch8   = SMCDataType("ch8*")
    public static let fds   = SMCDataType("{fds")   // Intel fan descriptor struct (F%dID)
    public static let hex   = SMCDataType("hex_")
}

/// Attribute byte (bit meanings per VirtualSMC SMCKeyAttribute, BSD-3).
public struct SMCKeyAttributes: OptionSet, Hashable, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let privateWrite = SMCKeyAttributes(rawValue: 0x01)
    public static let privateRead  = SMCKeyAttributes(rawValue: 0x02)
    public static let atomic       = SMCKeyAttributes(rawValue: 0x04)
    public static let const_       = SMCKeyAttributes(rawValue: 0x08)
    public static let function     = SMCKeyAttributes(rawValue: 0x10)
    public static let unknown20    = SMCKeyAttributes(rawValue: 0x20)
    public static let write        = SMCKeyAttributes(rawValue: 0x40)
    public static let read         = SMCKeyAttributes(rawValue: 0x80)
}

public struct SMCKeyInfo: Hashable, Sendable {
    public let size: UInt32
    public let type: SMCDataType
    public let attributes: SMCKeyAttributes
    public init(size: UInt32, type: SMCDataType, attributes: SMCKeyAttributes) {
        self.size = size; self.type = type; self.attributes = attributes
    }
    public var isReadable: Bool { attributes.contains(.read) }
    public var isWritable: Bool { attributes.contains(.write) }
    /// VERIFIED on M4 Max / macOS 27 (SENS §2.5): integer keys whose attribute has bit 0x04 are stored
    /// LITTLE-endian (B0DC 8579 mAh, B0CT 34, F0CR 150); keys without it are legacy BIG-endian (#KEY 3512,
    /// D4MP 139720 mW, RCID 0x6041). `flt `/`ioft` are always LE; `spXY`/`fpXY` always BE.
    public var integersAreLittleEndian: Bool { attributes.contains(.atomic) }
}

// MARK: - Result codes & errors

/// SMC firmware result byte (offset 40). Values per VirtualSMC SDK.
public enum SMCResultCode: UInt8, Sendable {
    case success = 0x00, error = 0x01
    case commCollision = 0x80, spuriousData = 0x81, badCommand = 0x82, badParameter = 0x83
    case notFound = 0x84, notReadable = 0x85, notWritable = 0x86, keySizeMismatch = 0x87
    case framingError = 0x88, badArgument = 0x89
    case timeout = 0xB7, keyIndexRange = 0xB8, badFunctionParameter = 0xC0
    case eventBufferWrongOrder = 0xC4, eventBufferReadError = 0xC5, deviceAccessError = 0xC7
    case unsupportedFeature = 0xCB, smbAccessError = 0xCC, invalidSize = 0xCE
}

public enum SMCError: Error, Sendable, CustomStringConvertible {
    case serviceNotFound
    case openFailed(kern_return_t)
    case ioKit(kern_return_t, key: FourCC)          // IOConnectCallStructMethod failed (e.g. kIOReturnNotOpen after wake)
    case notPrivileged(key: FourCC)                 // kIOReturnNotPrivileged (0xE00002C2): root required (writes)
    case firmware(UInt8, key: FourCC)               // non-zero SMC result byte
    case keyNotFound(FourCC)                        // result 0x84 (also: wrong mode-key casing on M5!)
    case typeMismatch(key: FourCC, expected: [SMCDataType], actual: SMCDataType)
    case sizeMismatch(key: FourCC, expected: Int, actual: Int)
    case tooLarge(key: FourCC, size: UInt32)        // payload > 32 bytes cannot be returned via SMCKeyData_t
    case notWritable(FourCC)
    case invalidValue(String)

    public var resultCode: SMCResultCode? {
        if case .firmware(let r, _) = self { return SMCResultCode(rawValue: r) }
        if case .keyNotFound = self { return .notFound }
        return nil
    }

    /// The connection should be reopened (sleep/wake, SMC restart).
    public var isConnectionLost: Bool {
        if case .ioKit(let kr, _) = self { return kr == kIOReturnNotOpen || kr == kIOReturnNoDevice || kr == kIOReturnAborted }
        return false
    }

    public var description: String {
        switch self {
        case .serviceNotFound: return "AppleSMC service not found"
        case .openFailed(let kr): return String(format: "IOServiceOpen failed 0x%08x", kr)
        case .ioKit(let kr, let k): return String(format: "IOKit error 0x%08x on %@", kr, k.description)
        case .notPrivileged(let k): return "Not privileged to access \(k) (root required)"
        case .firmware(let r, let k): return String(format: "SMC result 0x%02x on %@", r, k.description)
        case .keyNotFound(let k): return "SMC key \(k) not found"
        case .typeMismatch(let k, let e, let a): return "SMC key \(k) has type \(a), expected \(e)"
        case .sizeMismatch(let k, let e, let a): return "SMC key \(k) has size \(a), expected \(e)"
        case .tooLarge(let k, let s): return "SMC key \(k) payload \(s) > 32 bytes"
        case .notWritable(let k): return "SMC key \(k) is not writable"
        case .invalidValue(let s): return "Invalid value: \(s)"
        }
    }
}

// MARK: - Raw parameter block (SMCKeyData_t, 80 bytes)

/// Byte-exact image of the C struct passed to selector 2 (kSMCHandleYPCEvent). Explicit offsets avoid any
/// dependence on Swift struct layout.
///  off size field
///    0   4  key (UInt32, host order)          28  4  keyInfo.dataSize        40 1 result   42 1 data8 (command)
///    4   6  vers                              32  4  keyInfo.dataType        41 1 status   44 4 data32 (index)
///   12  16  pLimitData                        36  1  keyInfo.dataAttributes                48 32 bytes (payload)
package struct SMCParamBlock: Sendable {
    package static let size = 80
    package enum Off { package static let key = 0, size = 28, type = 32, attr = 36, result = 40, status = 41, cmd = 42, data32 = 44, bytes = 48 }

    package var raw = [UInt8](repeating: 0, count: SMCParamBlock.size)
    package init() {}

    private mutating func put32(_ off: Int, _ v: UInt32) {
        raw[off] = UInt8(v & 0xFF); raw[off + 1] = UInt8((v >> 8) & 0xFF)
        raw[off + 2] = UInt8((v >> 16) & 0xFF); raw[off + 3] = UInt8((v >> 24) & 0xFF)
    }
    private func get32(_ off: Int) -> UInt32 {
        UInt32(raw[off]) | UInt32(raw[off + 1]) << 8 | UInt32(raw[off + 2]) << 16 | UInt32(raw[off + 3]) << 24
    }

    package var key: FourCC { get { FourCC(rawValue: get32(Off.key)) } set { put32(Off.key, newValue.rawValue) } }
    package var dataSize: UInt32 { get { get32(Off.size) } set { put32(Off.size, newValue) } }
    package var dataType: UInt32 { get32(Off.type) }
    package var attributes: UInt8 { raw[Off.attr] }
    package var result: UInt8 { raw[Off.result] }
    package var command: UInt8 { get { raw[Off.cmd] } set { raw[Off.cmd] = newValue } }
    package var data32: UInt32 { get { get32(Off.data32) } set { put32(Off.data32, newValue) } }
    package func payload(count: Int) -> [UInt8] { Array(raw[Off.bytes ..< Off.bytes + min(max(count, 0), 32)]) }
    package mutating func setPayload(_ bytes: [UInt8]) {
        precondition(bytes.count <= 32)
        for i in 0..<32 { raw[Off.bytes + i] = i < bytes.count ? bytes[i] : 0 }
    }
}

package enum SMCCommand: UInt8, Sendable {
    case readKey = 5
    case writeKey = 6          // used ONLY by ThermikSMCWriter (helper)
    case keyFromIndex = 8
    case keyInfo = 9
}

// MARK: - Read interface

/// Read-only SMC interface (no root needed). Conformers must be thread-safe.
public protocol SMCReading: Sendable {
    func keyInfo(_ key: FourCC) throws -> SMCKeyInfo
    func readRaw(_ key: FourCC) throws -> (SMCKeyInfo, [UInt8])
    func keyCount() throws -> Int
    func key(at index: Int) throws -> FourCC
}

// MARK: - Connection

/// Thread-safe AppleSMC user-client connection (one per process is enough; reopen after wake on error).
/// Apple Silicon: matches AppleSMCKeysEndpoint (conforms to "AppleSMC"); Intel: AppleSMC.
public final class SMCConnection: SMCReading, @unchecked Sendable {
    private var conn: io_connect_t = 0
    private let lock = NSLock()
    private var infoCache: [FourCC: SMCKeyInfo] = [:]
    private var missing: Set<FourCC> = []             // cache "key not found" (a miss costs a full round trip)
    private static let selector: UInt32 = 2           // kSMCHandleYPCEvent

    public init() throws { conn = try Self.open() }
    deinit { if conn != 0 { IOServiceClose(conn) } }

    private static func open() throws -> io_connect_t {
        var service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        if service == 0 { service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMCKeysEndpoint")) }
        guard service != 0 else { throw SMCError.serviceNotFound }
        defer { IOObjectRelease(service) }
        var c: io_connect_t = 0
        let kr = IOServiceOpen(service, mach_task_self_, 0, &c)
        guard kr == kIOReturnSuccess else { throw SMCError.openFailed(kr) }
        return c
    }

    /// Re-open after `SMCError.isConnectionLost` (e.g. after wake). Keeps the key-info cache.
    public func reconnect() throws {
        lock.lock(); defer { lock.unlock() }
        if conn != 0 { IOServiceClose(conn); conn = 0 }
        conn = try Self.open()
    }

    /// One round trip. Package-visible so ThermikSMCWriter can issue command 6. Takes the lock.
    package func perform(_ input: SMCParamBlock) throws -> SMCParamBlock {
        lock.lock(); defer { lock.unlock() }
        return try callLocked(input)
    }

    private func callLocked(_ input: SMCParamBlock) throws -> SMCParamBlock {
        var inBlock = input
        var outBlock = SMCParamBlock()
        var outSize = SMCParamBlock.size
        let kr = inBlock.raw.withUnsafeMutableBytes { ip in
            outBlock.raw.withUnsafeMutableBytes { op in
                IOConnectCallStructMethod(conn, Self.selector, ip.baseAddress, SMCParamBlock.size, op.baseAddress, &outSize)
            }
        }
        if kr == kIOReturnNotPrivileged { throw SMCError.notPrivileged(key: input.key) }
        guard kr == kIOReturnSuccess else { throw SMCError.ioKit(kr, key: input.key) }
        return outBlock
    }

    private func keyInfoLocked(_ key: FourCC) throws -> SMCKeyInfo {
        if let cached = infoCache[key] { return cached }
        if missing.contains(key) { throw SMCError.keyNotFound(key) }
        var b = SMCParamBlock()
        b.key = key
        b.command = SMCCommand.keyInfo.rawValue
        let o = try callLocked(b)
        if o.result == SMCResultCode.notFound.rawValue { missing.insert(key); throw SMCError.keyNotFound(key) }
        guard o.result == 0 else { throw SMCError.firmware(o.result, key: key) }
        let info = SMCKeyInfo(size: o.dataSize, type: SMCDataType(FourCC(rawValue: o.dataType)),
                              attributes: SMCKeyAttributes(rawValue: o.attributes))
        infoCache[key] = info
        return info
    }

    public func keyInfo(_ key: FourCC) throws -> SMCKeyInfo {
        lock.lock(); defer { lock.unlock() }
        return try keyInfoLocked(key)
    }

    public func exists(_ key: FourCC) -> Bool { (try? keyInfo(key)) != nil }

    public func readRaw(_ key: FourCC) throws -> (SMCKeyInfo, [UInt8]) {
        lock.lock(); defer { lock.unlock() }
        let info = try keyInfoLocked(key)
        guard info.size <= 32 else { throw SMCError.tooLarge(key: key, size: info.size) }
        var b = SMCParamBlock()
        b.key = key
        b.dataSize = info.size
        b.command = SMCCommand.readKey.rawValue
        let o = try callLocked(b)
        if o.result == SMCResultCode.notFound.rawValue { infoCache[key] = nil; throw SMCError.keyNotFound(key) }
        guard o.result == 0 else { throw SMCError.firmware(o.result, key: key) }
        return (info, o.payload(count: Int(info.size)))
    }

    /// `#KEY` is ui32 with attribute 0x80 → big-endian (3512 on M4 Max).
    public func keyCount() throws -> Int {
        let (_, b) = try readRaw("#KEY")
        guard b.count >= 4 else { throw SMCError.sizeMismatch(key: "#KEY", expected: 4, actual: b.count) }
        return Int(UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3]))
    }

    public func key(at index: Int) throws -> FourCC {
        lock.lock(); defer { lock.unlock() }
        var b = SMCParamBlock()
        b.data32 = UInt32(index)
        b.command = SMCCommand.keyFromIndex.rawValue
        let o = try callLocked(b)
        guard o.result == 0 else { throw SMCError.firmware(o.result, key: FourCC(rawValue: 0)) }
        return o.key
    }

    /// All keys by index enumeration (~10 ms for 3512 keys). Call once at start; cache the result.
    public func allKeys() throws -> [FourCC] {
        let n = try keyCount()
        return (0..<n).compactMap { try? key(at: $0) }
    }
}
