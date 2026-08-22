import UIKit
import XCTest

/// End-to-end sign-up flow against a running API (spec §6):
/// welcome → info screens → sign-up → email form → submit →
/// asserts redirect to the questionnaire → completes it → asserts dashboard.
final class OnboardingSignUpUITests: XCTestCase {

    func testSignUpRedirectsToQuestionnaireAndCompletes() throws {
        let email = "e2e+\(UUID().uuidString.lowercased())@e2e.evaapp.dev"
        let password = "uitest-pass-1"

        let app = XCUIApplication()
        app.launchEnvironment["EVA_UITEST_RESET"] = "1"
        // scripts/verify-mobile.sh passes TEST_RUNNER_EVA_API_BASE_URL so the app
        // targets the API the harness actually started; falls back to the DEBUG default.
        let apiBaseURL = ProcessInfo.processInfo.environment["EVA_API_BASE_URL"]
            ?? "http://localhost:3003"
        app.launchEnvironment["EVA_API_BASE_URL"] = apiBaseURL
        print("UI test targeting API at \(apiBaseURL)")
        app.launch()

        // Public flow
        tap(app.buttons["primary.Get started"], timeout: 10)
        tap(app.buttons["primary.See how Eva helps"], timeout: 5)
        tap(app.buttons["primary.Create my account"], timeout: 5)
        tap(app.buttons["signup.method.Sign up with email"], timeout: 5)

        // Email form
        let emailField = app.textFields["signup.email"]
        XCTAssertTrue(emailField.waitForExistence(timeout: 5))
        emailField.tap()
        emailField.typeText(email)

        // typeText into the SecureField only ever lands one character (verified on
        // iOS 18.5 and 26 simulators), so paste instead. typeText is kept as a
        // fallback in case the edit menu doesn't appear.
        let passwordField = app.secureTextFields["signup.password"]
        XCTAssertTrue(passwordField.waitForExistence(timeout: 5))
        UIPasteboard.general.string = password
        passwordField.tap()
        passwordField.press(forDuration: 1.2)
        let paste = app.menuItems["Paste"]
        if paste.waitForExistence(timeout: 3) {
            paste.tap()
        } else {
            passwordField.typeText(password)
        }

        // Fail here, not three screens later, if the form didn't actually receive input.
        let submit = app.buttons["signup.submit"]
        XCTAssertTrue(submit.waitForExistence(timeout: 5))
        XCTAssertTrue(submit.isEnabled, "Sign-up CTA stayed disabled — form input did not land")
        submit.tap()

        // THE core assertion: signup redirects into the questionnaire.
        XCTAssertTrue(
            app.staticTexts["A little about you"].waitForExistence(timeout: 15),
            "Sign-up did not redirect to the questionnaire"
        )

        // Complete the questionnaire.
        tap(app.buttons["primary.Continue"], timeout: 5) // about you
        tap(app.buttons["Energy"], timeout: 5)           // goals
        tap(app.buttons["primary.Continue"], timeout: 5)
        tap(app.buttons["None of these"], timeout: 5)    // health
        tap(app.buttons["No"], timeout: 5)
        tap(app.buttons["primary.Continue"], timeout: 5)
        tap(app.buttons["Active"], timeout: 5)           // lifestyle
        tap(app.buttons["Yoga"], timeout: 5)
        tap(app.buttons["primary.Build my plan"], timeout: 5)

        // Done screen after successful PUT, then dashboard.
        XCTAssertTrue(
            app.staticTexts["You're all set"].waitForExistence(timeout: 15),
            "Questionnaire submission did not reach the done screen"
        )
        tap(app.buttons["primary.Enter Eva"], timeout: 5)
        XCTAssertTrue(
            app.staticTexts["dashboard.title"].waitForExistence(timeout: 10),
            "Did not land on the dashboard"
        )
    }

    private func tap(_ element: XCUIElement, timeout: TimeInterval) {
        XCTAssertTrue(element.waitForExistence(timeout: timeout), "Missing element: \(element)")
        element.tap()
    }
}
