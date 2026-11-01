import Foundation
import Testing
@testable import ThermikUpdates

private actor FakeTransport: ReleaseTransport {
    enum Answer: Sendable {
        case response(ReleaseResponse)
        case offline
        case cancelled
    }

    private var answers: [Answer]
    private(set) var requests: [URLRequest] = []

    init(_ answers: [Answer]) { self.answers = answers }

    func fetch(_ request: URLRequest) async throws -> ReleaseResponse {
        requests.append(request)
        guard !answers.isEmpty else { throw URLError(.cannotConnectToHost) }
        switch answers.removeFirst() {
        case .response(let response): return response
        case .offline: throw URLError(.notConnectedToInternet)
        case .cancelled: throw CancellationError()
        }
    }
}

private actor GatedTransport: ReleaseTransport {
    private var gates: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false
    private(set) var requestCount = 0

    func fetch(_ request: URLRequest) async throws -> ReleaseResponse {
        requestCount += 1
        if !isOpen { await withCheckedContinuation { gates.append($0) } }
        return release("1.2.3")
    }

    func open() {
        isOpen = true
        gates.forEach { $0.resume() }
        gates.removeAll()
    }
}

private func release(_ tag: String, etag: String? = nil, draft: Bool = false,
                     prerelease: Bool = false, htmlURL: String = "https://evil.invalid/download") -> ReleaseResponse {
    let json: [String: Any] = ["tag_name": tag, "draft": draft, "prerelease": prerelease,
                               "html_url": htmlURL, "body": "Notes", "assets": []]
    return ReleaseResponse(data: try! JSONSerialization.data(withJSONObject: json), statusCode: 200, entityTag: etag)
}

private func checker(_ answers: [FakeTransport.Answer], current: String = "1.0.4") throws -> GitHubReleaseChecker {
    GitHubReleaseChecker(configuration: try ReleaseConfiguration(repository: "stansful/thermik-swift", currentVersion: current),
                         transport: FakeTransport(answers))
}

@Suite("ThermikUpdates") struct GitHubReleaseCheckerTests {
    @Test func configurationRejectsUntrustedSlugsAndInvalidVersions() throws {
        for repository in ["", "owner", "owner/", "/repo", "a/b/c", "../repo", "owner/..", "a/.",
                           "owner/repo?token=secret", "owner/repo#tag", "owner/répo", "owner/r epo"] {
            #expect(throws: UpdateCheckError.invalidConfiguration) {
                try ReleaseConfiguration(repository: repository, currentVersion: "1.0.4")
            }
        }
        for version in ["", "v", "1.0", "1.0.0.0", "01.0.0", "-1.0.0", "1.0.0-", "1.0.0+", "1.0.0-01", "1.0.0+b..d"] {
            #expect(throws: UpdateCheckError.invalidConfiguration) {
                try ReleaseConfiguration(repository: "stansful/thermik-swift", currentVersion: version)
            }
        }
        #expect(try ReleaseConfiguration(repository: "stansful/thermik-swift", currentVersion: "v1.0.4+local").currentVersion == "v1.0.4+local")
    }

    @Test func newerReleaseReturnsItsExactRepositoryPage() async throws {
        let service = try checker([.response(release("v1.0.5"))])
        let expected = AvailableUpdate(version: "1.0.5", url: URL(string: "https://github.com/stansful/thermik-swift/releases/tag/v1.0.5")!)
        #expect(try await service.check() == .available(expected))
    }

    @Test func equalOrOlderReleaseIsUpToDate() async throws {
        for tag in ["1.0.4", "v1.0.4", "1.0.3", "0.99.99", "1.0.4+different"] {
            #expect(try await checker([.response(release(tag))]).check() == .upToDate)
        }
    }

    @Test func comparisonIsNumericAndDoesNotOverflow() async throws {
        for (current, remote) in [("1.9.9", "1.10.0"), ("1.99.99", "2.0.0"),
                                  ("999999999999999999.0.0", "1000000000000000000.0.0")] {
            let result = try await checker([.response(release(remote))], current: current).check()
            guard case .available(let available) = result else { Issue.record("Expected newer numeric version"); continue }
            #expect(available.version == remote)
        }
    }

    @Test func metadataDoesNotChangePrecedenceAndPrereleaseCurrentCanUpgradeToStable() async throws {
        #expect(try await checker([.response(release("1.0.4+release"))], current: "1.0.4+local").check() == .upToDate)
        guard case .available = try await checker([.response(release("1.0.4"))], current: "1.0.4-beta.1").check() else {
            Issue.record("Stable must be newer than its beta"); return
        }
    }

    @Test func draftsAndPrereleasesNeverCount() async throws {
        for response in [release("99.0.0", draft: true), release("99.0.0", prerelease: true), release("99.0.0-beta.1")] {
            #expect(try await checker([.response(response)]).check() == .upToDate)
        }
    }

    @Test func invalidReleaseMetadataFails() async throws {
        for response in [release("nightly"), release("01.2.3"), release("v"),
                         ReleaseResponse(data: Data("{\"message\":\"not a release\"}".utf8), statusCode: 200),
                         ReleaseResponse(data: Data("[]".utf8), statusCode: 200)] {
            await #expect(throws: UpdateCheckError.invalidResponse) { try await checker([.response(response)]).check() }
        }
    }

    @Test func requestHasNoCredentialsCookiesOrMachineIdentifiers() async throws {
        let transport = FakeTransport([.response(release("1.0.4"))])
        let configuration = try ReleaseConfiguration(repository: "stansful/thermik-swift", currentVersion: "1.0.4")
        _ = try await GitHubReleaseChecker(configuration: configuration, transport: transport).check()
        let request = try #require(await transport.requests.first)
        #expect(request.url?.absoluteString == "https://api.github.com/repos/stansful/thermik-swift/releases/latest")
        #expect(request.httpMethod == "GET")
        #expect(!request.httpShouldHandleCookies && request.cachePolicy == .reloadIgnoringLocalCacheData)
        #expect(request.timeoutInterval == 15)
        #expect(request.allHTTPHeaderFields == ["Accept": "application/vnd.github+json", "Accept-Language": "en",
                                               "User-Agent": "Thermik", "X-GitHub-Api-Version": "2022-11-28"])
    }

    @Test func secondCheckRevalidatesETagAndReusesRepresentation() async throws {
        let transport = FakeTransport([.response(release("v1.0.5", etag: "W/\"release\"")),
                                       .response(ReleaseResponse(data: Data(), statusCode: 304))])
        let service = GitHubReleaseChecker(configuration: try ReleaseConfiguration(repository: "stansful/thermik-swift", currentVersion: "1.0.4"), transport: transport)
        let first = try await service.check()
        #expect(try await service.check() == first)
        let requests = await transport.requests
        #expect(requests.count == 2)
        #expect(requests[0].value(forHTTPHeaderField: "If-None-Match") == nil)
        #expect(requests[1].value(forHTTPHeaderField: "If-None-Match") == "W/\"release\"")
    }

    @Test func cachedReleaseIsReevaluatedAgainstTheRunningVersion() async throws {
        let cache = ReleaseCache()
        let transport = FakeTransport([.response(release("1.0.5", etag: "\"v5\"")),
                                       .response(ReleaseResponse(data: Data(), statusCode: 304))])
        let old = GitHubReleaseChecker(configuration: try ReleaseConfiguration(repository: "stansful/thermik-swift", currentVersion: "1.0.4"), transport: transport, cache: cache)
        guard case .available = try await old.check() else { Issue.record("Expected an update"); return }
        let updated = GitHubReleaseChecker(configuration: try ReleaseConfiguration(repository: "stansful/thermik-swift", currentVersion: "1.0.5"), transport: transport, cache: cache)
        #expect(try await updated.check() == .upToDate)
    }

    @Test func anotherRepositoryDoesNotReceiveCachedETag() async throws {
        let cache = ReleaseCache()
        let transport = FakeTransport([.response(release("1.0.5", etag: "\"repo-a\"")), .response(release("1.0.4"))])
        _ = try await GitHubReleaseChecker(configuration: try ReleaseConfiguration(repository: "owner/first", currentVersion: "1.0.4"), transport: transport, cache: cache).check()
        _ = try await GitHubReleaseChecker(configuration: try ReleaseConfiguration(repository: "owner/second", currentVersion: "1.0.4"), transport: transport, cache: cache).check()
        #expect(await transport.requests.last?.value(forHTTPHeaderField: "If-None-Match") == nil)
    }

    @Test func missingETagClearsAnOlderRepresentation() async throws {
        let transport = FakeTransport([.response(release("1.0.5", etag: "\"v5\"")), .response(release("1.0.6")),
                                       .response(release("1.0.6"))])
        let service = GitHubReleaseChecker(configuration: try ReleaseConfiguration(repository: "owner/repo", currentVersion: "1.0.4"), transport: transport)
        for _ in 0..<3 { _ = try await service.check() }
        #expect(await transport.requests.last?.value(forHTTPHeaderField: "If-None-Match") == nil)
    }

    @Test func notModifiedWithoutRepresentationFails() async throws {
        await #expect(throws: UpdateCheckError.invalidResponse) {
            try await checker([.response(ReleaseResponse(data: Data(), statusCode: 304))]).check()
        }
    }

    @Test func unsafeETagIsNotSentAsAnHTTPHeader() async throws {
        let transport = FakeTransport([.response(release("1.0.5", etag: "x\r\nAuthorization: secret")),
                                       .response(release("1.0.5"))])
        let service = GitHubReleaseChecker(configuration: try ReleaseConfiguration(repository: "owner/repo", currentVersion: "1.0.4"), transport: transport)
        _ = try await service.check()
        _ = try await service.check()
        #expect(await transport.requests.last?.value(forHTTPHeaderField: "If-None-Match") == nil)
    }

    @Test func noStableReleaseIsDifferentFromUnknownRepository() async throws {
        let missing = ReleaseResponse(data: Data(), statusCode: 404)
        #expect(try await checker([.response(missing), .response(ReleaseResponse(data: Data("[]".utf8), statusCode: 200))]).check() == .upToDate)
        await #expect(throws: UpdateCheckError.repositoryNotFound) {
            try await checker([.response(missing), .response(missing)]).check()
        }
    }

    @Test func fallbackValidatesReleaseArrayBeforeReportingUpToDate() async throws {
        let missing = ReleaseResponse(data: Data(), statusCode: 404)
        for body in ["{\"message\":\"unexpected\"}", "not JSON", "[{}]"] {
            await #expect(throws: UpdateCheckError.invalidResponse) {
                try await checker([.response(missing), .response(ReleaseResponse(data: Data(body.utf8), statusCode: 200))]).check()
            }
        }
        let beta = release("2.0.0-beta.1", prerelease: true)
        let betaList = ReleaseResponse(data: Data("[".utf8) + beta.data + Data("]".utf8), statusCode: 200)
        #expect(try await checker([.response(missing), .response(betaList)]).check() == .upToDate)
        let stable = release("1.0.5")
        let stableList = ReleaseResponse(data: Data("[".utf8) + stable.data + Data("]".utf8), statusCode: 200)
        guard case .available(let update) = try await checker([.response(missing), .response(stableList)]).check() else {
            Issue.record("The fallback must still offer a newer stable release"); return
        }
        #expect(update.version == "1.0.5")
    }

    @Test func typedHTTPAndNetworkFailures() async throws {
        for (status, error) in [(403, UpdateCheckError.rateLimited), (429, .rateLimited), (500, .server(500))] {
            await #expect(throws: error) { try await checker([.response(ReleaseResponse(data: Data(), statusCode: status))]).check() }
        }
        await #expect(throws: UpdateCheckError.offline) { try await checker([.offline]).check() }
        await #expect(throws: CancellationError.self) { try await checker([.cancelled]).check() }
    }

    @Test func oversizedPayloadIsRejectedEvenFromAnInjectedTransport() async throws {
        let large = ReleaseResponse(data: Data(repeating: 32, count: ReleaseLimits.maximumResponseBytes + 1), statusCode: 200)
        await #expect(throws: UpdateCheckError.responseTooLarge) { try await checker([.response(large)]).check() }
    }

    @Test func overlappingChecksShareOneRequest() async throws {
        let transport = GatedTransport()
        let service = GitHubReleaseChecker(configuration: try ReleaseConfiguration(repository: "owner/repo", currentVersion: "1.0.4"), transport: transport)
        async let first = service.check()
        while await transport.requestCount == 0 { await Task.yield() }
        async let second = service.check()
        try await Task.sleep(for: .milliseconds(10))
        await transport.open()
        #expect(try await first == second)
        #expect(await transport.requestCount == 1)
    }

    @Test func semanticVersionPrereleaseOrderingMatchesSemver() {
        let ordered = ["1.0.0-alpha", "1.0.0-alpha.1", "1.0.0-alpha.beta", "1.0.0-beta", "1.0.0-beta.2",
                       "1.0.0-beta.11", "1.0.0-rc.1", "1.0.0"]
        for (left, right) in zip(ordered, ordered.dropFirst()) {
            #expect(SemanticVersion(left)! < SemanticVersion(right)!)
        }
    }

    @Test func cancellingACheckDoesNotBecomeAnOfflineFailure() async throws {
        let transport = GatedTransport()
        let service = GitHubReleaseChecker(configuration: try ReleaseConfiguration(repository: "owner/repo", currentVersion: "1.0.4"), transport: transport)
        let task = Task { try await service.check() }
        while await transport.requestCount == 0 { await Task.yield() }
        task.cancel()
        await transport.open()
        await #expect(throws: CancellationError.self) { try await task.value }
        guard case .available = try await service.check() else {
            Issue.record("A cancelled request must not poison subsequent checks"); return
        }
        #expect(await transport.requestCount == 2)
    }

    @Test func cancellingACoalescedConsumerCancelsTheSharedRequest() async throws {
        let transport = GatedTransport()
        let service = GitHubReleaseChecker(configuration: try ReleaseConfiguration(repository: "owner/repo", currentVersion: "1.0.4"), transport: transport)
        let first = Task { try await service.check() }
        while await transport.requestCount == 0 { await Task.yield() }
        let second = Task { try await service.check() }
        try await Task.sleep(for: .milliseconds(10))
        second.cancel()
        await transport.open()
        await #expect(throws: CancellationError.self) { try await first.value }
        await #expect(throws: CancellationError.self) { try await second.value }
        #expect(await transport.requestCount == 1)
        guard case .available = try await service.check() else {
            Issue.record("The shared cancelled request must be cleared"); return
        }
        #expect(await transport.requestCount == 2)
    }
}
