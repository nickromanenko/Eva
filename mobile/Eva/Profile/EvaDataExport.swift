import CoreTransferable
import Foundation
import UniformTypeIdentifiers

/// The user's data export (#58), as the bytes `GET /me/export` returned and the name to
/// save them under.
///
/// `Transferable` so `.fileExporter` can write it straight to wherever the user chooses.
/// That is also why there is no temporary file of Eva's to clean up: the bytes live in
/// memory until the exporter has written them, and the one copy that reaches disk is the
/// one the user asked for. This is the user's entire health record — a stray copy in
/// `tmp/` that outlives the moment would be exactly the leak the issue's Risks section
/// describes.
struct EvaDataExport: Sendable, Transferable {

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

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .json) { $0.data }
            .suggestedFileName { $0.filename }
    }
}
