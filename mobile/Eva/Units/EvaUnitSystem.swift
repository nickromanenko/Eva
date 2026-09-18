import Foundation

/// Which system Eva **shows and accepts** body measurements in (#82).
///
/// ## The rule this type exists to keep
///
/// **Eva stores one canonical unit and converts only at the edge.** A weight is stored in
/// kilograms and a height in centimeters — always, on every device, whatever this is set
/// to. This enum decides what a screen draws and what an entry control hands back, and
/// nothing else. No stored value may depend on it, or changing the setting would rewrite
/// history: a weight logged as 150 lb would silently become 150 kg.
///
/// `docs/ARCHITECTURE.md` §5 states the canonical unit. `EvaBodyUnits` is the whole of
/// the conversion boundary — two functions per quantity, one each way — and `EvaBodyRange`
/// derives the imperial input ranges from the SI ones so an imperial entry can never round
/// to a value the API's `parseProfile` rejects.
///
/// ## Compound units are two fields, never one decimal
///
/// Feet and inches are `EvaFeetInches`, stones and pounds are `EvaStonesPounds`, and both
/// are built from a whole-unit total (inches, pounds) rather than a fraction. A decimal
/// box for a compound unit is how 5'9" becomes 5.9 — a plausible number, and wrong by two
/// inches, with nothing on screen to show it (`docs/LAUNCH.md` §4.2).
///
/// ## Why there are three, where the canvas Settings row draws two
///
/// The canvas draws `Units · Follows your region by default · Imperial` and never draws
/// the screen behind it, so the values are a decision this issue had to take. The PRD
/// asks for pounds (§Nutrition coach Step 4, "kg/cm or lb/ft") and #82's decision comment
/// asks for stones and pounds as well, and those are two different weight units for one
/// word. They are separate options rather than one "Imperial" that means stones in some
/// regions, because a setting whose meaning still depends on the locale is the bug this
/// issue exists to prevent: the override has to win everywhere, unambiguously.
enum EvaUnitSystem: String, CaseIterable, Sendable, Codable, Identifiable {
    /// Kilograms and centimeters.
    case metric
    /// Pounds, feet and inches.
    case imperial
    /// Stones and pounds, feet and inches.
    case stonesAndPounds

    var id: String { rawValue }

    /// The setting's name, as the Settings row's value and the option's title.
    var title: String {
        switch self {
        case .metric: "Metric"
        case .imperial: "Imperial"
        case .stonesAndPounds: "Stones and pounds"
        }
    }

    /// What picking it actually changes, spelled out. The option list is the one place
    /// someone can check what she is choosing before she chooses it.
    var detail: String {
        switch self {
        case .metric: "Kilograms and centimeters"
        case .imperial: "Pounds, feet and inches"
        case .stonesAndPounds: "Stones and pounds, feet and inches"
        }
    }

    /// How a weight is typed in this system.
    var massEntry: EvaMassEntry {
        switch self {
        case .metric: .kilograms
        case .imperial: .pounds
        case .stonesAndPounds: .stonesAndPounds
        }
    }

    /// How a height is typed in this system.
    var heightEntry: EvaHeightEntry {
        switch self {
        case .metric: .centimeters
        case .imperial, .stonesAndPounds: .feetAndInches
        }
    }

    /// The system a device with this locale starts on, before anyone overrides it.
    ///
    /// PRD §Product frame A16, literally: "Units default from the device locale (imperial
    /// for a US locale)". So `.us` is the one measurement system that defaults to imperial
    /// and everything else defaults to metric — including `Locale.MeasurementSystem.uk`,
    /// which exists precisely because the UK says stones and pints. That is deliberate and
    /// is #82's own acceptance criterion ("with `en_GB`, kg and cm"): a British user is
    /// weighed in kilograms by her own health service, and stones is a preference she can
    /// state rather than one Eva assumes for her.
    static func `default`(for locale: Locale) -> EvaUnitSystem {
        locale.measurementSystem == .us ? .imperial : .metric
    }
}

/// The weight entry controls a unit system asks for.
enum EvaMassEntry: Sendable, Hashable {
    /// One field, whole kilograms.
    case kilograms
    /// One field, whole pounds. Pounds is not a compound unit — a single field is right.
    case pounds
    /// Two fields: stones, then pounds within the stone.
    case stonesAndPounds
}

/// The height entry controls a unit system asks for.
enum EvaHeightEntry: Sendable, Hashable {
    /// One field, whole centimeters.
    case centimeters
    /// Two fields: feet, then inches within the foot.
    case feetAndInches
}

/// Short unit marks, drawn beside a value. One place, so a view and a test cannot
/// disagree about what "lb" is spelled.
enum EvaUnitLabel {
    static let kilograms = "kg"
    static let centimeters = "cm"
    static let pounds = "lb"
    static let stones = "st"
    static let feet = "ft"
    static let inches = "in"
}

/// The same marks as VoiceOver should say them. "5 ft" read aloud as "five ft" is not a
/// height; DESIGN.md §1's "never colour alone" has a spoken equivalent, and this is it.
enum EvaSpokenUnit {
    static let kilograms = "kilograms"
    static let centimeters = "centimeters"
    static let pounds = "pounds"
    static let stones = "stones"
    static let feet = "feet"
    static let inches = "inches"
}
