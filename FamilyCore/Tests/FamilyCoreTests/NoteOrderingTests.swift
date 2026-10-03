import Foundation
import XCTest
@testable import FamilyCore

final class NoteOrderingTests: XCTestCase {
    private func note(_ title: String, body: String = "", pinned: Bool = false, at seconds: TimeInterval) -> NoteSummary {
        NoteSummary(id: UUID(), title: title, body: body, pinned: pinned, updatedAt: Date(timeIntervalSince1970: seconds))
    }

    func testPinnedFirstThenNewest() {
        let old = note("old", at: 100)
        let new = note("new", at: 300)
        let pinnedOld = note("pinned", pinned: true, at: 50)
        XCTAssertEqual(NoteOrdering.sorted([old, new, pinnedOld]).map(\.title), ["pinned", "new", "old"])
    }

    func testSearchIgnoresCaseAndAccents() {
        let sugar = note("Lista", body: "Comprar açúcar e café", at: 1)
        XCTAssertTrue(NoteOrdering.matches(sugar, query: "ACUCAR"))
        XCTAssertTrue(NoteOrdering.matches(sugar, query: "cafe lista"), "all words, in any order and field")
        XCTAssertFalse(NoteOrdering.matches(sugar, query: "leite"))
        XCTAssertTrue(NoteOrdering.matches(sugar, query: "   "), "an empty query matches everything")
        XCTAssertTrue(NoteOrdering.matches(note("Список", body: "Купить молоко", at: 1), query: "МОЛОКО"))
    }

    func testFilteredKeepsOrder() {
        let a = note("plan A", at: 10)
        let b = note("plan B", pinned: true, at: 5)
        let c = note("other", at: 20)
        XCTAssertEqual(NoteOrdering.filtered([a, b, c], query: "plan").map(\.title), ["plan B", "plan A"])
    }

    func testDisplayTitle() {
        XCTAssertEqual(NoteOrdering.displayTitle(title: "  Wi-Fi ", body: "x"), "Wi-Fi")
        XCTAssertEqual(NoteOrdering.displayTitle(title: "", body: "\nfirst line\nsecond"), "first line")
        XCTAssertEqual(NoteOrdering.displayTitle(title: " ", body: ""), "")
    }
}
