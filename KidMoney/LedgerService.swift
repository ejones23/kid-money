import Foundation
import SwiftData

enum LedgerError: LocalizedError {
    case emptyName
    case nonPositiveAmount

    var errorDescription: String? {
        switch self {
        case .emptyName: "Enter a child's name."
        case .nonPositiveAmount: "The amount must be greater than zero."
        }
    }
}

@MainActor
struct LedgerService {
    let modelContext: ModelContext

    func activeChildren() throws -> [Child] {
        let descriptor = FetchDescriptor<Child>(
            predicate: #Predicate { !$0.isArchived },
            sortBy: [SortDescriptor(\Child.sortOrder), SortDescriptor(\Child.name, order: .forward)]
        )
        return try modelContext.fetch(descriptor)
    }

    @discardableResult
    func addChild(named name: String) throws -> Child {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { throw LedgerError.emptyName }

        let child = Child(name: trimmedName, sortOrder: try activeChildren().count)
        modelContext.insert(child)
        try modelContext.save()
        return child
    }

    @discardableResult
    func addTransaction(
        cents: Int64,
        to child: Child,
        note: String? = nil,
        source: TransactionSource = .manual
    ) throws -> LedgerTransaction {
        guard cents != 0 else { throw LedgerError.nonPositiveAmount }
        let transaction = LedgerTransaction(amountCents: cents, note: note, source: source, child: child)
        modelContext.insert(transaction)
        try modelContext.save()
        return transaction
    }

    func balance(for child: Child) -> Int64 {
        child.transactions.reduce(0) { $0 + $1.amountCents }
    }

    func transactions(for child: Child) throws -> [LedgerTransaction] {
        let childID = child.id
        let descriptor = FetchDescriptor<LedgerTransaction>(
            predicate: #Predicate { $0.child?.id == childID },
            sortBy: [SortDescriptor(\LedgerTransaction.createdAt, order: .reverse)]
        )
        return try modelContext.fetch(descriptor)
    }
}

