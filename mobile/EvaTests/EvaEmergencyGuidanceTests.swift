import Testing
import Foundation
@testable import Eva

/// The per-country emergency guidance (#87): how a country resolves against the
/// `refdata/` table, how the country setting is kept, and the one card line the device
/// may swap.
///
/// The resolution rules are the device-side mirror of `resolveEmergencyGuidance`
/// (api/src/refdata.ts), and the cases here are its cases on purpose: the acceptance
/// criteria name two of them — an unknown country resolves to the fallback and never to
/// another country's number — and the rest are the ways a real device's country string
/// arrives deformed.
@MainActor
@Suite("Emergency guidance")
struct EvaEmergencyGuidanceTests {

    // MARK: The table

    /// The seed's shape, rebuilt in memory: the same rows the API test suite asserts
    /// against the live catalogue, minus the numbers this file has no business pinning —
    /// the seed file and the API tests own those. What the device owns is *resolution*.
    private static let fallback = EvaRefData.EmergencyEntry(
        code: EvaRefData.fallbackGuidanceCode,
        label: "Everywhere else",
        urgentCareWording: "Contact your provider or a local urgent care service for "
            + "guidance. Eva cannot assess this."
    )
    private static let us = EvaRefData.EmergencyEntry(
        code: "US",
        label: "United States",
        emergencyNumber: "911",
        urgentCareWording: "If you need urgent help, call 911 now. " + Self.fallback.urgentCareWording
    )
    private static let gb = EvaRefData.EmergencyEntry(
        code: "GB",
        label: "United Kingdom",
        emergencyNumber: "999",
        urgentCareWording: "If you need urgent help, call 999 now. " + Self.fallback.urgentCareWording
    )
    private static let retiredCountry = EvaRefData.EmergencyEntry(
        code: "IE",
        label: "Ireland",
        emergencyNumber: "112 or 999",
        urgentCareWording: "If you need urgent help, call 112 or 999 now. "
            + Self.fallback.urgentCareWording,
        status: .retired
    )

    private static let entries = [fallback, us, gb, retiredCountry]

    // MARK: Resolution

    @Test("A covered country resolves to its own entry")
    func coveredCountry() {
        #expect(EvaRefData.emergencyGuidance(from: Self.entries, forCountry: "US")?.code == "US")
        #expect(EvaRefData.emergencyGuidance(from: Self.entries, forCountry: "GB")?.code == "GB")
    }

    @Test(
        "Case and padding do not change which country resolves",
        arguments: ["us", "Us", " US", "US ", " uS ", "\u{FEFF}US"]
    )
    func normalisation(variant: String) {
        #expect(EvaRefData.emergencyGuidance(from: Self.entries, forCountry: variant)?.code == "US")
    }

    @Test(
        "An unknown, malformed or absent country resolves to the fallback — never to another country's number",
        arguments: ["DE", "FR", "USA", "419", "en_US", "", "  ", nil]
    )
    func unknownResolvesToFallback(country: String?) {
        let resolved = EvaRefData.emergencyGuidance(from: Self.entries, forCountry: country)
        #expect(resolved?.code == EvaRefData.fallbackGuidanceCode)
        // The acceptance criterion, twice over: the fallback states no number, so no
        // country the table has never heard of can be shown a 911 or a 999.
        #expect(resolved?.emergencyNumber == nil)
    }

    @Test("A retired country resolves to the fallback, not to its own stale wording")
    func retiredCountryResolvesToFallback() {
        // The row is still in the table — the same "retired, not deleted" rule every
        // catalogue keeps — but offering its wording would make retirement cosmetic.
        #expect(
            EvaRefData.emergencyGuidance(from: Self.entries, forCountry: "IE")?.code
                == EvaRefData.fallbackGuidanceCode
        )
    }

    @Test("A table with no fallback resolves to nothing, and the card keeps its own words")
    func noFallbackResolvesToNothing() {
        #expect(EvaRefData.emergencyGuidance(from: [], forCountry: "US") == nil)
        #expect(EvaRefData.emergencyGuidance(from: [Self.us], forCountry: "US") != nil)
        #expect(EvaRefData.emergencyGuidance(from: [Self.us], forCountry: "DE") == nil)
    }

    // MARK: The decode

    @Test("The table decodes leniently: a row missing every optional field still lands")
    func lenientDecode() throws {
        let json = """
        {
          "version": "abc123",
          "catalogues": {
            "symptoms": [],
            "sportActivities": [],
            "appointmentTypes": [],
            "emergencyGuidance": [
              { "code": "fallback", "label": "Everywhere else" },
              { "code": "US", "label": "United States", "emergencyNumber": "911",
                "urgentCareWording": "Call 911 now.", "support": [
                  { "label": "988", "detail": "Call or text 988" } ] },
              { "code": "XX", "label": "Retired", "status": "retired" }
            ]
          }
        }
        """.data(using: .utf8)!
        let refData = try JSONDecoder().decode(EvaRefData.self, from: json)
        let table = refData.catalogues.emergencyGuidance
        #expect(table.count == 3)
        #expect(table[0].emergencyNumber == nil)
        #expect(table[0].urgentCareWording == "")
        #expect(table[0].support.isEmpty)
        #expect(table[0].status == .active)
        #expect(table[1].support.count == 1)
        #expect(table[2].status == .retired)
    }

    @Test("A catalogue that predates the table decodes with an empty one")
    func absentTableDecodesEmpty() throws {
        let json = """
        { "version": "abc123", "catalogues": { "symptoms": [] } }
        """.data(using: .utf8)!
        let refData = try JSONDecoder().decode(EvaRefData.self, from: json)
        #expect(refData.catalogues.emergencyGuidance.isEmpty)
    }

    // MARK: The country setting

    /// A defaults domain nothing else can see, removed when the test is done with it.
    private func isolatedDefaults(
        _ body: (UserDefaults) throws -> Void
    ) rethrows {
        let name = "eva.emergency.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        try body(defaults)
    }

    @Test("The device region is the default, and nothing is stored")
    func regionIsTheDefault() {
        isolatedDefaults { defaults in
            let setting = EvaCountrySetting(
                defaults: defaults, locale: Locale(identifier: "en_US")
            )
            #expect(setting.country == "US")
            #expect(setting.isOverridden == false)
            #expect(defaults.string(forKey: EvaCountrySetting.storageKey) == nil)
        }
    }

    @Test("A device with no region still has a setting — it just resolves like any unknown")
    func missingRegionIsNotAnError() {
        isolatedDefaults { defaults in
            // A locale id with no region component: `Locale.region` answers nil.
            let setting = EvaCountrySetting(
                defaults: defaults, locale: Locale(identifier: "en")
            )
            #expect(setting.country == nil)
            #expect(setting.isOverridden == false)
        }
    }

    @Test("Choosing a country persists it and survives a relaunch")
    func choicePersists() {
        isolatedDefaults { defaults in
            let setting = EvaCountrySetting(
                defaults: defaults, locale: Locale(identifier: "en_US")
            )
            setting.choose("GB")
            #expect(setting.country == "GB")
            #expect(setting.isOverridden == true)

            // The relaunch: a new instance over the same defaults.
            let relaunched = EvaCountrySetting(
                defaults: defaults, locale: Locale(identifier: "en_US")
            )
            #expect(relaunched.country == "GB")
            #expect(relaunched.isOverridden == true)
        }
    }

    @Test("Choosing the country the region already gave still persists")
    func choosingTheRegionDefaultPersists() {
        isolatedDefaults { defaults in
            let setting = EvaCountrySetting(
                defaults: defaults, locale: Locale(identifier: "en_US")
            )
            // `country` does not change, so the `didSet` path would skip the write —
            // and a later trip abroad would quietly move her back to the new region.
            setting.choose("US")
            #expect(defaults.string(forKey: EvaCountrySetting.storageKey) == "US")
        }
    }

    @Test("Clearing the choice returns to following the region, and stores nothing")
    func clearingFollowsTheRegion() {
        isolatedDefaults { defaults in
            let setting = EvaCountrySetting(
                defaults: defaults, locale: Locale(identifier: "en_US")
            )
            setting.choose("GB")
            setting.choose(nil)
            #expect(setting.country == "US")
            #expect(setting.isOverridden == false)
            #expect(defaults.string(forKey: EvaCountrySetting.storageKey) == nil)
        }
    }

    // MARK: The one card substitution

    /// The canvas' own flag card, verbatim from `EvaTodayCardFixtures`.
    private static let flagCard = EvaTodayCard(
        tone: .flag,
        kicker: "Logged 14:20 today",
        title: "You logged reduced fetal movement today",
        line2: "Contact your maternity provider or local urgent care service for guidance. "
            + "Eva cannot assess this.",
        actions: [
            EvaTodayCardAction(label: "View contact options"),
            EvaTodayCardAction(label: "Review what I logged"),
        ]
    )

    @Test("A flag card's guidance line becomes the country's wording")
    func flagCardTakesTheWording() {
        let shown = Self.flagCard.withFlagGuidance(Self.us.urgentCareWording)
        #expect(shown.line2 == Self.us.urgentCareWording)
        #expect(shown.title == Self.flagCard.title)
        #expect(shown.actions == Self.flagCard.actions)
        // The line VoiceOver reads is the line on screen — one substitution, not two.
        #expect(shown.accessibilityLabel.contains(Self.us.urgentCareWording))
    }

    @Test("A flag card with no guidance keeps its own wording")
    func flagCardWithoutGuidanceIsUntouched() {
        for wording in [nil, ""] {
            #expect(Self.flagCard.withFlagGuidance(wording) == Self.flagCard)
        }
    }

    @Test("No other tone is ever substituted — the device does not edit a server card")
    func otherTonesAreNeverSubstituted() {
        let base = EvaTodayCard(
            tone: .base,
            title: "Many women notice higher energy around now",
            line2: "This is a tendency across cycles, not a prediction about your day."
        )
        #expect(base.withFlagGuidance(Self.us.urgentCareWording) == base)
    }
}
