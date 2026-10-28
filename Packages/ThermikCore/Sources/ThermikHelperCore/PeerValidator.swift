// PeerValidator.swift — Thermik (MIT). HELPER ONLY. OWNER: Unit 4.
// Port of research/helper/skeleton/Helper/PeerValidator.swift (HELP §5.3, §A.5); SPEC §2.6.4, invariant I12.
//
// Who may talk to the helper is derived at startup from the helper's OWN signature (`SecCodeCopySelf`), so nothing
// is baked in at build time:
//   - helper has a Team ID      → the client must be signed by the same team with an allowed identifier;
//   - ad-hoc, legacy/development → the client's cdhash must be listed in the root-owned trust file written by the
//                                   admin-authorized legacy installer;
//   - ad-hoc inside an app bundle (SMAppService) → deny all: the bundle is user-writable, so "trust the app that
//                                   contains me" can be defeated by re-signing it (HELP §2.4, §5.3);
//   - anything else              → deny all (fail closed).
// An identifier-only requirement is worthless for ad-hoc code: `codesign -s - -i app.thermik.Thermik` satisfies it
// (verified, HELP §1). Checks per connection: the audit-token CS status flags (valid | hard | kill | runtime; not
// `debugged`, and no get-task-allow in the requirement, unless the helper was built with the THERMIK_DEBUGGABLE
// developer opt-in (`allowDebuggable`, Helper/main.swift) — obdev "What we have learned from a vulnerability", the
// same checks Battery Toolkit (BSD-3-Clause) applies; facts only), `SecCodeCheckValidity` against the requirement,
// and then `setCodeSigningRequirement`, which XPC re-checks for EVERY message (defeats PID-reuse / exec races).
import Foundation
import Security
import ThermikHelperShared

public enum PeerPolicy: Sendable, Equatable, CustomStringConvertible {
    case sameTeam(teamID: String)
    case pinnedCDHashes([String])
    case denyAll(reason: String)

    /// Requirement for `NSXPCConnection.setCodeSigningRequirement` (macOS 13+). nil → reject every peer.
    public func requirement(allowDebuggable: Bool,
                            clientIdentifiers: [String] = ThermikHelper.allowedClientIdentifiers) -> String? {
        guard !clientIdentifiers.isEmpty else { return nil }
        let ids = clientIdentifiers.map { "identifier \"\($0)\"" }.joined(separator: " or ")
        let noDebug = allowDebuggable ? "" : " and !(entitlement[\"com.apple.security.get-task-allow\"] /* exists */)"
        switch self {
        case .sameTeam(let team):
            guard !team.isEmpty, team.allSatisfy({ $0.isLetter || $0.isNumber }) else { return nil }
            return "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\" and (\(ids))\(noDebug)"
        case .pinnedCDHashes(let hashes):
            let valid = hashes.filter(CodeIdentity.isValidCDHash)
            guard !valid.isEmpty else { return nil }
            return "(" + valid.map { "cdhash H\"\($0)\"" }.joined(separator: " or ") + ") and (\(ids))\(noDebug)"
        case .denyAll:
            return nil
        }
    }

    public var description: String {
        switch self {
        case .sameTeam(let team): "sameTeam(\(team))"
        case .pinnedCDHashes(let hashes): "pinnedCDHashes(\(hashes.count))"
        case .denyAll(let reason): "denyAll(\(reason))"
        }
    }
}

public final class PeerValidator: Sendable {
    public let policy: PeerPolicy
    public let allowDebuggable: Bool
    public let clientIdentifiers: [String]
    /// CS status bits every peer must carry. Production: `.requiredForPeers`. In-process tools whose client is
    /// a `swift build` binary (no hardened runtime) relax it; the requirement itself is never relaxed.
    public let requiredStatus: CodeIdentity.Status
    /// The requirement string, computed once (nil = deny all).
    public let requirement: String?

    public init(policy: PeerPolicy, allowDebuggable: Bool,
                clientIdentifiers: [String] = ThermikHelper.allowedClientIdentifiers,
                requiredStatus: CodeIdentity.Status = .requiredForPeers) {
        self.policy = policy
        self.allowDebuggable = allowDebuggable
        self.clientIdentifiers = clientIdentifiers
        self.requiredStatus = requiredStatus
        self.requirement = policy.requirement(allowDebuggable: allowDebuggable, clientIdentifiers: clientIdentifiers)
    }

    /// Policy from the helper's own signature and install kind (SPEC §2.6.5 step 5).
    public static func makePolicy(installKind: HelperInstallKind,
                                  trustFile: String = ThermikHelper.Legacy.trustFilePath) -> PeerPolicy {
        makePolicy(installKind: installKind, source: trustFile) { readTrustFile(trustFile) }
    }

    /// The same decision with the trust file's content given directly: the policy this helper binary would enforce
    /// once an installer pinned `trustedCDHashes`. Only for the build-time self-check
    /// (`thermik-helper --peer-requirement`, scripts/lib/build.sh); the daemon itself always reads the root-owned file.
    public static func makePolicy(installKind: HelperInstallKind, trustedCDHashes: [String]) -> PeerPolicy {
        makePolicy(installKind: installKind, source: "the given cdhashes") { trustedCDHashes }
    }

    private static func makePolicy(installKind: HelperInstallKind, source: String,
                                   trustedClients: () -> [String]) -> PeerPolicy {
        guard let me = CodeIdentity.ofSelf() else { return .denyAll(reason: "cannot read own signature") }
        if let team = me.teamID, !team.isEmpty { return .sameTeam(teamID: team) }
        switch installKind {
        case .legacy, .development:
            // Ad-hoc helper: only an admin-written, root-owned trust file can vouch for clients.
            let hashes = trustedClients()
            return hashes.isEmpty ? .denyAll(reason: "no trusted clients in \(source)") : .pinnedCDHashes(hashes)
        case .appService:
            return .denyAll(reason: "ad-hoc helper registered via SMAppService is unsupported")
        }
    }

    /// Accept or reject a new connection. On accept, installs the per-message requirement.
    /// Any logged-in user's trusted copy of Thermik may control the fans (euid is not checked): identity is
    /// established by code signature only.
    public func accept(_ connection: NSXPCConnection) -> Bool {
        let pid = connection.processIdentifier
        guard let requirement else {
            securityLog.error("rejecting pid \(pid, privacy: .public): policy \(self.policy.description, privacy: .public)")
            return false
        }
        // Dynamic checks through the audit token (private-but-stable KVC key "auditToken", verified on macOS 27,
        // HELP §1). If it ever disappears, the public per-message requirement below still applies.
        if let token = Self.auditToken(of: connection) {
            guard let (identity, code) = CodeIdentity.of(auditToken: token) else {
                securityLog.error("rejecting pid \(pid, privacy: .public): cannot read its signature")
                return false
            }
            var required = requiredStatus
            if identity.status.contains(.debugged) {
                guard allowDebuggable else {
                    securityLog.error("rejecting \(identity.identifier ?? "?", privacy: .public) (pid \(pid, privacy: .public)): a debugger is attached")
                    return false
                }
                required = required.intersection(.runtime)   // attaching a debugger may clear VALID / HARD / KILL
            }
            guard identity.status.isSuperset(of: required) else {
                securityLog.error("rejecting \(identity.identifier ?? "?", privacy: .public) (pid \(pid, privacy: .public)): CS status 0x\(String(identity.statusFlags, radix: 16), privacy: .public)")
                return false
            }
            var req: SecRequirement?
            guard SecRequirementCreateWithString(requirement as CFString, [], &req) == errSecSuccess, let req else {
                securityLog.error("invalid requirement string: \(requirement, privacy: .public)")
                return false
            }
            guard SecCodeCheckValidity(code, [], req) == errSecSuccess else {
                securityLog.error("rejecting \(identity.identifier ?? "?", privacy: .public) cdhash \(identity.cdhashHex ?? "?", privacy: .public) (pid \(pid, privacy: .public)): requirement not met")
                return false
            }
            securityLog.info("accepted \(identity.identifier ?? "?", privacy: .public) cdhash \(identity.cdhashHex ?? "?", privacy: .public) (pid \(pid, privacy: .public))")
        } else {
            securityLog.notice("no audit token for pid \(pid, privacy: .public): relying on the per-message requirement only")
        }
        connection.setCodeSigningRequirement(requirement)   // re-checked by XPC for every message
        return true
    }

    static func auditToken(of connection: NSXPCConnection) -> audit_token_t? {
        // `value(forKey:)` raises for an unknown key; check first.
        guard connection.responds(to: NSSelectorFromString("auditToken")),
              let value = connection.value(forKey: "auditToken") as? NSValue else { return nil }
        var token = audit_token_t()
        withUnsafeMutableBytes(of: &token) { buf in
            guard let base = buf.baseAddress else { return }
            value.getValue(base, size: buf.count)
        }
        return token
    }

    /// The trust file must be a regular, root-owned file that is not group- or other-writable, inside a root-owned
    /// directory with the same properties (`lstat`: a symlink is rejected). Returns [] when anything is off.
    public static func readTrustFile(_ path: String) -> [String] {
        func safe(_ p: String, directory: Bool) -> Bool {
            var st = stat()
            guard lstat(p, &st) == 0 else { return false }
            guard st.st_mode & S_IFMT == (directory ? S_IFDIR : S_IFREG), st.st_uid == 0 else { return false }
            return st.st_mode & (S_IWGRP | S_IWOTH) == 0
        }
        guard safe((path as NSString).deletingLastPathComponent, directory: true), safe(path, directory: false),
              let data = FileManager.default.contents(atPath: path), data.count <= 64 * 1024,
              let hashes = LegacyHelperInstaller.parseTrustFile(data) else { return [] }
        return hashes
    }
}
