import SafariServices
import SwiftUI

/// A banner's article, in `SFSafariViewController` (#102).
///
/// Until the Learn tab and the Blog reader exist (PRD §Blog, not yet specified), a banner
/// opens its web article — #10's instruction, and #102's "tap opens the URL in
/// `SFSafariViewController` or equivalent". Safari rather than a `WKWebView` of our own:
/// it is a system framework (no dependency, GUARDRAILS 25), it shares nothing with the app
/// process — no cookies, no JavaScript bridge, no way for the page to reach the session —
/// and it carries its own address bar, so the reader can see she has left Eva's reviewed
/// words for a web page. That last point is #102's third Risk: the web view is the one
/// place on Home that leaves the app's tone rules.
///
/// Only ever handed an `EvaTodayBanner.url`, which decoding has already limited to
/// absolute `https://` — `SFSafariViewController` raises an exception for any other scheme.
struct ArticleSafariView: UIViewControllerRepresentable {

    let url: URL
    /// Called when the reader taps Done. The controller cannot dismiss a SwiftUI
    /// presentation itself, so the presenter clears its own state here.
    let onDone: () -> Void

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let controller = SFSafariViewController(url: url)
        // The app's own action ink on Safari's bar buttons, so Done reads as part of Eva.
        controller.preferredControlTintColor = UIColor(Color.evaActionPinkTop)
        controller.dismissButtonStyle = .done
        controller.delegate = context.coordinator
        return controller
    }

    /// Nothing to update: a new article is a new presentation, keyed by the banner's id.
    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onDone: onDone) }

    /// `@preconcurrency`: SafariServices does not annotate its delegate, and UIKit calls it
    /// on the main thread — the conformance asserts that rather than hopping.
    @MainActor
    final class Coordinator: NSObject, @preconcurrency SFSafariViewControllerDelegate {
        let onDone: () -> Void

        init(onDone: @escaping () -> Void) { self.onDone = onDone }

        func safariViewControllerDidFinish(_ controller: SFSafariViewController) {
            onDone()
        }
    }
}

#Preview {
    ArticleSafariView(url: URL(string: "https://example.com")!) {}
        .ignoresSafeArea()
}
