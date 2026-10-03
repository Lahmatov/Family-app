import Foundation
import XCTest
@testable import FamilyCore

final class ListingLinkTests: XCTestCase {
    func testKnownSitesAndNormalisation() throws {
        let link = try ListingLink(parsing: "  https://WWW.Idealista.pt/imovel/123/?utm_source=x&fbclid=y&keep=1#photos ")
        XCTAssertEqual(link.source, "idealista")
        XCTAssertEqual(link.url.absoluteString, "https://www.idealista.pt/imovel/123/", "idealista ads are keyed by their id")
        XCTAssertEqual(try ListingLink(parsing: "https://www.idealista.pt/en/imovel/123/?xtmc=1").url, link.url)
        XCTAssertEqual(try ListingLink(parsing: "https://idealista.pt/imovel/123").url, link.url)
        XCTAssertEqual(try ListingLink(parsing: "https://www.idealista.pt/comprar-casas/lisboa/?x=1").url.absoluteString,
                       "https://www.idealista.pt/comprar-casas/lisboa/?x=1", "not an ad: left alone")
        XCTAssertEqual(try ListingLink(parsing: "https://www.imovirtual.com/pt/anuncio/x?utm_medium=a").url.absoluteString,
                       "https://www.imovirtual.com/pt/anuncio/x")
        XCTAssertEqual(try ListingLink(parsing: "https://casa.sapo.pt/comprar/1").source, "casasapo")
        XCTAssertEqual(try ListingLink(parsing: "https://pro.remax.pt/a").source, "remax")
        XCTAssertEqual(try ListingLink(parsing: "https://www.olx.pt/d/anuncio/x").source, "olx")
        XCTAssertEqual(try ListingLink(parsing: "https://www.century21.pt/comprar/x").source, "century21")
    }

    func testUnknownSiteUsesHost() throws {
        XCTAssertEqual(try ListingLink(parsing: "https://www.example.com/a").source, "example.com")
    }

    func testRejectsUnsafeOrBroken() {
        let cases: [(String, ListingLink.ParseError)] = [
            ("", .empty), ("   ", .empty),
            ("http://idealista.pt/a", .notHTTPS), ("javascript:alert(1)", .invalid), ("ftp://x.com/a", .notHTTPS),
            ("https://idealista.pt@evil.com/a", .invalid), ("https://user:pw@idealista.pt/a", .invalid),
            ("not a url", .invalid), ("https://localhost/a", .invalid),
            ("https://example.com/" + String(repeating: "a", count: 2100), .tooLong),
        ]
        for (text, expected) in cases {
            XCTAssertThrowsError(try ListingLink(parsing: text), text) { XCTAssertEqual($0 as? ListingLink.ParseError, expected, text) }
        }
    }

    func testSameAdWithDifferentTrackingIsEqual() throws {
        XCTAssertEqual(try ListingLink(parsing: "https://www.idealista.pt/imovel/1/?utm_campaign=a").url,
                       try ListingLink(parsing: "https://www.idealista.pt/imovel/1/#x").url)
    }
}
