import Foundation
import Testing
@testable import Eva

/// Issue #46: **the built bundle carries the commit, not the `project.yml` floor.**
///
/// `CURRENT_PROJECT_VERSION` is `1` and never moves; the real number is written into the
/// *built* `Info.plist` by the "Stamp build number and commit SHA" post-build phase in
/// mobile/project.yml. These tests are hosted in the Eva app process (`TEST_HOST`), so
/// `Bundle.main` is that built bundle — the same bytes an archive would upload.
///
/// The regression to catch is the stamp silently doing nothing. It has already happened
/// once: the phase ran before `Process Info.plist`, the plist processor overwrote it, and
/// the build log still said `note: stamped CFBundleVersion=35`. Nothing in the build
/// failed, and nothing in the bundle looked wrong — the same shape of invisibility as #42
/// and #4. Only reading the bundle back catches it.
///
/// **Unconditional, deliberately.** A source export with no `.git` legitimately produces
/// `1` / `unstamped`, and these tests fail there. That is accepted rather than guarded,
/// because a no-git export and a broken stamp leave *byte-identical* values in the
/// bundle: any guard able to excuse the first would excuse the second, and would go quiet
/// exactly when the bug is present. Tests are run from the repo, where git is the premise.
@Suite("Issue #46 build number and commit stamp")
struct BuildStampTests {

    /// Anything the stamp legitimately writes: a short SHA, optionally marked dirty.
    /// Built per call — `Regex` is not `Sendable`, so it cannot be a stored static.
    private func isShortSHA(_ value: String) -> Bool {
        value.wholeMatch(of: /[0-9a-f]{7,40}(-dirty)?/) != nil
    }

    @Test("CFBundleVersion is a stamped commit count, not the CURRENT_PROJECT_VERSION floor")
    func buildNumberIsStamped() {
        let raw = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        #expect(raw != nil, "CFBundleVersion missing from the built bundle")
        // Substitution failure leaves the literal `$(…)` rather than failing the build.
        #expect(raw?.contains("$(") == false)

        let number = raw.flatMap(Int.init)
        #expect(number != nil, "CFBundleVersion \(raw ?? "nil") is not an integer")
        // `1` is exactly what an unstamped build carries: the floor in project.yml.
        #expect(
            (number ?? 1) > 1,
            "CFBundleVersion is \(raw ?? "nil") — the stamp phase did not reach the built Info.plist"
        )
    }

    @Test("EvaGitSHA names the commit this bundle was built from")
    func commitIsStamped() {
        let sha = Bundle.main.object(forInfoDictionaryKey: "EvaGitSHA") as? String
        #expect(sha != nil, "EvaGitSHA missing from the built bundle")
        // The placeholder that ships in the tracked Eva/Info.plist. Seeing it here means
        // the phase did not run, ran too early, or failed to write.
        #expect(sha != "unstamped", "EvaGitSHA is still the placeholder — nothing stamped it")
        #expect(
            sha.map(isShortSHA) == true,
            "EvaGitSHA \(sha ?? "nil") is not a short SHA"
        )
    }

    /// Not a duplicate of the two above: they would both pass on a bundle stamped with a
    /// number from one build and a SHA from another. The stamp writes both or neither.
    @Test("The two stamped keys agree that a stamp happened")
    func bothKeysStampedTogether() {
        let number = (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String)
            .flatMap(Int.init)
        let sha = Bundle.main.object(forInfoDictionaryKey: "EvaGitSHA") as? String
        #expect(
            ((number ?? 1) > 1) == (sha != "unstamped"),
            "CFBundleVersion \(number.map(String.init) ?? "nil") and EvaGitSHA \(sha ?? "nil") disagree about whether the stamp ran"
        )
    }
}
