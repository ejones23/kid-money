import AppIntents
import Foundation
import OSLog
import SwiftData

struct ChildEntity: AppEntity, Sendable {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Child"
    static let defaultQuery = ChildEntityQuery()

    let id: UUID
    let name: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }
}

struct ChildEntityQuery: EntityStringQuery, Sendable {
    @MainActor
    func entities(for identifiers: [UUID]) async throws -> [ChildEntity] {
        let identifierSet = Set(identifiers)
        return try activeChildren()
            .filter { identifierSet.contains($0.id) }
            .map(ChildEntity.init)
    }

    @MainActor
    func entities(matching string: String) async throws -> [ChildEntity] {
        let container = try AppModelContainer.make()
        return try LedgerService(modelContext: ModelContext(container))
            .children(matching: string)
            .map(ChildEntity.init)
    }

    @MainActor
    func suggestedEntities() async throws -> [ChildEntity] {
        try activeChildren().map(ChildEntity.init)
    }

    @MainActor
    private func activeChildren() throws -> [Child] {
        let container = try AppModelContainer.make()
        return try LedgerService(modelContext: ModelContext(container)).activeChildren()
    }
}

private extension ChildEntity {
    init(_ child: Child) {
        self.init(id: child.id, name: child.name)
    }
}

enum GiveMoneyIntentError: LocalizedError {
    case childNotFound

    var errorDescription: String? {
        "That child is no longer available in Kid Money."
    }
}

struct GiveMoneyIntent: AppIntent {
    static let title: LocalizedStringResource = "Give Money"
    static let description = IntentDescription(
        "Add money to a child's Kid Money ledger.",
        categoryName: "Ledger",
        searchKeywords: ["allowance", "child", "money"]
    )
    static let supportedModes: IntentModes = .background

    @Parameter(
        title: "Child",
        description: "The child who should receive the money.",
        requestValueDialog: "Which child should receive the money?"
    )
    var child: ChildEntity

    @Parameter(
        title: "Amount",
        description: "The amount of US dollars to add.",
        requestValueDialog: "How much money should I add?"
    )
    var amount: IntentCurrencyAmount

    static var parameterSummary: some ParameterSummary {
        Summary("Give \(\.$amount) to \(\.$child)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let logger = Logger(subsystem: "com.ejones23.KidMoney", category: "GiveMoneyIntent")
        logger.info("Give Money intent invoked")

        let cents = try MoneyConversion.usdCents(
            from: amount.amount,
            currencyCode: amount.currencyCode
        )
        logger.info("Validated a \(cents, privacy: .public)-cent adjustment")

        let container = try AppModelContainer.make()
        let context = ModelContext(container)
        let service = LedgerService(modelContext: context)
        guard let persistedChild = try service.child(id: child.id) else {
            logger.error("Child resolution became stale before persistence")
            throw GiveMoneyIntentError.childNotFound
        }

        try service.addTransaction(cents: cents, to: persistedChild, source: .siri)
        let balance = service.balance(for: persistedChild)
        logger.info("Saved Siri transaction; new balance is \(balance, privacy: .public) cents")

        let adjustmentText = MoneyFormatter.string(cents: cents)
        let balanceText = MoneyFormatter.string(cents: balance)
        return .result(
            dialog: "Added \(adjustmentText) to \(persistedChild.name). \(persistedChild.name) now has \(balanceText)."
        )
    }
}

struct KidMoneyShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: GiveMoneyIntent(),
            phrases: [
                "Give \(\.$child) money in \(.applicationName)",
                "Add money to \(\.$child) in \(.applicationName)",
                "Give money in \(.applicationName)"
            ],
            shortTitle: "Give Money",
            systemImageName: "plus.circle"
        )
    }

    static let shortcutTileColor: ShortcutTileColor = .teal
}
