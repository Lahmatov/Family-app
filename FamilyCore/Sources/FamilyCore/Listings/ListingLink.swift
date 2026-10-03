import Foundation

/// A validated, normalised listing URL. Normalising makes the database's
/// `unique (family_id, url)` catch the same ad shared with different tracking params.
public struct ListingLink: Hashable, Sendable {
    public let url: URL
    /// Short site key ("idealista") or the bare host for unknown sites.
    public let source: String

    public enum ParseError: Error, Equatable, Sendable {
        case empty, notHTTPS, invalid, tooLong
    }

    static let knownSites: [(host: String, key: String)] = [
        ("idealista.pt", "idealista"), ("imovirtual.com", "imovirtual"), ("casa.sapo.pt", "casasapo"),
        ("supercasa.pt", "supercasa"), ("remax.pt", "remax"),
    ]
    public static let maxLength = 2048

    public init(parsing text: String) throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ParseError.empty }
        guard trimmed.count <= Self.maxLength else { throw ParseError.tooLong }
        guard var parts = URLComponents(string: trimmed), let host = parts.host?.lowercased(), host.contains(".") else {
            throw ParseError.invalid
        }
        guard parts.scheme?.lowercased() == "https" else { throw ParseError.notHTTPS }
        // `https://idealista.pt@evil.com/` shows a trusted name but opens another site.
        guard parts.user == nil, parts.password == nil else { throw ParseError.invalid }

        parts.scheme = "https"
        parts.host = host
        parts.fragment = nil
        parts.queryItems = parts.queryItems?.filter { item in
            let name = item.name.lowercased()
            return !(name.hasPrefix("utm_") || ["fbclid", "gclid", "igshid"].contains(name))
        }
        if parts.queryItems?.isEmpty == true { parts.queryItems = nil }
        guard let url = parts.url, url.absoluteString.count <= Self.maxLength else { throw ParseError.invalid }

        self.url = url
        let bare = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        source = Self.knownSites.first { bare == $0.host || bare.hasSuffix("." + $0.host) }?.key ?? bare
    }
}
