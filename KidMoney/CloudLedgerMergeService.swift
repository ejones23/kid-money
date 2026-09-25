import CloudKit
import Foundation
import SwiftData

struct DecodedCloudHousehold: Equatable {
    let id: UUID
    let displayName: String
    let schemaVersion: Int
    let createdAt: Date
}

struct DecodedCloudChild: Equatable {
    let id: UUID
    let name: String
    let createdAt: Date
    let sortOrder: Int
    let isArchived: Bool
    let lastModifiedAt: Date
}

struct DecodedCloudTransaction: Equatable {
    let id: UUID
    let childID: UUID
    let amountCents: Int64
    let createdAt: Date
    let note: String?
    let source: TransactionSource
    let reversesTransactionID: UUID?
}

enum CloudLedgerRecordDecodingError: Error, Equatable {
    case unexpectedRecordType(String)
    case missingOrInvalidField(String)
    case invalidRecordName(String)
    case unsupportedSchemaVersion(Int)
}

enum CloudLedgerRecordDecoder {
    static func household(_ record: CKRecord) throws -> DecodedCloudHousehold {
        try requireType(.household, record: record)
        let id = try uuid(CloudLedgerSchema.Field.identifier, record: record)
        try requireRecordName(CloudLedgerRecordName.household(id), record: record)
        let displayName = try nonemptyString(CloudLedgerSchema.Field.displayName, record: record)
        let schemaVersion = try int(CloudLedgerSchema.Field.schemaVersion, record: record)
        guard schemaVersion > 0, schemaVersion <= CloudLedgerSchema.currentVersion else {
            throw CloudLedgerRecordDecodingError.unsupportedSchemaVersion(schemaVersion)
        }
        return DecodedCloudHousehold(
            id: id,
            displayName: displayName,
            schemaVersion: schemaVersion,
            createdAt: try date(CloudLedgerSchema.Field.createdAt, record: record)
        )
    }

    static func child(_ record: CKRecord) throws -> DecodedCloudChild {
        try requireType(.child, record: record)
        let id = try uuid(CloudLedgerSchema.Field.identifier, record: record)
        try requireRecordName(CloudLedgerRecordName.child(id), record: record)
        return DecodedCloudChild(
            id: id,
            name: try nonemptyString(CloudLedgerSchema.Field.name, record: record),
            createdAt: try date(CloudLedgerSchema.Field.createdAt, record: record),
            sortOrder: try int(CloudLedgerSchema.Field.sortOrder, record: record),
            isArchived: try bool(CloudLedgerSchema.Field.isArchived, record: record),
            lastModifiedAt: try date(CloudLedgerSchema.Field.lastModifiedAt, record: record)
        )
    }

    static func transaction(_ record: CKRecord) throws -> DecodedCloudTransaction {
        try requireType(.ledgerTransaction, record: record)
        let id = try uuid(CloudLedgerSchema.Field.identifier, record: record)
        let childID = try uuid(CloudLedgerSchema.Field.childIdentifier, record: record)
        let amountCents = try int64(CloudLedgerSchema.Field.amountCents, record: record)
        guard amountCents != 0 else {
            throw CloudLedgerRecordDecodingError.missingOrInvalidField(
                CloudLedgerSchema.Field.amountCents
            )
        }
        let sourceRawValue = try nonemptyString(CloudLedgerSchema.Field.source, record: record)
        guard let source = TransactionSource(rawValue: sourceRawValue) else {
            throw CloudLedgerRecordDecodingError.missingOrInvalidField(
                CloudLedgerSchema.Field.source
            )
        }
        let reversesTransactionID = try optionalUUID(
            CloudLedgerSchema.Field.reversesTransactionIdentifier,
            record: record
        )
        if let reversesTransactionID {
            guard id == CloudLedgerTransactionIdentity.undo(reversing: reversesTransactionID) else {
                throw CloudLedgerRecordDecodingError.missingOrInvalidField(
                    CloudLedgerSchema.Field.identifier
                )
            }
        }
        try requireRecordName(
            CloudLedgerRecordName.transaction(
                id: id,
                reversesTransactionID: reversesTransactionID
            ),
            record: record
        )
        return DecodedCloudTransaction(
            id: id,
            childID: childID,
            amountCents: amountCents,
            createdAt: try date(CloudLedgerSchema.Field.createdAt, record: record),
            note: try optionalString(CloudLedgerSchema.Field.note, record: record),
            source: source,
            reversesTransactionID: reversesTransactionID
        )
    }

    private static func requireType(
        _ type: CloudLedgerRecordType,
        record: CKRecord
    ) throws {
        guard record.recordType == type.rawValue else {
            throw CloudLedgerRecordDecodingError.unexpectedRecordType(record.recordType)
        }
    }

    private static func requireRecordName(_ expected: String, record: CKRecord) throws {
        guard record.recordID.recordName == expected else {
            throw CloudLedgerRecordDecodingError.invalidRecordName(record.recordID.recordName)
        }
    }

    private static func uuid(_ key: String, record: CKRecord) throws -> UUID {
        guard let rawValue = record[key] as? String, let value = UUID(uuidString: rawValue) else {
            throw CloudLedgerRecordDecodingError.missingOrInvalidField(key)
        }
        return value
    }

    private static func optionalUUID(_ key: String, record: CKRecord) throws -> UUID? {
        guard record[key] != nil else { return nil }
        return try uuid(key, record: record)
    }

    private static func nonemptyString(_ key: String, record: CKRecord) throws -> String {
        guard let value = record[key] as? String,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CloudLedgerRecordDecodingError.missingOrInvalidField(key)
        }
        return value
    }

    private static func optionalString(_ key: String, record: CKRecord) throws -> String? {
        guard record[key] != nil else { return nil }
        guard let value = record[key] as? String else {
            throw CloudLedgerRecordDecodingError.missingOrInvalidField(key)
        }
        return value
    }

    private static func date(_ key: String, record: CKRecord) throws -> Date {
        guard let value = record[key] as? Date else {
            throw CloudLedgerRecordDecodingError.missingOrInvalidField(key)
        }
        return value
    }

    private static func bool(_ key: String, record: CKRecord) throws -> Bool {
        let value = try int64(key, record: record)
        guard value == 0 || value == 1 else {
            throw CloudLedgerRecordDecodingError.missingOrInvalidField(key)
        }
        return value == 1
    }

    private static func int(_ key: String, record: CKRecord) throws -> Int {
        let value = try int64(key, record: record)
        guard let result = Int(exactly: value) else {
            throw CloudLedgerRecordDecodingError.missingOrInvalidField(key)
        }
        return result
    }

    private static func int64(_ key: String, record: CKRecord) throws -> Int64 {
        guard let number = record[key] as? NSNumber else {
            throw CloudLedgerRecordDecodingError.missingOrInvalidField(key)
        }
        let decimal = number.decimalValue
        var rounded = Decimal()
        var candidate = decimal
        NSDecimalRound(&rounded, &candidate, 0, .plain)
        guard rounded == decimal,
              decimal >= Decimal(Int64.min),
              decimal <= Decimal(Int64.max) else {
            throw CloudLedgerRecordDecodingError.missingOrInvalidField(key)
        }
        return NSDecimalNumber(decimal: decimal).int64Value
    }
}

@Model
final class DeferredCloudTransaction {
    @Attribute(.unique) var id: UUID
    var householdID: UUID
    var childID: UUID
    var amountCents: Int64
    var createdAt: Date
    var note: String?
    var sourceRawValue: String
    var reversesTransactionID: UUID?

    init(householdID: UUID, transaction: DecodedCloudTransaction) {
        self.id = transaction.id
        self.householdID = householdID
        self.childID = transaction.childID
        self.amountCents = transaction.amountCents
        self.createdAt = transaction.createdAt
        self.note = transaction.note
        self.sourceRawValue = transaction.source.rawValue
        self.reversesTransactionID = transaction.reversesTransactionID
    }

    var decoded: DecodedCloudTransaction? {
        guard let source = TransactionSource(rawValue: sourceRawValue) else { return nil }
        return DecodedCloudTransaction(
            id: id,
            childID: childID,
            amountCents: amountCents,
            createdAt: createdAt,
            note: note,
            source: source,
            reversesTransactionID: reversesTransactionID
        )
    }
}

struct CloudLedgerMergeSummary: Equatable {
    var householdUpdated = false
    var insertedChildren = 0
    var updatedChildren = 0
    var insertedTransactions = 0
    var canonicalizedUndoTransactions = 0
    var unchangedRecords = 0
    var ignoredSystemRecords = 0
    var deferredTransactions = 0
}

enum CloudLedgerMergeError: Error, Equatable {
    case wrongZone
    case householdMismatch
    case duplicateRecordConflict(String)
    case immutableTransactionConflict(UUID)
    case balanceOutOfRange(UUID)
    case corruptDeferredTransaction(UUID)
}

@MainActor
struct CloudLedgerMergeService {
    let modelContext: ModelContext

    func merge(
        records: [CKRecord],
        into sharedLedger: SharedLedgerState
    ) throws -> CloudLedgerMergeSummary {
        do {
            var summary = CloudLedgerMergeSummary()
            var households: [DecodedCloudHousehold] = []
            var children: [DecodedCloudChild] = []
            var transactions: [DecodedCloudTransaction] = []
            var decodedByRecordName: [String: DecodedRecord] = [:]

            for record in records {
                guard record.recordID.zoneID == sharedLedger.zoneID else {
                    throw CloudLedgerMergeError.wrongZone
                }
                let decoded: DecodedRecord
                switch CloudLedgerRecordType(rawValue: record.recordType) {
                case .household:
                    decoded = .household(try CloudLedgerRecordDecoder.household(record))
                case .child:
                    decoded = .child(try CloudLedgerRecordDecoder.child(record))
                case .ledgerTransaction:
                    decoded = .transaction(try CloudLedgerRecordDecoder.transaction(record))
                case nil where record.recordType == "cloudkit.share":
                    summary.ignoredSystemRecords += 1
                    continue
                case nil:
                    throw CloudLedgerRecordDecodingError.unexpectedRecordType(record.recordType)
                }
                if let existing = decodedByRecordName[record.recordID.recordName], existing != decoded {
                    throw CloudLedgerMergeError.duplicateRecordConflict(record.recordID.recordName)
                }
                decodedByRecordName[record.recordID.recordName] = decoded
            }

            for decoded in decodedByRecordName.values {
                switch decoded {
                case .household(let value): households.append(value)
                case .child(let value): children.append(value)
                case .transaction(let value): transactions.append(value)
                }
            }

            for household in households.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
                guard household.id == sharedLedger.householdID else {
                    throw CloudLedgerMergeError.householdMismatch
                }
                if sharedLedger.displayName != household.displayName
                    || sharedLedger.schemaVersion != household.schemaVersion
                    || sharedLedger.createdAt != household.createdAt {
                    sharedLedger.displayName = household.displayName
                    sharedLedger.schemaVersion = household.schemaVersion
                    sharedLedger.createdAt = household.createdAt
                    summary.householdUpdated = true
                } else {
                    summary.unchangedRecords += 1
                }
            }

            var localChildren = Dictionary(
                uniqueKeysWithValues: try modelContext.fetch(FetchDescriptor<Child>()).map {
                    ($0.id, $0)
                }
            )
            for remote in children.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
                if let local = localChildren[remote.id] {
                    if shouldApply(remote: remote, over: local) {
                        local.name = remote.name
                        local.sortOrder = remote.sortOrder
                        local.isArchived = remote.isArchived
                        local.lastModifiedAt = remote.lastModifiedAt
                        summary.updatedChildren += 1
                    } else {
                        summary.unchangedRecords += 1
                    }
                } else {
                    let child = Child(
                        id: remote.id,
                        name: remote.name,
                        createdAt: remote.createdAt,
                        sortOrder: remote.sortOrder,
                        isArchived: remote.isArchived
                    )
                    child.lastModifiedAt = remote.lastModifiedAt
                    modelContext.insert(child)
                    localChildren[child.id] = child
                    summary.insertedChildren += 1
                }
            }

            var localTransactions = Dictionary(
                uniqueKeysWithValues: try modelContext.fetch(
                    FetchDescriptor<LedgerTransaction>()
                ).map { ($0.id, $0) }
            )
            var localUndoByOriginalID: [UUID: LedgerTransaction] = [:]
            for transaction in localTransactions.values {
                if let originalID = transaction.reversesTransactionID {
                    if localUndoByOriginalID[originalID] != nil {
                        throw CloudLedgerMergeError.immutableTransactionConflict(transaction.id)
                    }
                    localUndoByOriginalID[originalID] = transaction
                }
            }
            var deferredByID = Dictionary(
                uniqueKeysWithValues: try modelContext.fetch(
                    FetchDescriptor<DeferredCloudTransaction>()
                ).filter { $0.householdID == sharedLedger.householdID }.map { ($0.id, $0) }
            )
            var remoteTransactions: [UUID: DecodedCloudTransaction] = [:]
            for transaction in transactions {
                if let existing = remoteTransactions[transaction.id], existing != transaction {
                    throw CloudLedgerMergeError.immutableTransactionConflict(transaction.id)
                }
                if let deferred = deferredByID[transaction.id] {
                    guard deferred.decoded == transaction else {
                        throw CloudLedgerMergeError.immutableTransactionConflict(transaction.id)
                    }
                }
                remoteTransactions[transaction.id] = transaction
            }
            for (id, deferred) in deferredByID {
                guard let decoded = deferred.decoded else {
                    throw CloudLedgerMergeError.corruptDeferredTransaction(id)
                }
                remoteTransactions[id] = decoded
            }

            var balances: [UUID: Int64] = [:]
            for transaction in localTransactions.values.sorted(by: transactionOrder) {
                guard let childID = transaction.child?.id else { continue }
                let addition = balances[childID, default: 0]
                    .addingReportingOverflow(transaction.amountCents)
                guard !addition.overflow else {
                    throw CloudLedgerMergeError.balanceOutOfRange(childID)
                }
                balances[childID] = addition.partialValue
            }

            for remote in remoteTransactions.values.sorted(by: decodedTransactionOrder) {
                guard let child = localChildren[remote.childID] else {
                    if deferredByID[remote.id] == nil {
                        let deferred = DeferredCloudTransaction(
                            householdID: sharedLedger.householdID,
                            transaction: remote
                        )
                        modelContext.insert(deferred)
                        deferredByID[remote.id] = deferred
                    }
                    continue
                }

                if let originalID = remote.reversesTransactionID,
                   let semanticUndo = localUndoByOriginalID[originalID] {
                    guard sameLedgerEffect(semanticUndo, remote: remote) else {
                        throw CloudLedgerMergeError.immutableTransactionConflict(remote.id)
                    }
                    if semanticUndo.id != remote.id
                        || semanticUndo.createdAt != remote.createdAt
                        || semanticUndo.note != remote.note
                        || semanticUndo.source != remote.source {
                        localTransactions.removeValue(forKey: semanticUndo.id)
                        semanticUndo.id = remote.id
                        semanticUndo.createdAt = remote.createdAt
                        semanticUndo.note = remote.note
                        semanticUndo.sourceRawValue = remote.source.rawValue
                        localTransactions[remote.id] = semanticUndo
                        summary.canonicalizedUndoTransactions += 1
                    } else {
                        summary.unchangedRecords += 1
                    }
                    if let deferred = deferredByID.removeValue(forKey: remote.id) {
                        modelContext.delete(deferred)
                    }
                    continue
                }

                if let local = localTransactions[remote.id] {
                    guard sameTransaction(local, remote: remote) else {
                        throw CloudLedgerMergeError.immutableTransactionConflict(remote.id)
                    }
                    summary.unchangedRecords += 1
                } else {
                    let addition = balances[remote.childID, default: 0]
                        .addingReportingOverflow(remote.amountCents)
                    guard !addition.overflow else {
                        throw CloudLedgerMergeError.balanceOutOfRange(remote.childID)
                    }
                    let transaction = LedgerTransaction(
                        id: remote.id,
                        amountCents: remote.amountCents,
                        createdAt: remote.createdAt,
                        note: remote.note,
                        source: remote.source,
                        reversesTransactionID: remote.reversesTransactionID,
                        child: child
                    )
                    modelContext.insert(transaction)
                    localTransactions[remote.id] = transaction
                    if let originalID = remote.reversesTransactionID {
                        localUndoByOriginalID[originalID] = transaction
                    }
                    balances[remote.childID] = addition.partialValue
                    summary.insertedTransactions += 1
                }
                if let deferred = deferredByID.removeValue(forKey: remote.id) {
                    modelContext.delete(deferred)
                }
            }

            summary.deferredTransactions = deferredByID.count
            try modelContext.save()
            return summary
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    private func shouldApply(remote: DecodedCloudChild, over local: Child) -> Bool {
        let localModifiedAt = local.lastModifiedAt ?? local.createdAt
        if remote.lastModifiedAt != localModifiedAt {
            return remote.lastModifiedAt > localModifiedAt
        }
        if remote.name != local.name { return remote.name > local.name }
        if remote.sortOrder != local.sortOrder { return remote.sortOrder > local.sortOrder }
        return remote.isArchived && !local.isArchived
    }

    private func sameTransaction(
        _ local: LedgerTransaction,
        remote: DecodedCloudTransaction
    ) -> Bool {
        local.id == remote.id && sameLedgerEffect(local, remote: remote)
            && local.createdAt == remote.createdAt
            && local.note == remote.note
            && local.source == remote.source
    }

    private func sameLedgerEffect(
        _ local: LedgerTransaction,
        remote: DecodedCloudTransaction
    ) -> Bool {
        local.child?.id == remote.childID
            && local.amountCents == remote.amountCents
            && local.reversesTransactionID == remote.reversesTransactionID
    }

    private func transactionOrder(
        _ lhs: LedgerTransaction,
        _ rhs: LedgerTransaction
    ) -> Bool {
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private func decodedTransactionOrder(
        _ lhs: DecodedCloudTransaction,
        _ rhs: DecodedCloudTransaction
    ) -> Bool {
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private enum DecodedRecord: Equatable {
        case household(DecodedCloudHousehold)
        case child(DecodedCloudChild)
        case transaction(DecodedCloudTransaction)
    }
}
