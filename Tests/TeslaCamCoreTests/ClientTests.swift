import Foundation
import Testing
@testable import TeslaCamCore

/// Podvržený server; zachytí požadavek a vrátí připravenou odpověď.
final class StubProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, Data))?
    nonisolated(unsafe) static var seen: [URLRequest] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var request = request
        if request.httpBody == nil, let stream = request.httpBodyStream {
            stream.open()
            var body = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                body.append(buffer, count: n)
            }
            request.httpBody = body
        }
        Self.seen.append(request)
        let (status, body) = Self.handler!(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite(.serialized)
struct ClientTests {
    let token = try! BearerToken(parsing: "eyJhbGciOiJub25lIn0.eyJleHAiOjIwMDAwMDAwMDB9.c2ln")

    func client() -> TeslaKeyClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        return TeslaKeyClient(token: token, configuration: config, maxRetries: 2, backoff: 0.01)
    }

    func item() throws -> KeyRequestItem {
        KeyRequestItem(header: try Container.readHeader(Sample.fixture("real_clip.enc")))
    }

    @Test func sendsOnlyToTeslaWithBearer() async throws {
        StubProtocol.seen = []
        let key = Data(0..<16)
        StubProtocol.handler = { _ in
            (200, Data(#"{"results":[{"id":"00001388-3c81-b7f5-0000-0002000d0000","key":"\#(key.base64EncodedString())"}]}"#.utf8))
        }
        let set = try await client().fetchKeys([try item()])
        #expect(set.keys["00001388-3c81-b7f5-0000-0002000d0000"] == key)

        let request = try #require(StubProtocol.seen.first)
        #expect(request.url?.absoluteString == "https://dashcam.tesla.com/api/1/decrypt/batch")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(token.value)")
        let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: [[String: Any]]]
        let sent = body["items"]![0]
        #expect(sent["vin"] as? String == "5YJ3E1EA7KF000001")
        #expect(sent["key_id"] as? Int == 1)
        #expect(sent["timestamp"] as? Int == 1_782_000_000)
        #expect(Data(base64Encoded: sent["wrapped_key"] as! String)?.count == 44)
        #expect(Data(base64Encoded: sent["public_key"] as! String)?.first == 0x04)
    }

    @Test func perFileErrorsAreReported() async throws {
        StubProtocol.handler = { _ in (200, Data(#"{"results":[{"id":"x","error":"error.unable_to_verify_ownership"}]}"#.utf8)) }
        let set = try await client().fetchKeys([try item()])
        #expect(set.errors["x"] == "error.unable_to_verify_ownership")
    }

    @Test func unauthorizedIsNotRetried() async throws {
        StubProtocol.seen = []
        StubProtocol.handler = { _ in (401, Data()) }
        await #expect(throws: KeyServiceError.unauthorized) { try await client().fetchKeys([try item()]) }
        #expect(StubProtocol.seen.count == 1)
    }

    @Test func serverErrorsAreRetried() async throws {
        StubProtocol.seen = []
        StubProtocol.handler = { _ in (503, Data("busy".utf8)) }
        await #expect(throws: KeyServiceError.httpStatus(503, "busy")) { try await client().fetchKeys([try item()]) }
        #expect(StubProtocol.seen.count == 3)
    }
}
