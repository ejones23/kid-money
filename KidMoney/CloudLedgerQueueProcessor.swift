import CloudKit
import Foundation
import SwiftData

enum CloudLedgerSyncStatus: String, Codable {
    case idle
    case syncing
    case pending
    case offline
    case iCloudUnavailable
    case attentionRequired
    case synced
}

@Model
final class CloudLedgerSyncState {
    @Attribute(.unique) var key: String
    var householdID: UUID
    var databaseScopeRawValue: String
    var statusRawValue: String
    var engineStateData: Data?
    var lastAttemptAt: Date?
    var lastSuccessAt: Date?
    var nextRetryAt: Date?
    var lastErrorCode: String?

    init(
        householdID: UUID,
        databaseScope: SharedLedgerDatabaseScope,
        status: CloudLedgerSyncStatus = .idle,
        engineStateData: Data? = nil,
        lastAttemptAt: Date? = nil,
        lastSuccessAt: Date? = nil,
        nextRetryAt: Date? = nil,
        lastErrorCode: String? = nil
    ) {
        self.householdID = householdID
        self.databaseScopeRawValue = databaseScope.rawValue
        self.key = Self.makeKey(householdID: householdID, databaseScope: databaseScope)
        self.statusRawValue = status.rawValue
        self.engineStateData = engineStateData
        self.lastAttemptAt = lastAttemptAt
        self.lastSuccessAt = lastSuccessAt
        self.nextRetryAt = nextRetryAt
        self.lastErrorCode = lastErrorCode
    }

    var status: CloudLedgerSyncStatus? {
        CloudLedgerSyncStatus(rawValue: statusRawValue)
    }

    var databaseScope: SharedLedgerDatabaseScope? {
        SharedLedgerDatabaseScope(rawValue: databaseScopeRawValue)
    }

    static func makeKey(
        householdID: UUID,
        databaseScope: SharedLedgerDatabaseScope
    ) -> String {
        "\(householdID.uuidString.lowercased())|\(databaseScope.rawValue)"
    }
}

enum CloudLedgerTransportAccountState: Equatable, Sendable {
    case available
    case temporarilyUnavailable(retryAfter: TimeInterval?, code: String)
    case noAccount
    case restricted
    case couldNotDetermine
}

enum CloudLedgerTransportSaveResult: @unchecked Sendable {
    case saved(CKRecord)
    case conflict(CKRecord)
    case retry(after: TimeInterval?, code: String)
    case attentionRequired(code: String)
}

protocol CloudLedgerQueueTransport: Sendable {
    func accountState() async -> CloudLedgerTransportAccountState
    func save(_ record: CKRecord) async -> CloudLedgerTransportSaveResult
}

struct CloudLedgerQueueDrainSummary: Equatable {
    var savedChanges = 0
    var resolvedConflicts = 0
    var discardedStaleChanges = 0
    var remainingChanges = 0
    var status: CloudLedgerSyncStatus = .idle
}

enum CloudLedgerQueueProcessorError: Error, Equatable {
    case invalidSharedLedgerState
    case invalidPendingChange(UUID)
    case unsupportedDelete(UUID)
    case immutableConflict(UUID)
}

@MainActor
struct CloudLedgerQueueProcessor {
    let modelContext: ModelContext

    func drain(
        sharedLedger: SharedLedgerState,
        transport: any CloudLedgerQueueTransport,
        now: Date = .now
    ) async throws -> CloudLedgerQueueDrainSummary {
        guard sharedLedger.phase == .active,
              let databaseScope = sharedLedger.databaseScope else {
            throw CloudLedgerQueueProcessorError.invalidSharedLedgerState
        }
        let syncState = try syncState(
            householdID: sharedLedger.householdID,
            databaseScope: databaseScope
        )
        if let nextRetryAt = syncState.nextRetryAt, nextRetryAt > now {
            return try summary(syncState: syncState, householdID: sharedLedger.householdID)
        }

        switch await transport.accountState() {
        case .available:
            break
        case .temporarilyUnavailable(let retryAfter, let code):
            syncState.statusRawValue = CloudLedgerSyncStatus.offline.rawValue
            syncState.lastAttemptAt = now
            syncState.nextRetryAt = now.addingTimeInterval(retryAfter ?? 30)
            syncState.lastErrorCode = code
            try modelContext.save()
            return try summary(syncState: syncState, householdID: sharedLedger.householdID)
        case .couldNotDetermine:
            syncState.statusRawValue = CloudLedgerSyncStatus.offline.rawValue
            syncState.lastAttemptAt = now
            syncState.nextRetryAt = now.addingTimeInterval(30)
            syncState.lastErrorCode = "account-status-unknown"
            try modelContext.save()
            return try summary(syncState: syncState, householdID: sharedLedger.householdID)
        case .noAccount:
            try requireUserAttention(
                sharedLedger: sharedLedger,
                syncState: syncState,
                code: "no-icloud-account",
                now: now
            )
            return try summary(syncState: syncState, householdID: sharedLedger.householdID)
        case .restricted:
            try requireUserAttention(
                sharedLedger: sharedLedger,
                syncState: syncState,
                code: "icloud-restricted",
                now: now
            )
            return try summary(syncState: syncState, householdID: sharedLedger.householdID)
        }

        syncState.statusRawValue = CloudLedgerSyncStatus.syncing.rawValue
        syncState.lastAttemptAt = now
        syncState.nextRetryAt = nil
        syncState.lastErrorCode = nil
        try modelContext.save()

        var result = CloudLedgerQueueDrainSummary(status: .syncing)
        let pending = try pendingChanges(householdID: sharedLedger.householdID)
        for change in pending {
            guard change.operation == .save, let recordType = change.recordType else {
                try requireUserAttention(
                    sharedLedger: sharedLedger,
                    syncState: syncState,
                    code: "unsupported-pending-change",
                    now: now
                )
                if change.operation == .delete {
                    throw CloudLedgerQueueProcessorError.unsupportedDelete(change.id)
                }
                throw CloudLedgerQueueProcessorError.invalidPendingChange(change.id)
            }
            guard let record = try record(
                recordType: recordType,
                recordName: change.recordName,
                sharedLedger: sharedLedger
            ) else {
                modelContext.delete(change)
                result.discardedStaleChanges += 1
                try modelContext.save()
                continue
            }

            let completed = try await save(
                record,
                change: change,
                sharedLedger: sharedLedger,
                syncState: syncState,
                transport: transport,
                now: now,
                result: &result
            )
            if !completed { break }
        }

        let remaining = try pendingChanges(householdID: sharedLedger.householdID).count
        result.remainingChanges = remaining
        if sharedLedger.phase == .attentionRequired {
            syncState.statusRawValue = CloudLedgerSyncStatus.attentionRequired.rawValue
        } else if remaining == 0 {
            syncState.statusRawValue = CloudLedgerSyncStatus.synced.rawValue
            syncState.lastSuccessAt = now
            syncState.nextRetryAt = nil
            syncState.lastErrorCode = nil
        } else if syncState.status == .syncing {
            syncState.statusRawValue = CloudLedgerSyncStatus.pending.rawValue
        }
        result.status = syncState.status ?? .attentionRequired
        try modelContext.save()
        return result
    }

    private func save(
        _ initialRecord: CKRecord,
        change: PendingCloudChange,
        sharedLedger: SharedLedgerState,
        syncState: CloudLedgerSyncState,
        transport: any CloudLedgerQueueTransport,
        now: Date,
        result: inout CloudLedgerQueueDrainSummary
    ) async throws -> Bool {
        var record = initialRecord
        for _ in 0..<3 {
            switch await transport.save(record) {
            case .saved:
                modelContext.delete(change)
                result.savedChanges += 1
                try modelContext.save()
                return true
            case .conflict(let serverRecord):
                do {
                    _ = try CloudLedgerMergeService(modelContext: modelContext).merge(
                        records: [serverRecord],
                        into: sharedLedger
                    )
                } catch CloudLedgerMergeError.immutableTransactionConflict(let id) {
                    try requireUserAttention(
                        sharedLedger: sharedLedger,
                        syncState: syncState,
                        code: "immutable-transaction-conflict",
                        now: now
                    )
                    throw CloudLedgerQueueProcessorError.immutableConflict(id)
                }
                guard let refreshed = try refreshedRecord(
                    for: change,
                    sharedLedger: sharedLedger
                ) else {
                    modelContext.delete(change)
                    result.discardedStaleChanges += 1
                    result.resolvedConflicts += 1
                    try modelContext.save()
                    return true
                }
                if try recordsMatch(refreshed, serverRecord: serverRecord) {
                    modelContext.delete(change)
                    result.resolvedConflicts += 1
                    try modelContext.save()
                    return true
                }
                record = copyFields(from: refreshed, into: serverRecord)
                result.resolvedConflicts += 1
            case .retry(let retryAfter, let code):
                applyRetry(
                    change: change,
                    syncState: syncState,
                    retryAfter: retryAfter,
                    code: code,
                    now: now
                )
                try modelContext.save()
                return false
            case .attentionRequired(let code):
                try requireUserAttention(
                    sharedLedger: sharedLedger,
                    syncState: syncState,
                    code: code,
                    now: now
                )
                return false
            }
        }

        applyRetry(
            change: change,
            syncState: syncState,
            retryAfter: nil,
            code: "repeated-server-conflict",
            now: now
        )
        try modelContext.save()
        return false
    }

    private func syncState(
        householdID: UUID,
        databaseScope: SharedLedgerDatabaseScope
    ) throws -> CloudLedgerSyncState {
        let key = CloudLedgerSyncState.makeKey(
            householdID: householdID,
            databaseScope: databaseScope
        )
        if let existing = try modelContext.fetch(FetchDescriptor<CloudLedgerSyncState>()).first(
            where: { $0.key == key }
        ) {
            return existing
        }
        let state = CloudLedgerSyncState(
            householdID: householdID,
            databaseScope: databaseScope
        )
        modelContext.insert(state)
        try modelContext.save()
        return state
    }

    private func pendingChanges(householdID: UUID) throws -> [PendingCloudChange] {
        try modelContext.fetch(
            FetchDescriptor<PendingCloudChange>(
                sortBy: [SortDescriptor(\PendingCloudChange.enqueuedAt)]
            )
        ).filter { $0.householdID == householdID }
    }

    private func record(
        recordType: CloudLedgerRecordType,
        recordName: String,
        sharedLedger: SharedLedgerState
    ) throws -> CKRecord? {
        switch recordType {
        case .household:
            guard recordName == CloudLedgerRecordName.household(sharedLedger.householdID) else {
                return nil
            }
            return CloudLedgerRecordMapper.household(sharedLedger)
        case .child:
            guard let child = try modelContext.fetch(FetchDescriptor<Child>()).first(where: {
                CloudLedgerRecordName.child($0.id) == recordName
            }) else { return nil }
            return CloudLedgerRecordMapper.child(child, zoneID: sharedLedger.zoneID)
        case .ledgerTransaction:
            guard let transaction = try modelContext.fetch(
                FetchDescriptor<LedgerTransaction>()
            ).first(where: {
                CloudLedgerRecordName.transaction(
                    id: $0.id,
                    reversesTransactionID: $0.reversesTransactionID
                ) == recordName
            }) else { return nil }
            return CloudLedgerRecordMapper.transaction(transaction, zoneID: sharedLedger.zoneID)
        }
    }

    private func refreshedRecord(
        for change: PendingCloudChange,
        sharedLedger: SharedLedgerState
    ) throws -> CKRecord? {
        guard let recordType = change.recordType,
              let local = try record(
                recordType: recordType,
                recordName: change.recordName,
                sharedLedger: sharedLedger
              ) else { return nil }
        return local
    }

    private func copyFields(from local: CKRecord, into server: CKRecord) -> CKRecord {
        for key in server.allKeys() where local[key] == nil {
            server[key] = nil
        }
        for key in local.allKeys() {
            server[key] = local[key]
        }
        return server
    }

    private func recordsMatch(_ local: CKRecord, serverRecord: CKRecord) throws -> Bool {
        switch CloudLedgerRecordType(rawValue: local.recordType) {
        case .household:
            return try CloudLedgerRecordDecoder.household(local)
                == CloudLedgerRecordDecoder.household(serverRecord)
        case .child:
            return try CloudLedgerRecordDecoder.child(local)
                == CloudLedgerRecordDecoder.child(serverRecord)
        case .ledgerTransaction:
            return try CloudLedgerRecordDecoder.transaction(local)
                == CloudLedgerRecordDecoder.transaction(serverRecord)
        case nil:
            return false
        }
    }

    private func applyRetry(
        change: PendingCloudChange,
        syncState: CloudLedgerSyncState,
        retryAfter: TimeInterval?,
        code: String,
        now: Date
    ) {
        change.attemptCount += 1
        change.lastAttemptAt = now
        change.lastErrorCode = code
        let exponent = min(max(change.attemptCount - 1, 0), 8)
        let backoff = min(5 * pow(2, Double(exponent)), 1_800)
        syncState.statusRawValue = CloudLedgerSyncStatus.pending.rawValue
        syncState.nextRetryAt = now.addingTimeInterval(max(retryAfter ?? 0, backoff))
        syncState.lastErrorCode = code
    }

    private func requireUserAttention(
        sharedLedger: SharedLedgerState,
        syncState: CloudLedgerSyncState,
        code: String,
        now: Date
    ) throws {
        sharedLedger.phaseRawValue = SharedLedgerPhase.attentionRequired.rawValue
        syncState.statusRawValue = CloudLedgerSyncStatus.attentionRequired.rawValue
        syncState.lastAttemptAt = now
        syncState.nextRetryAt = nil
        syncState.lastErrorCode = code
        try modelContext.save()
    }

    private func summary(
        syncState: CloudLedgerSyncState,
        householdID: UUID
    ) throws -> CloudLedgerQueueDrainSummary {
        CloudLedgerQueueDrainSummary(
            remainingChanges: try pendingChanges(householdID: householdID).count,
            status: syncState.status ?? .attentionRequired
        )
    }
}
