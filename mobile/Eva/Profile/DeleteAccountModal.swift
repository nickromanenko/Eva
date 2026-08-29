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
/// ## Three departures from the artboard, all decided on #55
///
/// **The copy.** The artboard says deletion happens "within 30 days". It does not:
/// `DELETE /me` (#8) removes the account and its subcollections immediately. DESIGN.md
/// §8 asks us to describe rather than soften, and softening what an irreversible action
/// does is the worst place to do it. The body says "straight away".
///
/// **No "Export data instead" button and no "Export your data first" card.** There is no
/// export feature. A button that does nothing, sitting above an irreversible action,
/// reads as an offered way out and is not one. Tracked as #58; the card and the button
/// come back together when export exists.
///
/// **The card is `EvaRadius.card` (24), not the artboard's 26**, and its padding is
/// `EvaSpacing.lg` (24), not 22. Neither 26 nor 22 is a named token, and adding one for
/// a single modal is a design decision rather than a transcription.
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

            confirmationField
                .padding(.top, EvaSpacing.xxs)

            if let errorMessage {
                errorRow(errorMessage)
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
    private func errorRow(_ message: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: EvaSpacing.xxs) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.evaError)
                .accessibilityHidden(true)
            Text(message)
                .evaTextStyle(.error)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("delete.error")
        }
        .foregroundStyle(Color.evaErrorInk)
    }

    /// Confirm above Cancel, stacked, as the artboard draws them.
    ///
    /// The confirm button uses `EvaDestructiveButtonStyle` directly rather than
    /// `DestructiveButton`, for its identifier: the wrapper derives one from the title,
    /// and the title here is the same "Delete profile" the danger card behind this modal
    /// already carries. Two elements answering to `destructive.Delete profile`, one of
    /// them behind a scrim, is a trap for the tests that navigate by them.
    private var actions: some View {
        VStack(spacing: EvaSpacing.xs) {
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

    private func confirm() {
        guard isConfirmed, !isDeleting else { return }
        isFieldFocused = false
        isDeleting = true
        errorMessage = nil
        Task {
            do {
                try await session.deleteAccount()
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
}

#Preview("Delete account") {
    ZStack {
        EvaScreenBackground().ignoresSafeArea()
        DeleteAccountModal(session: AppSession()) {}
    }
}
