import Foundation

/// The user's data export (#58), as the bytes `GET /me/export` returned and the name to
/// save them under.
///
/// ## Why the app writes the file itself
///
/// This is the user's entire health record, and where copies of it end up is the risk the
/// issue names. SwiftUI's `.fileExporter` was the first choice and was measured out: given
/// a `Transferable` — in-memory `DataRepresentation` or file-backed `FileRepresentation`
/// alike — it stages its own copy at `tmp/<defaultFilename>` when the sheet opens and
/// **leaves it there** after the sheet is dismissed — the app is not told the path, so it
/// cannot remove it, and `tmp/` is only purged when the system chooses to.
///
/// So the app stages the one copy itself (`stage()`), in a directory of its own under
/// `tmp/`, with `.completeFileProtection`, and hands that URL to a document picker in
/// *move* mode (`EvaFileExportPicker`): a save moves the file out, and whatever happens —
/// saved, cancelled, failed — `discard(_:)` removes the directory afterwards.
struct EvaDataExport: Sendable {

    /// Used when the server names no file, or names one this build cannot trust.
    static let fallbackFilename = "eva-export.json"

    let data: Data
    let filename: String

    init(data: Data, serverFilename: String?) {
        self.data = data
        self.filename = serverFilename ?? Self.fallbackFilename
    }

    /// Whether `data` is a whole JSON object — the one test for a body the server could
    /// not finish (`AppSession.exportData()`). Nothing is kept from the parse.
    static func isComplete(_ data: Data) -> Bool {
        (try? JSONSerialization.jsonObject(with: data)) is [String: Any]
    }

    /// Writes the export to a fresh directory under `tmp/` and returns the file's URL.
    ///
    /// A directory per export, rather than the file straight into `tmp/`, so two exports
    /// cannot collide on a name the server chose by date, and so `discard(_:)` can remove
    /// exactly what this made and nothing else.
    func stage(in root: URL = FileManager.default.temporaryDirectory) throws -> URL {
        let directory = root.appending(path: "eva-export-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appending(path: filename, directoryHint: .notDirectory)
        do {
            try data.write(to: file, options: [.withoutOverwriting, .completeFileProtection])
        } catch {
            Self.discard(file)
            throw error
        }
        return file
    }

    /// Removes a file `stage()` made, and its directory. Safe to call after the picker
    /// has already moved the file away, and safe to call twice.
    static func discard(_ stagedFile: URL) {
        try? FileManager.default.removeItem(at: stagedFile.deletingLastPathComponent())
    }
}
