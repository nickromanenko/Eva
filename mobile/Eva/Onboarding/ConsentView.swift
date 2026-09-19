import SwiftUI

/// The version of the consent text this build displays — the "Consent v1 · 2026-08-30"
/// line the screen's footer carries. The app compares it against the version recorded on
/// `users/{uid}.consent` to decide whether the screen is owed (`APIUser.needsConsentGate`),
/// and sends it with the grant, because the record's whole value is being able to say
/// which text she agreed to. A change to the copy on this screen is a change to this
/// string, in the same PR, and re-prompts every account.
enum ConsentPolicy {
    static let version = "2026-08-30"
}

/// The consent screen (A21, #86) — the canvas' `consent` artboard, drawn between
/// authentication and the app.
///
/// Washington's My Health My Data Act and GDPR Article 9 both want explicit, separate,
/// withdrawable consent **before** health data is collected, and A21 applies the
/// strictest rule worldwide: one screen, two opt-ins, neither pre-selected, no
/// agree-to-all. The server enforces the same line from the other side — every
/// health-write route refuses `403 CONSENT_REQUIRED` until `consent.collect` exists — so
/// this screen is the way in, not the enforcement.
///
/// ## What the canvas draws, and where this rounds it off
///
/// * **The first toggle is required to use Eva; the second is hers either way.** The
///   canvas blocks Continue without the store toggle and toasts
///   "Eva needs the first choice to work. The second is yours either way." — that toast
///   text is kept verbatim, drawn as an inline message rather than a `EvaToast`, because
///   §7 reserves the toast for what *has* happened and this says what will not.
/// * **The processors list omits the canvas' two `[pending]` vendors.** A shipped screen
///   cannot show "assistant vendor — pending" as if it were a fact; the list grows when
///   the vendors do, alongside the privacy policy they are named in (L3, still with
///   counsel).
/// * **"Read the health-data privacy policy" is plain text.** The site has no configured
///   public URL for the app to open — the same limit the sign-up screen's footer lives
///   with — so the sentence is stated without promising a link it cannot open.
/// * **No log out.** The screen is reached with a session already granted (`AppSession`
///   routes here *after* the server has validated the token), so the auth screens' exits
///   do not apply; the way out of a consent she will not give is the same place she
///   withdraws one later — Settings › Privacy — plus the account-level exits that already
///   exist on Profile.
struct ConsentView: View {
    let session: AppSession

    /// The two toggles, both off. Neither is ever set from code before she touches it:
    /// a pre-selected consent is not consent (A21).
    @State private var storeConsent = false
    @State private var shareConsent = false
    /// Set when Continue is tapped without the store toggle. Cleared the moment she
    /// turns it on — the message describes the state, and the state has changed.
    @State private var needsFirstChoice = false
    @State private var processorsOpen = false
    @State private var isSubmitting = false
    @State private var submissionError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: EvaSpacing.lg) {
                VStack(alignment: .leading, spacing: EvaSpacing.sm) {
                    Text("Before you start")
                        .evaTextStyle(.h1)
                        .foregroundStyle(Color.evaPrimaryText)
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityIdentifier("consent.title")

                    Text(
                        "Two choices, both yours. Neither is on until you turn it on, "
                            + "and you can change either later in Settings › Privacy."
                    )
                    .evaTextStyle(.body)
                    .foregroundStyle(Color.evaSecondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("consent.subtitle")
                }

                VStack(alignment: .leading, spacing: EvaSpacing.sm) {
                    consentCard(
                        title: "Store my health entries so Eva can work",
                        body: "Cycle days, symptoms, notes and appointments, kept under "
                            + "your account. Required to use Eva.",
                        isOn: $storeConsent,
                        identifier: "consent.store"
                    )

                    consentCard(
                        title: "Let trusted providers process my entries",
                        body: "",
                        isOn: $shareConsent,
                        identifier: "consent.share"
                    ) {
                        Text(
                            "The services that run Eva — hosting, email, food data, the "
                                + "assistant. Never advertisers."
                        )
                        .evaTextStyle(.caption)
                        .foregroundStyle(Color.evaSecondaryText)
                        .fixedSize(horizontal: false, vertical: true)

                        Button(processorsOpen ? "Hide" : "Who?") {
                            processorsOpen.toggle()
                        }
                        .evaTextStyle(.caption)
                        .foregroundStyle(Color.evaDeepPink)
                        .accessibilityIdentifier("consent.processors")

                        if processorsOpen {
                            Text(
                                "Google Cloud (hosting, US) · Postmark (email) · Apple "
                                    + "(purchases). Each under a data-processing agreement."
                            )
                            .evaTextStyle(.caption)
                            .foregroundStyle(Color.evaInformationInk)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(EvaSpacing.sm)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                Color.evaInformationTint,
                                in: .rect(cornerRadius: EvaRadius.control, style: .continuous)
                            )
                            .accessibilityIdentifier("consent.processorList")
                        }
                    }
                }

                if needsFirstChoice {
                    Text("Eva needs the first choice to work. The second is yours either way.")
                        .evaTextStyle(.inputHelper)
                        .foregroundStyle(Color.evaInformationInk)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("consent.message")
                }

                if let submissionError {
                    Text(submissionError)
                        .evaTextStyle(.inputHelper)
                        .foregroundStyle(Color.evaDestructiveInk)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("consent.error")
                }

                Text("Consent v1 · \(ConsentPolicy.version). If the terms change, Eva asks again.")
                    .evaTextStyle(.caption)
                    .foregroundStyle(Color.evaMutedText)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("consent.footer")

                // `PrimaryButton` identifies its buttons "primary.\(title)" itself —
                // the screen's Continue is "primary.Continue" to the tests.
                PrimaryButton(title: "Continue", isLoading: isSubmitting, action: submit)
            }
            .padding(.horizontal, EvaSpacing.lg)
            .padding(.top, EvaSpacing.xl)
            .padding(.bottom, EvaSpacing.xxl)
        }
        .scrollBounceBehavior(.basedOnSize)
        .background {
            EvaScreenBackground().ignoresSafeArea()
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
    }

    /// One glass card: a title, optional body copy, and the toggle on the trailing edge.
    /// The artboard draws both cards as the settings row's glass at 22px radius, which is
    /// `evaCardSurface` at `EvaRadius.card` everywhere else in the app.
    private func consentCard<
        Body: View
    >(
        title: String,
        body: String,
        isOn: Binding<Bool>,
        identifier: String,
        @ViewBuilder extra: () -> Body = { EmptyView() }
    ) -> some View {
        VStack(alignment: .leading, spacing: EvaSpacing.xs) {
            HStack(alignment: .top, spacing: EvaSpacing.sm) {
                VStack(alignment: .leading, spacing: EvaSpacing.xxs) {
                    Text(title)
                        .evaTextStyle(.bodyMedium)
                        .foregroundStyle(Color.evaPrimaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    if !`body`.isEmpty {
                        Text(`body`)
                            .evaTextStyle(.caption)
                            .foregroundStyle(Color.evaSecondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Toggle("", isOn: isOn)
                    .toggleStyle(.switch)
                    .tint(Color.evaDeepPink)
                    .labelsHidden()
                    .accessibilityIdentifier(identifier)
                    .accessibilityLabel(Text(title))
            }

            extra()
        }
        .padding(EvaSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .evaCardSurface()
        .onChange(of: isOn.wrappedValue) {
            if isOn.wrappedValue { needsFirstChoice = false }
        }
    }

    /// Continue, with the canvas' one rule: the store toggle is what Eva needs, the share
    /// toggle is hers either way, and neither grants anything the server has not
    /// recorded — each granted toggle is its own `PUT /me/consent/:kind`.
    private func submit() {
        guard !isSubmitting else { return }
        guard storeConsent else {
            needsFirstChoice = true
            return
        }
        isSubmitting = true
        submissionError = nil
        Task {
            defer { isSubmitting = false }
            do {
                try await session.setConsent(.collect, granted: true)
                if shareConsent {
                    try await session.setConsent(.share, granted: true)
                }
                // The session recomputes its own state from the returned user: a granted
                // collect consent lands in `.ready` and EvaRootView switches to the app.
            } catch {
                submissionError = error.localizedDescription
            }
        }
    }
}

#Preview("Consent") {
    ConsentView(session: AppSession())
}
