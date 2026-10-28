// LegacyHelperInstaller.swift — Thermik (MIT). App side. OWNER: Unit 4.
// Port of research/helper/skeleton/App/LegacyHelperInstaller.swift (HELP §4, §A.11). Public API FROZEN (SPEC A.2);
// additions: Plan.init, Plan.helperIcon, launchdPlist(), trustFile(_:), trustedClientCDHashes(at:),
// installedHelperBuild(), iconResourceFork(_:), `KnownFanControlHelpers` (bottom of the file).
//
// Install path for builds WITHOUT a Team ID (ad-hoc / "Sign to Run Locally"), where SMAppService has no stable
// identity to pin (HELP §2.4). One administrator prompt (`do shell script … with administrator privileges`) runs a
// generated /bin/sh script as root that:
//   1. boots out a previous instance (it restores the fans on SIGTERM),
//   2. copies the bundled helper into a temp file INSIDE root-owned /Library/PrivilegedHelperTools, chowns it, and
//      verifies that root-owned copy with `codesign --verify --strict -R` against the bundled helper's own cdhash
//      (or Team requirement), so nothing can be swapped after verification; then gives the verified copy Thermik's
//      file icon (cosmetic, see "Helper icon"),
//   3. writes the launchd plist (`Program` = the root-owned copy, never a path inside the user-writable app bundle)
//      and the root-owned trust file that pins this app build's cdhash(es) — the helper's only trust anchor (§2.6.4),
//   4. `launchctl bootstrap system` (retried while a previous instance is still being torn down).
// The script travels base64-encoded inside the AppleScript string: no temp file a same-user process could swap,
// no quoting pitfalls (base64 is [A-Za-z0-9+/=]).
import Foundation

public enum LegacyHelperInstaller {
    public struct Plan: Sendable {
        /// Helper executable inside the app bundle (the copy source).
        public var helperSource: String
        /// Requirement the COPIED helper must satisfy before it is activated (`codesign -R`).
        public var helperRequirement: String
        /// cdhashes (40 hex digits) of the app executable the helper will trust, one per architecture slice.
        public var clientCDHashes: [String]
        /// Resource fork with the app's icon for the root-owned copy (`iconResourceFork`); nil → no icon.
        public var helperIcon: Data?

        public init(helperSource: String, helperRequirement: String, clientCDHashes: [String], helperIcon: Data? = nil) {
            self.helperSource = helperSource; self.helperRequirement = helperRequirement; self.clientCDHashes = clientCDHashes
            self.helperIcon = helperIcon
        }
    }

    /// Technical (English) descriptions; the app maps the cases to localized text (Core holds no UI strings, §4.12).
    public enum InstallError: Error, LocalizedError {
        case missingHelper(String), unsignedApp, cancelled, failed(Int, String)
        public var errorDescription: String? {
            switch self {
            case .missingHelper(let path): "helper executable not found at \(path)"
            case .unsignedApp: "cannot read the code signature of the app or its helper"
            case .cancelled: "cancelled by the user"
            case let .failed(code, message): "installer failed (\(code)): \(message)"
            }
        }
    }

    /// AppleScript error number when the user presses Cancel in the administrator dialog (userCanceledErr).
    static let userCancelledError = -128

    // MARK: Plan

    /// Reads the signatures of `appBundle` and its embedded helper. Throws `missingHelper` when the bundle has no
    /// executable helper, `unsignedApp` when a signature cannot be read, `failed` for unexpected identifiers.
    public static func makePlan(appBundle: URL = Bundle.main.bundleURL) throws -> Plan {
        let helper = appBundle.appending(path: "Contents/MacOS/\(ThermikHelper.helperExecutableName)")
        guard FileManager.default.isExecutableFile(atPath: helper.path) else { throw InstallError.missingHelper(helper.path) }
        guard let appExecutable = Bundle(url: appBundle)?.executableURL else { throw InstallError.unsignedApp }

        let clientHashes = CodeIdentity.cdhashes(ofCodeAt: appExecutable)
        guard !clientHashes.isEmpty, clientHashes.allSatisfy(CodeIdentity.isValidCDHash) else { throw InstallError.unsignedApp }
        guard let helperIdentity = CodeIdentity.ofCode(at: helper) else { throw InstallError.unsignedApp }
        guard helperIdentity.identifier == ThermikHelper.helperSigningIdentifier else {
            throw InstallError.failed(-2, "helper is signed as \(helperIdentity.identifier ?? "nil"), expected \(ThermikHelper.helperSigningIdentifier)")
        }

        let identifierClause = "identifier \"\(ThermikHelper.helperSigningIdentifier)\""
        let requirement: String
        if let team = helperIdentity.teamID, !team.isEmpty {
            requirement = "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\" and \(identifierClause)"
        } else {
            // Ad-hoc: pin the exact bundled helper (every slice) — an identifier alone is spoofable (HELP §1).
            let hashes = CodeIdentity.cdhashes(ofCodeAt: helper)
            guard !hashes.isEmpty, hashes.allSatisfy(CodeIdentity.isValidCDHash) else { throw InstallError.unsignedApp }
            requirement = "(" + hashes.map { "cdhash H\"\($0)\"" }.joined(separator: " or ") + ") and \(identifierClause)"
        }
        return Plan(helperSource: helper.path, helperRequirement: requirement, clientCDHashes: clientHashes,
                    helperIcon: appIcon(in: appBundle).map(iconResourceFork))
    }

    // MARK: Helper icon

    // Without a Team ID, Background Task Management cannot attribute the daemon to Thermik.app (it drops
    // AssociatedBundleIdentifiers), so System Settings › Login Items shows the root-owned executable with its Finder
    // icon: a blank document. A custom file icon (resource fork + FinderInfo flag) puts Thermik's icon there.
    // `codesign --verify --strict` rejects a resource fork ("detritus"), so the script adds it only AFTER verifying the
    // copy; launchd, AMFI and SecCode validation (the app's XPC requirement check) ignore it (verified on macOS 27).

    /// Keeps the AppleScript command line (the script, base64 twice) far below ARG_MAX.
    static let maxIconBytes = 256 * 1024

    /// The app's .icns (CFBundleIconFile), read here as the user: the root script only writes the bytes it carries.
    static func appIcon(in appBundle: URL) -> Data? {
        guard let bundle = Bundle(url: appBundle),
              let name = bundle.object(forInfoDictionaryKey: "CFBundleIconFile") as? String,
              let url = bundle.url(forResource: (name as NSString).deletingPathExtension, withExtension: "icns"),
              let icns = try? Data(contentsOf: url), icns.count <= maxIconBytes, icns.starts(with: Array("icns".utf8))
        else { return nil }
        return icns
    }

    /// Resource fork holding `icns` as the custom-icon resource ('icns', ID -16455 = kCustomIconResource): header,
    /// data (length-prefixed), map with one type and one unnamed reference. scripts/lib/install-helper.sh writes
    /// the same.
    public static func iconResourceFork(_ icns: Data) -> Data {
        func be(_ value: Int, _ bytes: Int) -> [UInt8] {
            (0..<bytes).reversed().map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }
        }
        let dataLength = 4 + icns.count, mapLength = 50
        let header = be(256, 4) + be(256 + dataLength, 4) + be(dataLength, 4) + be(mapLength, 4)
        let map = header + be(0, 4) + be(0, 2) + be(0, 2) + be(28, 2) + be(mapLength, 2)  // handle, file, attrs, list offsets
            + be(0, 2) + Array("icns".utf8) + be(0, 2) + be(10, 2)                        // one type, one resource
            + be(-16455, 2) + be(0xFFFF, 2) + be(0, 4) + be(0, 4)                         // ID, no name, data offset 0, handle
        return Data(header + [UInt8](repeating: 0, count: 240) + be(icns.count, 4)) + icns + Data(map)
    }

    /// FinderInfo (32 bytes, hex) with only kHasCustomIcon (0x0400) set in the Finder flags.
    static let customIconFinderInfo = String(repeating: "0", count: 16) + "0400" + String(repeating: "0", count: 44)

    // MARK: Generated files

    /// LaunchDaemon plist of the legacy install. Same keys as Resources/LaunchDaemons/app.thermik.helper.plist,
    /// except `Program` (absolute, root-owned path) instead of the SMAppService-only `BundleProgram`.
    public static func launchdPlist() throws -> Data {
        let plist: [String: Any] = [
            "Label": ThermikHelper.label,
            "Program": ThermikHelper.Legacy.helperPath,
            "ProgramArguments": [ThermikHelper.Legacy.helperPath],
            "MachServices": [ThermikHelper.machServiceName: true],
            // Only honoured when the helper's Team ID matches the app's; harmless otherwise (HELP §2.2).
            "AssociatedBundleIdentifiers": [ThermikHelper.appBundleIdentifier],
            // Relaunch after a crash (recovery marker, I7), not after a clean idle exit (I13).
            // Implies RunAtLoad: the helper runs once per boot and recovers stranded manual state.
            "KeepAlive": ["SuccessfulExit": false],
            "ProcessType": "Adaptive",
        ]
        return try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    }

    /// Trust file content: `{cdhashes: [<40 hex digits>, …]}` (XML plist).
    public static func trustFile(_ hashes: [String]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: ["cdhashes": hashes], format: .xml, options: 0)
    }

    /// Parses trust-file data. Returns the valid lower-cased cdhashes, or nil when the data is not a trust file.
    public static func parseTrustFile(_ data: Data) -> [String]? {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let list = plist["cdhashes"] as? [String] else { return nil }
        return list.map { $0.lowercased() }.filter(CodeIdentity.isValidCDHash)
    }

    /// App side, read-only (the file is root:wheel 0644): cdhashes the installed helper trusts, nil if no trust file.
    /// The HELPER does not use this: it also checks owner and mode (`PeerValidator.readTrustFile`).
    public static func trustedClientCDHashes(at path: String = ThermikHelper.Legacy.trustFilePath) -> [String]? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return parseTrustFile(data)
    }

    /// CFBundleVersion (HELPER_BUILD_VERSION) of the installed legacy helper, read from its embedded __info_plist.
    public static func installedHelperBuild(at path: String = ThermikHelper.Legacy.helperPath) -> String? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let info = CFBundleCopyInfoDictionaryForURL(URL(fileURLWithPath: path) as CFURL) as? [String: Any]
        return info?["CFBundleVersion"] as? String
    }

    /// POSIX single-quoting for /bin/sh.
    static func sq(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    /// The root script for `plan`. Pure string generation (never executed here); throws `failed` for a malformed plan.
    public static func installScript(_ plan: Plan) throws -> String {
        guard !plan.clientCDHashes.isEmpty, plan.clientCDHashes.allSatisfy(CodeIdentity.isValidCDHash) else {
            throw InstallError.failed(-3, "plan has no valid client cdhash")
        }
        guard plan.helperSource.hasPrefix("/"), !plan.helperRequirement.isEmpty else {
            throw InstallError.failed(-3, "plan has no helper source or requirement")
        }
        let L = ThermikHelper.Legacy.self
        let plist = try launchdPlist().base64EncodedString()
        let trust = try trustFile(plan.clientCDHashes.map { $0.lowercased() }).base64EncodedString()
        // Never fatal: a helper without an icon works the same. ":" keeps the line when there is no icon.
        let icon = plan.helperIcon.map {
            "/bin/echo \($0.base64EncodedString()) | /usr/bin/base64 -D > \"$T/..namedfork/rsrc\""
                + " && /usr/bin/xattr -wx com.apple.FinderInfo \(customIconFinderInfo) \"$T\" || true"
        } ?? ":"
        return """
        set -eu
        umask 022
        PATH=/usr/bin:/bin:/usr/sbin:/sbin
        export PATH
        [ "$(/usr/bin/id -u)" -eq 0 ] || { echo "must run as root" >&2; exit 1; }
        LABEL=\(sq(ThermikHelper.label))
        SRC=\(sq(plan.helperSource))
        DST=\(sq(L.helperPath))
        PLIST=\(sq(L.plistPath))
        SUPPORT=\(sq(L.supportDirectory))
        TRUST=\(sq(L.trustFilePath))
        [ -f "$SRC" ] || { echo "helper not found: $SRC" >&2; exit 2; }
        /bin/launchctl bootout "system/$LABEL" 2>/dev/null || true
        /usr/bin/install -d -m 0755 -o root -g wheel /Library/PrivilegedHelperTools "$SUPPORT"
        T="$(/usr/bin/mktemp /Library/PrivilegedHelperTools/.thermik-helper.XXXXXX)"
        trap '/bin/rm -f "$T" "$SUPPORT/.plist.new" "$SUPPORT/.trust.new"' EXIT
        /bin/cp -X "$SRC" "$T"
        /usr/sbin/chown root:wheel "$T"
        /bin/chmod 0755 "$T"
        /usr/bin/codesign --verify --strict -R \(sq("=" + plan.helperRequirement)) "$T"
        \(icon)
        /bin/mv -f "$T" "$DST"
        /bin/echo \(plist) | /usr/bin/base64 -D > "$SUPPORT/.plist.new"
        /bin/echo \(trust) | /usr/bin/base64 -D > "$SUPPORT/.trust.new"
        /usr/sbin/chown root:wheel "$SUPPORT/.plist.new" "$SUPPORT/.trust.new"
        /bin/chmod 0644 "$SUPPORT/.plist.new" "$SUPPORT/.trust.new"
        /bin/mv -f "$SUPPORT/.trust.new" "$TRUST"
        /bin/mv -f "$SUPPORT/.plist.new" "$PLIST"
        /bin/launchctl enable "system/$LABEL" 2>/dev/null || true
        n=0
        until /bin/launchctl bootstrap system "$PLIST"; do
            n=$((n + 1))
            [ "$n" -lt 5 ] || { echo "launchctl bootstrap failed" >&2; exit 3; }
            /bin/sleep 1
        done
        """
    }

    /// Root script that removes the legacy install. bootout SIGTERMs the helper, which restores the fans (I5).
    public static func uninstallScript() -> String {
        let L = ThermikHelper.Legacy.self
        return """
        set -u
        PATH=/usr/bin:/bin:/usr/sbin:/sbin
        export PATH
        /bin/launchctl bootout \(sq("system/" + ThermikHelper.label)) 2>/dev/null || true
        /bin/rm -f \(sq(L.plistPath)) \(sq(L.helperPath)) \(sq(ThermikHelper.manualMarkerPath))
        /bin/rm -rf \(sq(L.supportDirectory))
        """
    }

    // MARK: Privileged execution

    /// Shows the standard administrator dialog ("Thermik wants to make changes. <prompt>") and runs `script` as root.
    /// Blocks the main thread while the dialog is up (NSAppleScript is main-thread-only); the caller activates the
    /// app first (LSUIElement). Throws `cancelled` (-128) or `failed(code, message)`.
    @MainActor
    public static func runAsAdministrator(_ script: String, prompt: String) throws {
        let b64 = Data(script.utf8).base64EncodedString()
        let escapedPrompt = prompt.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let source = "do shell script \"/bin/echo \(b64) | /usr/bin/base64 -D | /bin/sh\" with prompt \"\(escapedPrompt)\" with administrator privileges"
        guard let apple = NSAppleScript(source: source) else { throw InstallError.failed(-1, "cannot build the AppleScript") }
        var error: NSDictionary?
        apple.executeAndReturnError(&error)
        if let error {
            let code = error[NSAppleScript.errorNumber] as? Int ?? -1
            if code == userCancelledError { throw InstallError.cancelled }
            throw InstallError.failed(code, error[NSAppleScript.errorMessage] as? String ?? "unknown error")
        }
    }

    /// Installs (or re-installs / upgrades) the helper bundled in the running app.
    @MainActor
    public static func install(prompt: String) throws {
        try runAsAdministrator(try installScript(try makePlan()), prompt: prompt)
    }

    /// Removes the legacy install (fallback when the helper cannot uninstall itself over XPC).
    @MainActor
    public static func uninstall(prompt: String) throws {
        try runAsAdministrator(uninstallScript(), prompt: prompt)
    }
}

/// Launch daemons of OTHER fan-control apps (SPEC §2.6.4 "Conflict detection"): plist PRESENCE only — no file is
/// opened or read. Used to name a foreign controller in the UI; the decision itself is SMC fan state (I10, §2.9.4).
/// Battery-charge limiters (e.g. AlDente) also run root SMC helpers but never force the fans: deliberately NOT listed.
public enum KnownFanControlHelpers {
    /// (launchd label, product). Public identifiers: TG Pro's (observed on the dev Mac, file name only), Stats' SMC
    /// helper (exelban/Stats, MIT), Macs Fan Control's SMC write helper (its documented uninstall path).
    public static let all: [(label: String, product: String)] = [
        ("com.tunabellysoftware.TGFanHelper", "TG Pro"),
        ("eu.exelban.Stats.SMC.Helper", "Stats"),
        ("com.crystalidea.macsfancontrol.smcwrite", "Macs Fan Control"),
    ]

    /// Products whose daemon plist exists in `directory`, in table order, without duplicates.
    public static func installed(in directory: String = "/Library/LaunchDaemons") -> [String] {
        var result: [String] = []
        for entry in all where FileManager.default.fileExists(atPath: "\(directory)/\(entry.label).plist") {
            if !result.contains(entry.product) { result.append(entry.product) }
        }
        return result
    }
}
