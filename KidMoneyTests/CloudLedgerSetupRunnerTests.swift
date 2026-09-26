import CloudKit
import Foundation
import SwiftData
import Testing
@testable import KidMoney

@MainActor
struct CloudLedgerSetupRunnerTests {
    @Test func completeSetupStopsBeforeActivationAndPreservesLocalLedger() async throws {
        let fixture = try makeFixture()
        let transport = SetupTransportStub(modelContext: fixture.context)
        let result = try await CloudLedgerSetupRunner(
            modelContext: fixture.context,
            transport: transport
        ).run(now: Date(timeIntervalSinceReferenceDate: 10))

        #expect(result.householdID == fixture.householdID)
        #expect(result.phase == .readyToActivate)
        #expect(result.share?.recordID.zoneID == fixture.zoneID)
        #expect(transport.accountStatusCallCount == 1)
        #expect(transport.ensureZoneCallCount == 1)
        #expect(transport.uploadCallCount == 1)
        #expect(transport.ensureShareCallCount == 1)
        #expect(try fixture.context.fetch(FetchDescriptor<PendingCloudChange>()).isEmpty)
        #expect(fixture.service.balance(for: fixture.child) == 250)

        let sharedLedger = try #require(
            fixture.context.fetch(FetchDescriptor<SharedLedgerState>()).first
        )
        #expect(sharedLedger.phase == .preparing)
        let migration = try #require(
            fixture.context.fetch(FetchDescriptor<CloudLedgerMigrationState>()).first
        )
        #expect(migration.zoneCreatedAt != nil)
        #expect(migration.initialUploadCompletedAt != nil)
        #expect(migration.shareCreatedAt != nil)
        #expect(migration.activatedAt == nil)
    }

    @Test func retryAfterZoneCreationInterruptionResumesIdempotently() async throws {
        let fixture = try makeFixture()
        let transport = SetupTransportStub(modelContext: fixture.context)
        transport.zoneFailure = .recoverable(code: "network-unavailable")
        let runner = CloudLedgerSetupRunner(
            modelContext: fixture.context,
            transport: transport
        )

        await #expect(
            throws: CloudLedgerSetupRunnerError.operationFailed(
                code: "network-unavailable"
            )
        ) {
            try await runner.run(now: Date(timeIntervalSinceReferenceDate: 20))
        }

        let interrupted = try #require(
            fixture.context.fetch(FetchDescriptor<CloudLedgerMigrationState>()).first
        )
        #expect(interrupted.phase == .awaitingZoneCreation)
        #expect(interrupted.attemptCount == 1)
        #expect(transport.zoneExists)

        let result = try await runner.run(now: Date(timeIntervalSinceReferenceDate: 30))

        #expect(result.phase == .readyToActivate)
        #expect(transport.ensureZoneCallCount == 2)
        #expect(transport.uploadCallCount == 1)
        #expect(transport.ensureShareCallCount == 1)
        #expect(fixture.service.balance(for: fixture.child) == 250)
    }

    @Test func incompleteUploadCannotAdvanceToShareAndCanRetry() async throws {
        let fixture = try makeFixture()
        let transport = SetupTransportStub(modelContext: fixture.context)
        transport.shouldDrainUpload = false
        let runner = CloudLedgerSetupRunner(
            modelContext: fixture.context,
            transport: transport
        )

        await #expect(
            throws: CloudLedgerSetupRunnerError.operationFailed(
                code: "initial-upload-incomplete"
            )
        ) {
            try await runner.run()
        }

        let interrupted = try #require(
            fixture.context.fetch(FetchDescriptor<CloudLedgerMigrationState>()).first
        )
        #expect(interrupted.phase == .uploadingInitialLedger)
        #expect(transport.ensureShareCallCount == 0)
        #expect(try fixture.context.fetch(FetchDescriptor<PendingCloudChange>()).count == 3)

        transport.shouldDrainUpload = true
        let result = try await runner.run()

        #expect(result.phase == .readyToActivate)
        #expect(transport.ensureZoneCallCount == 1)
        #expect(transport.uploadCallCount == 2)
        #expect(transport.ensureShareCallCount == 1)
    }

    @Test func existingRemoteShareIsRecoveredAfterLocalInterruption() async throws {
        let fixture = try makeFixture()
        let transport = SetupTransportStub(modelContext: fixture.context)
        transport.shareFailure = .recoverable(code: "lost-response")
        let runner = CloudLedgerSetupRunner(
            modelContext: fixture.context,
            transport: transport
        )

        await #expect(
            throws: CloudLedgerSetupRunnerError.operationFailed(code: "lost-response")
        ) {
            try await runner.run()
        }

        let remoteShareID = try #require(transport.share?.recordID)
        let interrupted = try #require(
            fixture.context.fetch(FetchDescriptor<CloudLedgerMigrationState>()).first
        )
        #expect(interrupted.phase == .awaitingShareCreation)

        let result = try await runner.run()

        #expect(result.share?.recordID == remoteShareID)
        #expect(transport.ensureZoneCallCount == 1)
        #expect(transport.uploadCallCount == 1)
        #expect(transport.ensureShareCallCount == 2)
    }

    @Test func unavailableAccountDoesNotCreateRemoteResources() async throws {
        let fixture = try makeFixture()
        let transport = SetupTransportStub(modelContext: fixture.context)
        transport.status = .restricted
        let runner = CloudLedgerSetupRunner(
            modelContext: fixture.context,
            transport: transport
        )

        await #expect(
            throws: CloudLedgerSetupRunnerError.iCloudUnavailable(
                code: "icloud-restricted"
            )
        ) {
            try await runner.run()
        }

        #expect(transport.ensureZoneCallCount == 0)
        #expect(transport.uploadCallCount == 0)
        #expect(transport.ensureShareCallCount == 0)
        let migration = try #require(
            fixture.context.fetch(FetchDescriptor<CloudLedgerMigrationState>()).first
        )
        #expect(migration.phase == .awaitingZoneCreation)
        #expect(migration.lastErrorCode == "icloud-restricted")

        transport.status = .available
        #expect(try await runner.run().phase == .readyToActivate)
    }

    @Test func terminalSetupFailureCanBeCleanedUpWithoutDeletingLedger() async throws {
        let fixture = try makeFixture()
        let transport = SetupTransportStub(modelContext: fixture.context)
        transport.uploadFailure = .terminal(code: "permission-failure")
        let runner = CloudLedgerSetupRunner(
            modelContext: fixture.context,
            transport: transport
        )

        await #expect(
            throws: CloudLedgerSetupRunnerError.operationFailed(
                code: "permission-failure"
            )
        ) {
            try await runner.run()
        }

        let migration = try #require(
            fixture.context.fetch(FetchDescriptor<CloudLedgerMigrationState>()).first
        )
        #expect(migration.phase == .attentionRequired)
        #expect(transport.zoneExists)
        #expect(fixture.service.balance(for: fixture.child) == 250)

        try await runner.cancelSetup()

        #expect(!transport.zoneExists)
        #expect(transport.deleteZoneCallCount == 1)
        #expect(try fixture.context.fetch(FetchDescriptor<SharedLedgerState>()).isEmpty)
        #expect(try fixture.context.fetch(FetchDescriptor<CloudLedgerMigrationState>()).isEmpty)
        #expect(try fixture.context.fetch(FetchDescriptor<PendingCloudChange>()).isEmpty)
        #expect(fixture.service.balance(for: fixture.child) == 250)
        #expect(try fixture.service.transactions(for: fixture.child).count == 1)
    }

    @Test func failedRemoteCleanupKeepsAllStateUntilRetrySucceeds() async throws {
        let fixture = try makeFixture()
        let transport = SetupTransportStub(modelContext: fixture.context)
        transport.uploadFailure = .recoverable(code: "offline")
        let runner = CloudLedgerSetupRunner(
            modelContext: fixture.context,
            transport: transport
        )
        await #expect(
            throws: CloudLedgerSetupRunnerError.operationFailed(code: "offline")
        ) {
            try await runner.run()
        }
        transport.deleteFailure = .recoverable(code: "delete-offline")

        await #expect(
            throws: CloudLedgerSetupRunnerError.operationFailed(code: "delete-offline")
        ) {
            try await runner.cancelSetup()
        }

        #expect(transport.zoneExists)
        #expect(try fixture.context.fetch(FetchDescriptor<SharedLedgerState>()).count == 1)
        #expect(try fixture.context.fetch(FetchDescriptor<CloudLedgerMigrationState>()).count == 1)
        #expect(fixture.service.balance(for: fixture.child) == 250)

        try await runner.cancelSetup()

        #expect(!transport.zoneExists)
        #expect(transport.deleteZoneCallCount == 2)
        #expect(try fixture.context.fetch(FetchDescriptor<SharedLedgerState>()).isEmpty)
        #expect(fixture.service.balance(for: fixture.child) == 250)
    }

    private func makeFixture() throws -> SetupFixture {
        let container = try AppModelContainer.make(inMemory: true)
        let context = ModelContext(container)
        let service = LedgerService(modelContext: context)
        let child = try service.addChild(named: "Rebecca")
        try service.addTransaction(cents: 250, to: child)
        let householdID = UUID()
        try CloudLedgerMigrationCoordinator(modelContext: context).beginOwnerMigration(
            displayName: "Family Ledger",
            householdID: householdID
        )
        let ledger = try #require(
            context.fetch(FetchDescriptor<SharedLedgerState>()).first
        )
        return SetupFixture(
            context: context,
            service: service,
            child: child,
            householdID: householdID,
            zoneID: ledger.zoneID
        )
    }
}

@MainActor
private struct SetupFixture {
    let context: ModelContext
    let service: LedgerService
    let child: Child
    let householdID: UUID
    let zoneID: CKRecordZone.ID
}

@MainActor
private final class SetupTransportStub: CloudLedgerSetupTransport {
    let modelContext: ModelContext
    var status: CKAccountStatus = .available
    var zoneFailure: CloudLedgerSetupTransportError?
    var uploadFailure: CloudLedgerSetupTransportError?
    var shareFailure: CloudLedgerSetupTransportError?
    var deleteFailure: CloudLedgerSetupTransportError?
    var shouldDrainUpload = true
    var zoneExists = false
    var share: CKShare?
    var accountStatusCallCount = 0
    var ensureZoneCallCount = 0
    var uploadCallCount = 0
    var ensureShareCallCount = 0
    var deleteZoneCallCount = 0

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    func accountStatus() async throws -> CKAccountStatus {
        accountStatusCallCount += 1
        return status
    }

    func ensurePrivateZone(_ zoneID: CKRecordZone.ID) async throws {
        ensureZoneCallCount += 1
        zoneExists = true
        if let failure = zoneFailure {
            zoneFailure = nil
            throw failure
        }
    }

    func uploadPendingChanges(householdID: UUID) async throws {
        uploadCallCount += 1
        if let failure = uploadFailure {
            uploadFailure = nil
            throw failure
        }
        guard shouldDrainUpload else { return }
        for change in try modelContext.fetch(FetchDescriptor<PendingCloudChange>())
            where change.householdID == householdID {
            modelContext.delete(change)
        }
        try modelContext.save()
    }

    func ensureZoneShare(
        zoneID: CKRecordZone.ID,
        title: String
    ) async throws -> CKShare {
        ensureShareCallCount += 1
        if share == nil {
            let newShare = CKShare(recordZoneID: zoneID)
            newShare.publicPermission = .none
            newShare[CKShare.SystemFieldKey.title] = title
            share = newShare
        }
        if let failure = shareFailure {
            shareFailure = nil
            throw failure
        }
        return try #require(share)
    }

    func deleteZoneIfPresent(_ zoneID: CKRecordZone.ID) async throws {
        deleteZoneCallCount += 1
        if let failure = deleteFailure {
            deleteFailure = nil
            throw failure
        }
        zoneExists = false
        share = nil
    }
}
