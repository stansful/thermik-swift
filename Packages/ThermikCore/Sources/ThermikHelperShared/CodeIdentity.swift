import Foundation
import Security

/// Code-signing facts about a running process or an executable on disk.
/// Used by the helper (peer validation, own policy) and by the app (choosing
/// SMAppService vs legacy install, pinning its own cdhash for ad-hoc builds).
public struct CodeIdentity: Sendable, CustomStringConvertible {
    public var identifier: String?
    public var teamID: String?
    public var cdhashHex: String?
    public var statusFlags: UInt32

    public var description: String {
        "identifier=\(identifier ?? "nil") team=\(teamID ?? "nil") cdhash=\(cdhashHex ?? "nil") status=0x\(String(statusFlags, radix: 16))"
    }

    /// Signing identity of the running process.
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
        return CodeIdentity(
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
}

private func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }
