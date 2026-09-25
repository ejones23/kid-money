import Foundation
import OSLog
import SwiftData

enum LedgerError: LocalizedError, Equatable {
    case emptyName
    case nonPositiveAmount
    case balanceOutOfRange
    case nothingToUndo
    case transactionAmountOutOfRange

    var errorDescription: String? {
        switch self {
        case .emptyName: "Enter a child's name."
        case .nonPositiveAmount: "The amount must be greater than zero."
        case .balanceOutOfRange: "That transaction would make the balance too large."
        case .nothingToUndo: "There are no transactions to undo."
        case .transactionAmountOutOfRange: "That transaction cannot be reversed."
        }
    }
}

struct UndoResult {
    let child: Child
    let originalAmountCents: Int64
    let newBalanceCents: Int64
}

@MainActor
struct LedgerService {
    private static let logger = Logger(
        subsystem: "io.github.ejones23.KidMoney",
        category: "Ledger"
    )

    let modelContext: ModelContext

    func activeChildren() throws -> [Child] {
        let descriptor = FetchDescriptor<Child>(
            predicate: #Predicate { !$0.isArchived },
            sortBy: [SortDescriptor(\Child.sortOrder), SortDescriptor(\Child.name, order: .forward)]
        )
        return try modelContext.fetch(descriptor)
    }

    func child(id: UUID) throws -> Child? {
        let descriptor = FetchDescriptor<Child>(
            predicate: #Predicate { $0.id == id && !$0.isArchived }
        )
        return try modelContext.fetch(descriptor).first
    }

    func children(matching name: String) throws -> [Child] {
        let query = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }

        let children = try activeChildren()
        let exactMatches = children.filter {
            $0.name.compare(query, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }
        if !exactMatches.isEmpty {
            return exactMatches
        }
        return children.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    @discardableResult
    func addChild(named name: String) throws -> Child {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { throw LedgerError.emptyName }

        let child = Child(name: trimmedName, sortOrder: try activeChildren().count)
        modelContext.insert(child)
        try enqueueCloudSave(for: child)
        try modelContext.save()
        Self.logger.info("Saved child creation")
        return child
    }

    func renameChild(_ child: Child, to name: String) throws {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { throw LedgerError.emptyName }

        child.name = trimmedName
        child.lastModifiedAt = .now
        try enqueueCloudSave(for: child)
        try modelContext.save()
        Self.logger.info("Saved child rename")
    }

    func archiveChild(_ child: Child) throws {
        child.isArchived = true
        child.lastModifiedAt = .now
        try enqueueCloudSave(for: child)
        try modelContext.save()
        Self.logger.info("Saved child archive")
    }

    @discardableResult
    func addTransaction(
        id: UUID = UUID(),
        cents: Int64,
        to child: Child,
        note: String? = nil,
        source: TransactionSource = .manual,
        reversesTransactionID: UUID? = nil
    ) throws -> LedgerTransaction {
        guard cents != 0 else { throw LedgerError.nonPositiveAmount }
        let addition = balance(for: child).addingReportingOverflow(cents)
        guard !addition.overflow else {
            Self.logger.error("Rejected transaction because the resulting balance overflowed")
            throw LedgerError.balanceOutOfRange
        }
        let transaction = LedgerTransaction(
            id: id,
            amountCents: cents,
            note: note,
            source: source,
            reversesTransactionID: reversesTransactionID,
            child: child
        )
        modelContext.insert(transaction)
        try enqueueCloudSave(for: transaction)
        try modelContext.save()
        Self.logger.info(
            "Saved \(cents, privacy: .private) cent \(source.rawValue, privacy: .public) transaction"
        )
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

    func undoLastTransaction(source: TransactionSource = .manual) throws -> UndoResult {
        let descriptor = FetchDescriptor<LedgerTransaction>(
            sortBy: [SortDescriptor(\LedgerTransaction.createdAt, order: .reverse)]
        )
        let transactions = try modelContext.fetch(descriptor)
        let reversedTransactionIDs = Set(transactions.compactMap(\.reversesTransactionID))
        guard let original = transactions.first(where: {
            $0.reversesTransactionID == nil
                && !reversedTransactionIDs.contains($0.id)
                && $0.child != nil
        }), let child = original.child else {
            throw LedgerError.nothingToUndo
        }
        guard original.amountCents != .min else {
            Self.logger.error("Rejected undo of minimum Int64 transaction")
            throw LedgerError.transactionAmountOutOfRange
        }

        try addTransaction(
            id: CloudLedgerTransactionIdentity.undo(reversing: original.id),
            cents: -original.amountCents,
            to: child,
            source: source,
            reversesTransactionID: original.id
        )
        let result = UndoResult(
            child: child,
            originalAmountCents: original.amountCents,
            newBalanceCents: balance(for: child)
        )
        Self.logger.info("Saved compensating undo transaction")
        return result
    }

    private func activeSharedLedger() throws -> SharedLedgerState? {
        try modelContext.fetch(FetchDescriptor<SharedLedgerState>()).first {
            $0.phase == .active
        }
    }

    private func enqueueCloudSave(for child: Child) throws {
        guard let sharedLedger = try activeSharedLedger() else { return }
        try enqueueCloudSave(
            householdID: sharedLedger.householdID,
            recordType: .child,
            recordName: CloudLedgerRecordName.child(child.id)
        )
    }

    private func enqueueCloudSave(for transaction: LedgerTransaction) throws {
        guard let sharedLedger = try activeSharedLedger() else { return }
        try enqueueCloudSave(
            householdID: sharedLedger.householdID,
            recordType: .ledgerTransaction,
            recordName: CloudLedgerRecordName.transaction(
                id: transaction.id,
                reversesTransactionID: transaction.reversesTransactionID
            )
        )
    }

    private func enqueueCloudSave(
        householdID: UUID,
        recordType: CloudLedgerRecordType,
        recordName: String
    ) throws {
        let key = PendingCloudChange.makeDeduplicationKey(
            householdID: householdID,
            operation: .save,
            recordName: recordName
        )
        let descriptor = FetchDescriptor<PendingCloudChange>(
            predicate: #Predicate { $0.deduplicationKey == key }
        )
        if let existing = try modelContext.fetch(descriptor).first {
            existing.enqueuedAt = .now
            existing.attemptCount = 0
            existing.lastAttemptAt = nil
            existing.lastErrorCode = nil
        } else {
            modelContext.insert(PendingCloudChange(
                householdID: householdID,
                operation: .save,
                recordType: recordType,
                recordName: recordName
            ))
        }
    }
}
