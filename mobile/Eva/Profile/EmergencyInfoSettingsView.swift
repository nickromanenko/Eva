import SwiftUI

/// Settings › Support › Medical and emergency information — the canvas' settings row
/// "Medical and emergency information · When to contact a provider", which used to toast
/// out of scope and is now the screen (#87).
///
/// Three facts, in the order a reader needs them: **which country's** guidance this is
/// and where that comes from, **what to do** when something is wrong (the urgent-care
/// wording the red-flag card shows), and **who else** to reach (the country's support
/// resources, PRD §Pregnancy loss 5). The table behind all three is `refdata/`'s
/// emergency guidance, fetched whole from `GET /refdata`; the screen resolves this
/// device's country against it exactly the way the Home tab's flag card does —
/// `EvaRefData.emergencyGuidance(from:forCountry:)` is the one resolver both read.
///
/// ## The country choice is device-local, and the screen says so
///
/// The override is written to `UserDefaults` on this device and **never sent anywhere**
/// (LAUNCH §2.4) — no request in this screen carries a country, because a country on the
/// account or in a query would be a health-adjacent fact in someone else's logs. The
/// picker lists the countries Eva actually carries and nothing else: an option whose
/// resolution is the fallback wording would be a control that changes nothing, and
/// "follows your region" is already what an uncovered region resolves to.
struct EmergencyInfoSettingsView: View {
    /// Read through the same seam the Home tab uses, for the same reason: one way to
    /// talk to the API. The fetch takes no country argument — see the type comment.
    let session: AppSession
    /// The device's country setting. Observed, not captured: a change made here is on
    /// this screen the moment the picker closes.
    let country: EvaCountrySetting

    /// The guidance table, once it has arrived. `nil` is still loading; an empty array
    /// is a table the server does not carry — both render, differently and honestly.
    @State private var entries: [EvaRefData.EmergencyEntry]?
    @State private var loadFailed = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: EvaSpacing.lg) {
                if let entries {
                    if entries.isEmpty {
                        missingTable
                    } else {
                        countryCard(entries)
                        guidanceCard(entries)
                        supportCard(entries)
                        privacyNote
                    }
                } else if loadFailed {
                    failedCard
                } else {
                    loadingCard
                }
            }
            .padding(.horizontal, EvaSpacing.lg)
            .padding(.top, EvaSpacing.xs)
            .padding(.bottom, EvaSpacing.xxl)
        }
        .navigationTitle("Medical and emergency information")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .background {
            EvaScreenBackground().ignoresSafeArea()
        }
        .task { await load() }
    }

    // MARK: - Loading

    private func load() async {
        loadFailed = false
        entries = await session.emergencyGuidance()
        loadFailed = entries == nil
    }

    private var loadingCard: some View {
        ProgressView()
            .frame(maxWidth: .infinity, minHeight: 96)
            .evaCardSurface()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Loading emergency information")
            .accessibilityIdentifier("emergency.loading")
    }

    /// The read failed. Information-toned, like the calendar's failed load: nothing she
    /// did was wrong and nothing about her data changed — a request did not land.
    private var failedCard: some View {
        VStack(alignment: .leading, spacing: EvaSpacing.sm) {
            Text("Emergency information didn't load")
                .evaTextStyle(.bodyMedium)
                .foregroundStyle(Color.evaPrimaryText)
            Text("Check your connection and try again.")
                .evaTextStyle(.caption)
                .foregroundStyle(Color.evaSecondaryText)
            Button("Try again") { Task { await load() } }
                .buttonStyle(EvaTextButtonStyle())
                .accessibilityIdentifier("emergency.retry")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(EvaSpacing.md)
        .evaCardSurface()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("emergency.loadError")
    }

    /// An API that predates the table. Distinct from a failed read, because retrying
    /// cannot help and saying so is more honest than a spinner that resolves to itself.
    private var missingTable: some View {
        Text("Eva doesn't carry emergency information for this account yet.")
            .evaTextStyle(.body)
            .foregroundStyle(Color.evaSecondaryText)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(EvaSpacing.md)
            .evaCardSurface()
            .accessibilityIdentifier("emergency.missing")
    }

    // MARK: - The three facts

    /// The country card: what governs the choice, and the picker that overrides it.
    private func countryCard(_ entries: [EvaRefData.EmergencyEntry]) -> some View {
        VStack(alignment: .leading, spacing: EvaSpacing.sm) {
            Text("Country")
                .evaTextStyle(.bodyMedium)
                .foregroundStyle(Color.evaPrimaryText)

            Picker("Country", selection: Binding(
                get: { country.isOverridden ? country.country ?? "" : "" },
                set: { country.choose($0.isEmpty ? nil : $0) }
            )) {
                Text("Follows your region").tag("")
                ForEach(Self.offeredCountries(entries)) { entry in
                    Text(entry.label).tag(entry.code)
                }
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("emergency.country")

            Text(regionNote)
                .evaTextStyle(.caption)
                .foregroundStyle(Color.evaSecondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(EvaSpacing.md)
        .evaCardSurface()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("emergency.countryCard")
    }

    /// What the country line says under the picker. An override is named as hers; a
    /// region default is named as a region, including the honest case where the region
    /// resolves to nothing — the fallback, and the picker is how she changes that.
    private var regionNote: String {
        if country.isOverridden {
            return "Set by you on this device."
        }
        if let region = country.regionDefault {
            return "Follows your device's region (\(region)). Change it here if your "
                + "region doesn't match where you need care."
        }
        return "Follows your device's region. Change it here if your region doesn't "
            + "match where you need care."
    }

    /// The urgent-care card: the wording the red-flag card shows, and the number, if the
    /// country has one. The wording is `refdata/`'s, verbatim — the screen edits nothing.
    private func guidanceCard(_ entries: [EvaRefData.EmergencyEntry]) -> some View {
        let resolved = EvaRefData.emergencyGuidance(
            from: entries, forCountry: country.country)
        return VStack(alignment: .leading, spacing: EvaSpacing.sm) {
            Text("When something needs urgent care")
                .evaTextStyle(.bodyMedium)
                .foregroundStyle(Color.evaPrimaryText)

            Text(resolved?.urgentCareWording ?? "")
                .evaTextStyle(.body)
                .foregroundStyle(Color.evaSecondaryText)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("emergency.wording")

            if let number = resolved?.emergencyNumber {
                Text("Emergency number: \(number)")
                    .evaTextStyle(.bodyMedium)
                    .foregroundStyle(Color.evaPrimaryText)
                    .accessibilityIdentifier("emergency.number")
            }

            Text("Eva is not a medical device and cannot assess symptoms. This screen "
                + "names whom to contact; it is not medical advice.")
                .evaTextStyle(.caption)
                .foregroundStyle(Color.evaSecondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(EvaSpacing.md)
        .evaCardSurface()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("emergency.guidanceCard")
    }

    /// The support card: the country's resources, quiet rows — a service and how to
    /// reach it. The fallback carries none, and says so rather than inventing one: a
    /// resource Eva cannot name with confidence stays unlisted (seed-refdata.ts).
    private func supportCard(_ entries: [EvaRefData.EmergencyEntry]) -> some View {
        let resolved = EvaRefData.emergencyGuidance(
            from: entries, forCountry: country.country)
        return VStack(alignment: .leading, spacing: EvaSpacing.sm) {
            Text("Support resources")
                .evaTextStyle(.bodyMedium)
                .foregroundStyle(Color.evaPrimaryText)

            if let support = resolved?.support, !support.isEmpty {
                ForEach(support) { resource in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(resource.label)
                            .evaTextStyle(.body)
                            .foregroundStyle(Color.evaPrimaryText)
                        Text(resource.detail)
                            .evaTextStyle(.caption)
                            .foregroundStyle(Color.evaSecondaryText)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("emergency.support.\(resource.label)")
                }
            } else {
                Text("No support services are listed for your country yet.")
                    .evaTextStyle(.caption)
                    .foregroundStyle(Color.evaSecondaryText)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(EvaSpacing.md)
        .evaCardSurface()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("emergency.supportCard")
    }

    /// The data-minimisation promise, stated where the choice is made — the one place a
    /// reader could reasonably wonder whether "United States" went into her account.
    private var privacyNote: some View {
        Text("Your country is stored on this device only. It is never sent to Eva's "
            + "servers or added to your account.")
            .evaTextStyle(.caption)
            .foregroundStyle(Color.evaSecondaryText)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("emergency.privacyNote")
    }

    /// What the picker offers: the countries the table carries and stands behind,
    /// sorted so the list cannot reorder itself between reads. The fallback row is
    /// deliberately absent — "Follows your region" *is* the way back to it.
    private static func offeredCountries(
        _ entries: [EvaRefData.EmergencyEntry]
    ) -> [EvaRefData.EmergencyEntry] {
        entries
            .filter { $0.code != EvaRefData.fallbackGuidanceCode && $0.status == .active }
            .sorted { $0.label < $1.label }
    }
}

#Preview("Emergency information") {
    NavigationStack {
        EmergencyInfoSettingsView(session: AppSession(), country: EvaCountrySetting())
    }
}
