import CloudKit
import Foundation
import SwiftData
import Testing
@testable import KidMoney

@MainActor
struct CloudLedgerMigrationCoordinatorTests {
    @Test func stagesTheCompleteExistingLedgerWithoutChangingIt() throws {
        let container = try AppModelContainer.make(inMemory: true)
        let context = ModelContext(container)
        let service = LedgerService(modelContext: context)
        let child = try service.addChild(named: "Rebecca")
        let transaction = try service.addTransaction(cents: 250, to: child)
        let householdID = UUID()

        let summary = try CloudLedgerMigrationCoordinator(modelContext: context)
            .beginOwnerMigration(
                displayName: "Family Ledger",
                householdID: householdID,
                now: Date(timeIntervalSinceReferenceDate: 10)
            )

        #expect(summary.phase == .awaitingZoneCreation)
        #expect(summary.expectedRecordCount == 3)
        #expect(summary.pendingRecordCount == 3)
        #expect(service.balance(for: child) == 250)
        #expect(try service.transactions(for: child).map(\.id) == [transaction.id])

        let sharedLedger = try #require(
            context.fetch(FetchDescriptor<SharedLedgerState>()).first
        )
        #expect(sharedLedger.phase == .preparing)
        #expect(sharedLedger.householdID == householdID)

        let pending = try context.fetch(
            FetchDescriptor<PendingCloudChange>(
                sortBy: [SortDescriptor(\PendingCloudChange.enqueuedAt)]
            )
        )
        #expect(pending.map(\.recordName) == [
            CloudLedgerRecordName.household(householdID),
            CloudLedgerRecordName.child(child.id),
            CloudLedgerRecordName.transaction(
                id: transaction.id,
                reversesTransactionID: nil
            )
        ])
    }

    @Test func restartRepairsAnInterruptedInitialQueueWithoutDuplicates() throws {
        let storeURL = temporaryStoreURL(prefix: "KidMoneyMigrationRepair")
        defer { removeStore(at: storeURL) }
        let householdID = UUID()
        let childID: UUID

        do {
            let container = try AppModelContainer.make(storeURL: storeURL)
            let context = ModelContext(container)
            let child = try LedgerService(modelContext: context).addChild(named: "Rebecca")
            childID = child.id
            try CloudLedgerMigrationCoordinator(modelContext: context).beginOwnerMigration(
                displayName: "Family Ledger",
                householdID: householdID
            )
            let missingName = CloudLedgerRecordName.child(child.id)
            let change = try #require(
                context.fetch(FetchDescriptor<PendingCloudChange>()).first {
                    $0.recordName == missingName
                }
            )
            context.delete(change)
            try context.save()
        }

        do {
            let container = try AppModelContainer.make(storeURL: storeURL)
            let context = ModelContext(container)
            let summary = try CloudLedgerMigrationCoordinator(modelContext: context)
                .resumeOwnerMigration()
            let pending = try context.fetch(FetchDescriptor<PendingCloudChange>())

            #expect(summary.expectedRecordCount == 2)
            #expect(summary.pendingRecordCount == 2)
            #expect(Set(pending.map(\.recordName)) == [
                CloudLedgerRecordName.household(householdID),
                CloudLedgerRecordName.child(childID)
            ])
            #expect(Set(pending.map(\.deduplicationKey)).count == 2)
        }
    }

    @Test func localEditsDuringPreparationJoinTheDurableQueue() throws {
        let container = try AppModelContainer.make(inMemory: true)
        let context = ModelContext(container)
        let coordinator = CloudLedgerMigrationCoordinator(modelContext: context)
        let householdID = UUID()
        try coordinator.beginOwnerMigration(
            displayName: "Family Ledger",
            householdID: householdID
        )

        let service = LedgerService(modelContext: context)
        let child = try service.addChild(named: "Rebecca")
        let transaction = try service.addTransaction(cents: 10, to: child)
        let summary = try coordinator.resumeOwnerMigration()
        let pendingNames = Set(
            try context.fetch(FetchDescriptor<PendingCloudChange>()).map(\.recordName)
        )

        #expect(summary.expectedRecordCount == 3)
        #expect(summary.pendingRecordCount == 3)
        #expect(pendingNames == [
            CloudLedgerRecordName.household(householdID),
            CloudLedgerRecordName.child(child.id),
            CloudLedgerRecordName.transaction(
                id: transaction.id,
                reversesTransactionID: nil
            )
        ])
    }

    @Test func uploadMustDrainBeforeShareAndActivation() throws {
        let container = try AppModelContainer.make(inMemory: true)
        let context = ModelContext(container)
        let service = LedgerService(modelContext: context)
        let child = try service.addChild(named: "Rebecca")
        try service.addTransaction(cents: 25, to: child)
        let coordinator = CloudLedgerMigrationCoordinator(modelContext: context)
        let householdID = UUID()
        try coordinator.beginOwnerMigration(
            displayName: "Family Ledger",
            householdID: householdID
        )
        try coordinator.recordZoneCreated()

        #expect(throws: CloudLedgerMigrationError.pendingInitialRecords(3)) {
            try coordinator.recordInitialUploadCompleted()
        }

        let store = try CloudLedgerSyncEngineStore(
            modelContext: context,
            householdID: householdID
        )
        let recordIDs = try store.pendingEngineChanges().compactMap { change in
            if case .saveRecord(let recordID) = change {
                return recordID
            }
            return nil
        }
        let records = try recordIDs.compactMap { try store.record(for: $0) }
        #expect(records.count == 3)
        #expect(try store.handleSavedRecords(records).isEmpty)

        #expect(try coordinator.recordInitialUploadCompleted().phase == .awaitingShareCreation)
        #expect(try coordinator.recordShareCreated().phase == .readyToActivate)
        #expect(try coordinator.resumeOwnerMigration().phase == .readyToActivate)

        let sharedLedger = try #require(
            context.fetch(FetchDescriptor<SharedLedgerState>()).first
        )
        #expect(sharedLedger.phase == .preparing)
        #expect(service.balance(for: child) == 25)
    }

    @Test func recoverableFailurePersistsAndRetryRepairsTheSameStep() throws {
        let container = try AppModelContainer.make(inMemory: true)
        let context = ModelContext(container)
        let child = try LedgerService(modelContext: context).addChild(named: "Rebecca")
        let coordinator = CloudLedgerMigrationCoordinator(modelContext: context)
        try coordinator.beginOwnerMigration(displayName: "Family Ledger")

        let childChange = try #require(
            context.fetch(FetchDescriptor<PendingCloudChange>()).first {
                $0.recordName == CloudLedgerRecordName.child(child.id)
            }
        )
        context.delete(childChange)
        try context.save()

        let failureTime = Date(timeIntervalSinceReferenceDate: 50)
        try coordinator.recordRecoverableFailure(code: "networkUnavailable", now: failureTime)
        let failed = try #require(
            context.fetch(FetchDescriptor<CloudLedgerMigrationState>()).first
        )
        #expect(failed.phase == .awaitingZoneCreation)
        #expect(failed.attemptCount == 1)
        #expect(failed.lastAttemptAt == failureTime)
        #expect(failed.lastErrorCode == "networkUnavailable")

        let retried = try coordinator.retryCurrentStep(
            now: Date(timeIntervalSinceReferenceDate: 60)
        )
        #expect(retried.phase == .awaitingZoneCreation)
        #expect(retried.pendingRecordCount == 2)
        #expect(failed.lastErrorCode == nil)
    }

    @Test func cancellationBeforeZoneCreationKeepsEveryLedgerRow() throws {
        let container = try AppModelContainer.make(inMemory: true)
        let context = ModelContext(container)
        let service = LedgerService(modelContext: context)
        let child = try service.addChild(named: "Rebecca")
        let transaction = try service.addTransaction(cents: 250, to: child)
        let coordinator = CloudLedgerMigrationCoordinator(modelContext: context)
        try coordinator.beginOwnerMigration(displayName: "Family Ledger")

        try coordinator.cancelBeforeRemoteChanges()

        #expect(try context.fetch(FetchDescriptor<SharedLedgerState>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<CloudLedgerMigrationState>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<PendingCloudChange>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<Child>()).map(\.id) == [child.id])
        #expect(try context.fetch(FetchDescriptor<LedgerTransaction>()).map(\.id) == [transaction.id])
        #expect(service.balance(for: child) == 250)
    }

    @Test func cancellationAfterRemoteWorkRequiresCleanupInstead() throws {
        let container = try AppModelContainer.make(inMemory: true)
        let context = ModelContext(container)
        let coordinator = CloudLedgerMigrationCoordinator(modelContext: context)
        try coordinator.beginOwnerMigration(displayName: "Family Ledger")
        try coordinator.recordZoneCreated()

        #expect(throws: CloudLedgerMigrationError.remoteCleanupRequired) {
            try coordinator.cancelBeforeRemoteChanges()
        }
        #expect(try context.fetch(FetchDescriptor<SharedLedgerState>()).count == 1)
        #expect(try context.fetch(FetchDescriptor<CloudLedgerMigrationState>()).count == 1)
    }

    @Test func participantInvitationCannotSilentlyMergeAnExistingLedger() throws {
        let container = try AppModelContainer.make(inMemory: true)
        let context = ModelContext(container)
        let service = LedgerService(modelContext: context)
        let child = try service.addChild(named: "Rebecca")
        try service.addTransaction(cents: 250, to: child)
        let coordinator = CloudLedgerMigrationCoordinator(modelContext: context)

        #expect(
            throws: CloudLedgerMigrationError.localLedgerNotEmpty(
                children: 1,
                transactions: 1
            )
        ) {
            try coordinator.validateEmptyLocalLedgerForParticipantAdoption()
        }

        let emptyContainer = try AppModelContainer.make(inMemory: true)
        try CloudLedgerMigrationCoordinator(
            modelContext: ModelContext(emptyContainer)
        ).validateEmptyLocalLedgerForParticipantAdoption()
    }

    @Test func terminalFailureBlocksFurtherLedgerMutationWithoutDeletingData() throws {
        let container = try AppModelContainer.make(inMemory: true)
        let context = ModelContext(container)
        let service = LedgerService(modelContext: context)
        let child = try service.addChild(named: "Rebecca")
        try service.addTransaction(cents: 250, to: child)
        let coordinator = CloudLedgerMigrationCoordinator(modelContext: context)
        try coordinator.beginOwnerMigration(displayName: "Family Ledger")

        let summary = try coordinator.recordTerminalFailure(code: "permissionFailure")

        #expect(summary.phase == .attentionRequired)
        #expect(service.balance(for: child) == 250)
        #expect(throws: LedgerError.sharedLedgerUnavailable) {
            try service.addTransaction(cents: 10, to: child)
        }
        #expect(service.balance(for: child) == 250)
    }

    @Test func initialUploadEngineFailuresUpdateTheDurableMigrationState() throws {
        let container = try AppModelContainer.make(inMemory: true)
        let context = ModelContext(container)
        let coordinator = CloudLedgerMigrationCoordinator(modelContext: context)
        let householdID = UUID()
        try coordinator.beginOwnerMigration(
            displayName: "Family Ledger",
            householdID: householdID
        )
        try coordinator.recordZoneCreated()
        let store = try CloudLedgerSyncEngineStore(
            modelContext: context,
            householdID: householdID
        )
        let pendingEngineChanges = try store.pendingEngineChanges()
        let recordID = try #require(pendingEngineChanges.compactMap { change in
            if case .saveRecord(let recordID) = change { return recordID }
            return nil
        }.first)
        let pendingRecord = try store.record(for: recordID)
        let record = try #require(pendingRecord)
        let retryTime = Date(timeIntervalSinceReferenceDate: 80)

        let retryAction = try store.handleFailedSave(
            CloudLedgerSyncEngineFailure(
                record: record,
                code: .networkUnavailable,
                serverRecord: nil,
                retryAfter: 10
            ),
            now: retryTime
        )
        guard case .engineWillRetry = retryAction else {
            Issue.record("Expected the engine to preserve the initial upload for retry")
            return
        }

        let migration = try #require(
            context.fetch(FetchDescriptor<CloudLedgerMigrationState>()).first
        )
        #expect(migration.phase == .uploadingInitialLedger)
        #expect(migration.attemptCount == 1)
        #expect(migration.lastAttemptAt == retryTime)
        #expect(migration.lastErrorCode == String(describing: CKError.Code.networkUnavailable))

        let terminalAction = try store.handleFailedSave(
            CloudLedgerSyncEngineFailure(
                record: record,
                code: .permissionFailure,
                serverRecord: nil,
                retryAfter: nil
            )
        )
        guard case .attentionRequired = terminalAction else {
            Issue.record("Expected a terminal upload error to require attention")
            return
        }
        #expect(migration.phase == .attentionRequired)
        #expect(
            try context.fetch(FetchDescriptor<SharedLedgerState>()).first?.phase
                == .attentionRequired
        )
        #expect(try context.fetch(FetchDescriptor<PendingCloudChange>()).count == 1)
    }

    private func temporaryStoreURL(prefix: String) -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "\(prefix)-\(UUID().uuidString).store")
    }

    private func removeStore(at url: URL) {
        for suffix in ["", "-shm", "-wal"] {
            try? FileManager.default.removeItem(atPath: url.path + suffix)
        }
    }
}
