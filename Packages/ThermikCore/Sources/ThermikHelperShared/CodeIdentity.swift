// CodeIdentity.swift — Thermik (MIT). Shared by Thermik.app and the privileged helper. OWNER: Unit 4.
// Port of research/helper/skeleton/Shared/CodeIdentity.swift (HELP §A.2).
// Code-signing facts about a running process or an executable on disk. Used by the helper (peer validation,
// its own policy), by the app (SMAppService vs legacy install, pinning its own cdhash for ad-hoc builds) and by
// the legacy installer (cdhashes of every slice).
import Foundation
import Security

public struct CodeIdentity: Sendable, CustomStringConvertible {
    public var identifier: String?
    public var teamID: String?
    public var cdhashHex: String?
    /// Dynamic code-signing status (`kSecCodeInfoStatus`, the kernel's CS_* flags). 0 for static code on disk.
    public var statusFlags: UInt32

    /// Kernel code-signing status bits (`<kern/cs_blobs.h>`, public xnu source). The helper requires
    /// valid | hard | kill | runtime from every peer (obdev "What we have learned from a vulnerability",
    /// the same checks Battery Toolkit (BSD-3-Clause) applies; facts only).
    public struct Status: OptionSet, Sendable {
        public let rawValue: UInt32
        public init(rawValue: UInt32) { self.rawValue = rawValue }
        public static let valid    = Status(rawValue: 0x0000_0001)   // CS_VALID
        public static let adhoc    = Status(rawValue: 0x0000_0002)   // CS_ADHOC
        public static let hard     = Status(rawValue: 0x0000_0100)   // CS_HARD: refuse invalid pages
        public static let kill     = Status(rawValue: 0x0000_0200)   // CS_KILL: kill the process if it becomes invalid
        public static let runtime  = Status(rawValue: 0x0001_0000)   // CS_RUNTIME: hardened runtime
        public static let debugged = Status(rawValue: 0x1000_0000)   // CS_DEBUGGED: a debugger attached
        /// What every XPC peer of the helper must have.
        public static let requiredForPeers: Status = [.valid, .hard, .kill, .runtime]
    }

    public var status: Status { Status(rawValue: statusFlags) }
    /// No Team ID: ad-hoc ("Sign to Run Locally") or linker-signed code.
    public var isAdHoc: Bool { teamID?.isEmpty ?? true }

    public init(identifier: String?, teamID: String?, cdhashHex: String?, statusFlags: UInt32) {
        self.identifier = identifier; self.teamID = teamID; self.cdhashHex = cdhashHex; self.statusFlags = statusFlags
    }

    public var description: String {
        "identifier=\(identifier ?? "nil") team=\(teamID ?? "nil") cdhash=\(cdhashHex ?? "nil") status=0x\(String(statusFlags, radix: 16))"
    }

    /// Signing identity of the running process (dynamic: includes the live status flags).
    public static func ofSelf() -> CodeIdentity? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        return of(code)
    }

    /// Identity of an XPC peer, race-free (audit token, not pid).
    public static func of(auditToken: audit_token_t) -> (CodeIdentity, SecCode)? {
        let tokenData = withUnsafeBytes(of: auditToken) { Data($0) }
        var code: SecCode?
        let attrs = [kSecGuestAttributeAudit: tokenData] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attrs, [], &code) == errSecSuccess, let code,
              let id = of(code) else { return nil }
        return (id, code)
    }

    static func of(_ code: SecCode) -> CodeIdentity? {
        var info: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation | kSecCSDynamicInformation)
        // A SecCode may be passed where a SecStaticCode is expected (documented in SecCode.h).
        guard SecCodeCopySigningInformation(unsafeBitCast(code, to: SecStaticCode.self), flags, &info) == errSecSuccess,
              let d = info as? [String: Any] else { return nil }
        return identity(from: d)
    }

    /// Static identity of an executable or bundle on disk (native slice). `statusFlags` is 0.
    public static func ofCode(at url: URL) -> CodeIdentity? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let d = info as? [String: Any] else { return nil }
        return identity(from: d)
    }

    private static func identity(from d: [String: Any]) -> CodeIdentity {
        CodeIdentity(
            identifier: d[kSecCodeInfoIdentifier as String] as? String,
            teamID: d[kSecCodeInfoTeamIdentifier as String] as? String,
            cdhashHex: (d[kSecCodeInfoUnique as String] as? Data).map(hex),
            statusFlags: (d[kSecCodeInfoStatus as String] as? UInt32) ?? 0)
    }

    /// cdhash of every architecture slice of an executable or bundle on disk
    /// (a universal binary has one cdhash per slice; the kernel checks the
    /// running slice's). Used to build the legacy trust file.
    public static func cdhashes(ofCodeAt url: URL) -> [String] {
        var result: [String] = []
        for arch in ["arm64", "x86_64"] {
            var code: SecStaticCode?
            let attrs = [kSecCodeAttributeArchitecture: arch] as CFDictionary
            guard SecStaticCodeCreateWithPathAndAttributes(url as CFURL, [], attrs, &code) == errSecSuccess,
                  let code else { continue }
            var info: CFDictionary?
            guard SecCodeCopySigningInformation(code, [], &info) == errSecSuccess,
                  let d = info as? [String: Any], let u = d[kSecCodeInfoUnique as String] as? Data else { continue }
            let h = hex(u)
            if !result.contains(h) { result.append(h) }
        }
        return result
    }

    /// True for a cdhash as codesign prints it: 20 bytes (the CodeDirectory hash, truncated) = 40 hex digits.
    public static func isValidCDHash(_ s: String) -> Bool { s.count == 40 && s.allSatisfy(\.isHexDigit) }
}

private func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }
