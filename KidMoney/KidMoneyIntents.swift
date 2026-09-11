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

enum KidMoneyIntentError: LocalizedError {
    case childNotFound

    var errorDescription: String? {
        "That child is no longer available in Kid Money."
    }
}

enum CoinDenomination: String, AppEnum {
    case nickel
    case dime
    case quarter
    case halfDollar
    case dollar

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Coin"
    static let caseDisplayRepresentations: [CoinDenomination: DisplayRepresentation] = [
        .nickel: DisplayRepresentation(
            title: "Nickel",
            synonyms: ["a nickel", "one nickel", "five-cent coin"]
        ),
        .dime: DisplayRepresentation(
            title: "Dime",
            synonyms: ["a dime", "one dime", "ten-cent coin"]
        ),
        .quarter: DisplayRepresentation(
            title: "Quarter",
            synonyms: ["a quarter", "one quarter", "twenty-five-cent coin"]
        ),
        .halfDollar: DisplayRepresentation(
            title: "Half Dollar",
            synonyms: ["a half dollar", "one half dollar", "fifty-cent coin"]
        ),
        .dollar: DisplayRepresentation(
            title: "Dollar",
            synonyms: ["a dollar", "one dollar", "dollar coin"]
        )
    ]

    var cents: Int64 {
        switch self {
        case .nickel: 5
        case .dime: 10
        case .quarter: 25
        case .halfDollar: 50
        case .dollar: 100
        }
    }
}

@MainActor
private func intentLedger(for entity: ChildEntity) throws -> (LedgerService, Child) {
    let container = try AppModelContainer.make()
    let service = LedgerService(modelContext: ModelContext(container))
    guard let child = try service.child(id: entity.id) else {
        throw KidMoneyIntentError.childNotFound
    }
    return (service, child)
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

        let requestedAmount: IntentCurrencyAmount
        if amount.amount == .zero {
            requestedAmount = try await $amount.requestValue("How much money should I add?")
        } else {
            requestedAmount = amount
        }

        let cents = try MoneyConversion.usdCents(
            from: requestedAmount.amount,
            currencyCode: requestedAmount.currencyCode
        )
        logger.info("Validated a \(cents, privacy: .public)-cent adjustment")

        let (service, persistedChild) = try intentLedger(for: child)

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

struct TakeMoneyIntent: AppIntent {
    static let title: LocalizedStringResource = "Take Money"
    static let description = IntentDescription(
        "Subtract money from a child's Kid Money ledger.",
        categoryName: "Ledger",
        searchKeywords: ["allowance", "child", "money", "subtract"]
    )
    static let supportedModes: IntentModes = .background

    @Parameter(
        title: "Child",
        description: "The child whose balance should be reduced.",
        requestValueDialog: "Which child should I take money from?"
    )
    var child: ChildEntity

    @Parameter(
        title: "Amount",
        description: "The amount of US dollars to subtract.",
        requestValueDialog: "How much money should I take?"
    )
    var amount: IntentCurrencyAmount

    static var parameterSummary: some ParameterSummary {
        Summary("Take \(\.$amount) from \(\.$child)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let logger = Logger(subsystem: "com.ejones23.KidMoney", category: "TakeMoneyIntent")
        logger.info("Take Money intent invoked")

        let requestedAmount: IntentCurrencyAmount
        if amount.amount == .zero {
            requestedAmount = try await $amount.requestValue("How much money should I take?")
        } else {
            requestedAmount = amount
        }

        let cents = try MoneyConversion.usdCents(
            from: requestedAmount.amount,
            currencyCode: requestedAmount.currencyCode
        )
        logger.info("Validated a \(cents, privacy: .public)-cent subtraction")

        let (service, persistedChild) = try intentLedger(for: child)
        try service.addTransaction(cents: -cents, to: persistedChild, source: .siri)
        let balance = service.balance(for: persistedChild)
        logger.info("Saved Siri transaction; new balance is \(balance, privacy: .public) cents")

        return .result(
            dialog: "Removed \(MoneyFormatter.string(cents: cents)) from \(persistedChild.name). \(persistedChild.name) now has \(MoneyFormatter.string(cents: balance))."
        )
    }
}

struct GetBalanceIntent: AppIntent {
    static let title: LocalizedStringResource = "Check Balance"
    static let description = IntentDescription(
        "Report a child's current Kid Money balance.",
        categoryName: "Ledger",
        searchKeywords: ["allowance", "balance", "child", "money"]
    )
    static let supportedModes: IntentModes = .background

    @Parameter(
        title: "Child",
        description: "The child whose balance should be reported.",
        requestValueDialog: "Whose balance should I check?"
    )
    var child: ChildEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Check \(\.$child)'s balance")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let logger = Logger(subsystem: "com.ejones23.KidMoney", category: "GetBalanceIntent")
        logger.info("Check Balance intent invoked")

        let (service, persistedChild) = try intentLedger(for: child)
        let balance = service.balance(for: persistedChild)
        logger.info("Returning a \(balance, privacy: .public)-cent balance")
        return .result(
            dialog: "\(persistedChild.name) has \(MoneyFormatter.string(cents: balance))."
        )
    }
}

struct UndoLastTransactionIntent: AppIntent {
    static let title: LocalizedStringResource = "Undo Last Transaction"
    static let description = IntentDescription(
        "Reverse the most recent transaction in Kid Money without deleting history.",
        categoryName: "Ledger",
        searchKeywords: ["allowance", "money", "reverse", "undo"]
    )
    static let supportedModes: IntentModes = .background

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let logger = Logger(subsystem: "com.ejones23.KidMoney", category: "UndoLastTransactionIntent")
        logger.info("Undo Last Transaction intent invoked")

        let container = try AppModelContainer.make()
        let service = LedgerService(modelContext: ModelContext(container))
        let result = try service.undoLastTransaction(source: .siri)
        let magnitude = result.originalAmountCents > 0
            ? result.originalAmountCents
            : -result.originalAmountCents
        let action = result.originalAmountCents > 0 ? "adding" : "removing"
        logger.info("Saved undo transaction; new balance is \(result.newBalanceCents, privacy: .public) cents")

        return .result(
            dialog: "Undid \(action) \(MoneyFormatter.string(cents: magnitude)) for \(result.child.name). \(result.child.name) now has \(MoneyFormatter.string(cents: result.newBalanceCents))."
        )
    }
}

struct GiveCoinIntent: AppIntent {
    static let title: LocalizedStringResource = "Give Coin"
    static let description = IntentDescription(
        "Add a named US coin denomination to a child's Kid Money ledger.",
        categoryName: "Ledger",
        searchKeywords: ["allowance", "coin", "dime", "nickel", "quarter"]
    )
    static let supportedModes: IntentModes = .background

    @Parameter(
        title: "Child",
        description: "The child who should receive the coin.",
        requestValueDialog: "Which child should receive the coin?"
    )
    var child: ChildEntity

    @Parameter(
        title: "Coin",
        description: "The US coin denomination to add.",
        requestValueDialog: "Which coin?"
    )
    var denomination: CoinDenomination

    static var parameterSummary: some ParameterSummary {
        Summary("Give \(\.$denomination) to \(\.$child)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let logger = Logger(subsystem: "com.ejones23.KidMoney", category: "GiveCoinIntent")
        logger.info("Give Coin intent invoked with \(denomination.cents, privacy: .public) cents")
        let (service, persistedChild) = try intentLedger(for: child)
        try service.addTransaction(cents: denomination.cents, to: persistedChild, source: .siri)
        let balance = service.balance(for: persistedChild)
        return .result(
            dialog: "Added \(MoneyFormatter.string(cents: denomination.cents)) to \(persistedChild.name). \(persistedChild.name) now has \(MoneyFormatter.string(cents: balance))."
        )
    }
}

struct TakeCoinIntent: AppIntent {
    static let title: LocalizedStringResource = "Take Coin"
    static let description = IntentDescription(
        "Subtract a named US coin denomination from a child's Kid Money ledger.",
        categoryName: "Ledger",
        searchKeywords: ["allowance", "coin", "dime", "nickel", "quarter", "subtract"]
    )
    static let supportedModes: IntentModes = .background

    @Parameter(
        title: "Child",
        description: "The child whose balance should be reduced.",
        requestValueDialog: "Which child should I take the coin from?"
    )
    var child: ChildEntity

    @Parameter(
        title: "Coin",
        description: "The US coin denomination to subtract.",
        requestValueDialog: "Which coin?"
    )
    var denomination: CoinDenomination

    static var parameterSummary: some ParameterSummary {
        Summary("Take \(\.$denomination) from \(\.$child)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let logger = Logger(subsystem: "com.ejones23.KidMoney", category: "TakeCoinIntent")
        logger.info("Take Coin intent invoked with \(denomination.cents, privacy: .public) cents")
        let (service, persistedChild) = try intentLedger(for: child)
        try service.addTransaction(cents: -denomination.cents, to: persistedChild, source: .siri)
        let balance = service.balance(for: persistedChild)
        return .result(
            dialog: "Removed \(MoneyFormatter.string(cents: denomination.cents)) from \(persistedChild.name). \(persistedChild.name) now has \(MoneyFormatter.string(cents: balance))."
        )
    }
}

struct KidMoneyShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: GiveMoneyIntent(),
            phrases: [
                "Give \(\.$child) money in \(.applicationName)",
                "Give money in \(.applicationName)"
            ],
            shortTitle: "Give Money",
            systemImageName: "plus.circle"
        )
        AppShortcut(
            intent: TakeMoneyIntent(),
            phrases: [
                "Take money from \(\.$child) in \(.applicationName)",
                "Take money in \(.applicationName)"
            ],
            shortTitle: "Take Money",
            systemImageName: "minus.circle"
        )
        AppShortcut(
            intent: GetBalanceIntent(),
            phrases: [
                "Check \(\.$child) balance in \(.applicationName)",
                "Check balance in \(.applicationName)"
            ],
            shortTitle: "Check Balance",
            systemImageName: "dollarsign.circle"
        )
        AppShortcut(
            intent: UndoLastTransactionIntent(),
            phrases: [
                "Undo kid money in \(.applicationName)",
                "Undo the last transaction in \(.applicationName)"
            ],
            shortTitle: "Undo Last Transaction",
            systemImageName: "arrow.uturn.backward.circle"
        )
        AppShortcut(
            intent: GiveCoinIntent(),
            phrases: [
                "Give a \(\.$denomination) in \(.applicationName)",
                "Give \(\.$child) a coin in \(.applicationName)",
                "Give a coin in \(.applicationName)"
            ],
            shortTitle: "Give Coin",
            systemImageName: "centsign.circle"
        )
        AppShortcut(
            intent: TakeCoinIntent(),
            phrases: [
                "Take a \(\.$denomination) in \(.applicationName)",
                "Take a coin from \(\.$child) in \(.applicationName)",
                "Take a coin in \(.applicationName)"
            ],
            shortTitle: "Take Coin",
            systemImageName: "centsign.circle"
        )
    }

    static let shortcutTileColor: ShortcutTileColor = .teal
}
