import Foundation

/// What could be read from a listing page. Every field is optional: the person checks and completes
/// the form before saving, so a wrong guess must never be silent (the UI says "check the values").
public struct ListingDraft: Equatable, Sendable {
    public var title = ""
    public var priceMinor: Int64?
    public var areaM2: Decimal?
    /// Bedrooms by Portuguese typology (T3 = 3), not the total number of rooms.
    public var rooms: Int?
    public var address: String?
    public var latitude: Double?
    public var longitude: Double?
    public var imageURL: URL?

    public init() {}

    public var isEmpty: Bool {
        title.isEmpty && priceMinor == nil && areaM2 == nil && rooms == nil && address == nil && latitude == nil
    }
}

/// Reads schema.org JSON-LD and Open Graph / meta tags from a listing page, then falls back to the
/// typology / area / price written in the title and description. Works on the HTML a browser shows,
/// so it never needs the server to fetch (and be blocked by) the portal.
///
/// Tested against excerpts of real Imovirtual and Casa SAPO pages; other portals go through the same
/// generic rules (Idealista and Supercasa refuse non-browser requests, so they could not be checked here).
public enum ListingPageParser {
    /// Pages are parsed in memory; a real listing page is 0.4–1.5 MB.
    public static let maxCharacters = 3_000_000

    public static func parse(html rawHTML: String) -> ListingDraft {
        let html = String(rawHTML.prefix(maxCharacters))
        var draft = ListingDraft()
        let meta = metaTags(html)
        let nodes = jsonLDNodes(html)

        applyJSONLD(nodes, to: &draft)
        applyMeta(meta, html: html, nodes: nodes, to: &draft)
        applyText(meta: meta, nodes: nodes, to: &draft)
        draft.title = String(draft.title.prefix(200))
        return draft
    }

    // MARK: JSON-LD

    private static let listingTypes: Set<String> = [
        "product", "offer", "apartment", "house", "singlefamilyresidence", "realestatelisting",
        "residence", "accommodation", "place", "lodgingbusiness",
    ]
    /// Whoever sells the property is not where the property is: skip their addresses and names.
    private static let skippedKeys: Set<String> = [
        "seller", "provider", "brand", "publisher", "author", "organization", "offeredby", "agent", "broker", "breadcrumb",
    ]

    private static func jsonLDNodes(_ html: String) -> [[String: Any]] {
        // Portals write `type='application/ld&#x2B;json'` (single quotes, escaped plus) as well as the plain form.
        let pattern = #"<script[^>]*type\s*=\s*["']application/ld(?:\+|&#x2B;|&#43;|&plus;)json["'][^>]*>(.*?)</script>"#
        var result: [[String: Any]] = []
        for body in captures(pattern, in: html, options: [.caseInsensitive, .dotMatchesLineSeparators]) {
            guard let data = body.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) else { continue }
            collect(json, depth: 0, into: &result)
        }
        return result
    }

    private static func collect(_ node: Any, depth: Int, into result: inout [[String: Any]]) {
        guard depth < 8 else { return }
        if let dictionary = node as? [String: Any] {
            result.append(dictionary)
            for key in dictionary.keys.sorted() where !skippedKeys.contains(key.lowercased()) {
                collect(dictionary[key]!, depth: depth + 1, into: &result)
            }
        } else if let array = node as? [Any] {
            for element in array { collect(element, depth: depth + 1, into: &result) }
        }
    }

    private static func types(of node: [String: Any]) -> Set<String> {
        let raw = node["@type"]
        let list = (raw as? [String]) ?? (raw as? String).map { [$0] } ?? []
        return Set(list.map { $0.lowercased() })
    }

    private static func applyJSONLD(_ nodes: [[String: Any]], to draft: inout ListingDraft) {
        for node in nodes {
            let nodeTypes = types(of: node)
            let isListing = !nodeTypes.isDisjoint(with: listingTypes)

            if draft.title.isEmpty, isListing, let name = string(node["name"]), !name.isEmpty { draft.title = decode(name) }

            // Only offers: a UnitPriceSpecification inside an offer is the price per m², not the price.
            if draft.priceMinor == nil, nodeTypes.contains("offer") || nodeTypes.contains("aggregateoffer"),
               currencyIsEuro(node["priceCurrency"]), let price = priceMinor(from: node["price"] ?? node["lowPrice"]) {
                draft.priceMinor = price
            }
            if draft.areaM2 == nil, let floor = node["floorSize"] { draft.areaM2 = area(from: floor) }
            if draft.rooms == nil, let bedrooms = integer(node["numberOfBedrooms"]), (0...20).contains(bedrooms) { draft.rooms = bedrooms }
            // `numberOfRooms` is deliberately ignored: Imovirtual says 4 for a T3 (it counts the living room).
            if nodeTypes.contains("propertyvalue"), let name = string(node["name"])?.lowercased(), let value = string(node["value"]) {
                if draft.areaM2 == nil, name.contains("área") || name.contains("area") || name.contains("superf") {
                    draft.areaM2 = areaFromText(value)
                }
                if draft.rooms == nil, name.contains("tipologia") || name.contains("typology") || name.contains("bedroom") || name.contains("quartos") {
                    draft.rooms = typology(in: value) ?? integer(value).flatMap { (0...20).contains($0) ? $0 : nil }
                }
            }
            if draft.address == nil, let address = node["address"], let text = addressText(address) { draft.address = text }
            if draft.latitude == nil {
                let geo = (node["geo"] as? [String: Any]) ?? (node["latitude"] != nil ? node : nil)
                if let geo, let lat = double(geo["latitude"]), let lng = double(geo["longitude"]), validCoordinate(lat, lng) {
                    draft.latitude = lat
                    draft.longitude = lng
                }
            }
            if draft.imageURL == nil, let image = node["image"], isListing { draft.imageURL = imageURL(from: image) }
        }
    }

    private static func addressText(_ value: Any) -> String? {
        if let text = string(value) { return text.isEmpty ? nil : decode(text) }
        guard let dictionary = value as? [String: Any] else { return nil }
        let parts = ["streetAddress", "addressLocality", "addressRegion"].compactMap { string(dictionary[$0]) }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : decode(parts.joined(separator: ", "))
    }

    private static func imageURL(from value: Any) -> URL? {
        let text = string(value) ?? (value as? [Any])?.compactMap { string($0) }.first
            ?? ((value as? [String: Any]).flatMap { string($0["url"]) })
        guard let text, let url = URL(string: decode(text)), url.scheme == "https" else { return nil }
        return url
    }

    // MARK: Meta tags

    private static func metaTags(_ html: String) -> [String: String] {
        var result: [String: String] = [:]
        for tag in matches(#"<meta\b[^>]*>"#, in: html, options: [.caseInsensitive]) {
            var attributes: [String: String] = [:]
            for pair in captures2(#"([a-zA-Z_:-]+)\s*=\s*(?:"([^"]*)"|'([^']*)')"#, in: tag) {
                attributes[pair.0.lowercased()] = pair.1
            }
            guard let content = attributes["content"],
                  let key = (attributes["property"] ?? attributes["name"] ?? attributes["itemprop"])?.lowercased(),
                  result[key] == nil else { continue }
            result[key] = decode(content).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return result
    }

    private static func pageTitle(_ html: String) -> String? {
        captures(#"<title[^>]*>(.*?)</title>"#, in: html, options: [.caseInsensitive, .dotMatchesLineSeparators]).first
            .map { decode($0).trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    private static func applyMeta(_ meta: [String: String], html: String, nodes: [[String: Any]], to draft: inout ListingDraft) {
        // The page title says more than the structured name ("Apartamento T3 para venda" is on every Imovirtual ad).
        if let heading = meta["og:title"] ?? pageTitle(html), !heading.isEmpty {
            draft.title = stripSiteName(heading, siteName: meta["og:site_name"])
        }
        if draft.priceMinor == nil, let amount = meta["product:price:amount"] ?? meta["og:price:amount"],
           ["", "EUR"].contains((meta["product:price:currency"] ?? meta["og:price:currency"] ?? "").uppercased()) {
            draft.priceMinor = priceMinor(from: amount)
        }
        if draft.latitude == nil {
            var pair: (Double, Double)?
            if let position = meta["geo.position"] ?? meta["icbm"] {
                let numbers = position.split(whereSeparator: { ";, ".contains($0) }).compactMap { Double($0) }
                if numbers.count == 2 { pair = (numbers[0], numbers[1]) }
            } else if let lat = double(meta["place:location:latitude"] ?? meta["og:latitude"]),
                      let lng = double(meta["place:location:longitude"] ?? meta["og:longitude"]) {
                pair = (lat, lng)
            }
            if let pair, validCoordinate(pair.0, pair.1) { (draft.latitude, draft.longitude) = pair }
        }
        if draft.imageURL == nil, let image = meta["og:image"], let url = URL(string: image), url.scheme == "https" { draft.imageURL = url }
    }

    /// "… • www.imovirtual.com" or "… - CASA SAPO - Portal Nacional de Imobiliário": the site name is not part of the title.
    private static func stripSiteName(_ title: String, siteName: String?) -> String {
        var result = title
        if let site = siteName?.trimmingCharacters(in: CharacterSet(charactersIn: "/ ")), !site.isEmpty {
            for separator in [" • ", " | ", " - ", " – ", " — "] where result.hasSuffix(separator + site) {
                result = String(result.dropLast(separator.count + site.count))
                break
            }
        }
        return result
    }

    // MARK: Text fallback

    private static func applyText(meta: [String: String], nodes: [[String: Any]], to draft: inout ListingDraft) {
        let descriptions = [meta["og:description"], meta["description"]] + nodes.map { string($0["description"]) }
        let text = ([draft.title] + descriptions.compactMap { $0 }.map(stripTags)).joined(separator: " ")
        if draft.rooms == nil { draft.rooms = typology(in: text) }
        if draft.areaM2 == nil { draft.areaM2 = areaFromText(text) }
        if draft.priceMinor == nil { draft.priceMinor = priceFromText(text) }
    }

    // MARK: Numbers

    /// "250.000 €", "635 000 €", "€ 1.250.000", "650.000,50 €": whole euros with Portuguese grouping.
    static func priceFromText(_ text: String) -> Int64? {
        let number = #"(\d{1,3}(?:[ .   ]\d{3})+|\d+)(?:,(\d{1,2}))?"#
        let leading = #"(?<![\p{L}\d])"#
        for pattern in [leading + number + #"\s*(?:€|eur\b)"#, #"(?:€|eur\b)\s*"# + number] {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                  let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let whole = Range(match.range(at: 1), in: text) else { continue }
            let digits = text[whole].filter(\.isNumber)
            var cents = "00"
            if let fraction = Range(match.range(at: 2), in: text) { cents = (text[fraction] + "0").prefix(2).description }
            if let value = Int64(digits + cents), value > 0, value < 100_000_000_000 { return value }
        }
        return nil
    }

    /// Structured data: 635000, "635000.00", ["650.000 €"].
    private static func priceMinor(from value: Any?) -> Int64? {
        if let array = value as? [Any] { return priceMinor(from: array.first) }
        if let number = value as? NSNumber, !(value is Bool) {
            return minor(Decimal(string: number.stringValue) ?? Decimal(number.doubleValue))
        }
        guard let text = string(value) else { return nil }
        if text.range(of: #"^\d+(\.\d{1,2})?$"#, options: .regularExpression) != nil, let decimal = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")) {
            return minor(decimal)
        }
        return priceFromText(text.contains("€") || text.lowercased().contains("eur") ? text : text + " €")
    }

    private static func minor(_ euros: Decimal) -> Int64? {
        var scaled = euros * 100
        var rounded = Decimal()
        NSDecimalRound(&rounded, &scaled, 0, .plain)
        let value = NSDecimalNumber(decimal: rounded).int64Value
        return value > 0 && value < 100_000_000_000 ? value : nil
    }

    private static func currencyIsEuro(_ value: Any?) -> Bool {
        guard let value else { return true }
        let text = ((value as? [Any])?.first ?? value) as? String
        return text == nil || ["€", "eur"].contains(text!.lowercased())
    }

    private static func area(from value: Any) -> Decimal? {
        if let dictionary = value as? [String: Any] {
            let unit = (string(dictionary["unitCode"]) ?? string(dictionary["unitText"]) ?? "").lowercased()
            guard unit.isEmpty || unit == "mtk" || unit.contains("m") else { return nil }
            return area(from: dictionary["value"] as Any)
        }
        if let number = value as? NSNumber { return validArea(Decimal(string: number.stringValue)) }
        return string(value).flatMap { areaFromText($0) ?? validArea(portugueseDecimal($0)) }
    }

    /// "118 m²", "90 m2" (the first one: "varanda de 11m2" comes later).
    static func areaFromText(_ text: String) -> Decimal? {
        guard let regex = try? NSRegularExpression(pattern: #"(?<![\p{L}\d])(\d{1,5}(?:[.,]\d{1,2})?)\s*m(?:²|2)(?!\d)"#),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return validArea(portugueseDecimal(String(text[range])))
    }

    private static func validArea(_ value: Decimal?) -> Decimal? {
        guard let value, value >= 5, value < 100_000 else { return nil }
        return value
    }

    private static func portugueseDecimal(_ text: String) -> Decimal? {
        Decimal(string: text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "."), locale: Locale(identifier: "en_US_POSIX"))
    }

    /// "T3" -> 3 (bedrooms), or "3 quartos" / "2 bedrooms".
    static func typology(in text: String) -> Int? {
        for pattern in [#"(?<![\p{L}\d])T(\d{1,2})(?![\p{L}\d])"#, #"(\d{1,2})\s*(?:quartos|bedrooms|dormit)"#] {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let range = Range(match.range(at: 1), in: text), let value = Int(text[range]), value <= 20 else { continue }
            return value
        }
        return nil
    }

    // MARK: Small helpers

    private static func string(_ value: Any?) -> String? {
        if let text = value as? String { return text.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let number = value as? NSNumber, !(value is Bool) { return number.stringValue }
        return nil
    }

    private static func integer(_ value: Any?) -> Int? {
        if let number = value as? NSNumber, !(value is Bool) { return number.intValue }
        return string(value).flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
    }

    private static func double(_ value: Any?) -> Double? {
        if let number = value as? NSNumber, !(value is Bool) { return number.doubleValue }
        return string(value).flatMap { Double($0) }
    }

    private static func validCoordinate(_ lat: Double, _ lng: Double) -> Bool {
        (-90...90).contains(lat) && (-180...180).contains(lng) && !(lat == 0 && lng == 0)
    }

    private static func stripTags(_ html: String) -> String {
        decode(html.replacingOccurrences(of: #"<[^>]*>"#, with: " ", options: .regularExpression))
    }

    /// The handful of entities that appear in meta content and titles, plus numeric ones (`&#x20AC;`, `&#237;`).
    static func decode(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var result = text
        for (entity, character) in [("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"), ("&lt;", "<"), ("&gt;", ">"),
                                    ("&nbsp;", " "), ("&euro;", "€")] {
            result = result.replacingOccurrences(of: entity, with: character)
        }
        if let regex = try? NSRegularExpression(pattern: #"&#(x[0-9a-fA-F]+|\d+);"#) {
            for match in regex.matches(in: result, range: NSRange(result.startIndex..., in: result)).reversed() {
                guard let whole = Range(match.range, in: result), let code = Range(match.range(at: 1), in: result) else { continue }
                let digits = result[code]
                let scalar = digits.hasPrefix("x") ? UInt32(digits.dropFirst(), radix: 16) : UInt32(digits)
                if let scalar, let unicode = Unicode.Scalar(scalar) { result.replaceSubrange(whole, with: String(Character(unicode))) }
            }
        }
        return result.replacingOccurrences(of: "&amp;", with: "&")   // last, so "&amp;quot;" stays "&quot;"
    }

    // MARK: Regex plumbing

    private static func matches(_ pattern: String, in text: String, options: NSRegularExpression.Options = []) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { Range($0.range, in: text).map { String(text[$0]) } }
    }

    private static func captures(_ pattern: String, in text: String, options: NSRegularExpression.Options = []) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range(at: 1), in: text).map { String(text[$0]) }
        }
    }

    /// (name, value) pairs of HTML attributes, double- or single-quoted.
    private static func captures2(_ pattern: String, in text: String) -> [(String, String)] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            guard let name = Range(match.range(at: 1), in: text) else { return nil }
            let value = [2, 3].lazy.compactMap { Range(match.range(at: $0), in: text) }.first
            return (String(text[name]), value.map { String(text[$0]) } ?? "")
        }
    }
}
