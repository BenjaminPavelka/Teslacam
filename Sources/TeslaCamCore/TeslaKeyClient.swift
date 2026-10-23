import Foundation

/// Jedna položka dotazu na klíč. Posílají se jen metadata z hlavičky, nikdy video.
public struct KeyRequestItem: Encodable, Sendable, Equatable {
    public var id: String
    public var vin: String
    public var keyID: UInt32
    public var timestamp: UInt64
    public var wrappedKey: String
    public var publicKey: String

    enum CodingKeys: String, CodingKey {
        case id, vin, timestamp
        case keyID = "key_id"
        case wrappedKey = "wrapped_key"
        case publicKey = "public_key"
    }

    public init(header: ContainerHeader) {
        id = header.id
        vin = header.vin
        keyID = header.keyID
        timestamp = header.timestamp
        wrappedKey = header.wrappedKey.base64EncodedString()
        publicKey = header.publicKey.base64EncodedString()
    }
}

public struct KeySet: Sendable {
    public var keys: [String: Data] = [:]
    /// Chyba, kterou API vrátilo pro konkrétní id (např. `error.unable_to_verify_ownership`).
    public var errors: [String: String] = [:]
}

public enum KeyServiceError: Error, Equatable, Sendable {
    /// 401/403: token vypršel nebo je neplatný.
    case unauthorized
    case httpStatus(Int, String)
    case network(String)
    case malformedResponse
    case responseTooLarge
}

public protocol KeyFetching: Sendable {
    func fetchKeys(_ items: [KeyRequestItem]) async throws -> KeySet
}

/// Klient pro `https://dashcam.tesla.com/api/1/decrypt/batch`.
///
/// Adresa je pevná a přesměrování se odmítají, takže token nemůže odejít jinam.
public final class TeslaKeyClient: NSObject, KeyFetching, URLSessionTaskDelegate, @unchecked Sendable {
    public static let origin = URL(string: "https://dashcam.tesla.com")!
    static let endpoint = URL(string: "https://dashcam.tesla.com/api/1/decrypt/batch")!
    static let maxResponseBody = 4 << 20

    private let token: BearerToken
    private let maxRetries: Int
    private let backoff: TimeInterval
    private var session: URLSession!

    /// `configuration` jde přepsat jen kvůli testům (podvržený URLProtocol).
    public init(
        token: BearerToken,
        configuration: URLSessionConfiguration = .ephemeral,
        maxRetries: Int = 3,
        backoff: TimeInterval = 1
    ) {
        self.token = token
        self.maxRetries = maxRetries
        self.backoff = backoff
        super.init()
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.timeoutIntervalForRequest = 30
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

    public func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        nil
    }

    public func fetchKeys(_ items: [KeyRequestItem]) async throws -> KeySet {
        guard !items.isEmpty else { return KeySet() }
        let body = try JSONEncoder().encode(["items": items])

        var lastError: KeyServiceError = .network("neznámá chyba")
        for attempt in 0...maxRetries {
            if attempt > 0 {
                try await Task.sleep(nanoseconds: UInt64(backoff * pow(2, Double(attempt - 1)) * 1e9))
            }
            do {
                return try parse(try await post(body))
            } catch let error as RetryableError {
                lastError = error.underlying
            }
        }
        throw lastError
    }

    private struct RetryableError: Error { let underlying: KeyServiceError }

    private func post(_ body: Data) async throws -> Data {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("Bearer \(token.value)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(Self.origin.absoluteString, forHTTPHeaderField: "Origin")
        request.setValue(Self.origin.absoluteString + "/", forHTTPHeaderField: "Referer")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw RetryableError(underlying: .network(error.localizedDescription))
        }

        guard let http = response as? HTTPURLResponse else { throw KeyServiceError.malformedResponse }
        let snippet = String(decoding: data.prefix(512), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        switch http.statusCode {
        case 200:
            guard data.count <= Self.maxResponseBody else { throw KeyServiceError.responseTooLarge }
            return data
        case 401, 403:
            throw KeyServiceError.unauthorized
        case 429, 500...:
            throw RetryableError(underlying: .httpStatus(http.statusCode, snippet))
        default:
            throw KeyServiceError.httpStatus(http.statusCode, snippet)
        }
    }

    private struct BatchResponse: Decodable {
        struct Result: Decodable {
            var id: String
            var key: String?
            var error: String?
        }
        var results: [Result]
    }

    private func parse(_ data: Data) throws -> KeySet {
        guard let response = try? JSONDecoder().decode(BatchResponse.self, from: data) else {
            throw KeyServiceError.malformedResponse
        }
        var out = KeySet()
        for result in response.results {
            if let error = result.error, !error.isEmpty {
                out.errors[result.id] = error
            } else if let b64 = result.key, let key = Data(base64Encoded: b64) {
                out.keys[result.id] = key
            } else {
                out.errors[result.id] = "malformed_key"
            }
        }
        return out
    }
}
