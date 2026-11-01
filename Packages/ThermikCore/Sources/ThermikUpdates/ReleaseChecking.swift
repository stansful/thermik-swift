// ThermikUpdates — GitHub release checks, independent of AppKit and fan control.
import Foundation

public struct AvailableUpdate: Equatable, Sendable {
    public let version: String
    public let url: URL

    public init(version: String, url: URL) {
        self.version = version
        self.url = url
    }
}

public enum UpdateCheckResult: Equatable, Sendable {
    case upToDate
    case available(AvailableUpdate)
}

public protocol ReleaseChecking: Sendable {
    func check() async throws -> UpdateCheckResult
}

/// Expected failures; the application supplies the localized presentation.
public enum UpdateCheckError: Error, Equatable, Sendable {
    case invalidConfiguration
    case invalidResponse
    case offline
    case rateLimited
    case repositoryNotFound
    case server(Int)
    case responseTooLarge
}

public struct ReleaseConfiguration: Equatable, Sendable {
    public let repository: String
    public let currentVersion: String
    let parsedVersion: SemanticVersion

    public init(repository: String, currentVersion: String) throws {
        let parts = repository.split(separator: "/", omittingEmptySubsequences: false)
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.".utf8)
        guard repository.utf8.count <= 256, parts.count == 2,
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.utf8.allSatisfy(allowed.contains) }),
              let version = SemanticVersion(currentVersion) else {
            throw UpdateCheckError.invalidConfiguration
        }
        self.repository = repository
        self.currentVersion = currentVersion
        parsedVersion = version
    }
}
