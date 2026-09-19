import SwiftUI

/// Settings › Privacy — where both consent kinds are shown and withdrawn (#86).
///
/// The canvas puts withdrawal here ("Both withdrawable in Settings › Privacy", consent
/// artboard), and this screen is the whole of that promise for now: both kinds with the
/// state each is in, and the one action each state can take. It is a third of what the
/// canvas' privacy row eventually grows into — the health-data privacy policy itself is
/// L3 and still with counsel — and it is built on the same principle `ProfileView` set:
/// grow into the artboard rather than replace it.
///
/// **What withdrawal does is stated before it is asked twice.** The confirm dialog is
/// where the consequence lives, because it is the last thing she reads before the
/// account changes: withdrawing is the *freeze* decided on #86 — nothing new is
/// collected, everything already stored stays until export or account deletion removes
/// it — and a withdrawal that read as "delete my data" would be as wrong as the silent
/// opposite.
struct PrivacySettingsView: View {
    let session: AppSession

    /// Which kind, if any, is waiting on its confirmation. The dialog is bound to this,
    /// so its copy names the kind being withdrawn and a second dialog can never stack on
    /// the first.
    @State private var confirmingWithdrawal: EvaConsentKind?
    @State private var isWorking = false
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: EvaSpacing.lg) {
                consentRow(
                    kind: .collect,
                    title: "Store my health entries",
                    explanation: "Cycle days, symptoms, notes and appointments, kept "
                        + "under your account.",
                    record: session.user?.consent?.collect,
                    identifier: "privacy.collect"
                )

                consentRow(
                    kind: .share,
                    title: "Let trusted providers process my entries",
                    explanation: "The services that run Eva. Never advertisers.",
                    record: session.user?.consent?.share,
                    identifier: "privacy.share"
                )

                if let error {
                    Text(error)
                        .evaTextStyle(.inputHelper)
                        .foregroundStyle(Color.evaDestructiveInk)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("privacy.error")
                }
            }
            .padding(.horizontal, EvaSpacing.lg)
            .padding(.top, EvaSpacing.xs)
            .padding(.bottom, EvaSpacing.xxl)
        }
        .navigationTitle("Privacy")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .background {
            EvaScreenBackground().ignoresSafeArea()
        }
        .confirmationDialog(
            withdrawTitle,
            isPresented: Binding(
                get: { confirmingWithdrawal != nil },
                set: { if !$0 { confirmingWithdrawal = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Withdraw", role: .destructive) {
                withdraw(confirmingWithdrawal)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "Withdrawing stops Eva collecting anything new. What's already stored "
                    + "stays until you delete your account or export it."
            )
        }
    }

    private var withdrawTitle: String {
        switch confirmingWithdrawal {
        case .collect: "Withdraw consent to store your health entries?"
        case .share: "Withdraw consent for providers to process your entries?"
        case nil: ""
        }
    }

    /// One consent kind: its title, the state it is in, and the one action that state
    /// can take. A granted record shows the version she consented to — the fact a policy
    /// change re-prompts on — and withdraws; a withdrawn one offers the way back; an
    /// absent one (the second toggle on the screen she never turned on) offers the grant.
    /// The kind travels with the row rather than being inferred from the record, so the
    /// two call sites cannot be swapped without the compiler noticing.
    private func consentRow(
        kind: EvaConsentKind,
        title: String,
        explanation: String,
        record: APIUserConsentRecord?,
        identifier: String
    ) -> some View {
        VStack(alignment: .leading, spacing: EvaSpacing.sm) {
            VStack(alignment: .leading, spacing: EvaSpacing.xxs) {
                Text(title)
                    .evaTextStyle(.bodyMedium)
                    .foregroundStyle(Color.evaPrimaryText)
                Text(explanation)
                    .evaTextStyle(.caption)
                    .foregroundStyle(Color.evaSecondaryText)
                    .fixedSize(horizontal: false, vertical: true)

                Text(stateLine(record))
                    .evaTextStyle(.caption)
                    .foregroundStyle(Color.evaSecondaryText)
                    .accessibilityIdentifier("\(identifier).state")
            }

            if let record, record.withdrawnAt == nil {
                // `TextButton`/`PrimaryButton` identify themselves from their titles, and
                // both rows here can be in the same state — two "Withdraw"s would be
                // indistinguishable to a test. So the styles are used directly, under
                // this row's own identifier.
                Button("Withdraw") { confirmingWithdrawal = kind }
                    .buttonStyle(EvaTextButtonStyle())
                    .disabled(isWorking)
                    .accessibilityIdentifier("\(identifier).withdraw")
            } else {
                Button {
                    grant(kind)
                } label: {
                    if isWorking {
                        ProgressView()
                            .tint(Color.evaTextOnDark)
                    } else {
                        Text("Turn back on")
                    }
                }
                .buttonStyle(EvaPrimaryButtonStyle(isLoading: isWorking))
                .accessibilityIdentifier("\(identifier).grant")
            }
        }
        .padding(EvaSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .evaCardSurface()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
    }

    /// What the state says, in the screen's own words. "On" and "Paused" are the two
    /// facts the consent record holds: a grant with no withdrawal, and a grant that no
    /// longer holds. "Off" is no record at all — the share toggle she never turned on.
    private func stateLine(_ record: APIUserConsentRecord?) -> String {
        guard let record else { return "Off" }
        let version = "Consent \(record.version)"
        return record.withdrawnAt == nil ? "On · \(version)" : "Paused · \(version)"
    }

    private func withdraw(_ kind: EvaConsentKind?) {
        guard let kind, !isWorking else { return }
        confirmingWithdrawal = nil
        isWorking = true
        error = nil
        Task {
            defer { isWorking = false }
            do {
                try await session.setConsent(kind, granted: false)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func grant(_ kind: EvaConsentKind) {
        guard !isWorking else { return }
        isWorking = true
        error = nil
        Task {
            defer { isWorking = false }
            do {
                try await session.setConsent(kind, granted: true)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

#Preview("Privacy settings") {
    NavigationStack {
        PrivacySettingsView(session: AppSession())
    }
}
