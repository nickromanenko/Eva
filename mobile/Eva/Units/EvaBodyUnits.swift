import Foundation

/// The conversion boundary: the only place SI becomes imperial or the other way round.
///
/// Everything Eva stores is SI — `weightKg`, `heightCm` — so these four functions are the
/// entire surface on which a display preference can touch a number. Keeping it to four is
/// what makes the round-trip testable at all (`EvaBodyUnitsTests`).
///
/// ## Why the canonical value is not a whole kilogram
///
/// A kilogram is 2.2 lb, so integer kilograms cannot tell 150 lb from 151 lb: both round
/// to 68 kg and both come back as 150. Losing a pound is not a rounding detail, it is the
/// typed value coming back different, which is the same class of defect as 5'9" becoming
/// 5.9. The canonical value therefore lands on a **0.01 kg** grid and a **0.1 cm** grid —
/// fine enough that every pound and every inch recovers exactly (0.01 kg is 0.022 lb
/// against the 0.5 lb that would be needed to change a rounded pound), coarse enough that
/// nothing accumulates float noise across edits.
///
/// The wire format is unchanged: `PUT /me/questionnaire` validates `weightKg` and
/// `heightCm` as finite numbers in a range (`api/src/index.ts`, `parseProfile`), never as
/// integers, and `JSONEncoder` writes a whole `Double` as `64`. A metric entry sends
/// exactly the bytes it sent before this change.
enum EvaBodyUnits {

    // MARK: - Definitions

    /// Exact by definition (international pound, 1959).
    static let kilogramsPerPound = 0.45359237
    /// Exact by definition (international inch, 1959).
    static let centimetersPerInch = 2.54
    static let poundsPerStone = 14
    static let inchesPerFoot = 12

    /// The grid a stored mass lands on, in kilograms. See the note above.
    static let kilogramPrecision = 2
    /// The grid a stored height lands on, in centimeters.
    static let centimeterPrecision = 1

    // MARK: - Mass

    /// Imperial → canonical. Whole pounds in, kilograms on the storage grid out.
    static func kilograms(fromPounds pounds: Int) -> Double {
        rounded(Double(pounds) * kilogramsPerPound, places: kilogramPrecision)
    }

    /// Canonical → imperial. Kilograms in, whole pounds out.
    static func pounds(fromKilograms kilograms: Double) -> Int {
        Int((kilograms / kilogramsPerPound).rounded())
    }

    // MARK: - Height

    /// Imperial → canonical. Whole inches in, centimeters on the storage grid out.
    static func centimeters(fromInches inches: Int) -> Double {
        rounded(Double(inches) * centimetersPerInch, places: centimeterPrecision)
    }

    /// Canonical → imperial. Centimeters in, whole inches out.
    static func inches(fromCentimeters centimeters: Double) -> Int {
        Int((centimeters / centimetersPerInch).rounded())
    }

    // MARK: - Metric display
    //
    // Metric entry is in whole kilograms and whole centimeters, so the canonical value a
    // metric screen hands back is a whole number — but the value it was *given* need not
    // be, because it may have been typed in pounds on another screen or another day.
    // These two round for display; neither writes anything back. A screen that rewrote the
    // canonical value just to tidy it would lose the pound it was storing (see
    // `EvaBodyInputTests.readingAValueDoesNotRewriteIt`).

    static func wholeKilograms(_ kilograms: Double) -> Int { Int(kilograms.rounded()) }

    static func wholeCentimeters(_ centimeters: Double) -> Int { Int(centimeters.rounded()) }

    // MARK: - Rounding

    /// Half-away-from-zero to a fixed number of decimal places, via an integer so the
    /// result is the shortest `Double` that prints as that decimal — `68.04`, not
    /// `68.04000000000001`.
    private static func rounded(_ value: Double, places: Int) -> Double {
        let scale = pow(10.0, Double(places))
        return (value * scale).rounded() / scale
    }
}

/// A height in feet and inches — **two fields, not one decimal** (#82).
///
/// Built from a total in whole inches, so `feet` and `inches` can never disagree and an
/// inch can never be a fraction of a foot. Adding an inch to 5'11" gives 6'0", which is
/// what a `+` beside an inches field has to mean.
struct EvaFeetInches: Equatable, Sendable {
    let feet: Int
    let inches: Int

    init(totalInches: Int) {
        feet = totalInches / EvaBodyUnits.inchesPerFoot
        inches = totalInches % EvaBodyUnits.inchesPerFoot
    }

    var totalInches: Int { feet * EvaBodyUnits.inchesPerFoot + inches }
}

/// A weight in stones and pounds — the other compound unit, on the same construction.
struct EvaStonesPounds: Equatable, Sendable {
    let stones: Int
    let pounds: Int

    init(totalPounds: Int) {
        stones = totalPounds / EvaBodyUnits.poundsPerStone
        pounds = totalPounds % EvaBodyUnits.poundsPerStone
    }

    var totalPounds: Int { stones * EvaBodyUnits.poundsPerStone + pounds }
}

/// What a body measurement is allowed to be, in every system that can express it.
///
/// The SI ranges are the API's, verbatim: `parseProfile` refuses anything outside
/// 30–200 kg and 120–220 cm (`docs/ARCHITECTURE.md` §4). The imperial ranges are
/// **derived** from them rather than written down, because a hand-written imperial bound
/// is exactly the thing #82's risk note names — an imperial entry that rounds to just
/// outside the SI range, refused by the server with a message in kilograms.
///
/// Rounded inward on both ends, so every value an imperial control can reach converts to
/// an SI value the server accepts. `EvaBodyUnitsTests.everyImperialValueConvertsInRange`
/// checks all of them, not just the ends.
enum EvaBodyRange {
    static let kilograms: ClosedRange<Double> = 30...200
    static let centimeters: ClosedRange<Double> = 120...220

    static let pounds: ClosedRange<Int> = inwardRange(
        kilograms, perUnit: EvaBodyUnits.kilogramsPerPound
    )
    static let inches: ClosedRange<Int> = inwardRange(
        centimeters, perUnit: EvaBodyUnits.centimetersPerInch
    )

    /// The widest whole-unit range that stays inside `si` once converted.
    private static func inwardRange(
        _ si: ClosedRange<Double>, perUnit: Double
    ) -> ClosedRange<Int> {
        Int((si.lowerBound / perUnit).rounded(.up))...Int((si.upperBound / perUnit).rounded(.down))
    }
}

extension Comparable {
    /// Pins a value inside a range. Every step of an entry control goes through this, so a
    /// `+` can never produce a measurement the API's `parseProfile` would refuse.
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
