import CloudKit
import CryptoKit
import Foundation
import SwiftData

enum SharedLedgerRole: String, Codable {
    case owner
    case participant
}

enum SharedLedgerDatabaseScope: String, Codable {
    case privateDatabase
    case sharedDatabase
}

enum SharedLedgerPhase: String, Codable {
    case preparing
    case active
    case attentionRequired
}

@Model
final class SharedLedgerState {
    @Attribute(.unique) var householdID: UUID
    var displayName: String
    var zoneName: String
    var zoneOwnerName: String
    var roleRawValue: String
    var databaseScopeRawValue: String
    var phaseRawValue: String
    var schemaVersion: Int
    var createdAt: Date
    var accountRecordName: String? = nil

    init(
        householdID: UUID = UUID(),
        displayName: String,
        zoneName: String,
        zoneOwnerName: String,
        role: SharedLedgerRole,
        databaseScope: SharedLedgerDatabaseScope,
        phase: SharedLedgerPhase,
        schemaVersion: Int = CloudLedgerSchema.currentVersion,
        createdAt: Date = .now
    ) {
        self.householdID = householdID
        self.displayName = displayName
        self.zoneName = zoneName
        self.zoneOwnerName = zoneOwnerName
        self.roleRawValue = role.rawValue
        self.databaseScopeRawValue = databaseScope.rawValue
        self.phaseRawValue = phase.rawValue
        self.schemaVersion = schemaVersion
        self.createdAt = createdAt
    }

    var role: SharedLedgerRole? {
        SharedLedgerRole(rawValue: roleRawValue)
    }

    var databaseScope: SharedLedgerDatabaseScope? {
        SharedLedgerDatabaseScope(rawValue: databaseScopeRawValue)
    }

    var phase: SharedLedgerPhase? {
        SharedLedgerPhase(rawValue: phaseRawValue)
    }

    var zoneID: CKRecordZone.ID {
        CKRecordZone.ID(zoneName: zoneName, ownerName: zoneOwnerName)
    }
}

enum CloudLedgerRecordType: String, Codable {
    case household = "Household"
    case child = "Child"
    case ledgerTransaction = "LedgerTransaction"
}

enum PendingCloudOperation: String, Codable {
    case save
    case delete
}

@Model
final class PendingCloudChange {
    @Attribute(.unique) var deduplicationKey: String
    var id: UUID
    var householdID: UUID
    var operationRawValue: String
    var recordTypeRawValue: String
    var recordName: String
    var enqueuedAt: Date
    var attemptCount: Int
    var lastAttemptAt: Date?
    var lastErrorCode: String?

    init(
        id: UUID = UUID(),
        householdID: UUID,
        operation: PendingCloudOperation,
        recordType: CloudLedgerRecordType,
        recordName: String,
        enqueuedAt: Date = .now,
        attemptCount: Int = 0,
        lastAttemptAt: Date? = nil,
        lastErrorCode: String? = nil
    ) {
        self.id = id
        self.householdID = householdID
        self.operationRawValue = operation.rawValue
        self.recordTypeRawValue = recordType.rawValue
        self.recordName = recordName
        self.deduplicationKey = Self.makeDeduplicationKey(
            householdID: householdID,
            operation: operation,
            recordName: recordName
        )
        self.enqueuedAt = enqueuedAt
        self.attemptCount = attemptCount
        self.lastAttemptAt = lastAttemptAt
        self.lastErrorCode = lastErrorCode
    }

    var operation: PendingCloudOperation? {
        PendingCloudOperation(rawValue: operationRawValue)
    }

    var recordType: CloudLedgerRecordType? {
        CloudLedgerRecordType(rawValue: recordTypeRawValue)
    }

    static func makeDeduplicationKey(
        householdID: UUID,
        operation: PendingCloudOperation,
        recordName: String
    ) -> String {
        "\(householdID.uuidString.lowercased())|\(operation.rawValue)|\(recordName)"
    }
}

enum CloudLedgerSchema {
    static let currentVersion = 1

    enum Field {
        static let identifier = "identifier"
        static let displayName = "displayName"
        static let schemaVersion = "schemaVersion"
        static let createdAt = "createdAt"
        static let name = "name"
        static let sortOrder = "sortOrder"
        static let isArchived = "isArchived"
        static let lastModifiedAt = "lastModifiedAt"
        static let childIdentifier = "childIdentifier"
        static let amountCents = "amountCents"
        static let note = "note"
        static let source = "source"
        static let reversesTransactionIdentifier = "reversesTransactionIdentifier"
    }
}

enum CloudLedgerRecordName {
    static func household(_ id: UUID) -> String {
        "household-\(canonical(id))"
    }

    static func child(_ id: UUID) -> String {
        "child-\(canonical(id))"
    }

    static func transaction(id: UUID, reversesTransactionID: UUID?) -> String {
        if let reversesTransactionID {
            return "undo-\(canonical(reversesTransactionID))"
        }
        return "transaction-\(canonical(id))"
    }

    private static func canonical(_ id: UUID) -> String {
        id.uuidString.lowercased()
    }
}

enum CloudLedgerTransactionIdentity {
    private static let undoNamespace = UUID(
        uuid: (0x31, 0x77, 0x15, 0x99, 0xa4, 0xbd, 0x42, 0x94,
               0x83, 0x87, 0x56, 0xb1, 0xf6, 0x0f, 0x32, 0x1e)
    )

    static func undo(reversing transactionID: UUID) -> UUID {
        let namespace = undoNamespace.uuid
        var input = Data([
            namespace.0, namespace.1, namespace.2, namespace.3,
            namespace.4, namespace.5, namespace.6, namespace.7,
            namespace.8, namespace.9, namespace.10, namespace.11,
            namespace.12, namespace.13, namespace.14, namespace.15
        ])
        input.append(contentsOf: transactionID.uuidString.lowercased().utf8)

        var bytes = Array(Insecure.SHA1.hash(data: input).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}

@MainActor
enum CloudLedgerRecordMapper {
    static func household(_ state: SharedLedgerState) -> CKRecord {
        let record = CKRecord(
            recordType: CloudLedgerRecordType.household.rawValue,
            recordID: CKRecord.ID(
                recordName: CloudLedgerRecordName.household(state.householdID),
                zoneID: state.zoneID
            )
        )
        record[CloudLedgerSchema.Field.identifier] = state.householdID.uuidString.lowercased()
        record[CloudLedgerSchema.Field.displayName] = state.displayName
        record[CloudLedgerSchema.Field.schemaVersion] = NSNumber(value: state.schemaVersion)
        record[CloudLedgerSchema.Field.createdAt] = state.createdAt
        return record
    }

    static func child(_ child: Child, zoneID: CKRecordZone.ID) -> CKRecord {
        let record = CKRecord(
            recordType: CloudLedgerRecordType.child.rawValue,
            recordID: CKRecord.ID(
                recordName: CloudLedgerRecordName.child(child.id),
                zoneID: zoneID
            )
        )
        record[CloudLedgerSchema.Field.identifier] = child.id.uuidString.lowercased()
        record[CloudLedgerSchema.Field.name] = child.name
        record[CloudLedgerSchema.Field.createdAt] = child.createdAt
        record[CloudLedgerSchema.Field.sortOrder] = NSNumber(value: child.sortOrder)
        record[CloudLedgerSchema.Field.isArchived] = NSNumber(value: child.isArchived ? 1 : 0)
        record[CloudLedgerSchema.Field.lastModifiedAt] = child.lastModifiedAt ?? child.createdAt
        return record
    }

    static func transaction(_ transaction: LedgerTransaction, zoneID: CKRecordZone.ID) -> CKRecord? {
        guard let childID = transaction.child?.id else { return nil }

        let record = CKRecord(
            recordType: CloudLedgerRecordType.ledgerTransaction.rawValue,
            recordID: CKRecord.ID(
                recordName: CloudLedgerRecordName.transaction(
                    id: transaction.id,
                    reversesTransactionID: transaction.reversesTransactionID
                ),
                zoneID: zoneID
            )
        )
        let cloudIdentifier = transaction.reversesTransactionID.map {
            CloudLedgerTransactionIdentity.undo(reversing: $0)
        } ?? transaction.id
        record[CloudLedgerSchema.Field.identifier] = cloudIdentifier.uuidString.lowercased()
        record[CloudLedgerSchema.Field.childIdentifier] = childID.uuidString.lowercased()
        record[CloudLedgerSchema.Field.amountCents] = NSNumber(value: transaction.amountCents)
        record[CloudLedgerSchema.Field.createdAt] = transaction.createdAt
        record[CloudLedgerSchema.Field.source] = transaction.sourceRawValue
        if let note = transaction.note {
            record[CloudLedgerSchema.Field.note] = note
        }
        if let reversesTransactionID = transaction.reversesTransactionID {
            record[CloudLedgerSchema.Field.reversesTransactionIdentifier] =
                reversesTransactionID.uuidString.lowercased()
        }
        return record
    }
}
