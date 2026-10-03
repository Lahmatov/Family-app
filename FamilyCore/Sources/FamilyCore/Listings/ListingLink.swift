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
        ("supercasa.pt", "supercasa"), ("remax.pt", "remax"), ("olx.pt", "olx"), ("century21.pt", "century21"),
        ("zome.pt", "zome"),
    ]
    public static let maxLength = 2048
    /// Mirrors the CHECK on `public.listings.source`.
    public static let maxSourceLength = 40

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

        let bare = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        source = Self.knownSites.first { bare == $0.host || bare.hasSuffix("." + $0.host) }?.key
            ?? String(bare.prefix(Self.maxSourceLength))
        self.url = source == "idealista" ? Self.idealistaCanonical(url) ?? url : url
    }

    /// Idealista ads are `/imovel/<id>/` whatever the language prefix, slug or search parameters, so the same
    /// ad shared from the app, the site or a search result is one row.
    private static func idealistaCanonical(_ url: URL) -> URL? {
        guard let regex = try? NSRegularExpression(pattern: #"^/(?:[a-z]{2}/)?imovel/(\d{1,12})(?:/|$)"#),
              let match = regex.firstMatch(in: url.path, range: NSRange(url.path.startIndex..., in: url.path)),
              let range = Range(match.range(at: 1), in: url.path) else { return nil }
        return URL(string: "https://www.idealista.pt/imovel/\(url.path[range])/")
    }
}
