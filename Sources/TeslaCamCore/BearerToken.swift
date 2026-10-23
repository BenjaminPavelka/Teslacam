import Foundation

/// Přístupový token k Tesla účtu. Drží se jen v paměti: nemá Codable a jeho
/// popis nikdy neobsahuje hodnotu, takže se nedostane do logu ani na disk.
public struct BearerToken: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    let value: String
    /// Čas vypršení z JWT (`exp`), pokud ho token nese.
    public let expiresAt: Date?

    public enum ParseError: Error, Equatable {
        case empty
        case notJWT
    }

    /// Přijme text ze schránky: ořízne mezery, uvozovky, `Authorization:` a `Bearer `.
    public init(parsing raw: String) throws {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'")))
        for prefix in ["authorization:", "bearer"] where text.lowercased().hasPrefix(prefix) {
            text = String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        text.removeAll { $0.isWhitespace }
        guard !text.isEmpty else { throw ParseError.empty }

        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard text.hasPrefix("eyJ"), parts.count == 3, parts.allSatisfy({ !$0.isEmpty }),
              text.allSatisfy({ $0.isLetter || $0.isNumber || "-_.=".contains($0) }), text.allSatisfy(\.isASCII)
        else { throw ParseError.notJWT }

        value = text
        expiresAt = Self.expiry(payload: String(parts[1]))
    }

    public func isExpired(now: Date = Date()) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt <= now
    }

    public var description: String { "BearerToken(<skryto>)" }
    public var debugDescription: String { description }

    private static func expiry(payload: String) -> Date? {
        var b64 = payload.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        b64 += String(repeating: "=", count: (4 - b64.count % 4) % 4)
        guard let data = Data(base64Encoded: b64),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let exp = json["exp"] as? Double
        else { return nil }
        return Date(timeIntervalSince1970: exp)
    }
}
