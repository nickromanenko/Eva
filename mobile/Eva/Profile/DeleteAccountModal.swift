import SwiftUI

/// The confirmation in front of `DELETE /me` — "Eva App.dc.html", rail item
/// **Delete profile**, the `isDeleteModal` block.
///
/// A centred card on a `rgba(40,33,38,.38)` scrim: title, what deletion actually does,
/// a field that has to be typed into, the §5 solid destructive (which exists for exactly
/// this and nowhere else), and Cancel as a text button.
///
/// **The typed word is the mechanism, not the decoration.** A confirmation you can tap
/// through by reflex in front of something irreversible is worse than no confirmation,
/// which is what #55's Risks section says. `isConfirmed` is the only thing that enables
/// the confirm button.
///
/// ## Departures from the artboard, decided on #55 and #58
///
/// **The copy.** The artboard says deletion happens "within 30 days". It does not:
/// `DELETE /me` (#8) removes the account and its subcollections immediately. DESIGN.md
/// §8 asks us to describe rather than soften, and softening what an irreversible action
/// does is the worst place to do it. The body says "straight away".
///
/// ## Export, restored on #58
///
/// #55 dropped the artboard's "Export your data first" card and its "Export data instead"
/// button, because there was no export and an inert way out sitting above an irreversible
/// action is worse than none. `GET /me/export` exists now, so both are back where the
/// original artboard drew them — the card under the body, the button first in the
/// action stack. The canvas' `SPEC.danger` note says exactly this: the button "returns to
/// this modal when #58 ships".
///
/// **Offering export changes nothing about reaching deletion.** The button does not
/// dismiss the modal, does not clear the typed word, and does not disable the confirm
/// button while it runs: the delete path is the same taps it was before. Only the
/// reverse holds — export is disabled while a deletion is in flight, because a file that
/// arrives after the account is gone is a request against an account that no longer
/// exists.
///
/// The file goes through `.fileExporter`, not a share sheet: the export is the user's
/// entire health record, and the exporter's one destination — a place the user picks in
/// Files — is the least surprising thing to do with it. The bytes stay in memory until
/// the exporter writes them and are dropped as soon as it finishes or is dismissed, so
/// Eva leaves no temporary copy behind (`EvaDataExport`).
///
/// **The card's inks are §2's Success tokens.** The artboard draws it
/// `rgba(205,231,157,.26)` / `rgba(142,173,86,.3)` / `#5C7434`; the tint is
/// `evaSuccessTint` exactly, and the border and ink take `evaSuccessBorder` (.32) and
/// `evaSuccessInk` (`#4F6630`). Its 16pt radius is `EvaRadius.control` (17), its 12/14
/// padding `EvaSpacing.sm`/`.md`, and its `500 12.5px/1.5` text the Caption row (12.5/19,
/// weight 400) — the scale has no medium caption.
///
/// **The card is `EvaRadius.card` (24), not the artboard's 26**, and its padding is
/// `EvaSpacing.lg` (24), not 22. Neither 26 nor 22 is a named token, and adding one for
/// a single modal is a design decision rather than a transcription.
///
/// ## Apple revocation, added on #7
///
/// An app that offers **both** Sign in with Apple and in-app account deletion has to
/// revoke Apple's token when the account goes, and App Review checks it. Eva deliberately
/// stores no Apple refresh token, so there is nothing on the server to revoke with — the
/// code has to be obtained at the moment of deletion, from a fresh authorization.
///
/// So when the account has Apple attached, confirming runs
/// `AppleSignInController.reauthorizationCode()` first and sends what it returns in the
/// `DELETE /me` body. The modal says this will happen, above the button, because a system
/// sheet appearing unannounced in the middle of deleting an account reads as the app
/// asking you to sign in to something.
///
/// **Cancelling that step does not stop the deletion.** If Apple's sheet is dismissed, or
/// the authorization fails, the account is deleted without a code. The user asked for
/// their data to be destroyed and typed a word to prove it; a provider handshake is not
/// allowed to be what stands between them and that. The cost is a token that stays
/// unrevoked, which is Eva's problem with Apple, not the user's with Eva.
///
/// ## The gap this does not close
///
/// If `deleteAccount()` fails with `APIError.sessionExpired`, `AppSession` signs out
/// before the error reaches the `catch` here, the root view swaps to onboarding, and
/// this modal goes with the screen that presented it — so the user sees a signed-out app
/// for an account that was **not** deleted. Filed separately. What this view guarantees
/// is only that it never *claims* success in that path: the success branch is reached
/// solely by `deleteAccount()` returning, and it says nothing at all.
struct DeleteAccountModal: View {

    let session: AppSession
    /// Dismisses the modal. Only Cancel calls it — a successful deletion tears the whole
    /// screen down instead, and a failure has to leave the modal standing.
    let onCancel: () -> Void

    @State private var confirmation = ""
    @State private var errorMessage: String?
    @State private var isDeleting = false

    @State private var exportErrorMessage: String?
    @State private var isExporting = false
    /// The fetched export, held only between the response and the exporter finishing.
    @State private var export: EvaDataExport?
    @State private var isExporterPresented = false
    @State private var exportTask: Task<Void, Never>?

    @FocusState private var isFieldFocused: Bool

    /// The word the field has to contain. Not localised, deliberately: the API, the
    /// artboard's placeholder and this comparison are the same six characters.
    private static let confirmationWord = "DELETE"

    /// **Case-sensitive, and tolerant of leading and trailing whitespace.**
    ///
    /// The artboard says only "Type DELETE to confirm", so both halves are decisions.
    ///
    /// Case-sensitive because the field does not autocapitalize: reaching capitals costs
    /// a deliberate shift, and that cost *is* the gate. Accepting "delete" would let the
    /// same reflex that taps through a dialog type through this one.
    ///
    /// Whitespace-tolerant because a leading or trailing space is an artefact of the
    /// keyboard, not a sign of hesitation — the user typed the word. Refusing it leaves a
    /// button that stays disabled with `DELETE` visibly in the field, which reads as a
    /// bug and teaches nothing. Nothing *inside* the word is trimmed, so "DEL ETE" is
    /// still not a confirmation.
    private var isConfirmed: Bool {
        confirmation.trimmingCharacters(in: .whitespacesAndNewlines) == Self.confirmationWord
    }

    var body: some View {
        ZStack {
            Color.evaPrimaryText
                .opacity(DeleteAccountModalSurface.scrimOpacity)
                .ignoresSafeArea()

            // The artboard centres the card in the frame. A scroll view keeps it whole
            // with the keyboard up and at accessibility text sizes, and `minHeight`
            // against the container is what keeps it centred while it still fits —
            // scroll content aligns to the top otherwise.
            GeometryReader { proxy in
                ScrollView {
                    card
                        .padding(EvaSpacing.lg)
                        .frame(minHeight: proxy.size.height, alignment: .center)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
        }
        .fileExporter(
            isPresented: $isExporterPresented,
            item: export,
            contentTypes: [.json],
            defaultFilename: export?.filename,
            onCompletion: exportFinished,
            onCancellation: { export = nil }
        )
        // Cancel tears the modal down with a request possibly still open. Its answer would
        // land on a view that is gone; cancelling it is cheaper than letting it arrive.
        .onDisappear { exportTask?.cancel() }
    }

    // MARK: - The card

    private var card: some View {
        VStack(alignment: .leading, spacing: EvaSpacing.sm) {
            Text("Delete your Eva profile?")
                .evaTextStyle(.h3)
                .foregroundStyle(Color.evaPrimaryText)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("delete.title")

            Text(
                "This deletes your account and everything in it — your cycle history, "
                    + "logs and notes — from Eva's servers straight away. It cannot be undone."
            )
            .evaTextStyle(.caption)
            .foregroundStyle(Color.evaSecondaryText)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("delete.body")

            exportCard
                .padding(.top, EvaSpacing.xxs)

            if revokesApple {
                appleRevocationNote
            }

            confirmationField
                .padding(.top, EvaSpacing.xxs)

            if let exportErrorMessage {
                errorRow(exportErrorMessage, identifier: "delete.exportError")
            }

            if let errorMessage {
                errorRow(errorMessage, identifier: "delete.error")
            }

            actions
                .padding(.top, EvaSpacing.xxs)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(EvaSpacing.lg)
        .evaGlass(.sheet, in: DeleteAccountModalSurface.shape)
        .overlay {
            DeleteAccountModalSurface.shape
                .strokeBorder(
                    Color.white.opacity(DeleteAccountModalSurface.borderOpacity),
                    lineWidth: 1
                )
        }
        .shadow(
            color: DeleteAccountModalSurface.shadowColor,
            radius: DeleteAccountModalSurface.shadowRadius,
            x: 0,
            y: DeleteAccountModalSurface.shadowOffsetY
        )
    }

    /// The artboard's green note — export is the thing to do *before* this, not instead of
    /// reading the rest of the modal. Text only: the button that acts on it is in the
    /// action stack, where the artboard puts it.
    private var exportCard: some View {
        Text("Export your data first — one file, readable outside Eva.")
            .evaTextStyle(.caption)
            .foregroundStyle(Color.evaSuccessInk)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, EvaSpacing.sm)
            .padding(.horizontal, EvaSpacing.md)
            .background(Color.evaSuccessTint, in: DeleteAccountModalSurface.exportCardShape)
            .overlay {
                DeleteAccountModalSurface.exportCardShape
                    .strokeBorder(Color.evaSuccessBorder, lineWidth: 1)
            }
            .accessibilityIdentifier("delete.exportNote")
    }

    /// Whether confirming will ask Apple for a fresh authorization first.
    ///
    /// Read from the session's user rather than remembered: an account whose
    /// `authProviders` this build could not read has an empty list, so this is `false` and
    /// deletion simply proceeds without a code — the safe direction, and the one that
    /// keeps an older API from putting a sheet in front of the user for no reason.
    private var revokesApple: Bool {
        session.user?.isConnected(.apple) == true
    }

    /// Says the sheet is coming, and that it is optional.
    ///
    /// The artboard has nothing here — the whole revocation step postdates it. This takes
    /// the §2 Information treatment, which is the tone for "here is how this works": no
    /// warning, nothing went wrong, and nothing about it changes what the button does.
    private var appleRevocationNote: some View {
        EvaInfoBanner(
            title: "Apple will ask you to confirm",
            message: "So Eva can remove its access to your Apple ID. You can dismiss it — "
                + "your profile is deleted either way."
        )
        .accessibilityIdentifier("delete.appleNote")
    }

    /// The gate.
    ///
    /// Every input assist that could type the word for the user, or argue with them
    /// while they do, is off: no autocapitalization (the shift presses are the point),
    /// no autocorrection — which also takes inline predictions and the spell checker
    /// with it — and no `textContentType`, so QuickType has nothing to offer from the
    /// address book. The ASCII keyboard keeps the six characters reachable in one plane.
    private var confirmationField: some View {
        EvaInputField(
            label: "Type \(Self.confirmationWord) to confirm",
            placeholder: Self.confirmationWord,
            isFocused: isFieldFocused
        ) { prompt in
            TextField("Type \(Self.confirmationWord) to confirm", text: $confirmation, prompt: prompt)
                .keyboardType(.asciiCapable)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($isFieldFocused)
                // Return dismisses the keyboard; it does **not** confirm. Submitting
                // from here would collapse the gate into a single keystroke: with
                // `DELETE` typed, the key in the corner — labelled "done" — would
                // destroy the account, and the likeliest reason to press it is wanting
                // the keyboard out of the way to see the button it replaces. The gate is
                // two deliberate acts, type the word and then press the destructive
                // button, or it is not a gate. Found by the #55 security review.
                .submitLabel(.done)
                .onSubmit { isFieldFocused = false }
                .accessibilityIdentifier("delete.confirmation")
        }
        .disabled(isDeleting)
    }

    /// The failure, where the artboard has nothing — it draws no error state for this
    /// modal, and `DELETE /me` can fail. It takes the §2 Error treatment the input field
    /// uses, mark and all, but sits above the buttons rather than under the field: what
    /// failed is the request, not what was typed.
    ///
    /// Export failures use the same row under their own identifier, so a test can tell
    /// "the export failed" from "the deletion failed".
    private func errorRow(_ message: String, identifier: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: EvaSpacing.xxs) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.evaError)
                .accessibilityHidden(true)
            Text(message)
                .evaTextStyle(.error)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier(identifier)
        }
        .foregroundStyle(Color.evaErrorInk)
    }

    /// Export, then confirm, then Cancel, stacked, as the artboard draws them.
    ///
    /// The confirm button uses `EvaDestructiveButtonStyle` directly rather than
    /// `DestructiveButton`, for its identifier: the wrapper derives one from the title,
    /// and the title here is the same "Delete profile" the danger card behind this modal
    /// already carries. Two elements answering to `destructive.Delete profile`, one of
    /// them behind a scrim, is a trap for the tests that navigate by them.
    private var actions: some View {
        VStack(spacing: EvaSpacing.xs) {
            // The §5 secondary glass, which is what the artboard's white-on-hairline
            // button is. Built from the style rather than `SecondaryButton` for the same
            // reason as confirm below: it needs a loading label.
            Button(action: startExport) {
                if isExporting {
                    ProgressView().tint(Color.evaPrimaryText)
                } else {
                    Text("Export data instead")
                }
            }
            .buttonStyle(EvaSecondaryButtonStyle())
            .disabled(isExporting || isDeleting)
            .accessibilityLabel(Text("Export data instead"))
            .accessibilityValue(isExporting ? Text("Preparing your file") : Text(""))
            .accessibilityHint(Text("Saves everything in your account as one file you choose where to keep."))
            .accessibilityIdentifier("delete.export")

            Button(action: confirm) {
                if isDeleting {
                    ProgressView().tint(Color.evaTextOnDark)
                } else {
                    Text("Delete profile")
                }
            }
            .buttonStyle(EvaDestructiveButtonStyle(kind: .solid, isLoading: isDeleting))
            .disabled(!isConfirmed || isDeleting)
            // The label is a spinner while the request is in flight, so the title has to
            // be spoken from here — the same arrangement `PrimaryButton` uses.
            .accessibilityLabel(Text("Delete profile"))
            .accessibilityIdentifier("delete.confirm")

            TextButton(title: "Cancel", action: onCancel)
                .disabled(isDeleting)
        }
    }

    // MARK: - Behaviour

    private func startExport() {
        guard !isExporting, !isDeleting else { return }
        isFieldFocused = false
        isExporting = true
        exportErrorMessage = nil
        exportTask = Task {
            defer { isExporting = false }
            do {
                let fetched = try await session.exportData()
                guard !Task.isCancelled else { return }
                export = fetched
                isExporterPresented = true
            } catch {
                guard !Task.isCancelled else { return }
                exportErrorMessage = Self.exportFailureMessage(for: error)
            }
        }
    }

    /// Whatever the outcome, the bytes are released here: once the exporter has written
    /// the file — or failed to — there is no reason for the record to stay in memory.
    private func exportFinished(_ result: Result<URL, any Error>) {
        export = nil
        if case .failure = result {
            exportErrorMessage = "Your export wasn't saved. Try again."
        }
    }

    /// What an export failure says, in §8's voice: what happened and what to do next.
    ///
    /// A `429` gets words of its own rather than the server's message, which is written for
    /// the auth screens ("Too many attempts") and would read here as if something had been
    /// guessed. The window is given as a time of day when the server sent one — a clock
    /// time survives the user switching apps, where a countdown would not.
    static func exportFailureMessage(for error: any Error, timeZone: TimeZone = .current) -> String {
        guard let apiError = error as? APIError else {
            return "Your export couldn't be prepared. Try again."
        }
        switch apiError {
        case .rateLimited(_, let retryAt):
            let base = "You've asked for several exports in a short time."
            guard let retryAt else { return "\(base) Try again later." }
            var format = Date.FormatStyle(date: .omitted, time: .shortened)
            format.timeZone = timeZone
            return "\(base) Try again after \(retryAt.formatted(format))."
        case .server(_, _, let status) where status == 503:
            return "Your export can't be prepared right now. Try again in a few minutes."
        case .network:
            return apiError.localizedDescription
        // The only `.decoding` an export produces: a 200 whose body stopped early.
        case .decoding:
            return "Eva couldn't finish preparing your file. Try again."
        default:
            return "Your export couldn't be prepared. Try again."
        }
    }

    private func confirm() {
        guard isConfirmed, !isDeleting else { return }
        isFieldFocused = false
        isDeleting = true
        errorMessage = nil
        Task {
            do {
                // Ahead of the delete, and never allowed to stop it. `try?` folds a
                // cancellation (`nil`) and a failed authorization (a throw) into the same
                // answer — no code — because from here they mean the same thing: delete
                // the account, and tell Apple later or not at all.
                var appleCode: String?
                if revokesApple {
                    appleCode = try? await AppleSignInController.shared.reauthorizationCode()
                }
                try await session.deleteAccount(appleAuthorizationCode: appleCode)
                // Nothing to do and nothing to say. `AppSession` has already cleared the
                // Keychain and moved to `.signedOut`, so `EvaRootView` swaps to
                // onboarding and this modal goes with the screen that presented it.
                // `isDeleting` deliberately stays true through that teardown: releasing
                // it would flash an enabled confirm button on the way out.
            } catch {
                errorMessage = error.localizedDescription
                isDeleting = false
            }
        }
    }
}

/// The artboard's elevated modal surface, which has no named expression yet.
///
/// L3 glass is the §4 level for a modal and carries the fill; the scrim, the 95% white
/// border and the drop shadow are read straight from `isDeleteModal` and have no tokens.
/// They live here rather than inline so the modal's body stays readable — and so that if
/// a second modal ever wants them, the move into `EvaGlass.swift` is one step. That move
/// is a design decision, so it is reported rather than taken.
///
/// The artboard's two decorative radial glows (pink at the top-left, pistachio at the
/// right) are not drawn: `EvaScreenBackground`'s glow is private to that file, and
/// reproducing it here would be a second implementation of a decorative effect.
private enum DeleteAccountModalSurface {

    /// `background:rgba(40,33,38,.38)` — Primary Text is `#282126`.
    static let scrimOpacity: Double = 0.38

    /// `border:1px solid rgba(255,255,255,.95)`. Brighter than the §4 card's 72%
    /// hairline, which is what lifts the modal off the scrim.
    static let borderOpacity: Double = 0.95

    /// `box-shadow:0 24px 50px -20px rgba(40,33,38,.5)`. CSS blur 50 → SwiftUI radius
    /// 25; the −20 spread has no SwiftUI expression, the same limit `EvaGlass.swift`'s
    /// card shadow hits, so this renders wider and softer than the artboard.
    static let shadowColor = Color.evaPrimaryText.opacity(0.5)
    static let shadowRadius: CGFloat = 25
    static let shadowOffsetY: CGFloat = 24

    static var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: EvaRadius.card, style: .continuous)
    }

    /// The export note's `border-radius:16px`, on the nearest named radius.
    static var exportCardShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: EvaRadius.control, style: .continuous)
    }
}

#Preview("Delete account") {
    ZStack {
        EvaScreenBackground().ignoresSafeArea()
        DeleteAccountModal(session: AppSession()) {}
    }
}
