import Foundation

/// What a weight entry control shows, and what one press of it produces — with no
/// SwiftUI in it.
///
/// `kilograms` is the canonical value and the only thing here that is stored. Every
/// number on screen is derived from it, and every step is a change to *it*, expressed in
/// the row's own unit: `+` on the stones row moves the weight by fourteen pounds, not by
/// a stone-shaped number of its own.
///
/// It is a struct outside the view on purpose. The round trip this whole issue turns on —
/// enter 150 lb, switch to metric, switch back, still 150 lb — is then a unit test over
/// arithmetic rather than a UI test over pixels, and the place a bug would be introduced
/// (a step that stored what it displayed) is the place the tests point at.
struct EvaMassInput: Equatable, Sendable {

    /// The fields a system asks for. `pounds` is the whole weight on its own and the
    /// remainder beside `stones`; which one it means is `system`'s to say.
    enum Row: String, CaseIterable, Sendable {
        case kilograms
        case pounds
        case stones

        var unit: String {
            switch self {
            case .kilograms: EvaUnitLabel.kilograms
            case .pounds: EvaUnitLabel.pounds
            case .stones: EvaUnitLabel.stones
            }
        }

        var spokenUnit: String {
            switch self {
            case .kilograms: EvaSpokenUnit.kilograms
            case .pounds: EvaSpokenUnit.pounds
            case .stones: EvaSpokenUnit.stones
            }
        }
    }

    /// Canonical. Kilograms, whatever `system` is.
    var kilograms: Double
    var system: EvaUnitSystem

    /// The rows to draw, in order.
    var rows: [Row] {
        switch system.massEntry {
        case .kilograms: [.kilograms]
        case .pounds: [.pounds]
        case .stonesAndPounds: [.stones, .pounds]
        }
    }

    /// The whole weight in pounds, however it is split for display.
    var totalPounds: Int { EvaBodyUnits.pounds(fromKilograms: kilograms) }

    /// The number this row shows.
    func value(_ row: Row) -> Int {
        switch row {
        case .kilograms:
            EvaBodyUnits.wholeKilograms(kilograms)
        case .stones:
            EvaStonesPounds(totalPounds: totalPounds).stones
        case .pounds:
            system.massEntry == .stonesAndPounds
                ? EvaStonesPounds(totalPounds: totalPounds).pounds
                : totalPounds
        }
    }

    /// Whether the step would stay inside what the API accepts (`EvaBodyRange`).
    func canStep(_ row: Row, by delta: Int) -> Bool {
        switch row {
        case .kilograms:
            EvaBodyRange.kilograms.contains(Double(value(.kilograms) + delta))
        case .pounds:
            EvaBodyRange.pounds.contains(totalPounds + delta)
        case .stones:
            EvaBodyRange.pounds.contains(totalPounds + delta * EvaBodyUnits.poundsPerStone)
        }
    }

    /// Applies `delta` steps of `row`'s own unit to the canonical value.
    mutating func step(_ row: Row, by delta: Int) {
        switch row {
        case .kilograms:
            kilograms = Double(value(.kilograms) + delta).clamped(to: EvaBodyRange.kilograms)
        case .pounds:
            setPounds(totalPounds + delta)
        case .stones:
            setPounds(totalPounds + delta * EvaBodyUnits.poundsPerStone)
        }
    }

    private mutating func setPounds(_ pounds: Int) {
        kilograms = EvaBodyUnits.kilograms(
            fromPounds: pounds.clamped(to: EvaBodyRange.pounds)
        )
    }
}

/// Height, on the same construction as `EvaMassInput`.
struct EvaHeightInput: Equatable, Sendable {

    enum Row: String, CaseIterable, Sendable {
        case centimeters
        case feet
        case inches

        var unit: String {
            switch self {
            case .centimeters: EvaUnitLabel.centimeters
            case .feet: EvaUnitLabel.feet
            case .inches: EvaUnitLabel.inches
            }
        }

        var spokenUnit: String {
            switch self {
            case .centimeters: EvaSpokenUnit.centimeters
            case .feet: EvaSpokenUnit.feet
            case .inches: EvaSpokenUnit.inches
            }
        }
    }

    /// Canonical. Centimeters, whatever `system` is.
    var centimeters: Double
    var system: EvaUnitSystem

    var rows: [Row] {
        switch system.heightEntry {
        case .centimeters: [.centimeters]
        case .feetAndInches: [.feet, .inches]
        }
    }

    var totalInches: Int { EvaBodyUnits.inches(fromCentimeters: centimeters) }

    func value(_ row: Row) -> Int {
        switch row {
        case .centimeters: EvaBodyUnits.wholeCentimeters(centimeters)
        case .feet: EvaFeetInches(totalInches: totalInches).feet
        case .inches: EvaFeetInches(totalInches: totalInches).inches
        }
    }

    func canStep(_ row: Row, by delta: Int) -> Bool {
        switch row {
        case .centimeters:
            EvaBodyRange.centimeters.contains(Double(value(.centimeters) + delta))
        case .feet:
            EvaBodyRange.inches.contains(totalInches + delta * EvaBodyUnits.inchesPerFoot)
        case .inches:
            EvaBodyRange.inches.contains(totalInches + delta)
        }
    }

    mutating func step(_ row: Row, by delta: Int) {
        switch row {
        case .centimeters:
            centimeters = Double(value(.centimeters) + delta)
                .clamped(to: EvaBodyRange.centimeters)
        case .feet:
            setInches(totalInches + delta * EvaBodyUnits.inchesPerFoot)
        case .inches:
            setInches(totalInches + delta)
        }
    }

    private mutating func setInches(_ inches: Int) {
        centimeters = EvaBodyUnits.centimeters(
            fromInches: inches.clamped(to: EvaBodyRange.inches)
        )
    }
}
