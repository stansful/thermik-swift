// HelperProtocol.swift — Thermik (MIT). Shared by Thermik.app and the privileged helper.
// The ENTIRE privileged surface. Deliberately tiny and typed: no paths, no shell commands,
// no raw SMC key reads/writes (the app reads the SMC itself, unprivileged). Rich results travel as
// binary-plist `Data` of Codable structs, so the NSXPC interface needs no NSSecureCoding allow-lists.
// Merge of research/helper/skeleton/Shared/HelperProtocol.swift and research/fans/code/Shared/FanXPCProtocol.swift.
import Foundation

public enum ThermikHelper {
    // PLACEHOLDER identifiers (decision D3): replace `app.thermik` with a reverse-DNS prefix the project
    // controls BEFORE the first public release. Changing them later orphans BTM records and legacy installs.
    /// launchd Label == Mach service name == helper code-signing identifier.
    public static let label = "app.thermik.helper"
    public static let machServiceName = label
    public static let helperSigningIdentifier = label
    public static let appBundleIdentifier = "app.thermik.Thermik"
    /// Every client identifier the helper accepts (the app now; a CLI later).
    public static let allowedClientIdentifiers = [appBundleIdentifier]
    /// Plist inside Thermik.app/Contents/Library/LaunchDaemons (SMAppService mode). Keep it BYTE-IDENTICAL
    /// across releases: BTM keys its record on the plist's SHA-256 (HELP §6).
    public static let plistName = "\(label).plist"
    /// Executable inside Thermik.app/Contents/MacOS (SMAppService mode).
    public static let helperExecutableName = "thermik-helper"
    /// Bump on ANY incompatible change of ThermikHelperXPC or of the wire structs below.
    public static let protocolVersion = 1
    public static let errorDomain = "app.thermik.helper"

    /// Legacy install (ad-hoc builds without a Team ID, HELP §4).
    public enum Legacy {
        public static let helperPath = "/Library/PrivilegedHelperTools/\(label)"
        public static let plistPath = "/Library/LaunchDaemons/\(label).plist"
        public static let supportDirectory = "/Library/Application Support/Thermik"
        /// root:wheel 0644, written only by the admin-authorized installer: cdhashes of trusted app builds.
        public static let trustFilePath = "\(supportDirectory)/trusted-clients.plist"
    }

    /// Per-boot crash-recovery marker (/var/run is emptied at boot). Present (JSON RecoveryMarker) while the
    /// helper holds any fan in manual mode. Written BEFORE the first manual write, removed after full restore.
    public static let manualMarkerPath = "/var/run/\(label).manual"

    /// Limits enforced by the helper regardless of what the client asks.
    public enum Limits {
        public static let minLeaseSeconds: Double = 5
        public static let defaultLeaseSeconds: Double = 10
        public static let maxLeaseSeconds: Double = 30
        /// The app renews the lease at least this often while any fan is manual.
        public static let heartbeatSeconds: Double = 2
        public static let clientGoneGraceSeconds: Double = 3
        public static let maxCommandsPerSecond = 20
        public static let maxMessageBytes = 64 * 1024
        public static let idleExitSeconds: Double = 120
        /// Client-side XPC reply timeout. The FIRST manual command on M3/M4 can block ~3–6 s (Ftst unlock).
        public static let replyTimeoutSeconds: Double = 15
    }

    /// Helper-side last-resort thermal override (FANS §8.3 I8). Deliberately ABOVE the app engine's (100/105 °C).
    public enum Safety {
        public static let overrideTop4MeanC: Double = 103
        public static let overrideHottestC: Double = 108
        public static let releaseTop4MeanC: Double = 95
        public static let sensorFailureTicks = 3
        public static let staticKeySeconds: Double = 30
        /// Fan stop (0 rpm) is refused while the hottest die sensor is at or above this…
        public static let stopRefusedHottestC: Double = 90
        /// …and a stopped fan is restarted at its minimum when it reaches this (the app restarts it much earlier,
        /// at the first point of its curve; this only covers an app that stopped deciding).
        public static let stopRestartHottestC: Double = 95
    }
}

/// Wire error codes (NSError.code in `ThermikHelper.errorDomain`). Merged HELP + FANS codes.
public enum HelperErrorCode: Int, Sendable, CaseIterable {
    case invalidArgument = 1        // NaN / negative / bad lease
    case fanNotFound = 2
    case hardwareFailure = 3        // IOKit / SMC error (detail in message)
    case unsupportedProtocol = 4    // hello(clientProtocolVersion:) mismatch → app upgrades the helper
    case internalError = 5
    case rateLimited = 6
    case notPermitted = 7           // peer/policy refused, or not available in this install mode
    case notControllable = 8        // fanless Mac or unknown scheme
    case foreignController = 9      // another app forces the fans and we hold no marker → refuse (I10)
    case unlockTimeout = 10         // Ftst unlock not accepted within the deadline (thermalmonitord refused)
    case verificationFailed = 11    // write accepted but read-back disagrees
    case safetyOverride = 12        // thermal override active: fans held at max, request ignored
    case sleeping = 13              // system is going to / coming back from sleep
}

public extension NSError {
    static func thermikHelper(_ code: HelperErrorCode, _ message: String) -> NSError {
        NSError(domain: ThermikHelper.errorDomain, code: code.rawValue, userInfo: [NSLocalizedDescriptionKey: message])
    }
    var thermikHelperCode: HelperErrorCode? {
        domain == ThermikHelper.errorDomain ? HelperErrorCode(rawValue: code) : nil
    }
}

public enum HelperInstallKind: String, Codable, Sendable {
    case appService      // SMAppService.daemon, executable inside Thermik.app
    case legacy          // /Library/PrivilegedHelperTools + /Library/LaunchDaemons (ad-hoc builds)
    case development     // started by hand from a build directory (only with --mock)
}

/// hello() reply.
public struct HelperInfo: Codable, Sendable, Equatable {
    public var protocolVersion: Int
    public var helperVersion: String        // CFBundleShortVersionString (embedded __info_plist)
    public var helperBuild: String          // CFBundleVersion = HELPER_BUILD_VERSION → drives upgrade decisions
    public var pid: Int32
    public var installKind: HelperInstallKind
    public var fanCount: Int
    public var scheme: String               // FanControlScheme.description, e.g. "appleSilicon(modeKey: F%dMd, Ftst: true)"
    public init(protocolVersion: Int, helperVersion: String, helperBuild: String, pid: Int32,
                installKind: HelperInstallKind, fanCount: Int, scheme: String) {
        self.protocolVersion = protocolVersion; self.helperVersion = helperVersion; self.helperBuild = helperBuild
        self.pid = pid; self.installKind = installKind; self.fanCount = fanCount; self.scheme = scheme
    }
}

/// One fan as the helper sees it.
public struct HelperFanState: Codable, Sendable, Equatable {
    public var index: Int
    public var minRPM: Double
    public var maxRPM: Double
    public var actualRPM: Double
    public var targetRPM: Double             // live F%dTg
    public var modeRaw: Int?                 // live mode key value (0 auto, 1 manual, 3 system) — nil on Intel force-bit Macs
    public var ownedByThermik: Bool
    public var appliedRPM: Double?           // last clamped target the helper wrote
    public init(index: Int, minRPM: Double, maxRPM: Double, actualRPM: Double, targetRPM: Double,
                modeRaw: Int?, ownedByThermik: Bool, appliedRPM: Double?) {
        self.index = index; self.minRPM = minRPM; self.maxRPM = maxRPM; self.actualRPM = actualRPM
        self.targetRPM = targetRPM; self.modeRaw = modeRaw; self.ownedByThermik = ownedByThermik; self.appliedRPM = appliedRPM
    }
}

/// getState() reply.
public struct HelperState: Codable, Sendable, Equatable {
    public var info: HelperInfo
    public var fans: [HelperFanState]
    public var ftst: Int?                    // live Ftst (nil if the key is absent)
    public var ftstSetByThermik: Bool
    public var isControlling: Bool
    public var leaseRemainingSeconds: Double?
    public var safetyOverrideActive: Bool
    public var foreignControllerSuspected: Bool
    public var sleeping: Bool
    /// "leaseExpired", "clientGone", "sleep", "signal 15", "startupRecovery", "sensorFailure", "overTemperature", "resetAll", …
    public var lastRevertReason: String?
    public var lastRevertDate: Date?
    public init(info: HelperInfo, fans: [HelperFanState], ftst: Int?, ftstSetByThermik: Bool, isControlling: Bool,
                leaseRemainingSeconds: Double?, safetyOverrideActive: Bool, foreignControllerSuspected: Bool,
                sleeping: Bool, lastRevertReason: String?, lastRevertDate: Date?) {
        self.info = info; self.fans = fans; self.ftst = ftst; self.ftstSetByThermik = ftstSetByThermik
        self.isControlling = isControlling; self.leaseRemainingSeconds = leaseRemainingSeconds
        self.safetyOverrideActive = safetyOverrideActive; self.foreignControllerSuspected = foreignControllerSuspected
        self.sleeping = sleeping; self.lastRevertReason = lastRevertReason; self.lastRevertDate = lastRevertDate
    }
}

/// Crash-recovery marker content (I7), JSON at ThermikHelper.manualMarkerPath.
public struct RecoveryMarker: Codable, Sendable, Equatable {
    public var pid: Int32
    public var ftstSetByUs: Bool
    public var fans: [Int]
    public var createdAt: Date
    /// intelMinimumOnly only: the ORIGINAL raw F%dMn bytes per fan index, written before the minimum is raised, so a
    /// relaunched helper can write them back (raising F%dMn is the only "manual mode" there). nil everywhere else;
    /// absent in markers of older helpers (decoded as nil).
    public var savedMinimumBytes: [Int: [UInt8]]?
    public init(pid: Int32, ftstSetByUs: Bool, fans: [Int], createdAt: Date) {
        self.pid = pid; self.ftstSetByUs = ftstSetByUs; self.fans = fans; self.createdAt = createdAt
    }
}

/// XPC protocol (helper exports it, app calls it). Exactly one of reply / proxy error handler fires per call.
@objc public protocol ThermikHelperXPC {
    /// Version handshake. Error `unsupportedProtocol` if versions differ → the app upgrades the helper.
    func hello(clientProtocolVersion: Int, reply: @escaping @Sendable (Data?, NSError?) -> Void)        // HelperInfo
    func getState(reply: @escaping @Sendable (Data?, NSError?) -> Void)                                  // HelperState
    /// Manual mode for one fan at `rpm` (helper clamps to the SMC's own [Mn, Mx]; exactly 0 stops the fan on Apple
    /// Silicon unless the dies are hot, see `Safety.stopRefusedHottestC`). Runs the Ftst unlock on M3/M4
    /// (may block several seconds). Renews the lease (clamped to Limits). Replies with the rpm actually written.
    func setFanTarget(fanIndex: Int, rpm: Double, leaseSeconds: Double,
                      reply: @escaping @Sendable (Double, NSError?) -> Void)
    /// One fan back to System. Releasing the last Thermik-owned fan also clears Ftst if Thermik set it.
    func setFanAutomatic(fanIndex: Int, reply: @escaping @Sendable (NSError?) -> Void)
    /// Extends the lease. Replies `false` when nothing is controlled any more (helper reverted: sleep, lease,
    /// safety, macOS reclaimed a fan) → the app must re-send its targets.
    func renewLease(leaseSeconds: Double, reply: @escaping @Sendable (Bool, NSError?) -> Void)
    /// Every fan back to System, Ftst cleared if we set it. Idempotent, never refused.
    func resetAllFans(reply: @escaping @Sendable (NSError?) -> Void)
    /// Legacy mode only: reset fans, delete own plist/binary/trust file, boot out. `notPermitted` otherwise.
    func uninstallLegacyHelper(reply: @escaping @Sendable (NSError?) -> Void)
}

public enum HelperWire {
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let enc = PropertyListEncoder()
        enc.outputFormat = .binary
        return try enc.encode(value)
    }
    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        guard data.count <= ThermikHelper.Limits.maxMessageBytes else {
            throw NSError.thermikHelper(.invalidArgument, "message too large")
        }
        return try PropertyListDecoder().decode(type, from: data)
    }
    public static func makeInterface() -> NSXPCInterface { NSXPCInterface(with: ThermikHelperXPC.self) }
}

/// App-side async facade over the XPC connection. Implemented by `HelperConnection` (Unit 4) and by
/// `MockFanHelperClient` (demo mode). Every method may throw NSError in `ThermikHelper.errorDomain`
/// or NSCocoaErrorDomain 4097/4099/4102 (connection interrupted / invalid / code-signing requirement failed).
public protocol FanHelperClient: AnyObject, Sendable {
    func hello() async throws -> HelperInfo
    func state() async throws -> HelperState
    func setFanTarget(_ index: Int, rpm: Double, leaseSeconds: Double) async throws -> Double
    func setFanAutomatic(_ index: Int) async throws
    func renewLease(seconds: Double) async throws -> Bool
    func resetAllFans() async throws
    func uninstallLegacyHelper() async throws
    /// Bounded synchronous reset for applicationWillTerminate (never throws).
    func resetAllFansBlocking(timeout: TimeInterval)
}
