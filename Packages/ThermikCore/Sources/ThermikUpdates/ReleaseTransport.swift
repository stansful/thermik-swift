import Foundation

public struct ReleaseResponse: Sendable {
    public let data: Data
    public let statusCode: Int
    public let entityTag: String?

    public init(data: Data, statusCode: Int, entityTag: String? = nil) {
        self.data = data
        self.statusCode = statusCode
        self.entityTag = entityTag
    }
}

public protocol ReleaseTransport: Sendable {
    func fetch(_ request: URLRequest) async throws -> ReleaseResponse
}

enum ReleaseLimits {
    static let maximumResponseBytes = 1_048_576
}

/// Streaming enforces the response limit before a whole oversized body reaches memory.
public actor URLSessionReleaseTransport: ReleaseTransport {
    private let session: URLSession

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration, delegate: GitHubRedirectPolicy(), delegateQueue: nil)
    }

    public func fetch(_ request: URLRequest) async throws -> ReleaseResponse {
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        guard let response = response as? HTTPURLResponse else { throw UpdateCheckError.invalidResponse }
        guard response.expectedContentLength <= Int64(ReleaseLimits.maximumResponseBytes) else {
            throw UpdateCheckError.responseTooLarge
        }
        let data = try await read(bytes)
        return ReleaseResponse(data: data, statusCode: response.statusCode,
                               entityTag: response.value(forHTTPHeaderField: "ETag"))
    }

    private func read(_ bytes: URLSession.AsyncBytes) async throws -> Data {
        var data = Data()
        for try await byte in bytes {
            guard data.count < ReleaseLimits.maximumResponseBytes else { throw UpdateCheckError.responseTooLarge }
            data.append(byte)
        }
        return data
    }

    deinit { session.invalidateAndCancel() }
}

private final class GitHubRedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        let url = request.url
        completionHandler(url?.scheme == "https" && url?.host == "api.github.com" ? request : nil)
    }
}
