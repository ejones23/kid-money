import AppIntentsTesting
import XCTest

@available(iOS 27.0, *)
final class KidMoneyAppIntentsTests: XCTestCase {
    @MainActor
    func testPresetIntentDefinitionsAndEntityQueryReachAppProcess() async throws {
        // A first launch lets the simulator register the app's intent metadata
        // before AppIntentsTesting opens its out-of-process connection.
        let app = XCUIApplication()
        app.launch()

        let definitions = IntentDefinitions(
            bundleIdentifier: "io.github.ejones23.KidMoney"
        )

        let giveDefinition = definitions.intents["GivePresetMoneyIntent"]
        XCTAssertEqual(giveDefinition.identifier, "GivePresetMoneyIntent")
        XCTAssertEqual(
            definitions.intents["TakePresetMoneyIntent"].identifier,
            "TakePresetMoneyIntent"
        )

        let childName = "Intent Test \(UUID().uuidString.prefix(8))"
        try await definitions.intents["SeedAppIntentsTestChildIntent"]
            .makeIntent(name: childName)
            .run()

        let matches = try await definitions.entities["LedgerAdjustmentEntity"]
            .entities(matching: "\(childName) fifteen cents")
        XCTAssertEqual(matches.count, 1)

        try await giveDefinition
            .makeIntent(adjustment: matches[0])
            .run()

        let balanceResult = try await definitions.intents["ReadAppIntentsTestBalanceIntent"]
            .makeIntent(name: childName)
            .run()
        let balance: String = try balanceResult.value
        XCTAssertEqual(balance, "15")
    }
}
