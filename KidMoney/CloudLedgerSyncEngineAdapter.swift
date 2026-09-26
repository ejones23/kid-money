import CloudKit
import Foundation
import SwiftData

@Model
final class CloudLedgerRecordMetadata {
    @Attribute(.unique) var key: String
    var householdID: UUID
    var recordName: String
    var encodedSystemFields: Data

    init(householdID: UUID, recordName: String, encodedSystemFields: Data) {
        self.householdID = householdID
        self.recordName = recordName
        self.key = Self.makeKey(householdID: householdID, recordName: recordName)
        self.encodedSystemFields = encodedSystemFields
    }

    static func makeKey(householdID: UUID, recordName: String) -> String {
        "\(householdID.uuidString.lowercased())|\(recordName)"
    }
}

enum CloudLedgerSystemFieldsError: Error, Equatable {
    case invalidArchive
    case recordIdentityMismatch
}

enum CloudLedgerSystemFieldsCodec {
    static func encode(_ record: CKRecord) -> Data {
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: archiver)
        archiver.finishEncoding()
        return archiver.encodedData
    }

    static func decode(_ data: Data) throws -> CKRecord {
        let unarchiver = try NSKeyedUnarchiver(forReadingFrom: data)
        unarchiver.requiresSecureCoding = true
        defer { unarchiver.finishDecoding() }
        guard let record = CKRecord(coder: unarchiver) else {
            throw CloudLedgerSystemFieldsError.invalidArchive
        }
        return record
    }
}

enum CloudLedgerSyncEngineAccountChange: Sendable {
    case signIn
    case signOut
    case switchAccounts
}

struct CloudLedgerFetchedDeletion: Sendable {
    let recordID: CKRecord.ID
    let recordType: CKRecord.RecordType
}

struct CloudLedgerSyncEngineFailure: @unchecked Sendable {
    let record: CKRecord
    let code: CKError.Code
    let serverRecord: CKRecord?
    let retryAfter: TimeInterval?
}

enum CloudLedgerSyncEngineFailureAction: Sendable {
    case engineWillRetry
    case retrySave(CKRecord.ID)
    case removeSave(CKRecord.ID)
    case attentionRequired
}

enum CloudLedgerSyncEngineAdapterError: Error, Equatable {
    case missingSharedLedger
    case invalidSharedLedger
    case invalidPendingChange(UUID)
    case unsupportedDelete(UUID)
    case fetchedRecordDeletion(String)
    case sharedZoneDeleted
    case corruptEngineState
}

@MainActor
final class CloudLedgerSyncEngineStore {
    let modelContext: ModelContext
    let householdID: UUID
    let zoneID: CKRecordZone.ID

    init(modelContext: ModelContext, householdID: UUID) throws {
        self.modelContext = modelContext
        self.householdID = householdID
        guard let sharedLedger = try modelContext.fetch(
            FetchDescriptor<SharedLedgerState>()
        ).first(where: { $0.householdID == householdID }) else {
            throw CloudLedgerSyncEngineAdapterError.missingSharedLedger
        }
        guard sharedLedger.phase == .active, sharedLedger.databaseScope != nil else {
            throw CloudLedgerSyncEngineAdapterError.invalidSharedLedger
        }
        self.zoneID = sharedLedger.zoneID
    }

    func restoredStateSerialization() throws -> CKSyncEngine.State.Serialization? {
        guard let data = try syncState().engineStateData else { return nil }
        do {
            return try JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: data)
        } catch {
            throw CloudLedgerSyncEngineAdapterError.corruptEngineState
        }
    }

    func persist(_ stateSerialization: CKSyncEngine.State.Serialization) throws {
        try persistEngineStateData(JSONEncoder().encode(stateSerialization))
    }

    func persistEngineStateData(_ data: Data) throws {
        let state = try syncState()
        state.engineStateData = data
        try modelContext.save()
    }

    func pendingEngineChanges() throws -> [CKSyncEngine.PendingRecordZoneChange] {
        let changes = try pendingChanges()
        return try changes.map { change in
            guard let operation = change.operation else {
                throw CloudLedgerSyncEngineAdapterError.invalidPendingChange(change.id)
            }
            let recordID = CKRecord.ID(recordName: change.recordName, zoneID: zoneID)
            switch operation {
            case .save:
                return .saveRecord(recordID)
            case .delete:
                throw CloudLedgerSyncEngineAdapterError.unsupportedDelete(change.id)
            }
        }
    }

    func record(for recordID: CKRecord.ID) throws -> CKRecord? {
        guard recordID.zoneID == zoneID else { return nil }
        guard try pendingChanges().contains(where: {
            $0.operation == .save && $0.recordName == recordID.recordName
        }) else {
            return nil
        }
        guard let fresh = try freshRecord(recordName: recordID.recordName) else {
            return nil
        }
        guard let metadata = try metadata(recordName: recordID.recordName) else {
            return fresh
        }
        let serverBased = try CloudLedgerSystemFieldsCodec.decode(
            metadata.encodedSystemFields
        )
        guard serverBased.recordID == fresh.recordID,
              serverBased.recordType == fresh.recordType else {
            throw CloudLedgerSystemFieldsError.recordIdentityMismatch
        }
        return copyFields(from: fresh, into: serverBased)
    }

    func discardStaleSave(recordID: CKRecord.ID) throws {
        guard recordID.zoneID == zoneID else { return }
        for change in try pendingChanges() where
            change.operation == .save && change.recordName == recordID.recordName {
            modelContext.delete(change)
        }
        try modelContext.save()
    }

    func handleFetchedRecords(
        _ records: [CKRecord],
        deletions: [CloudLedgerFetchedDeletion]
    ) throws {
        if let deletion = deletions.first(where: { $0.recordID.zoneID == zoneID }) {
            try requireUserAttention(code: "remote-record-deleted")
            throw CloudLedgerSyncEngineAdapterError.fetchedRecordDeletion(
                deletion.recordID.recordName
            )
        }
        let relevantRecords = records.filter { $0.recordID.zoneID == zoneID }
        guard !relevantRecords.isEmpty else { return }

        _ = try CloudLedgerMergeService(modelContext: modelContext).merge(
            records: relevantRecords,
            into: try sharedLedger()
        )
        for record in relevantRecords where
            CloudLedgerRecordType(rawValue: record.recordType) != nil {
            try upsertMetadata(for: record)
        }
        try finishSuccessfulWork()
    }

    func handleFetchedZoneDeletions(_ deletedZoneIDs: [CKRecordZone.ID]) throws {
        guard deletedZoneIDs.contains(zoneID) else { return }
        try requireUserAttention(code: "shared-zone-deleted")
        throw CloudLedgerSyncEngineAdapterError.sharedZoneDeleted
    }

    func handleSavedRecords(_ records: [CKRecord]) throws -> [CKRecord.ID] {
        var changesToRetry: [CKRecord.ID] = []
        for record in records where record.recordID.zoneID == zoneID {
            if CloudLedgerRecordType(rawValue: record.recordType) != nil {
                try upsertMetadata(for: record)
            }
            if let current = try freshRecord(recordName: record.recordID.recordName),
               try !recordsMatch(current, serverRecord: record) {
                changesToRetry.append(record.recordID)
            } else {
                try removePendingSave(recordName: record.recordID.recordName)
            }
        }
        try finishSuccessfulWork()
        return changesToRetry
    }

    func handleFailedSave(
        _ failure: CloudLedgerSyncEngineFailure,
        now: Date = .now
    ) throws -> CloudLedgerSyncEngineFailureAction {
        guard failure.record.recordID.zoneID == zoneID else {
            return .attentionRequired
        }
        let codeName = String(describing: failure.code)
        switch failure.code {
        case .serverRecordChanged:
            guard let serverRecord = failure.serverRecord else {
                try requireUserAttention(code: "conflict-missing-server-record")
                return .attentionRequired
            }
            do {
                try upsertMetadata(for: serverRecord)
                _ = try CloudLedgerMergeService(modelContext: modelContext).merge(
                    records: [serverRecord],
                    into: try sharedLedger()
                )
                guard let local = try freshRecord(
                    recordName: failure.record.recordID.recordName
                ) else {
                    try removePendingSave(recordName: failure.record.recordID.recordName)
                    try modelContext.save()
                    return .removeSave(failure.record.recordID)
                }
                if try recordsMatch(local, serverRecord: serverRecord) {
                    try removePendingSave(recordName: failure.record.recordID.recordName)
                    try finishSuccessfulWork()
                    return .removeSave(failure.record.recordID)
                }
                try markPending(code: codeName, retryAfter: nil, now: now)
                return .retrySave(failure.record.recordID)
            } catch {
                try requireUserAttention(code: "unresolved-server-conflict")
                return .attentionRequired
            }
        case .unknownItem:
            try removeMetadata(recordName: failure.record.recordID.recordName)
            try markPending(code: codeName, retryAfter: nil, now: now)
            return .retrySave(failure.record.recordID)
        case .networkFailure, .networkUnavailable, .zoneBusy, .serviceUnavailable,
                .requestRateLimited, .notAuthenticated, .operationCancelled,
                .accountTemporarilyUnavailable, .batchRequestFailed:
            try markPending(
                code: codeName,
                retryAfter: failure.retryAfter,
                now: now
            )
            return .engineWillRetry
        default:
            try requireUserAttention(code: "cloudkit-\(codeName)")
            return .attentionRequired
        }
    }

    func handleAccountChange(_ change: CloudLedgerSyncEngineAccountChange) throws {
        switch change {
        case .signIn:
            try finishSuccessfulWork()
        case .signOut:
            try requireUserAttention(code: "icloud-account-signed-out")
        case .switchAccounts:
            try requireUserAttention(code: "icloud-account-changed")
        }
    }

    func markSyncing(now: Date = .now) throws {
        let state = try syncState()
        guard try sharedLedger().phase != .attentionRequired else {
            state.statusRawValue = CloudLedgerSyncStatus.attentionRequired.rawValue
            try modelContext.save()
            return
        }
        state.statusRawValue = CloudLedgerSyncStatus.syncing.rawValue
        state.lastAttemptAt = now
        state.nextRetryAt = nil
        state.lastErrorCode = nil
        try modelContext.save()
    }

    func finishSuccessfulWork(now: Date = .now) throws {
        let state = try syncState()
        guard try sharedLedger().phase != .attentionRequired else {
            state.statusRawValue = CloudLedgerSyncStatus.attentionRequired.rawValue
            try modelContext.save()
            return
        }
        if try pendingChanges().isEmpty {
            state.statusRawValue = CloudLedgerSyncStatus.synced.rawValue
            state.lastSuccessAt = now
            state.nextRetryAt = nil
            state.lastErrorCode = nil
        } else {
            state.statusRawValue = CloudLedgerSyncStatus.pending.rawValue
        }
        try modelContext.save()
    }

    func requireUserAttention(code: String, now: Date = .now) throws {
        let ledger = try sharedLedger()
        ledger.phaseRawValue = SharedLedgerPhase.attentionRequired.rawValue
        let state = try syncState()
        state.statusRawValue = CloudLedgerSyncStatus.attentionRequired.rawValue
        state.lastAttemptAt = now
        state.nextRetryAt = nil
        state.lastErrorCode = code
        try modelContext.save()
    }

    private func sharedLedger() throws -> SharedLedgerState {
        guard let ledger = try modelContext.fetch(
            FetchDescriptor<SharedLedgerState>()
        ).first(where: { $0.householdID == householdID }) else {
            throw CloudLedgerSyncEngineAdapterError.missingSharedLedger
        }
        return ledger
    }

    private func syncState() throws -> CloudLedgerSyncState {
        let ledger = try sharedLedger()
        guard let databaseScope = ledger.databaseScope else {
            throw CloudLedgerSyncEngineAdapterError.invalidSharedLedger
        }
        let key = CloudLedgerSyncState.makeKey(
            householdID: householdID,
            databaseScope: databaseScope
        )
        if let state = try modelContext.fetch(
            FetchDescriptor<CloudLedgerSyncState>()
        ).first(where: { $0.key == key }) {
            return state
        }
        let state = CloudLedgerSyncState(
            householdID: householdID,
            databaseScope: databaseScope
        )
        modelContext.insert(state)
        try modelContext.save()
        return state
    }

    private func pendingChanges() throws -> [PendingCloudChange] {
        try modelContext.fetch(
            FetchDescriptor<PendingCloudChange>(
                sortBy: [SortDescriptor(\PendingCloudChange.enqueuedAt)]
            )
        ).filter { $0.householdID == householdID }
    }

    private func freshRecord(recordName: String) throws -> CKRecord? {
        let ledger = try sharedLedger()
        if recordName == CloudLedgerRecordName.household(householdID) {
            return CloudLedgerRecordMapper.household(ledger)
        }
        if let child = try modelContext.fetch(FetchDescriptor<Child>()).first(where: {
            CloudLedgerRecordName.child($0.id) == recordName
        }) {
            return CloudLedgerRecordMapper.child(child, zoneID: zoneID)
        }
        if let transaction = try modelContext.fetch(
            FetchDescriptor<LedgerTransaction>()
        ).first(where: {
            CloudLedgerRecordName.transaction(
                id: $0.id,
                reversesTransactionID: $0.reversesTransactionID
            ) == recordName
        }) {
            return CloudLedgerRecordMapper.transaction(transaction, zoneID: zoneID)
        }
        return nil
    }

    private func metadata(recordName: String) throws -> CloudLedgerRecordMetadata? {
        let key = CloudLedgerRecordMetadata.makeKey(
            householdID: householdID,
            recordName: recordName
        )
        return try modelContext.fetch(
            FetchDescriptor<CloudLedgerRecordMetadata>()
        ).first(where: { $0.key == key })
    }

    private func upsertMetadata(for record: CKRecord) throws {
        let data = CloudLedgerSystemFieldsCodec.encode(record)
        if let existing = try metadata(recordName: record.recordID.recordName) {
            existing.encodedSystemFields = data
        } else {
            modelContext.insert(CloudLedgerRecordMetadata(
                householdID: householdID,
                recordName: record.recordID.recordName,
                encodedSystemFields: data
            ))
        }
    }

    private func removeMetadata(recordName: String) throws {
        if let existing = try metadata(recordName: recordName) {
            modelContext.delete(existing)
        }
    }

    private func removePendingSave(recordName: String) throws {
        for change in try pendingChanges() where
            change.operation == .save && change.recordName == recordName {
            modelContext.delete(change)
        }
    }

    private func markPending(
        code: String,
        retryAfter: TimeInterval?,
        now: Date
    ) throws {
        let state = try syncState()
        state.statusRawValue = CloudLedgerSyncStatus.pending.rawValue
        state.lastAttemptAt = now
        state.nextRetryAt = retryAfter.map { now.addingTimeInterval($0) }
        state.lastErrorCode = code
        try modelContext.save()
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
}

final class CloudLedgerSyncEngineDelegate: CKSyncEngineDelegate, @unchecked Sendable {
    let store: CloudLedgerSyncEngineStore
    let zoneID: CKRecordZone.ID

    @MainActor
    init(store: CloudLedgerSyncEngineStore) {
        self.store = store
        self.zoneID = store.zoneID
    }

    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        do {
            switch event {
            case .stateUpdate(let event):
                try await store.persist(event.stateSerialization)
            case .accountChange(let event):
                let change: CloudLedgerSyncEngineAccountChange
                switch event.changeType {
                case .signIn: change = .signIn
                case .signOut: change = .signOut
                case .switchAccounts: change = .switchAccounts
                @unknown default: change = .switchAccounts
                }
                try await store.handleAccountChange(change)
            case .fetchedDatabaseChanges(let event):
                try await store.handleFetchedZoneDeletions(event.deletions.map(\.zoneID))
            case .fetchedRecordZoneChanges(let event):
                try await store.handleFetchedRecords(
                    event.modifications.map(\.record),
                    deletions: event.deletions.map {
                        CloudLedgerFetchedDeletion(
                            recordID: $0.recordID,
                            recordType: $0.recordType
                        )
                    }
                )
            case .sentRecordZoneChanges(let event):
                var changesToAdd = try await store.handleSavedRecords(
                    event.savedRecords
                ).map(CKSyncEngine.PendingRecordZoneChange.saveRecord)
                var changesToRemove: [CKSyncEngine.PendingRecordZoneChange] = []
                for failure in event.failedRecordSaves {
                    let action = try await store.handleFailedSave(
                        CloudLedgerSyncEngineFailure(
                            record: failure.record,
                            code: failure.error.code,
                            serverRecord: failure.error.serverRecord,
                            retryAfter: failure.error.retryAfterSeconds
                        )
                    )
                    switch action {
                    case .engineWillRetry, .attentionRequired:
                        break
                    case .retrySave(let recordID):
                        changesToAdd.append(.saveRecord(recordID))
                    case .removeSave(let recordID):
                        changesToRemove.append(.saveRecord(recordID))
                    }
                }
                syncEngine.state.remove(pendingRecordZoneChanges: changesToRemove)
                syncEngine.state.add(pendingRecordZoneChanges: changesToAdd)
            case .willFetchChanges, .willSendChanges:
                try await store.markSyncing()
            case .didFetchChanges, .didSendChanges:
                try await store.finishSuccessfulWork()
            case .sentDatabaseChanges, .willFetchRecordZoneChanges,
                    .didFetchRecordZoneChanges:
                break
            @unknown default:
                break
            }
        } catch {
            try? await store.requireUserAttention(code: "sync-engine-event-failed")
        }
    }

    func nextRecordZoneChangeBatch(
        _ context: CKSyncEngine.SendChangesContext,
        syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let changes = syncEngine.state.pendingRecordZoneChanges.filter {
            context.options.scope.contains($0)
        }
        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: changes) {
            [store] recordID in
            do {
                guard let record = try await store.record(for: recordID) else {
                    syncEngine.state.remove(
                        pendingRecordZoneChanges: [.saveRecord(recordID)]
                    )
                    try await store.discardStaleSave(recordID: recordID)
                    return nil
                }
                return record
            } catch {
                try? await store.requireUserAttention(code: "record-materialization-failed")
                return nil
            }
        }
    }

    func nextFetchChangesOptions(
        _ context: CKSyncEngine.FetchChangesContext,
        syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.FetchChangesOptions {
        var options = context.options
        options.scope = .zoneIDs([zoneID])
        options.prioritizedZoneIDs = [zoneID]
        return options
    }
}

@MainActor
final class CloudLedgerSyncEngineRuntime {
    let engine: CKSyncEngine
    let delegate: CloudLedgerSyncEngineDelegate

    init(
        database: CKDatabase,
        modelContext: ModelContext,
        householdID: UUID,
        automaticallySync: Bool = false
    ) throws {
        let store = try CloudLedgerSyncEngineStore(
            modelContext: modelContext,
            householdID: householdID
        )
        let delegate = CloudLedgerSyncEngineDelegate(store: store)
        var configuration = CKSyncEngine.Configuration(
            database: database,
            stateSerialization: try store.restoredStateSerialization(),
            delegate: delegate
        )
        configuration.automaticallySync = automaticallySync
        let engine = CKSyncEngine(configuration)
        engine.state.add(pendingRecordZoneChanges: try store.pendingEngineChanges())
        self.delegate = delegate
        self.engine = engine
    }
}
