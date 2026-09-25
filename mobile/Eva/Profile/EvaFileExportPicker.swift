import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The system "save to Files" sheet for one file the app has already written — the
/// export's delivery (#58).
///
/// UIKit on purpose: SwiftUI's `.fileExporter` leaves a copy of whatever it exports in
/// `tmp/` (see `EvaDataExport`), and for a user's whole health record that is not
/// acceptable. `UIDocumentPickerViewController(forExporting:asCopy:)` with `asCopy: false`
/// takes the app's own file and **moves** it, so nothing is duplicated on the way out.
///
/// `onFinish` is called once, with `true` when the file was saved and `false` when the
/// sheet was cancelled. Cleanup is the presenter's, in its `onDismiss`, so it also runs
/// for a sheet taken down by any other route.
struct EvaFileExportPicker: UIViewControllerRepresentable {

    let file: URL
    let onFinish: (Bool) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forExporting: [file], asCopy: false)
        picker.delegate = context.coordinator
        picker.shouldShowFileExtensions = true
        return picker
    }

    func updateUIViewController(_ picker: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onFinish: onFinish)
    }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onFinish: (Bool) -> Void

        init(onFinish: @escaping (Bool) -> Void) {
            self.onFinish = onFinish
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            onFinish(true)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onFinish(false)
        }
    }
}

#Preview("Save export") {
    let file = try? EvaDataExport(
        data: Data(#"{"preview":true}"#.utf8),
        serverFilename: "eva-export-2026-09-24.json"
    ).stage()
    if let file {
        EvaFileExportPicker(file: file) { _ in EvaDataExport.discard(file) }
    }
}
