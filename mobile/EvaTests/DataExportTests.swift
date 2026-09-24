import Foundation
import Testing
@testable import Eva

/// Issue #58: **the export is fetched as bytes, under the user's own token, and saved
/// under the name the server gave it** — or a safe one when it gave none.
///
/// The body is opaque to the app on purpose, so nothing here asserts on its shape; what
/// is asserted is that the bytes arrive untouched, that the request carried the
/// credential (the issue's last acceptance criterion is that the file is not retrievable
/// without it), and that the failures map the way every other authorized call's do.

/// A body that is valid JSON but deliberately not any model the app knows, so a client
/// that tried to decode it would fail the test rather than pass it.
private let exportBody = #"{"exportedAt":"2026-09-24T10:00:00Z","user":{"id":"u1"},"events":[{"k":1}]}"#

private let serverFilename = "eva-export-2026-09-24.json"

extension SessionExpiryTests {

    /// Nested in `SessionExpiryTests` for the reason `OfflineLaunch` is: that suite is
    /// `.serialized`, and `EvaStubURLProtocol` is one global armed outcome.
    @Suite("Issue #58 · GET /me/export")
    struct DataExportDownload {

        static func client(token: String? = "a-live-looking-token") -> APIClient {
            APIClient(baseURL: EvaStubURLProtocol.baseURL, token: { token })
        }

        @Test("the bytes come back untouched, with the server's file name")
        func returnsBytesAndFilename() async throws {
            EvaStubURLProtocol.stub(
                status: 200,
                body: exportBody,
                headers: [
                    "Content-Disposition": #"attachment; filename="\#(serverFilename)""#,
                    "Cache-Control": "no-store",
                ]
            )

            let download = try await Self.client().download("/me/export", authorized: true)

            #expect(download.data == Data(exportBody.utf8))
            #expect(download.filename == serverFilename)
            #expect(EvaStubURLProtocol.lastAuthorization == "Bearer a-live-looking-token")
            #expect(EvaStubURLProtocol.requestCount(for: .get("/me/export")) == 1)
        }

        @Test("a response with no Content-Disposition saves under the fallback name")
        @MainActor
        func fallsBackWithoutAName() async throws {
            EvaStubURLProtocol.stub(status: 200, body: exportBody)
            let session = AppSession(client: Self.client(), tokenStore: .shared)

            let export = try await session.exportData()

            #expect(export.filename == EvaDataExport.fallbackFilename)
            #expect(export.data == Data(exportBody.utf8))
        }

        /// The route streams, so a Firestore failure mid-export arrives as a 200 whose
        /// body stops before its closing `]}`. That must be a failed export — the modal
        /// only presents the exporter when `exportData()` returns, so a throw here is
        /// what guarantees a truncated file is never offered.
        @Test("a 200 with a truncated body is a failed export, never a file")
        @MainActor
        func truncatedBodyIsAnError() async {
            let truncated = String(exportBody.dropLast(3))
            EvaStubURLProtocol.stub(
                status: 200,
                body: truncated,
                headers: ["Content-Disposition": #"attachment; filename="\#(serverFilename)""#]
            )
            let session = AppSession(client: Self.client(), tokenStore: .shared)

            do {
                let export = try await session.exportData()
                Issue.record("A truncated body was handed back as a \(export.data.count)-byte file")
            } catch APIError.decoding {
                // Expected.
            } catch {
                Issue.record("Threw \(error), not .decoding")
            }
            #expect(
                DeleteAccountModal.exportFailureMessage(for: APIError.decoding)
                    == "Eva couldn't finish preparing your file. Try again."
            )
        }

        /// Through the session, not just the client: the export is inside `authorized(_:)`,
        /// so a dead token on it signs out and clears the Keychain like any other call.
        @Test("a 401 through session.exportData() ends the session")
        @MainActor
        func unauthorizedThroughSessionSignsOut() async {
            let store = KeychainTokenStore.shared
            store.clear()
            store.save("a-live-looking-token")
            defer { store.clear() }
            let session = AppSession(
                client: APIClient(
                    baseURL: EvaStubURLProtocol.baseURL,
                    token: { KeychainTokenStore.shared.token }
                ),
                tokenStore: store
            )
            EvaStubURLProtocol.stub(status: 200, body: ClientMapping.user)
            await session.bootstrap()
            guard case .ready = session.state else {
                Issue.record("The fixture never got signed in (\(session.state)), so nothing below means anything")
                return
            }

            EvaStubURLProtocol.stub(
                status: 401,
                body: #"{"error":{"code":"UNAUTHORIZED","message":"Missing or invalid token"}}"#
            )
            do {
                _ = try await session.exportData()
                Issue.record("A 401 was returned as a file")
            } catch APIError.sessionExpired {
                // Expected.
            } catch {
                Issue.record("Threw \(error), not .sessionExpired")
            }

            #expect(EvaStubURLProtocol.lastAuthorization == "Bearer a-live-looking-token")
            if case .signedOut = session.state {} else {
                Issue.record("A 401 on the export left the app in \(session.state)")
            }
            #expect(store.token == nil, "A dead token was left in the Keychain")
        }

        @Test("a 429 is .rateLimited with its window, like every other route")
        func rateLimited() async {
            EvaStubURLProtocol.stub(
                status: 429,
                body: #"{"error":{"code":"RATE_LIMITED","message":"Too many attempts. Try again later."}}"#,
                headers: ["Retry-After": "600"]
            )

            do {
                _ = try await Self.client().download("/me/export", authorized: true)
                Issue.record("A 429 was returned as a file")
            } catch let error as APIError {
                #expect(error.isRateLimited)
                #expect(error.retryAt != nil)
            } catch {
                Issue.record("Threw \(error), which is not an APIError")
            }
        }

        @Test("a 503 keeps its status, so the modal can say something specific")
        func unavailable() async {
            EvaStubURLProtocol.stub(
                status: 503,
                body: #"{"error":{"code":"UNAVAILABLE","message":"Service unavailable"}}"#
            )

            do {
                _ = try await Self.client().download("/me/export", authorized: true)
                Issue.record("A 503 was returned as a file")
            } catch APIError.server(_, _, let status) {
                #expect(status == 503)
            } catch {
                Issue.record("Threw \(error), not a .server")
            }
        }

        @Test("a 401 on the export is a dead session, like any token-carrying request")
        func unauthorized() async {
            EvaStubURLProtocol.stub(
                status: 401,
                body: #"{"error":{"code":"UNAUTHORIZED","message":"Missing or invalid token"}}"#
            )

            do {
                _ = try await Self.client().download("/me/export", authorized: true)
                Issue.record("A 401 was returned as a file")
            } catch APIError.sessionExpired {
                // Expected.
            } catch {
                Issue.record("Threw \(error), not .sessionExpired")
            }
        }
    }
}

@Suite("Issue #58 · the export's file name")
struct DataExportFilenameTests {

    @Test(
        "the filename parameter is read in the forms the server can send",
        arguments: [
            (#"attachment; filename="eva-export-2026-09-24.json""#, "eva-export-2026-09-24.json"),
            ("attachment; filename=eva-export-2026-09-24.json", "eva-export-2026-09-24.json"),
            (#"attachment;filename="eva.json""#, "eva.json"),
            (#"Attachment; FILENAME="eva.json"; size=10"#, "eva.json"),
        ]
    )
    func readsFilename(header: String, expected: String) {
        #expect(APIClient.filename(fromContentDisposition: header) == expected)
    }

    @Test(
        "a name that would climb out of its folder is cut to its last component",
        arguments: [
            (#"attachment; filename="../../etc/eva.json""#, "eva.json"),
            (#"attachment; filename="..\..\eva.json""#, "eva.json"),
        ]
    )
    func stripsPath(header: String, expected: String) {
        #expect(APIClient.filename(fromContentDisposition: header) == expected)
    }

    @Test(
        "nothing usable is nil, and the caller's fallback applies",
        arguments: [
            nil,
            "attachment",
            #"attachment; filename="""#,
            #"attachment; filename="..""#,
            #"attachment; filename="/""#,
            "inline; name=eva.json",
        ] as [String?]
    )
    func refusesUnusable(header: String?) {
        #expect(APIClient.filename(fromContentDisposition: header) == nil)
        #expect(EvaDataExport(data: Data(), serverFilename: APIClient.filename(fromContentDisposition: header))
            .filename == EvaDataExport.fallbackFilename)
    }
}

@Suite("Issue #58 · what an export failure says")
@MainActor
struct DataExportFailureMessageTests {

    @Test("a 429 with a window names the time to come back")
    func rateLimitedWithWindow() {
        let utc = TimeZone(identifier: "UTC")!
        let at = Date(timeIntervalSince1970: 1_790_000_000)
        var format = Date.FormatStyle(date: .omitted, time: .shortened)
        format.timeZone = utc

        let message = DeleteAccountModal.exportFailureMessage(
            for: APIError.rateLimited(message: "Too many attempts. Try again later.", retryAt: at),
            timeZone: utc
        )

        #expect(message.contains(at.formatted(format)))
        // The server's auth wording reads as if something had been guessed. Not here.
        #expect(!message.contains("attempts"))
    }

    @Test("a 429 with no window still says to wait, without inventing a time")
    func rateLimitedWithoutWindow() {
        let message = DeleteAccountModal.exportFailureMessage(
            for: APIError.rateLimited(message: "x", retryAt: nil)
        )
        #expect(message.hasSuffix("Try again later."))
    }

    @Test("a 503 says it is temporary")
    func unavailable() {
        let message = DeleteAccountModal.exportFailureMessage(
            for: APIError.server(code: "UNAVAILABLE", message: "x", status: 503)
        )
        #expect(message.contains("right now"))
    }

    @Test("no connection says so, in the app's usual words")
    func network() {
        #expect(
            DeleteAccountModal.exportFailureMessage(for: APIError.network)
                == APIError.network.localizedDescription
        )
    }
}

/// The one copy of the export that ever touches this device's disk (#58): the app writes
/// it, protected, into a directory of its own, and removes that directory afterwards.
/// `.fileExporter` was measured leaving its own copy in `tmp/`, which is why
/// this exists at all — see `EvaDataExport`.
@Suite("Issue #58 · the staged export file")
struct DataExportStagingTests {

    let root = FileManager.default.temporaryDirectory
        .appending(path: "DataExportStagingTests-\(UUID().uuidString)", directoryHint: .isDirectory)

    @Test("it is written under the server's name, byte for byte, with complete protection")
    func writesProtectedFile() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let export = EvaDataExport(data: Data(exportBody.utf8), serverFilename: serverFilename)

        let file = try export.stage(in: root)

        #expect(file.lastPathComponent == serverFilename)
        #expect(try Data(contentsOf: file) == Data(exportBody.utf8))
        let protection = try FileManager.default.attributesOfItem(atPath: file.path)[.protectionKey]
            as? FileProtectionType
        // The simulator does not always report a protection class; a device does. What it
        // must never report is a weaker one.
        if let protection {
            #expect(protection == .complete)
        }
    }

    @Test("two exports on the same day do not collide")
    func separateDirectories() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let export = EvaDataExport(data: Data(exportBody.utf8), serverFilename: serverFilename)

        let first = try export.stage(in: root)
        let second = try export.stage(in: root)

        #expect(first != second)
        #expect(first.lastPathComponent == second.lastPathComponent)
    }

    @Test("discard removes the file and its directory, and is safe to repeat")
    func discardRemovesEverything() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try EvaDataExport(data: Data(exportBody.utf8), serverFilename: serverFilename)
            .stage(in: root)

        EvaDataExport.discard(file)
        EvaDataExport.discard(file)

        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(!FileManager.default.fileExists(atPath: file.deletingLastPathComponent().path))
        // Nothing else under the root was touched, and nothing was left in it.
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }
}
