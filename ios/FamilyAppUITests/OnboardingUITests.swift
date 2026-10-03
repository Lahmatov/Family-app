import XCTest

/// End-to-end UI flows against the in-memory backend (`-ui-testing`).
/// Backend rules themselves are covered by supabase/tests (pgTAP).
final class OnboardingUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func launch(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-AppleLanguages", "(en)", "-AppleLocale", "en_PT"] + extra
        app.launch()
        return app
    }

    private func signIn(_ app: XCUIApplication, password: String) {
        let email = app.textFields["emailField"]
        XCTAssertTrue(email.waitForExistence(timeout: 5))
        email.tap()
        email.typeText("parent@example.com")
        app.secureTextFields["passwordField"].tap()
        app.secureTextFields["passwordField"].typeText(password)
        app.buttons["signInButton"].tap()
    }

    func testWrongPasswordIsRejected() {
        let app = launch()
        signIn(app, password: "wrong-password")
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.textFields["codeField"].exists)
    }

    func testSignInRequiresSecondFactorThenCreatesFamilyAndAddsExpense() {
        let app = launch()

        // Correct password leads to MFA enrollment, never directly to data.
        signIn(app, password: "Correct-Horse-1")
        let code = app.textFields["codeField"]
        XCTAssertTrue(code.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["addTransactionButton"].exists)
        code.tap()
        code.typeText("123456")
        app.buttons["verifyCodeButton"].tap()

        // Create a family.
        let familyName = app.textFields["familyNameField"]
        XCTAssertTrue(familyName.waitForExistence(timeout: 5))
        familyName.tap()
        familyName.typeText("Lahmatov")
        app.buttons["createFamilyButton"].tap()

        // Add an expense.
        let add = app.buttons["addTransactionButton"]
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        add.tap()
        let amount = app.textFields["amountField"]
        XCTAssertTrue(amount.waitForExistence(timeout: 5))
        amount.tap()
        amount.typeText("45.50")
        app.buttons["category-groceries"].tap()
        app.buttons["saveTransactionButton"].tap()

        let total = app.staticTexts["totalSpent"]
        XCTAssertTrue(total.waitForExistence(timeout: 5))
        XCTAssertTrue(total.label.contains("45"), total.label)
    }

    func testValidationBlocksEmptyExpense() {
        let app = launch(["-signed-in"])
        let add = app.buttons["addTransactionButton"]
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        add.tap()
        app.buttons["saveTransactionButton"].tap()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 5))
    }

    func testSignOut() {
        let app = launch(["-signed-in"])
        XCTAssertTrue(app.buttons["addTransactionButton"].waitForExistence(timeout: 5))
        app.tabBars.buttons.element(boundBy: 4).tap()
        app.buttons["signOutButton"].tap()
        XCTAssertTrue(app.textFields["emailField"].waitForExistence(timeout: 5))
    }
}
