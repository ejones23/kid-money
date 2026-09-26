import CloudKit
import Foundation
import SwiftData
import Testing
@testable import KidMoney

@MainActor
struct CloudLedgerParticipantAdoptionTests {
    @Test func acceptedInvitationLoadsTheInvitedLedgerAndWaitsForActivation() async throws {
        let fixture = try fixture()
        let coordinator = CloudLedgerParticipantAdoptionCoordinator(
            modelContext: fixture.context,
            transport: fixture.transport
        )

        try coordinator.stage(fixture.invitation)
        #expect(throws: LedgerError.sharedLedgerUnavailable) {
            try LedgerService(modelContext: fixture.context).addChild(named: "Local")
        }

        let state = try await coordinator.resume()

        #expect(state.phase == .readyToActivate)
        #expect(state.householdID == fixture.householdID)
        #expect(fixture.transport.acceptCount == 1)
        #expect(fixture.transport.fetchCount == 1)
        let shared = try #require(
            fixture.context.fetch(FetchDescriptor<SharedLedgerState>()).first
        )
        #expect(shared.role == .participant)
        #expect(shared.databaseScope == .sharedDatabase)
        #expect(shared.phase == .preparing)
        #expect(shared.zoneID == fixture.invitation.zoneID)
        let child = try #require(fixture.context.fetch(FetchDescriptor<Child>()).first)
        #expect(child.name == "Rebecca")
        #expect(LedgerService(modelContext: fixture.context).balance(for: child) == 250)
        #expect(try fixture.context.fetch(FetchDescriptor<PendingCloudChange>()).isEmpty)
        #expect(throws: LedgerError.sharedLedgerUnavailable) {
            try LedgerService(modelContext: fixture.context).addTransaction(cents: 10, to: child)
        }

        _ = try await coordinator.resume()
        #expect(fixture.transport.acceptCount == 1)
        #expect(fixture.transport.fetchCount == 1)
        #expect(try fixture.context.fetch(FetchDescriptor<LedgerTransaction>()).count == 1)
    }

    @Test func existingLocalLedgerIsRejectedBeforeCloudAcceptance() throws {
        let fixture = try fixture()
        _ = try LedgerService(modelContext: fixture.context).addChild(named: "Local")
        let coordinator = CloudLedgerParticipantAdoptionCoordinator(
            modelContext: fixture.context,
            transport: fixture.transport
        )

        #expect(throws: CloudLedgerMigrationError.localLedgerNotEmpty(
            children: 1,
            transactions: 0
        )) {
            try coordinator.stage(fixture.invitation)
        }
        #expect(try fixture.context.fetch(
            FetchDescriptor<CloudLedgerParticipantAdoptionState>()
        ).isEmpty)
    }

    @Test func wrongContainerOrSharePermissionIsRejected() throws {
        let fixture = try fixture()
        let coordinator = CloudLedgerParticipantAdoptionCoordinator(
            modelContext: fixture.context,
            transport: fixture.transport
        )
        let wrongContainer = CloudLedgerInvitation(
            containerIdentifier: "other.container",
            zoneID: fixture.invitation.zoneID
        )
        let readOnly = CloudLedgerInvitation(
            containerIdentifier: FamilySharingProbe.containerIdentifier,
            zoneID: fixture.invitation.zoneID,
            isReadWrite: false
        )

        #expect(throws: CloudLedgerParticipantAdoptionError.invalidInvitation) {
            try coordinator.stage(wrongContainer)
        }
        #expect(throws: CloudLedgerParticipantAdoptionError.invalidInvitation) {
            try coordinator.stage(readOnly)
        }
        #expect(fixture.transport.acceptCount == 0)
    }

    @Test func lostAcceptanceResponseRecoversAfterStoreReopen() async throws {
        let storeURL = FileManager.default.temporaryDirectory
            .appending(path: "KidMoneyAdoption-\(UUID().uuidString).store")
        defer {
            for suffix in ["", "-shm", "-wal"] {
                try? FileManager.default.removeItem(atPath: storeURL.path + suffix)
            }
        }
        let householdID = UUID()
        let zoneID = CKRecordZone.ID(
            zoneName: "KidMoneyHousehold-\(householdID.uuidString)",
            ownerName: "other-account"
        )
        let invitation = CloudLedgerInvitation(
            containerIdentifier: FamilySharingProbe.containerIdentifier,
            zoneID: zoneID
        )
        let transport = AdoptionTransportStub(records: snapshot(
            householdID: householdID,
            zoneID: zoneID
        ))
        transport.loseAcceptanceResponseOnce = true

        do {
            let container = try AppModelContainer.make(storeURL: storeURL)
            let context = ModelContext(container)
            let coordinator = CloudLedgerParticipantAdoptionCoordinator(
                modelContext: context,
                transport: transport
            )
            try coordinator.stage(invitation)
            await #expect(throws: AdoptionTransportStub.Failure.lostResponse) {
                _ = try await coordinator.resume()
            }
            let state = try #require(context.fetch(
                FetchDescriptor<CloudLedgerParticipantAdoptionState>()
            ).first)
            #expect(state.phase == .awaitingAcceptance)
            #expect(transport.accepted)
        }

        do {
            let container = try AppModelContainer.make(storeURL: storeURL)
            let context = ModelContext(container)
            let state = try await CloudLedgerParticipantAdoptionCoordinator(
                modelContext: context,
                transport: transport
            ).resume()
            #expect(state.phase == .readyToActivate)
            #expect(transport.acceptCount == 2)
            #expect(try context.fetch(FetchDescriptor<LedgerTransaction>()).count == 1)
        }
    }

    @Test func failedInitialFetchCanRetryWithoutDuplicateTransactions() async throws {
        let fixture = try fixture()
        fixture.transport.failFetchOnce = true
        let coordinator = CloudLedgerParticipantAdoptionCoordinator(
            modelContext: fixture.context,
            transport: fixture.transport
        )
        try coordinator.stage(fixture.invitation)

        await #expect(throws: AdoptionTransportStub.Failure.fetchFailed) {
            _ = try await coordinator.resume()
        }
        let pending = try #require(fixture.context.fetch(
            FetchDescriptor<CloudLedgerParticipantAdoptionState>()
        ).first)
        #expect(pending.phase == .awaitingInitialFetch)
        #expect(try fixture.context.fetch(FetchDescriptor<Child>()).isEmpty)

        let completed = try await coordinator.resume()
        #expect(completed.phase == .readyToActivate)
        #expect(fixture.transport.acceptCount == 1)
        #expect(fixture.transport.fetchCount == 2)
        #expect(try fixture.context.fetch(FetchDescriptor<LedgerTransaction>()).count == 1)
    }

    @Test func incompleteOrInvalidSnapshotLeavesTheLocalLedgerEmpty() async throws {
        let fixture = try fixture()
        fixture.transport.records = fixture.transport.records.filter {
            $0.recordType != CloudLedgerRecordType.household.rawValue
        }
        let coordinator = CloudLedgerParticipantAdoptionCoordinator(
            modelContext: fixture.context,
            transport: fixture.transport
        )
        try coordinator.stage(fixture.invitation)

        await #expect(throws: CloudLedgerParticipantAdoptionError.missingHousehold) {
            _ = try await coordinator.resume()
        }
        #expect(try fixture.context.fetch(FetchDescriptor<SharedLedgerState>()).isEmpty)
        #expect(try fixture.context.fetch(FetchDescriptor<Child>()).isEmpty)
        #expect(try fixture.context.fetch(FetchDescriptor<LedgerTransaction>()).isEmpty)
    }

    @Test func invalidTransactionRollsBackTheWholeInitialSnapshot() async throws {
        let fixture = try fixture()
        let transaction = try #require(fixture.transport.records.first {
            $0.recordType == CloudLedgerRecordType.ledgerTransaction.rawValue
        })
        transaction[CloudLedgerSchema.Field.amountCents] = NSNumber(value: 0)
        let coordinator = CloudLedgerParticipantAdoptionCoordinator(
            modelContext: fixture.context,
            transport: fixture.transport
        )
        try coordinator.stage(fixture.invitation)

        await #expect(throws: CloudLedgerRecordDecodingError.missingOrInvalidField(
            CloudLedgerSchema.Field.amountCents
        )) {
            _ = try await coordinator.resume()
        }

        let adoption = try #require(fixture.context.fetch(
            FetchDescriptor<CloudLedgerParticipantAdoptionState>()
        ).first)
        #expect(adoption.phase == .awaitingInitialFetch)
        #expect(try fixture.context.fetch(FetchDescriptor<SharedLedgerState>()).isEmpty)
        #expect(try fixture.context.fetch(FetchDescriptor<Child>()).isEmpty)
        #expect(try fixture.context.fetch(FetchDescriptor<LedgerTransaction>()).isEmpty)
    }

    private func fixture() throws -> AdoptionFixture {
        let container = try AppModelContainer.make(inMemory: true)
        let context = ModelContext(container)
        let householdID = UUID()
        let zoneID = CKRecordZone.ID(
            zoneName: "KidMoneyHousehold-\(householdID.uuidString)",
            ownerName: "other-account"
        )
        let invitation = CloudLedgerInvitation(
            containerIdentifier: FamilySharingProbe.containerIdentifier,
            zoneID: zoneID
        )
        let transport = AdoptionTransportStub(records: snapshot(
            householdID: householdID,
            zoneID: zoneID
        ))
        return AdoptionFixture(
            context: context,
            householdID: householdID,
            invitation: invitation,
            transport: transport
        )
    }

    private func snapshot(householdID: UUID, zoneID: CKRecordZone.ID) -> [CKRecord] {
        let shared = SharedLedgerState(
            householdID: householdID,
            displayName: "Family Ledger",
            zoneName: zoneID.zoneName,
            zoneOwnerName: zoneID.ownerName,
            role: .owner,
            databaseScope: .privateDatabase,
            phase: .active
        )
        let child = Child(name: "Rebecca", sortOrder: 0)
        let transaction = LedgerTransaction(
            amountCents: 250,
            source: .manual,
            child: child
        )
        return [
            CloudLedgerRecordMapper.household(shared),
            CloudLedgerRecordMapper.child(child, zoneID: zoneID),
            CloudLedgerRecordMapper.transaction(transaction, zoneID: zoneID)!
        ]
    }
}

@MainActor
private struct AdoptionFixture {
    let context: ModelContext
    let householdID: UUID
    let invitation: CloudLedgerInvitation
    let transport: AdoptionTransportStub
}

@MainActor
private final class AdoptionTransportStub: CloudLedgerParticipantTransport {
    enum Failure: Error, Equatable {
        case lostResponse
        case fetchFailed
    }

    var records: [CKRecord]
    var accepted = false
    var loseAcceptanceResponseOnce = false
    var failFetchOnce = false
    var acceptCount = 0
    var fetchCount = 0

    init(records: [CKRecord]) {
        self.records = records
    }

    func accountStatus() async throws -> CKAccountStatus { .available }

    func accept(_ adoption: CloudLedgerParticipantAdoptionState) async throws {
        acceptCount += 1
        guard !accepted else { return }
        accepted = true
        if loseAcceptanceResponseOnce {
            loseAcceptanceResponseOnce = false
            throw Failure.lostResponse
        }
    }

    func initialRecords(in zoneID: CKRecordZone.ID) async throws -> [CKRecord] {
        fetchCount += 1
        if failFetchOnce {
            failFetchOnce = false
            throw Failure.fetchFailed
        }
        return records
    }
}
