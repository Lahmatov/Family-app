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

    /// Tab bar on iPhone, sidebar on iPad.
    private func openSection(_ app: XCUIApplication, _ id: String) {
        let sidebarItem = app.descendants(matching: .any)["section-\(id)"].firstMatch
        if app.tabBars.firstMatch.waitForExistence(timeout: 2) {
            let order = ["budget", "listings", "children", "goals", "family"]
            app.tabBars.buttons.element(boundBy: order.firstIndex(of: id)!).tap()
        } else {
            XCTAssertTrue(sidebarItem.waitForExistence(timeout: 5))
            sidebarItem.tap()
        }
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
        openSection(app, "family")
        app.buttons["settingsLink"].tap()
        app.buttons["signOutButton"].tap()
        XCTAssertTrue(app.textFields["emailField"].waitForExistence(timeout: 5))
    }

    func testVaultSetupRequiresRetypingTheRecoveryKey() {
        let app = launch(["-signed-in"])
        XCTAssertTrue(app.buttons["addTransactionButton"].waitForExistence(timeout: 5))
        openSection(app, "family")
        app.buttons["vaultLink"].tap()
        let create = app.buttons["createVaultButton"]
        XCTAssertTrue(create.waitForExistence(timeout: 5))
        create.tap()

        let key = app.staticTexts["recoveryKeyText"]
        XCTAssertTrue(key.waitForExistence(timeout: 5))
        let done = app.buttons["recoveryDoneButton"]
        XCTAssertFalse(done.isEnabled, "cannot continue before confirming the key")

        let field = app.textFields["recoveryConfirmField"]
        field.tap()
        field.typeText(key.label)
        XCTAssertTrue(done.isEnabled)
        done.tap()
        XCTAssertTrue(app.buttons["addVaultDocumentButton"].waitForExistence(timeout: 5))
    }

    func testPlanATrip() {
        let app = launch(["-signed-in"])
        XCTAssertTrue(app.buttons["addTransactionButton"].waitForExistence(timeout: 5))
        openSection(app, "family")
        app.buttons["tripsLink"].tap()
        app.buttons["addTripButton"].tap()
        let title = app.textFields["tripTitleField"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        title.tap()
        title.typeText("Algarve")
        app.buttons["saveTripButton"].tap()
        XCTAssertTrue(app.staticTexts["Algarve"].waitForExistence(timeout: 5))
    }

    func testEraseAccountReturnsToSignIn() {
        let app = launch(["-signed-in"])
        XCTAssertTrue(app.buttons["addTransactionButton"].waitForExistence(timeout: 5))
        openSection(app, "family")
        app.buttons["settingsLink"].tap()
        app.buttons["eraseAccountButton"].tap()
        let confirm = app.buttons["Delete everything"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        XCTAssertTrue(app.textFields["emailField"].waitForExistence(timeout: 5))
    }
}
