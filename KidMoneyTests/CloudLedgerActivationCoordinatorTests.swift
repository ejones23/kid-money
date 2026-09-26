import CloudKit
import Foundation
import SwiftData
import Testing
@testable import KidMoney

@MainActor
private final class ActivationTransportStub: CloudLedgerActivationTransport {
    var result: CloudLedgerAccessResult = .available(accountRecordName: "account-one")
    var checkCount = 0

    func checkAccess(to sharedLedger: SharedLedgerState) async -> CloudLedgerAccessResult {
        checkCount += 1
        return result
    }
}

@MainActor
struct CloudLedgerActivationCoordinatorTests {
    @Test func ownerNeedsCompletedSetupAndLiveShareAccess() async throws {
        let context = ModelContext(try AppModelContainer.make(inMemory: true))
        let shared = owner(in: context)
        let migration = CloudLedgerMigrationState(
            householdID: shared.householdID,
            phase: .awaitingShareCreation
        )
        context.insert(migration)
        try context.save()
        let transport = ActivationTransportStub()
        let coordinator = CloudLedgerActivationCoordinator(
            modelContext: context,
            transport: transport
        )

        await #expect(throws: CloudLedgerActivationError.notReady) {
            try await coordinator.activate()
        }
        #expect(transport.checkCount == 0)

        migration.phaseRawValue = CloudLedgerMigrationPhase.readyToActivate.rawValue
        transport.result = .offline(code: "network-unavailable")
        await #expect(throws: CloudLedgerActivationError.offline(code: "network-unavailable")) {
            try await coordinator.activate()
        }
        #expect(shared.phase == .preparing)

        transport.result = .available(accountRecordName: "account-one")
        try await coordinator.activate()
        #expect(shared.phase == .active)
        #expect(shared.accountRecordName == "account-one")
        #expect(migration.phase == .completed)
    }

    @Test func participantActivationUnlocksQueuedEditsButRevocationFreezesThem() async throws {
        let context = ModelContext(try AppModelContainer.make(inMemory: true))
        let (shared, adoption) = participant(in: context)
        let transport = ActivationTransportStub()
        let coordinator = CloudLedgerActivationCoordinator(
            modelContext: context,
            transport: transport
        )

        #expect(throws: LedgerError.sharedLedgerUnavailable) {
            try LedgerService(modelContext: context).addChild(named: "Rebecca")
        }
        try await coordinator.activate()
        #expect(shared.phase == .active)
        #expect(adoption.phase == .completed)

        let child = try LedgerService(modelContext: context).addChild(named: "Rebecca")
        try LedgerService(modelContext: context).addTransaction(cents: 25, to: child)
        let pendingCount = try context.fetch(FetchDescriptor<PendingCloudChange>()).count
        #expect(pendingCount == 2)

        transport.result = .denied(code: "share-revoked")
        #expect(try await coordinator.checkActiveAccess() == .denied(code: "share-revoked"))
        #expect(shared.phase == .attentionRequired)
        #expect(try context.fetch(FetchDescriptor<PendingCloudChange>()).count == pendingCount)
        #expect(LedgerService(modelContext: context).balance(for: child) == 25)
        #expect(throws: LedgerError.sharedLedgerUnavailable) {
            try LedgerService(modelContext: context).addTransaction(cents: 10, to: child)
        }
    }

    @Test func accountSwitchFreezesActiveLedgerWithoutLosingLocalRows() async throws {
        let context = ModelContext(try AppModelContainer.make(inMemory: true))
        let (shared, _) = participant(in: context)
        let transport = ActivationTransportStub()
        let coordinator = CloudLedgerActivationCoordinator(
            modelContext: context,
            transport: transport
        )
        try await coordinator.activate()
        let child = try LedgerService(modelContext: context).addChild(named: "Rebecca")

        transport.result = .available(accountRecordName: "account-two")
        await #expect(throws: CloudLedgerActivationError.accountChanged) {
            try await coordinator.checkActiveAccess()
        }
        #expect(shared.phase == .attentionRequired)
        #expect(shared.accountRecordName == "account-one")
        #expect(try context.fetch(FetchDescriptor<Child>()).map(\.id) == [child.id])
    }

    @Test func offlineEditsAndActivationSurviveRestart() async throws {
        let storeURL = FileManager.default.temporaryDirectory
            .appending(path: "KidMoneyActivation-\(UUID().uuidString).store")
        defer {
            for suffix in ["", "-shm", "-wal"] {
                try? FileManager.default.removeItem(atPath: storeURL.path + suffix)
            }
        }
        let transport = ActivationTransportStub()
        let householdID: UUID
        do {
            let container = try AppModelContainer.make(storeURL: storeURL)
            let context = ModelContext(container)
            let (shared, _) = participant(in: context)
            householdID = shared.householdID
            let coordinator = CloudLedgerActivationCoordinator(
                modelContext: context,
                transport: transport
            )
            try await coordinator.activate()
            transport.result = .offline(code: "network-unavailable")
            #expect(try await coordinator.checkActiveAccess() == .offline(
                code: "network-unavailable"
            ))
            let child = try LedgerService(modelContext: context).addChild(named: "Rebecca")
            try LedgerService(modelContext: context).addTransaction(cents: 15, to: child)
            #expect(shared.phase == .active)
        }
        do {
            let container = try AppModelContainer.make(storeURL: storeURL)
            let context = ModelContext(container)
            let shared = try #require(context.fetch(FetchDescriptor<SharedLedgerState>()).first)
            let child = try #require(context.fetch(FetchDescriptor<Child>()).first)
            #expect(shared.householdID == householdID)
            #expect(shared.accountRecordName == "account-one")
            #expect(shared.phase == .active)
            #expect(LedgerService(modelContext: context).balance(for: child) == 15)
            #expect(try context.fetch(FetchDescriptor<PendingCloudChange>()).count == 2)
            #expect(try context.fetch(FetchDescriptor<CloudLedgerSyncState>()).first?.status
                    == .offline)
            transport.result = .available(accountRecordName: "account-one")
            #expect(try await CloudLedgerActivationCoordinator(
                modelContext: context,
                transport: transport
            ).checkActiveAccess() == .available(accountRecordName: "account-one"))
        }
    }

    private func owner(in context: ModelContext) -> SharedLedgerState {
        let id = UUID()
        let shared = SharedLedgerState(
            householdID: id,
            displayName: "Family",
            zoneName: "KidMoneyHousehold-\(id.uuidString)",
            zoneOwnerName: CKCurrentUserDefaultName,
            role: .owner,
            databaseScope: .privateDatabase,
            phase: .preparing
        )
        context.insert(shared)
        return shared
    }

    private func participant(
        in context: ModelContext
    ) -> (SharedLedgerState, CloudLedgerParticipantAdoptionState) {
        let id = UUID()
        let zoneID = CKRecordZone.ID(
            zoneName: "KidMoneyHousehold-\(id.uuidString)",
            ownerName: "owner-account"
        )
        let invitation = CloudLedgerInvitation(
            containerIdentifier: FamilySharingProbe.containerIdentifier,
            zoneID: zoneID
        )
        let shared = SharedLedgerState(
            householdID: id,
            displayName: "Family",
            zoneName: zoneID.zoneName,
            zoneOwnerName: zoneID.ownerName,
            role: .participant,
            databaseScope: .sharedDatabase,
            phase: .preparing
        )
        let adoption = CloudLedgerParticipantAdoptionState(invitation: invitation)
        adoption.householdID = id
        adoption.phaseRawValue = CloudLedgerParticipantAdoptionPhase.readyToActivate.rawValue
        context.insert(shared)
        context.insert(adoption)
        return (shared, adoption)
    }
}
