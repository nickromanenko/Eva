import Testing
import Foundation
@testable import Eva

/// Issue #4: the API base URL comes from the build configuration via Info.plist, and
/// `EVA_API_BASE_URL` still overrides it.
///
/// These tests are hosted in the Eva app process (`TEST_HOST` in mobile/project.yml),
/// so `Bundle.main` is the app bundle and `EVAAPIBaseURL` is the value the running app
/// actually resolves. The UI tests always supply the override, so without this suite
/// nothing exercises the configured value at all.
@Suite("Issue #4 API base URL resolution")
struct APIBaseURLTests {

    @Test("The launch environment override wins over the bundled value")
    func environmentOverrideWins() {
        let url = APIClient.resolveBaseURL(
            environment: ["EVA_API_BASE_URL": "http://127.0.0.1:9999"]
        )
        #expect(url.absoluteString == "http://127.0.0.1:9999")
    }

    @Test("An empty override is treated as unset")
    func emptyOverrideFallsThrough() {
        // `FOO= cmd` is how a shell says "not set"; it must not strand the app on a URL
        // it can't request.
        let url = APIClient.resolveBaseURL(environment: ["EVA_API_BASE_URL": ""])
        #expect(url.absoluteString == APIClient.resolveBaseURL(environment: [:]).absoluteString)
    }

    @Test("Without an override the value comes from Info.plist")
    func fallsBackToTheBundledValue() {
        let bundled = Bundle.main.object(forInfoDictionaryKey: APIClient.baseURLInfoKey) as? String
        #expect(bundled != nil, "EVAAPIBaseURL missing — check EVA_API_BASE_URL_DEFAULT in project.yml")
        #expect(APIClient.resolveBaseURL(environment: [:]).absoluteString == bundled)
    }

    @Test("The bundled value is a fully substituted absolute URL")
    func bundledValueIsSubstituted() {
        let bundled = Bundle.main.object(forInfoDictionaryKey: APIClient.baseURLInfoKey) as? String
        // Catches the build-setting name being wrong: Info.plist substitution leaves the
        // literal `$(…)` behind rather than failing the build.
        #expect(bundled?.contains("$(") == false)
        let url = APIClient.resolveBaseURL(environment: [:])
        #expect(url.scheme == "http" || url.scheme == "https")
        #expect(url.host() != nil)
    }

    #if DEBUG
    @Test("A Debug build points at the local API")
    func debugTargetsLocalhost() {
        #expect(APIClient.resolveBaseURL(environment: [:]).absoluteString == "http://localhost:3003")
    }
    #endif
}
