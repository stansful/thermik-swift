// LegacyHelperInstaller.swift — Thermik (MIT). UNIT 0 STUB; OWNER: Unit 4
// (port research/helper/skeleton/App/LegacyHelperInstaller.swift). Public API FROZEN.
import Foundation

public enum LegacyHelperInstaller {
    public struct Plan: Sendable {
        public var helperSource: String
        public var helperRequirement: String
        public var clientCDHashes: [String]
    }
    public enum InstallError: Error, LocalizedError {
        case missingHelper(String), unsignedApp, cancelled, failed(Int, String)
        public var errorDescription: String? { "\(self)" }
    }
    public static func makePlan(appBundle: URL = Bundle.main.bundleURL) throws -> Plan { throw InstallError.unsignedApp }
    public static func installScript(_ plan: Plan) throws -> String { "" }
    public static func uninstallScript() -> String { "" }
    @MainActor public static func install(prompt: String) throws { throw InstallError.unsignedApp }
    @MainActor public static func uninstall(prompt: String) throws { throw InstallError.unsignedApp }
}
