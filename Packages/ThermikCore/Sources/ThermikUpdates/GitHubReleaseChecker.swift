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
        return try await finish(task)
    }

    private func result(of task: Task<UpdateCheckResult, Error>) async throws -> UpdateCheckResult {
        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func finish(_ task: Task<UpdateCheckResult, Error>) async throws -> UpdateCheckResult {
        defer { inFlight = nil }
        return try await result(of: task)
    }

    private func fetch() async throws -> UpdateCheckResult {
        let cached = await cache.load(repository: configuration.repository)
        let response = try await request(path: "/repos/\(configuration.repository)/releases/latest", entityTag: cached?.entityTag)
        return try await handle(response, cached: cached)
    }

    private func handle(_ response: ReleaseResponse, cached: CachedRelease?) async throws -> UpdateCheckResult {
        switch response.statusCode {
        case 200:
            return try await handleLatest(response)
        case 304:
            return try handleNotModified(cached)
        case 404:
            return try await fetchFallback()
        default:
            throw Self.failure(status: response.statusCode)
        }
    }

    private func handleLatest(_ response: ReleaseResponse) async throws -> UpdateCheckResult {
        let release = try decode(GitHubRelease.self, from: response.data)
        let result = try evaluate(release)
        await cache.save(cachedRelease(for: response, release: release))
        return result
    }

    private func cachedRelease(for response: ReleaseResponse, release: GitHubRelease) -> CachedRelease? {
        guard let tag = response.entityTag, !tag.isEmpty, tag.utf8.count <= 1024,
              !tag.contains("\r"), !tag.contains("\n") else { return nil }
        return CachedRelease(repository: configuration.repository, entityTag: tag, release: release)
    }

    private func handleNotModified(_ cached: CachedRelease?) throws -> UpdateCheckResult {
        guard let cached else { throw UpdateCheckError.invalidResponse }
        return try evaluate(cached.release)
    }

    private func fetchFallback() async throws -> UpdateCheckResult {
        // The latest endpoint also returns 404 for an existing repo with no stable release yet.
        let fallback = try await request(path: "/repos/\(configuration.repository)/releases", query: [URLQueryItem(name: "per_page", value: "1")])
        guard fallback.statusCode == 200 else { throw Self.failure(status: fallback.statusCode) }
        let releases = try decode([GitHubRelease].self, from: fallback.data)
        await cache.save(nil)
        return try firstAvailableUpdate(in: releases)
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw UpdateCheckError.invalidResponse
        }
    }

    private func firstAvailableUpdate(in releases: [GitHubRelease]) throws -> UpdateCheckResult {
        // GitHub can briefly serve a published release in the list before /latest catches up.
        for release in releases {
            let result = try evaluate(release)
            if case .available = result { return result }
        }
        return .upToDate
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
        let request = try makeRequest(path: path, entityTag: entityTag, query: query)
        do {
            return try await validatedResponse(to: request)
        } catch {
            throw requestError(error)
        }
    }

    private func makeRequest(path: String, entityTag: String?, query: [URLQueryItem]) throws -> URLRequest {
        let url = try endpoint(path: path, query: query)
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.httpShouldHandleCookies = false
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Thermik", forHTTPHeaderField: "User-Agent")
        request.setValue("en", forHTTPHeaderField: "Accept-Language")
        if let entityTag { request.setValue(entityTag, forHTTPHeaderField: "If-None-Match") }
        return request
    }

    private func endpoint(path: String, query: [URLQueryItem]) throws -> URL {
        var endpoint = URLComponents()
        endpoint.scheme = "https"
        endpoint.host = "api.github.com"
        endpoint.path = path
        if !query.isEmpty { endpoint.queryItems = query }
        guard let url = endpoint.url else { throw UpdateCheckError.invalidConfiguration }
        return url
    }

    private func validatedResponse(to request: URLRequest) async throws -> ReleaseResponse {
        try Task.checkCancellation()
        let response = try await transport.fetch(request)
        try Task.checkCancellation()
        guard response.data.count <= ReleaseLimits.maximumResponseBytes else { throw UpdateCheckError.responseTooLarge }
        return response
    }

    private func requestError(_ error: Error) -> Error {
        if let failure = error as? UpdateCheckError { return failure }
        if error is CancellationError { return CancellationError() }
        if let error = error as? URLError, error.code == .cancelled { return CancellationError() }
        return UpdateCheckError.offline
    }

    private static func failure(status: Int) -> UpdateCheckError {
        switch status {
        case 403, 429: .rateLimited
        case 404: .repositoryNotFound
        default: .server(status)
        }
    }
}
