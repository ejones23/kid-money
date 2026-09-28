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
private final class AutomaticSyncRunnerStub: CloudLedgerSyncRunning {
    var ignoreBackoffCalls: [Bool] = []

    func run(now: Date, ignoreBackoff: Bool) async throws -> CloudLedgerSyncStatus {
        ignoreBackoffCalls.append(ignoreBackoff)
        return .synced
    }
}

@MainActor
private final class BlockingAutomaticSyncRunnerStub: CloudLedgerSyncRunning {
    var ignoreBackoffCalls: [Bool] = []
    private var firstRunContinuation: CheckedContinuation<Void, Never>?

    func run(now: Date, ignoreBackoff: Bool) async throws -> CloudLedgerSyncStatus {
        ignoreBackoffCalls.append(ignoreBackoff)
        if ignoreBackoffCalls.count == 1 {
            await withCheckedContinuation { continuation in
                firstRunContinuation = continuation
            }
        }
        return .synced
    }

    func finishFirstRun() {
        firstRunContinuation?.resume()
        firstRunContinuation = nil
    }
}

@MainActor
struct CloudLedgerSyncSessionTests {
    @Test func liveTransportRetainsDelegateAcrossFetchAndSendAndRefreshesQueue() throws {
        let (context, shared) = try fixture()
        let transport = CloudLedgerLiveSyncSessionTransport(modelContext: context)
        #expect(!transport.automaticallySync)
        weak var delegate: CloudLedgerSyncEngineDelegate?

        do {
            let runtime = try transport.runtime(for: shared)
            delegate = runtime.delegate
            #expect(try transport.runtime(for: shared) === runtime)

            let child = try LedgerService(modelContext: context).addChild(named: "Rebecca")
            let pending = CKSyncEngine.PendingRecordZoneChange.saveRecord(
                CKRecord.ID(
                    recordName: CloudLedgerRecordName.child(child.id),
                    zoneID: shared.zoneID
                )
            )
            #expect(!runtime.engine.state.pendingRecordZoneChanges.contains(pending))
            try runtime.refreshPendingChangesFromQueue()
            #expect(runtime.engine.state.pendingRecordZoneChanges.contains(pending))
        }

        #expect(delegate != nil)
    }

    @Test func automaticCoordinatorDebouncesMutationsAndReusesOneSession() async throws {
        let runner = AutomaticSyncRunnerStub()
        var factoryCalls = 0
        let coordinator = CloudLedgerAutomaticSyncCoordinator(
            debounceNanoseconds: 5_000_000
        ) {
            factoryCalls += 1
            return runner
        }

        coordinator.scheduleAfterLocalMutation()
        coordinator.scheduleAfterLocalMutation()
        coordinator.scheduleAfterLocalMutation()
        try await Task.sleep(nanoseconds: 50_000_000)

        #expect(runner.ignoreBackoffCalls == [false])
        await coordinator.syncWhenAppBecomesActive()
        #expect(runner.ignoreBackoffCalls == [false, true])
        _ = try await coordinator.syncNow()
        #expect(runner.ignoreBackoffCalls == [false, true, true])
        #expect(factoryCalls == 1)
    }

    @Test func automaticTransportEnablesSystemScheduling() throws {
        let (context, _) = try fixture()
        let transport = CloudLedgerLiveSyncSessionTransport(
            modelContext: context,
            automaticallySync: true
        )

        #expect(transport.automaticallySync)
    }

    @Test func mutationDuringAnOlderSyncGetsAFollowUpSendOpportunity() async throws {
        let runner = BlockingAutomaticSyncRunnerStub()
        let coordinator = CloudLedgerAutomaticSyncCoordinator(
            debounceNanoseconds: 1_000_000
        ) {
            runner
        }
        let foregroundTask = Task {
            await coordinator.syncWhenAppBecomesActive()
        }
        try await Task.sleep(nanoseconds: 5_000_000)
        #expect(runner.ignoreBackoffCalls == [true])

        coordinator.scheduleAfterLocalMutation()
        try await Task.sleep(nanoseconds: 5_000_000)
        runner.finishFirstRun()
        await foregroundTask.value
        try await Task.sleep(nanoseconds: 10_000_000)

        #expect(runner.ignoreBackoffCalls == [true, false])
    }

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
