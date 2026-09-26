import CloudKit
import Foundation
import SwiftData
import Testing
@testable import KidMoney

@MainActor
private final class SessionAccessStub: CloudLedgerActivationTransport {
    var results: [CloudLedgerAccessResult] = []
    var calls = 0

    func checkAccess(to sharedLedger: SharedLedgerState) async -> CloudLedgerAccessResult {
        calls += 1
        return results.isEmpty
            ? .available(accountRecordName: "account-one")
            : results.removeFirst()
    }
}

@MainActor
private final class SessionWorkStub: CloudLedgerSyncSessionTransport {
    var actions: [String] = []
    var fetchError: (any Error)?
    var sendError: (any Error)?

    func fetchChanges(for ledger: SharedLedgerState) async throws {
        actions.append("fetch")
        if let fetchError { throw fetchError }
    }

    func sendChanges(for ledger: SharedLedgerState) async throws {
        actions.append("send")
        if let sendError { throw sendError }
    }
}

@MainActor
struct CloudLedgerSyncSessionTests {
    @Test func accessibleSessionFetchesBeforeSendingAndReportsSynced() async throws {
        let (context, shared) = try fixture()
        let access = SessionAccessStub()
        let work = SessionWorkStub()

        let status = try await CloudLedgerSyncSession(
            modelContext: context,
            accessTransport: access,
            syncTransport: work
        ).run()

        #expect(status == .synced)
        #expect(work.actions == ["fetch", "send"])
        #expect(access.calls == 2)
        #expect(shared.phase == .active)
    }

    @Test func offlinePreflightRetainsEditsAndHonorsDurableBackoff() async throws {
        let (context, shared) = try fixture()
        let child = try LedgerService(modelContext: context).addChild(named: "Rebecca")
        let access = SessionAccessStub()
        access.results = [.offline(code: "network-unavailable")]
        let work = SessionWorkStub()
        let session = CloudLedgerSyncSession(
            modelContext: context,
            accessTransport: access,
            syncTransport: work
        )
        let start = Date(timeIntervalSinceReferenceDate: 100)

        #expect(try await session.run(now: start) == .offline)
        #expect(work.actions.isEmpty)
        #expect(access.calls == 1)
        #expect(shared.phase == .active)
        try LedgerService(modelContext: context).addTransaction(cents: 25, to: child)
        #expect(try context.fetch(FetchDescriptor<PendingCloudChange>()).count == 2)

        #expect(try await session.run(now: start.addingTimeInterval(10)) == .offline)
        #expect(access.calls == 1)
        #expect(try await session.run(now: start.addingTimeInterval(31)) == .pending)
        #expect(work.actions == ["fetch", "send"])
        #expect(try context.fetch(FetchDescriptor<PendingCloudChange>()).count == 2)
    }

    @Test func accountSwitchAfterFetchPreventsSendingQueuedFamilyData() async throws {
        let (context, shared) = try fixture()
        _ = try LedgerService(modelContext: context).addChild(named: "Rebecca")
        let access = SessionAccessStub()
        access.results = [
            .available(accountRecordName: "account-one"),
            .available(accountRecordName: "account-two")
        ]
        let work = SessionWorkStub()

        #expect(try await CloudLedgerSyncSession(
            modelContext: context,
            accessTransport: access,
            syncTransport: work
        ).run() == .attentionRequired)
        #expect(work.actions == ["fetch"])
        #expect(shared.phase == .attentionRequired)
        #expect(try context.fetch(FetchDescriptor<PendingCloudChange>()).count == 1)
    }

    @Test func revokedShareBeforeFetchPreventsAllNetworkWork() async throws {
        let (context, shared) = try fixture()
        let access = SessionAccessStub()
        access.results = [.denied(code: "share-revoked")]
        let work = SessionWorkStub()

        #expect(try await CloudLedgerSyncSession(
            modelContext: context,
            accessTransport: access,
            syncTransport: work
        ).run() == .attentionRequired)
        #expect(work.actions.isEmpty)
        #expect(shared.phase == .attentionRequired)
    }

    @Test func networkFailureDuringFetchIsRetryableWithoutLosingQueue() async throws {
        let (context, shared) = try fixture()
        _ = try LedgerService(modelContext: context).addChild(named: "Rebecca")
        let access = SessionAccessStub()
        let work = SessionWorkStub()
        work.fetchError = cloudError(.networkUnavailable)
        let start = Date(timeIntervalSinceReferenceDate: 200)

        #expect(try await CloudLedgerSyncSession(
            modelContext: context,
            accessTransport: access,
            syncTransport: work
        ).run(now: start) == .offline)
        #expect(work.actions == ["fetch"])
        #expect(shared.phase == .active)
        #expect(try context.fetch(FetchDescriptor<PendingCloudChange>()).count == 1)
        let state = try #require(context.fetch(FetchDescriptor<CloudLedgerSyncState>()).first)
        #expect(state.nextRetryAt == start.addingTimeInterval(30))
    }

    @Test func missingZoneDuringSendFreezesEditsButKeepsQueue() async throws {
        let (context, shared) = try fixture()
        _ = try LedgerService(modelContext: context).addChild(named: "Rebecca")
        let work = SessionWorkStub()
        work.sendError = cloudError(.zoneNotFound)

        #expect(try await CloudLedgerSyncSession(
            modelContext: context,
            accessTransport: SessionAccessStub(),
            syncTransport: work
        ).run() == .attentionRequired)
        #expect(work.actions == ["fetch", "send"])
        #expect(shared.phase == .attentionRequired)
        #expect(try context.fetch(FetchDescriptor<PendingCloudChange>()).count == 1)
    }

    @Test func failurePolicyInspectsPartialCloudKitFailures() throws {
        let recordID = CKRecord.ID(recordName: "child")
        let nested = cloudError(.permissionFailure)
        let wrapped = NSError(
            domain: CKErrorDomain,
            code: CKError.Code.partialFailure.rawValue,
            userInfo: [CKPartialErrorsByItemIDKey: [recordID: nested]]
        )
        let error = try #require(wrapped as? CKError)
        #expect(CloudLedgerSyncFailurePolicy.classify(error)
                == .attentionRequired(code: "cloudkit-\(CKError.Code.permissionFailure.rawValue)"))
    }

    @Test func incompleteParticipantSetupCannotOpenSyncSession() async throws {
        let (context, _) = try fixture()
        let adoption = try #require(context.fetch(
            FetchDescriptor<CloudLedgerParticipantAdoptionState>()
        ).first)
        adoption.phaseRawValue = CloudLedgerParticipantAdoptionPhase.readyToActivate.rawValue
        try context.save()
        let work = SessionWorkStub()

        await #expect(throws: CloudLedgerSyncSessionError.invalidLedger) {
            try await CloudLedgerSyncSession(
                modelContext: context,
                accessTransport: SessionAccessStub(),
                syncTransport: work
            ).run()
        }
        #expect(work.actions.isEmpty)
    }

    private func fixture() throws -> (ModelContext, SharedLedgerState) {
        let context = ModelContext(try AppModelContainer.make(inMemory: true))
        let householdID = UUID()
        let shared = SharedLedgerState(
            householdID: householdID,
            displayName: "Family",
            zoneName: "KidMoneyHousehold-\(householdID.uuidString)",
            zoneOwnerName: "owner-account",
            role: .participant,
            databaseScope: .sharedDatabase,
            phase: .active
        )
        shared.accountRecordName = "account-one"
        let invitation = CloudLedgerInvitation(
            containerIdentifier: FamilySharingProbe.containerIdentifier,
            zoneID: shared.zoneID
        )
        let adoption = CloudLedgerParticipantAdoptionState(invitation: invitation)
        adoption.householdID = householdID
        adoption.phaseRawValue = CloudLedgerParticipantAdoptionPhase.completed.rawValue
        context.insert(shared)
        context.insert(adoption)
        try context.save()
        return (context, shared)
    }

    private func cloudError(_ code: CKError.Code) -> CKError {
        NSError(domain: CKErrorDomain, code: code.rawValue) as! CKError
    }
}
