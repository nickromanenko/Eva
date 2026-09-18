import Testing
import Foundation
@testable import Eva

/// The units setting itself (#82): where it starts, what overrides it, and that the
/// override outlives the launch it was made in.
///
/// Every test gets its own `UserDefaults` suite, so nothing here reads or writes the
/// simulator's real defaults and the order the tests run in cannot matter.
@MainActor
@Suite("Units preference")
struct EvaUnitPreferenceTests {

    /// A defaults domain nothing else can see, removed when the test is done with it.
    private func isolatedDefaults(
        _ body: (UserDefaults) throws -> Void
    ) rethrows {
        let name = "eva.units.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        try body(defaults)
    }

    // MARK: The locale default

    @Test(
        "The device locale picks the starting system",
        arguments: [
            ("en_US", EvaUnitSystem.imperial),
            ("es_US", .imperial),
            ("en_GB", .metric),
            ("en_IE", .metric),
            ("de_DE", .metric),
            ("fr_FR", .metric),
            ("ja_JP", .metric)
        ]
    )
    func localeDecidesTheDefault(identifier: String, expected: EvaUnitSystem) {
        isolatedDefaults { defaults in
            let preference = EvaUnitPreference(
                defaults: defaults, locale: Locale(identifier: identifier)
            )
            #expect(preference.system == expected)
            #expect(preference.localeDefault == expected)
            #expect(preference.isOverridden == false)
        }
    }

    @Test("en_GB is metric, even though its measurement system is `uk`")
    func britainIsMetricByDefault() {
        // `Locale.MeasurementSystem.uk` exists because Britain says stones and pints, and
        // mapping it to stones would be the obvious reading. It is not this one: #82's
        // acceptance criterion is "with `en_GB`, kg and cm", and the PRD's rule (A16) is
        // "imperial for a US locale" and nothing else. Stones stays available as a choice.
        #expect(Locale(identifier: "en_GB").measurementSystem == .uk)
        #expect(EvaUnitSystem.default(for: Locale(identifier: "en_GB")) == .metric)
    }

    // MARK: The override

    @Test("A choice wins over the locale")
    func theOverrideBeatsTheLocale() {
        isolatedDefaults { defaults in
            let preference = EvaUnitPreference(
                defaults: defaults, locale: Locale(identifier: "en_US")
            )
            #expect(preference.system == .imperial)

            preference.choose(.metric)
            #expect(preference.system == .metric)
            #expect(preference.isOverridden)
            // The locale has not changed and is not forgotten — Settings still says where
            // the default came from.
            #expect(preference.localeDefault == .imperial)
        }
    }

    @Test("The choice survives a relaunch")
    func theOverrideSurvivesRelaunch() {
        isolatedDefaults { defaults in
            let first = EvaUnitPreference(defaults: defaults, locale: Locale(identifier: "en_US"))
            first.choose(.stonesAndPounds)

            // A second instance over the same domain is what the next launch sees.
            let second = EvaUnitPreference(defaults: defaults, locale: Locale(identifier: "en_US"))
            #expect(second.system == .stonesAndPounds)
            #expect(second.isOverridden)
        }
    }

    @Test("Choosing what the locale already gives still records the choice")
    func choosingTheLocaleDefaultIsStillAChoice() {
        isolatedDefaults { defaults in
            let first = EvaUnitPreference(defaults: defaults, locale: Locale(identifier: "en_US"))
            first.choose(.imperial)
            #expect(first.isOverridden)

            // The same stored choice, read on a device that has since moved to a metric
            // locale. Without the write, this would silently become metric.
            let second = EvaUnitPreference(defaults: defaults, locale: Locale(identifier: "de_DE"))
            #expect(second.system == .imperial)
            #expect(second.localeDefault == .metric)
        }
    }

    @Test("An unreadable stored value falls back to the locale rather than crashing")
    func nonsenseFallsBackToTheLocale() {
        isolatedDefaults { defaults in
            defaults.set("cubits", forKey: EvaUnitPreference.storageKey)
            let preference = EvaUnitPreference(
                defaults: defaults, locale: Locale(identifier: "en_US")
            )
            #expect(preference.system == .imperial)
            #expect(preference.isOverridden == false)
        }
    }

    // MARK: What the setting is allowed to reach

    @Test("Every system names the fields it will ask for")
    func everySystemDescribesItself() {
        for system in EvaUnitSystem.allCases {
            #expect(!system.title.isEmpty)
            #expect(!system.detail.isEmpty)
        }
        #expect(EvaUnitSystem.metric.massEntry == .kilograms)
        #expect(EvaUnitSystem.metric.heightEntry == .centimeters)
        #expect(EvaUnitSystem.imperial.massEntry == .pounds)
        #expect(EvaUnitSystem.imperial.heightEntry == .feetAndInches)
        #expect(EvaUnitSystem.stonesAndPounds.massEntry == .stonesAndPounds)
        #expect(EvaUnitSystem.stonesAndPounds.heightEntry == .feetAndInches)
    }

    @Test("The stored raw values are stable — a rename would silently reset everyone")
    func rawValuesAreAContract() {
        #expect(EvaUnitSystem.metric.rawValue == "metric")
        #expect(EvaUnitSystem.imperial.rawValue == "imperial")
        #expect(EvaUnitSystem.stonesAndPounds.rawValue == "stonesAndPounds")
        #expect(EvaUnitPreference.storageKey == "eva.units.system")
    }
}
