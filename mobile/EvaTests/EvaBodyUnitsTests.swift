import Testing
import Foundation
@testable import Eva

/// The conversion boundary (#82). Everything Eva stores is SI, and these four functions
/// are the only place a display preference touches a number — so this is where the bugs
/// the issue exists to prevent would live.
///
/// The three the issue names, in order:
///
/// 1. **Round-tripping.** 5'9" → cm → ft/in is 5'9", not 5'8.99" and not 5.75 ft.
///    Checked for every value in range rather than for the two the issue quotes, because
///    the failure mode is a rounding rule that is right in the middle and wrong at 4'0".
/// 2. **An imperial entry can never fall outside the SI range.** `parseProfile` refuses
///    anything outside 30–200 kg and 120–220 cm and says so in kilograms; an imperial
///    control that can reach 441 lb would produce that message for a number the user
///    never saw.
/// 3. **Precision.** A kilogram is 2.2 lb, so whole kilograms cannot tell 150 lb from
///    151 lb. The canonical grid is fine enough that every pound survives it.
@Suite("Body units — the conversion boundary")
struct EvaBodyUnitsTests {

    // MARK: Round trips

    @Test("Every height in range survives inches → centimeters → inches")
    func everyHeightRoundTripsThroughCentimeters() {
        for inches in EvaBodyRange.inches {
            let centimeters = EvaBodyUnits.centimeters(fromInches: inches)
            let back = EvaBodyUnits.inches(fromCentimeters: centimeters)
            #expect(back == inches, "\(inches) in stored as \(centimeters) cm came back as \(back) in")
        }
    }

    @Test("Every weight in range survives pounds → kilograms → pounds")
    func everyWeightRoundTripsThroughKilograms() {
        for pounds in EvaBodyRange.pounds {
            let kilograms = EvaBodyUnits.kilograms(fromPounds: pounds)
            let back = EvaBodyUnits.pounds(fromKilograms: kilograms)
            #expect(back == pounds, "\(pounds) lb stored as \(kilograms) kg came back as \(back) lb")
        }
    }

    @Test("5 ft 6 in comes back as 5 ft 6 in — the acceptance criterion, literally")
    func fiveSixRoundTrips() {
        let entered = EvaFeetInches(totalInches: 5 * 12 + 6)
        let stored = EvaBodyUnits.centimeters(fromInches: entered.totalInches)
        let shown = EvaFeetInches(totalInches: EvaBodyUnits.inches(fromCentimeters: stored))
        #expect(shown == entered)
        #expect(shown.feet == 5)
        #expect(shown.inches == 6)
        // Not 5.5 ft, and not 5 ft 5.9 in: the stored value is a height, and the split
        // back into feet and inches is integer division of whole inches.
        #expect(stored == 167.6)
    }

    @Test("5 ft 9 in comes back as 5 ft 9 in")
    func fiveNineRoundTrips() {
        let stored = EvaBodyUnits.centimeters(fromInches: 69)
        #expect(stored == 175.3)
        let shown = EvaFeetInches(totalInches: EvaBodyUnits.inches(fromCentimeters: stored))
        #expect(shown == EvaFeetInches(totalInches: 69))
    }

    @Test("150 lb comes back as 150 lb, and as 10 st 10 lb")
    func oneFiftyRoundTrips() {
        let stored = EvaBodyUnits.kilograms(fromPounds: 150)
        #expect(abs(stored - 68.04) < 1e-9)
        #expect(EvaBodyUnits.pounds(fromKilograms: stored) == 150)
        #expect(EvaStonesPounds(totalPounds: 150) == EvaStonesPounds(totalPounds: 10 * 14 + 10))
        #expect(EvaStonesPounds(totalPounds: 150).stones == 10)
        #expect(EvaStonesPounds(totalPounds: 150).pounds == 10)
    }

    @Test("151 lb does not collapse into 150 — whole kilograms would lose it")
    func adjacentPoundsStayDistinct() {
        // The reason the canonical value is not an `Int`. At whole kilograms both of
        // these are 68 and both come back as 150, so a typed 151 would silently become
        // 150 — the same class of defect as 5'9" becoming 5.9, and just as invisible.
        let one = EvaBodyUnits.kilograms(fromPounds: 150)
        let two = EvaBodyUnits.kilograms(fromPounds: 151)
        #expect(one != two)
        #expect(EvaBodyUnits.pounds(fromKilograms: two) == 151)
        #expect(one.rounded() == two.rounded())
    }

    @Test("Converting a stored value twice changes nothing the second time")
    func conversionIsIdempotent() {
        for pounds in stride(from: EvaBodyRange.pounds.lowerBound, through: EvaBodyRange.pounds.upperBound, by: 7) {
            let once = EvaBodyUnits.kilograms(fromPounds: pounds)
            let twice = EvaBodyUnits.kilograms(fromPounds: EvaBodyUnits.pounds(fromKilograms: once))
            #expect(once == twice, "\(pounds) lb drifted on a second edit")
        }
        for inches in EvaBodyRange.inches {
            let once = EvaBodyUnits.centimeters(fromInches: inches)
            let twice = EvaBodyUnits.centimeters(fromInches: EvaBodyUnits.inches(fromCentimeters: once))
            #expect(once == twice, "\(inches) in drifted on a second edit")
        }
    }

    // MARK: Ranges

    @Test("The imperial ranges are derived from the SI ones and sit inside them")
    func everyImperialValueConvertsInRange() {
        for pounds in EvaBodyRange.pounds {
            let kilograms = EvaBodyUnits.kilograms(fromPounds: pounds)
            #expect(
                EvaBodyRange.kilograms.contains(kilograms),
                "\(pounds) lb is \(kilograms) kg, which parseProfile would refuse"
            )
        }
        for inches in EvaBodyRange.inches {
            let centimeters = EvaBodyUnits.centimeters(fromInches: inches)
            #expect(
                EvaBodyRange.centimeters.contains(centimeters),
                "\(inches) in is \(centimeters) cm, which parseProfile would refuse"
            )
        }
    }

    @Test("The imperial ranges are as wide as they can be")
    func imperialRangesAreNotNarrowerThanTheyNeedToBe() {
        // One step outside each bound has to fall outside the SI range, or the control
        // is refusing weights and heights the API would have taken.
        #expect(!EvaBodyRange.kilograms.contains(
            EvaBodyUnits.kilograms(fromPounds: EvaBodyRange.pounds.lowerBound - 1)))
        #expect(!EvaBodyRange.kilograms.contains(
            EvaBodyUnits.kilograms(fromPounds: EvaBodyRange.pounds.upperBound + 1)))
        #expect(!EvaBodyRange.centimeters.contains(
            EvaBodyUnits.centimeters(fromInches: EvaBodyRange.inches.lowerBound - 1)))
        #expect(!EvaBodyRange.centimeters.contains(
            EvaBodyUnits.centimeters(fromInches: EvaBodyRange.inches.upperBound + 1)))
    }

    @Test("The SI ranges are the API's own, from ARCHITECTURE §4")
    func siRangesMatchTheServer() {
        // `parseProfile` in api/src/index.ts: age 13–99, weight 30–200 kg, height
        // 120–220 cm. Widening one is a product decision; this fails loudly if the two
        // copies of the number drift apart.
        #expect(EvaBodyRange.kilograms == 30...200)
        #expect(EvaBodyRange.centimeters == 120...220)
        #expect(EvaBodyRange.pounds == 67...440)
        #expect(EvaBodyRange.inches == 48...86)
    }

    // MARK: Compound values

    @Test("Feet and inches are two whole fields, never a fraction of a foot")
    func feetAndInchesSplitAndJoin() {
        #expect(EvaFeetInches(totalInches: 69).feet == 5)
        #expect(EvaFeetInches(totalInches: 69).inches == 9)
        #expect(EvaFeetInches(totalInches: 72).inches == 0)
        for inches in EvaBodyRange.inches {
            let split = EvaFeetInches(totalInches: inches)
            #expect(split.totalInches == inches)
            #expect((0..<12).contains(split.inches))
        }
    }

    @Test("Stones and pounds are two whole fields")
    func stonesAndPoundsSplitAndJoin() {
        for pounds in EvaBodyRange.pounds {
            let split = EvaStonesPounds(totalPounds: pounds)
            #expect(split.totalPounds == pounds)
            #expect((0..<14).contains(split.pounds))
        }
    }

    // MARK: Precision

    @Test("A stored value lands on the canonical grid")
    func storedValuesAreOnTheGrid() {
        for pounds in EvaBodyRange.pounds {
            let kilograms = EvaBodyUnits.kilograms(fromPounds: pounds)
            let scaled = kilograms * 100
            #expect(abs(scaled - scaled.rounded()) < 1e-6, "\(kilograms) kg is off the 0.01 grid")
        }
        for inches in EvaBodyRange.inches {
            let centimeters = EvaBodyUnits.centimeters(fromInches: inches)
            let scaled = centimeters * 10
            #expect(abs(scaled - scaled.rounded()) < 1e-6, "\(centimeters) cm is off the 0.1 grid")
        }
    }

    @Test("A whole canonical value still encodes as an integer on the wire")
    func metricEntriesEncodeAsTheyAlwaysDid() throws {
        // `weightKg` and `heightCm` went from `Int` to `Double` so a pound could survive
        // storage. Nothing about a metric profile's request body may change with it:
        // `parseProfile` has always taken a finite number in a range.
        let payload = ProfilePayload(
            dateOfBirth: "1996-03-14", weightKg: 64, heightCm: 168,
            goals: [], conditions: [], medications: "", lifestyle: nil, sports: [],
            timeZone: "UTC"
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let json = try String(decoding: encoder.encode(payload), as: UTF8.self)
        #expect(json.contains("\"weightKg\":64"))
        #expect(json.contains("\"heightCm\":168"))
        #expect(!json.contains("64.0"))
    }
}
