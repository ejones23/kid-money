import CloudKit
import Foundation
import SwiftData

enum CloudLedgerSyncSessionError: Error, Equatable {
    case invalidLedger
    case alreadyRunning
}

@MainActor
protocol CloudLedgerSyncSessionTransport: AnyObject {
    func fetchChanges(for ledger: SharedLedgerState) async throws
    func sendChanges(for ledger: SharedLedgerState) async throws
}

/// The only entry point for ordinary real-ledger network work. The sharing
/// screen constructs it only for an explicit Sync Now action. It keeps
/// automatic CKSyncEngine synchronization off and rechecks access between
/// fetch and send.
@MainActor
final class CloudLedgerSyncSession {
    let modelContext: ModelContext
    let accessTransport: any CloudLedgerActivationTransport
    let syncTransport: any CloudLedgerSyncSessionTransport
    private var isRunning = false

    init(
        modelContext: ModelContext,
        accessTransport: any CloudLedgerActivationTransport,
        syncTransport: any CloudLedgerSyncSessionTransport
    ) {
        self.modelContext = modelContext
        self.accessTransport = accessTransport
        self.syncTransport = syncTransport
    }

    @discardableResult
    func run(now: Date = .now, ignoreBackoff: Bool = false) async throws -> CloudLedgerSyncStatus {
        guard !isRunning else { throw CloudLedgerSyncSessionError.alreadyRunning }
        isRunning = true
        defer { isRunning = false }

        let ledger = try activeLedger()
        let state = try syncState(for: ledger)
        if !ignoreBackoff, let nextRetry = state.nextRetryAt, nextRetry > now {
            return state.status ?? .offline
        }

        if let blocked = try await checkAccess(now: now) {
            return try finishAccessResult(blocked, state: state, now: now)
        }

        do {
            try await syncTransport.fetchChanges(for: ledger)
        } catch {
            return try handle(error, ledger: ledger, state: state, now: now)
        }
        guard ledger.phase == .active else { return .attentionRequired }

        // Fetch may have taken long enough for an iCloud account switch or
        // share revocation. Never send the queued family data without recheck.
        if let blocked = try await checkAccess(now: now) {
            return try finishAccessResult(blocked, state: state, now: now)
        }
        do {
            try await syncTransport.sendChanges(for: ledger)
        } catch {
            return try handle(error, ledger: ledger, state: state, now: now)
        }
        guard ledger.phase == .active else { return .attentionRequired }
        try CloudLedgerSyncEngineStore(
            modelContext: modelContext,
            householdID: ledger.householdID
        ).finishSuccessfulWork(now: now)
        return state.status ?? .attentionRequired
    }

    private func checkAccess(now: Date) async throws -> CloudLedgerSyncStatus? {
        do {
            let result = try await CloudLedgerActivationCoordinator(
                modelContext: modelContext,
                transport: accessTransport
            ).checkActiveAccess(now: now)
            switch result {
            case .available: return nil
            case .offline: return .offline
            case .denied: return .attentionRequired
            }
        } catch CloudLedgerActivationError.accountChanged {
            return .attentionRequired
        }
    }

    private func finishAccessResult(
        _ status: CloudLedgerSyncStatus,
        state: CloudLedgerSyncState,
        now: Date
    ) throws -> CloudLedgerSyncStatus {
        if status == .offline {
            state.nextRetryAt = now.addingTimeInterval(30)
            try modelContext.save()
        }
        return status
    }

    private func handle(
        _ error: any Error,
        ledger: SharedLedgerState,
        state: CloudLedgerSyncState,
        now: Date
    ) throws -> CloudLedgerSyncStatus {
        guard ledger.phase == .active else { return .attentionRequired }
        let failure = CloudLedgerSyncFailurePolicy.classify(error)
        switch failure {
        case .offline(let code, let retryAfter):
            state.statusRawValue = CloudLedgerSyncStatus.offline.rawValue
            state.lastAttemptAt = now
            state.nextRetryAt = now.addingTimeInterval(max(30, retryAfter ?? 0))
            state.lastErrorCode = code
            try modelContext.save()
            return .offline
        case .attentionRequired(let code):
            try CloudLedgerSyncEngineStore(
                modelContext: modelContext,
                householdID: ledger.householdID
            ).requireUserAttention(code: code, now: now)
            return .attentionRequired
        }
    }

    private func activeLedger() throws -> SharedLedgerState {
        let ledgers = try modelContext.fetch(FetchDescriptor<SharedLedgerState>())
        guard ledgers.count == 1, let ledger = ledgers.first,
              ledger.phase == .active,
              let accountName = ledger.accountRecordName, !accountName.isEmpty,
              (ledger.role == .owner && ledger.databaseScope == .privateDatabase)
                || (ledger.role == .participant && ledger.databaseScope == .sharedDatabase) else {
            throw CloudLedgerSyncSessionError.invalidLedger
        }
        let migrations = try modelContext.fetch(FetchDescriptor<CloudLedgerMigrationState>())
        let adoptions = try modelContext.fetch(
            FetchDescriptor<CloudLedgerParticipantAdoptionState>()
        )
        switch ledger.role {
        case .owner:
            guard migrations.count == 1,
                  migrations.first?.householdID == ledger.householdID,
                  migrations.first?.phase == .completed,
                  adoptions.isEmpty else {
                throw CloudLedgerSyncSessionError.invalidLedger
            }
        case .participant:
            guard migrations.isEmpty,
                  adoptions.count == 1,
                  adoptions.first?.householdID == ledger.householdID,
                  adoptions.first?.zoneID == ledger.zoneID,
                  adoptions.first?.phase == .completed else {
                throw CloudLedgerSyncSessionError.invalidLedger
            }
        case nil:
            throw CloudLedgerSyncSessionError.invalidLedger
        }
        return ledger
    }

    private func syncState(for ledger: SharedLedgerState) throws -> CloudLedgerSyncState {
        guard let scope = ledger.databaseScope else {
            throw CloudLedgerSyncSessionError.invalidLedger
        }
        let key = CloudLedgerSyncState.makeKey(
            householdID: ledger.householdID,
            databaseScope: scope
        )
        if let state = try modelContext.fetch(FetchDescriptor<CloudLedgerSyncState>())
            .first(where: { $0.key == key }) {
            return state
        }
        let state = CloudLedgerSyncState(householdID: ledger.householdID, databaseScope: scope)
        modelContext.insert(state)
        try modelContext.save()
        return state
    }
}

enum CloudLedgerSyncFailure: Equatable {
    case offline(code: String, retryAfter: TimeInterval?)
    case attentionRequired(code: String)
}

enum CloudLedgerSyncFailurePolicy {
    static func classify(_ error: any Error) -> CloudLedgerSyncFailure {
        guard let cloudError = error as? CKError else {
            return .attentionRequired(code: "sync-operation-failed")
        }
        if cloudError.code == .partialFailure {
            let nested = cloudError.partialErrorsByItemID?.values.compactMap { $0 as? CKError }
                ?? []
            guard !nested.isEmpty else {
                return .attentionRequired(code: "cloudkit-partial-failure")
            }
            for failure in nested {
                if case .attentionRequired = classify(failure) {
                    return .attentionRequired(code: "cloudkit-\(failure.code.rawValue)")
                }
            }
            return .offline(code: "cloudkit-partial-failure", retryAfter: nil)
        }
        let code = "cloudkit-\(cloudError.code.rawValue)"
        switch cloudError.code {
        case .networkFailure, .networkUnavailable, .zoneBusy, .serviceUnavailable,
                .requestRateLimited, .operationCancelled,
                .accountTemporarilyUnavailable, .serverResponseLost,
                .batchRequestFailed:
            return .offline(code: code, retryAfter: cloudError.retryAfterSeconds)
        default:
            return .attentionRequired(code: code)
        }
    }
}

/// A live transport exists for the future explicit setup flow, but is not
/// constructed on app launch. Each operation restores the engine's persisted
/// token; `automaticallySync` remains false.
@MainActor
final class CloudLedgerLiveSyncSessionTransport: CloudLedgerSyncSessionTransport {
    let modelContext: ModelContext
    let container: CKContainer

    init(
        modelContext: ModelContext,
        container: CKContainer = CKContainer(
            identifier: FamilySharingProbe.containerIdentifier
        )
    ) {
        self.modelContext = modelContext
        self.container = container
    }

    func fetchChanges(for ledger: SharedLedgerState) async throws {
        try await runtime(for: ledger).engine.fetchChanges()
    }

    func sendChanges(for ledger: SharedLedgerState) async throws {
        try await runtime(for: ledger).engine.sendChanges()
    }

    private func runtime(for ledger: SharedLedgerState) throws -> CloudLedgerSyncEngineRuntime {
        let database: CKDatabase
        switch ledger.databaseScope {
        case .privateDatabase:
            database = container.privateCloudDatabase
        case .sharedDatabase:
            database = container.sharedCloudDatabase
        case nil:
            throw CloudLedgerSyncSessionError.invalidLedger
        }
        return try CloudLedgerSyncEngineRuntime(
            database: database,
            modelContext: modelContext,
            householdID: ledger.householdID
        )
    }
}
