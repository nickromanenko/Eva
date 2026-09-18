import Testing
import Foundation
@testable import Eva

/// The entry controls' arithmetic (#82) — what a screen shows, and what one press of it
/// stores.
///
/// The assertion the whole issue is built on is `switchingSystemsLeavesTheStoredValue
/// Identical`: the setting changes display and nothing else. It compares the encoded
/// request body before and after a tour of all three systems, because "the number looks
/// the same" is satisfied by a value that was rewritten to an equal one, and the defect
/// this prevents is a rewrite that is *nearly* equal — 151 lb quietly becoming 150.
@Suite("Body entry — display changes, storage does not")
struct EvaBodyInputTests {

    /// The request body for a profile carrying these two measurements, with sorted keys
    /// so two encodings of the same profile are the same bytes.
    private func payload(kilograms: Double, centimeters: Double) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try encoder.encode(
            ProfilePayload(
                dateOfBirth: "1996-03-14", weightKg: kilograms, heightCm: centimeters,
                goals: [], conditions: [], medications: "", lifestyle: "", sports: [],
                timeZone: "UTC"
            )
        )
    }

    // MARK: The rule

    @Test("Switching systems leaves the stored value byte-identical")
    func switchingSystemsLeavesTheStoredValueIdentical() throws {
        // 151 lb and 5 ft 9 in, entered in imperial.
        var mass = EvaMassInput(
            kilograms: EvaBodyUnits.kilograms(fromPounds: 151), system: .imperial
        )
        var height = EvaHeightInput(
            centimeters: EvaBodyUnits.centimeters(fromInches: 69), system: .imperial
        )
        let before = try payload(kilograms: mass.kilograms, centimeters: height.centimeters)

        // Every system, reading every row the way a screen does on each one.
        for system in [EvaUnitSystem.metric, .stonesAndPounds, .imperial, .metric, .imperial] {
            mass.system = system
            height.system = system
            for row in mass.rows { _ = mass.value(row) }
            for row in height.rows { _ = height.value(row) }
        }

        #expect(try payload(kilograms: mass.kilograms, centimeters: height.centimeters) == before)
        // And what she typed is still what she sees.
        #expect(mass.value(.pounds) == 151)
        #expect(height.value(.feet) == 5)
        #expect(height.value(.inches) == 9)
    }

    @Test("Reading a value in another system does not round it away")
    func readingAValueDoesNotRewriteIt() {
        // 151 lb is 68.49 kg, and a metric screen shows 68. If the act of showing it
        // wrote 68 back, the pound would be gone and the next imperial read would say
        // 150 — which is the whole bug class, and it is invisible: 150 is plausible.
        let stored = EvaBodyUnits.kilograms(fromPounds: 151)
        var mass = EvaMassInput(kilograms: stored, system: .metric)
        #expect(mass.value(.kilograms) == 68)
        #expect(mass.kilograms == stored)

        mass.system = .imperial
        #expect(mass.value(.pounds) == 151)
        #expect(mass.kilograms == stored)
    }

    @Test("A round trip through the entry control, not just the converter")
    func theRoundTripThroughTheEntryControl() {
        var height = EvaHeightInput(
            centimeters: EvaBodyUnits.centimeters(fromInches: 68), system: .imperial
        )
        height.step(.inches, by: 1)                 // 5 ft 8 in → 5 ft 9 in
        #expect(height.value(.feet) == 5)
        #expect(height.value(.inches) == 9)

        let stored = height.centimeters
        height.system = .metric
        #expect(height.value(.centimeters) == 175)
        #expect(height.centimeters == stored)

        height.system = .imperial
        #expect(height.value(.feet) == 5)
        #expect(height.value(.inches) == 9)
    }

    // MARK: Which rows a system asks for

    @Test("Each system asks for the fields it names", arguments: [
        (EvaUnitSystem.metric, [EvaMassInput.Row.kilograms], [EvaHeightInput.Row.centimeters]),
        (.imperial, [.pounds], [.feet, .inches]),
        (.stonesAndPounds, [.stones, .pounds], [.feet, .inches])
    ])
    func rowsPerSystem(
        system: EvaUnitSystem, mass: [EvaMassInput.Row], height: [EvaHeightInput.Row]
    ) {
        #expect(EvaMassInput(kilograms: 64, system: system).rows == mass)
        #expect(EvaHeightInput(centimeters: 168, system: system).rows == height)
    }

    // MARK: Compound stepping

    @Test("An inch past 5 ft 11 in is 6 ft 0 in, not 5 ft 12 in")
    func inchesCarryIntoFeet() {
        var height = EvaHeightInput(
            centimeters: EvaBodyUnits.centimeters(fromInches: 71), system: .imperial
        )
        height.step(.inches, by: 1)
        #expect(height.value(.feet) == 6)
        #expect(height.value(.inches) == 0)

        height.step(.inches, by: -1)
        #expect(height.value(.feet) == 5)
        #expect(height.value(.inches) == 11)
    }

    @Test("The feet row moves the height by twelve inches and leaves the inches alone")
    func feetStepByTwelveInches() {
        var height = EvaHeightInput(
            centimeters: EvaBodyUnits.centimeters(fromInches: 69), system: .imperial
        )
        height.step(.feet, by: 1)
        #expect(height.value(.feet) == 6)
        #expect(height.value(.inches) == 9)
    }

    @Test("A pound past 10 st 13 lb is 11 st 0 lb")
    func poundsCarryIntoStones() {
        var mass = EvaMassInput(
            kilograms: EvaBodyUnits.kilograms(fromPounds: 10 * 14 + 13), system: .stonesAndPounds
        )
        mass.step(.pounds, by: 1)
        #expect(mass.value(.stones) == 11)
        #expect(mass.value(.pounds) == 0)
    }

    @Test("The stones row moves the weight by fourteen pounds")
    func stonesStepByFourteenPounds() {
        var mass = EvaMassInput(
            kilograms: EvaBodyUnits.kilograms(fromPounds: 150), system: .stonesAndPounds
        )
        mass.step(.stones, by: -1)
        #expect(mass.value(.stones) == 9)
        #expect(mass.value(.pounds) == 10)
        #expect(EvaBodyUnits.pounds(fromKilograms: mass.kilograms) == 136)
    }

    // MARK: Staying inside what the API accepts

    @Test("No step from anywhere in range produces a value parseProfile would refuse")
    func steppingNeverLeavesTheRange() {
        for pounds in EvaBodyRange.pounds {
            let stored = EvaBodyUnits.kilograms(fromPounds: pounds)
            for system in [EvaUnitSystem.imperial, .stonesAndPounds, .metric] {
                let mass = EvaMassInput(kilograms: stored, system: system)
                for row in mass.rows {
                    for delta in [-1, 1] {
                        var next = mass
                        next.step(row, by: delta)
                        #expect(
                            EvaBodyRange.kilograms.contains(next.kilograms),
                            "\(pounds) lb stepped \(delta) on \(row) left the range at \(next.kilograms) kg"
                        )
                    }
                }
            }
        }

        for inches in EvaBodyRange.inches {
            let stored = EvaBodyUnits.centimeters(fromInches: inches)
            for system in [EvaUnitSystem.imperial, .metric] {
                let height = EvaHeightInput(centimeters: stored, system: system)
                for row in height.rows {
                    for delta in [-1, 1] {
                        var next = height
                        next.step(row, by: delta)
                        #expect(
                            EvaBodyRange.centimeters.contains(next.centimeters),
                            "\(inches) in stepped \(delta) on \(row) left the range at \(next.centimeters) cm"
                        )
                    }
                }
            }
        }
    }

    @Test("The bounds say they are the bounds")
    func stepsAreRefusedAtTheEnds() {
        let lightest = EvaMassInput(
            kilograms: EvaBodyUnits.kilograms(fromPounds: EvaBodyRange.pounds.lowerBound),
            system: .imperial
        )
        #expect(!lightest.canStep(.pounds, by: -1))
        #expect(lightest.canStep(.pounds, by: 1))

        let heaviest = EvaMassInput(
            kilograms: EvaBodyUnits.kilograms(fromPounds: EvaBodyRange.pounds.upperBound),
            system: .imperial
        )
        #expect(!heaviest.canStep(.pounds, by: 1))

        let shortest = EvaHeightInput(centimeters: EvaBodyRange.centimeters.lowerBound, system: .metric)
        #expect(!shortest.canStep(.centimeters, by: -1))
        #expect(shortest.canStep(.centimeters, by: 1))

        // A stone step is fourteen pounds, so it runs out long before a pound step does.
        let nearTheTop = EvaMassInput(
            kilograms: EvaBodyUnits.kilograms(fromPounds: EvaBodyRange.pounds.upperBound - 3),
            system: .stonesAndPounds
        )
        #expect(!nearTheTop.canStep(.stones, by: 1))
        #expect(nearTheTop.canStep(.pounds, by: 1))
    }
}
