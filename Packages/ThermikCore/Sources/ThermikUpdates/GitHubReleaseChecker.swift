import Foundation

/// Stores the release representation, not the answer for one installed version. A 304 is always re-evaluated.
public actor ReleaseCache {
    private var entry: CachedRelease?

    public init() {}

    fileprivate func load(repository: String) -> CachedRelease? {
        entry?.repository == repository ? entry : nil
    }

    fileprivate func save(_ entry: CachedRelease?) { self.entry = entry }
}

fileprivate struct GitHubRelease: Decodable, Sendable {
    let tagName: String
    let draft: Bool
    let prerelease: Bool

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name", draft, prerelease
    }
}

fileprivate struct CachedRelease: Sendable {
    let repository: String
    let entityTag: String
    let release: GitHubRelease
}

/// Only checks for an available release. Downloading the app is a browser action owned by the application.
public actor GitHubReleaseChecker: ReleaseChecking {
    private let configuration: ReleaseConfiguration
    private let transport: any ReleaseTransport
    private let cache: ReleaseCache
    private var inFlight: Task<UpdateCheckResult, Error>?

    public init(configuration: ReleaseConfiguration,
                transport: any ReleaseTransport = URLSessionReleaseTransport(),
                cache: ReleaseCache = ReleaseCache()) {
        self.configuration = configuration
        self.transport = transport
        self.cache = cache
    }

    public func check() async throws -> UpdateCheckResult {
        if let inFlight { return try await result(of: inFlight) }
        let task = Task { try await fetch() }
        inFlight = task
        do {
            let result = try await result(of: task)
            inFlight = nil
            return result
        } catch {
            inFlight = nil
            throw error
        }
    }

    private func result(of task: Task<UpdateCheckResult, Error>) async throws -> UpdateCheckResult {
        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func fetch() async throws -> UpdateCheckResult {
        let cached = await cache.load(repository: configuration.repository)
        let response = try await request(path: "/repos/\(configuration.repository)/releases/latest", entityTag: cached?.entityTag)
        switch response.statusCode {
        case 200:
            let release: GitHubRelease
            do { release = try JSONDecoder().decode(GitHubRelease.self, from: response.data) }
            catch { throw UpdateCheckError.invalidResponse }
            let result = try evaluate(release)
            if let tag = response.entityTag, !tag.isEmpty, tag.utf8.count <= 1024,
               !tag.contains("\r"), !tag.contains("\n") {
                await cache.save(CachedRelease(repository: configuration.repository, entityTag: tag, release: release))
            } else {
                await cache.save(nil)
            }
            return result
        case 304:
            guard let cached else { throw UpdateCheckError.invalidResponse }
            return try evaluate(cached.release)
        case 404:
            // The latest endpoint also returns 404 for an existing repo with no stable release yet.
            let fallback = try await request(path: "/repos/\(configuration.repository)/releases", query: [URLQueryItem(name: "per_page", value: "1")])
            guard fallback.statusCode == 200 else { throw Self.failure(status: fallback.statusCode) }
            let releases: [GitHubRelease]
            do { releases = try JSONDecoder().decode([GitHubRelease].self, from: fallback.data) }
            catch { throw UpdateCheckError.invalidResponse }
            await cache.save(nil)
            // GitHub can briefly serve a published release in the list before /latest catches up.
            for release in releases {
                let result = try evaluate(release)
                if case .available = result { return result }
            }
            return .upToDate
        default:
            throw Self.failure(status: response.statusCode)
        }
    }

    private func evaluate(_ release: GitHubRelease) throws -> UpdateCheckResult {
        guard !release.draft, !release.prerelease else { return .upToDate }
        guard let version = SemanticVersion(release.tagName) else { throw UpdateCheckError.invalidResponse }
        guard !version.isPrerelease, configuration.parsedVersion < version else { return .upToDate }
        var page = URLComponents()
        page.scheme = "https"
        page.host = "github.com"
        page.path = "/\(configuration.repository)/releases/tag/\(release.tagName)"
        guard let url = page.url else { throw UpdateCheckError.invalidResponse }
        return .available(AvailableUpdate(version: version.display, url: url))
    }

    private func request(path: String, entityTag: String? = nil,
                         query: [URLQueryItem] = []) async throws -> ReleaseResponse {
        var endpoint = URLComponents()
        endpoint.scheme = "https"
        endpoint.host = "api.github.com"
        endpoint.path = path
        if !query.isEmpty { endpoint.queryItems = query }
        guard let url = endpoint.url else { throw UpdateCheckError.invalidConfiguration }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.httpShouldHandleCookies = false
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Thermik", forHTTPHeaderField: "User-Agent")
        request.setValue("en", forHTTPHeaderField: "Accept-Language")
        if let entityTag { request.setValue(entityTag, forHTTPHeaderField: "If-None-Match") }
        do {
            try Task.checkCancellation()
            let response = try await transport.fetch(request)
            try Task.checkCancellation()
            guard response.data.count <= ReleaseLimits.maximumResponseBytes else { throw UpdateCheckError.responseTooLarge }
            return response
        } catch let failure as UpdateCheckError { throw failure }
        catch is CancellationError { throw CancellationError() }
        catch let error as URLError where error.code == .cancelled { throw CancellationError() }
        catch { throw UpdateCheckError.offline }
    }

    private static func failure(status: Int) -> UpdateCheckError {
        switch status {
        case 403, 429: .rateLimited
        case 404: .repositoryNotFound
        default: .server(status)
        }
    }
}
