import Foundation

/// Step 5's target-weight entry, in her units (#82) — and the text Step 4 confirms her
/// stored body metrics in.
///
/// **No second conversion path.** Every number here comes from or goes to kilograms through
/// `EvaBodyUnits`, `EvaMassInput` and `EvaHeightInput`; this type only decides which fields
/// a unit system asks for and parses what was typed into them. Pounds and stones are whole
/// units on the same grid the Profile editor uses, and stones-and-pounds is two fields,
/// never one decimal (ARCHITECTURE §5).
///
/// Metric stays a decimal kilogram field: the guard cards offer values like 52.2 kg (canvas
/// `sGuard`), and a kilogram is already the canonical unit, so there is nothing to convert.
struct NutritionTargetEntry: Equatable, Sendable {

    var system: EvaUnitSystem
    var kilogramsText = ""
    var stonesText = ""
    var poundsText = ""

    init(system: EvaUnitSystem) {
        self.system = system
    }

    /// The fields to draw, in order — `EvaMassInput`'s own rows for this system.
    var rows: [EvaMassInput.Row] {
        EvaMassInput(kilograms: 0, system: system).rows
    }

    /// The typed target in kilograms, or `nil` while it is empty, unreadable, or outside what
    /// the API accepts (`EvaBodyRange`, the server's own 30–200 kg).
    var kilograms: Double? {
        let value: Double?
        switch system.massEntry {
        case .kilograms:
            // A decimal pad types the locale's separator; the canonical value does not care.
            value = Double(kilogramsText.replacingOccurrences(of: ",", with: "."))
        case .pounds:
            value = Int(poundsText).map(EvaBodyUnits.kilograms(fromPounds:))
        case .stonesAndPounds:
            guard let stones = Int(stonesText) else { return nil }
            let pounds = poundsText.isEmpty ? 0 : Int(poundsText)
            guard let pounds, (0..<EvaBodyUnits.poundsPerStone).contains(pounds) else { return nil }
            value = EvaBodyUnits.kilograms(
                fromPounds: stones * EvaBodyUnits.poundsPerStone + pounds
            )
        }
        guard let value, EvaBodyRange.kilograms.contains(value) else { return nil }
        return value
    }

    /// Fills the fields from a canonical value — her stored target on resume, or a guard's
    /// offered value.
    ///
    /// `atLeast`: a guard's value is a **floor** (the lowest weight it accepts), and the
    /// nearest whole pound can land under it — 52.2 kg is 115.08 lb, and 115 lb is 52.16 kg,
    /// which the same guard would refuse again. So an offered value rounds up to the first
    /// whole pound that converts back to at least the floor.
    mutating func set(kilograms: Double, atLeast: Bool = false) {
        switch system.massEntry {
        case .kilograms:
            kilogramsText = Self.kilogramFormat(kilograms, atLeast: atLeast)
        case .pounds, .stonesAndPounds:
            var pounds = EvaBodyUnits.pounds(fromKilograms: kilograms)
            if atLeast, EvaBodyUnits.kilograms(fromPounds: pounds) < kilograms {
                pounds += 1
            }
            if system.massEntry == .pounds {
                poundsText = String(pounds)
            } else {
                let split = EvaStonesPounds(totalPounds: pounds)
                stonesText = String(split.stones)
                poundsText = String(split.pounds)
            }
        }
    }

    /// A weight as this entry would show it — "52.2 kg", "116 lb", "8 st 4 lb" — with the
    /// same rounding `set(kilograms:atLeast:)` puts in the fields.
    func display(kilograms: Double, atLeast: Bool = false) -> String {
        var entry = NutritionTargetEntry(system: system)
        entry.set(kilograms: kilograms, atLeast: atLeast)
        switch system.massEntry {
        case .kilograms:
            return "\(entry.kilogramsText) \(EvaUnitLabel.kilograms)"
        case .pounds:
            return "\(entry.poundsText) \(EvaUnitLabel.pounds)"
        case .stonesAndPounds:
            return "\(entry.stonesText) \(EvaUnitLabel.stones) \(entry.poundsText) \(EvaUnitLabel.pounds)"
        }
    }

    /// One decimal at most, and none for a whole number: "62", "52.2". A floor rounds up
    /// to the tenth, never under it; the epsilon keeps 52.2 from reading as 52.200…01.
    private static func kilogramFormat(_ kilograms: Double, atLeast: Bool) -> String {
        let tenths = atLeast
            ? (kilograms * 10 - 1e-9).rounded(.up) / 10
            : (kilograms * 10).rounded() / 10
        return tenths == tenths.rounded()
            ? String(Int(tenths))
            : String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), tenths)
    }
}

// MARK: - Step 4: her stored metrics, in her units

extension EvaMassInput {
    /// The weight as its rows show it: "64 kg", "141 lb", "10 st 1 lb".
    var displayText: String {
        rows.map { "\(value($0)) \($0.unit)" }.joined(separator: " ")
    }
}

extension EvaHeightInput {
    /// The height as its rows show it: "168 cm", "5 ft 6 in".
    var displayText: String {
        rows.map { "\(value($0)) \($0.unit)" }.joined(separator: " ")
    }
}
