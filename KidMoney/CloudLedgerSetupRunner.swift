import CloudKit
import Foundation
import SwiftData

enum CloudLedgerSetupTransportError: Error, Equatable {
    case recoverable(code: String)
    case terminal(code: String)
}

enum CloudLedgerSetupRunnerError: Error, Equatable {
    case invalidMigrationState
    case iCloudUnavailable(code: String)
    case operationFailed(code: String)
}

struct CloudLedgerSetupResult {
    let householdID: UUID
    let phase: CloudLedgerMigrationPhase
    let share: CKShare?
}

/// The network boundary for owner setup. Tests inject a deterministic fake;
/// the live implementation below is intentionally not constructed by the app.
@MainActor
protocol CloudLedgerSetupTransport: AnyObject {
    func accountStatus() async throws -> CKAccountStatus
    func ensurePrivateZone(_ zoneID: CKRecordZone.ID) async throws
    func uploadPendingChanges(householdID: UUID) async throws
    func ensureZoneShare(
        zoneID: CKRecordZone.ID,
        title: String
    ) async throws -> CKShare
    func deleteZoneIfPresent(_ zoneID: CKRecordZone.ID) async throws
}

/// Resumes owner setup from its durable migration phase. Completing this runner
/// leaves the ledger in `readyToActivate`; it does not enable live sync or alter
/// any child or transaction rows.
@MainActor
struct CloudLedgerSetupRunner {
    let modelContext: ModelContext
    let transport: any CloudLedgerSetupTransport

    func run(now: Date = .now) async throws -> CloudLedgerSetupResult {
        let coordinator = CloudLedgerMigrationCoordinator(modelContext: modelContext)
        var summary: CloudLedgerMigrationSummary
        do {
            summary = try coordinator.resumeOwnerMigration(now: now)
        } catch {
            throw CloudLedgerSetupRunnerError.invalidMigrationState
        }

        guard let sharedLedger = try sharedLedger(householdID: summary.householdID),
              sharedLedger.role == .owner,
              sharedLedger.databaseScope == .privateDatabase,
              sharedLedger.phase == .preparing else {
            throw CloudLedgerSetupRunnerError.invalidMigrationState
        }

        do {
            try await requireAvailableAccount()

            if summary.phase == .awaitingZoneCreation {
                try await transport.ensurePrivateZone(sharedLedger.zoneID)
                summary = try coordinator.recordZoneCreated(now: now)
            }

            if summary.phase == .uploadingInitialLedger {
                try await transport.uploadPendingChanges(householdID: summary.householdID)
                summary = try coordinator.recordInitialUploadCompleted(now: now)
            }

            var share: CKShare?
            if summary.phase == .awaitingShareCreation || summary.phase == .readyToActivate {
                share = try await transport.ensureZoneShare(
                    zoneID: sharedLedger.zoneID,
                    title: sharedLedger.displayName
                )
                summary = try coordinator.recordShareCreated(now: now)
            }

            guard summary.phase == .readyToActivate else {
                throw CloudLedgerSetupRunnerError.invalidMigrationState
            }
            return CloudLedgerSetupResult(
                householdID: summary.householdID,
                phase: summary.phase,
                share: share
            )
        } catch {
            let failure = classify(error)
            switch failure {
            case .recoverable(let code):
                _ = try? coordinator.recordRecoverableFailure(code: code, now: now)
                if case CloudLedgerSetupRunnerError.iCloudUnavailable = error {
                    throw error
                }
                throw CloudLedgerSetupRunnerError.operationFailed(code: code)
            case .terminal(let code):
                _ = try? coordinator.recordTerminalFailure(code: code, now: now)
                throw CloudLedgerSetupRunnerError.operationFailed(code: code)
            }
        }
    }

    /// Cancellation is committed locally only after CloudKit confirms that the
    /// setup zone is absent. A failed deletion leaves all migration state and
    /// local ledger data available for retry.
    func cancelSetup(now: Date = .now) async throws {
        guard let migration = try modelContext.fetch(
            FetchDescriptor<CloudLedgerMigrationState>()
        ).first,
              migration.phase != .completed,
              let sharedLedger = try sharedLedger(householdID: migration.householdID),
              sharedLedger.phase != .active else {
            throw CloudLedgerSetupRunnerError.invalidMigrationState
        }

        let coordinator = CloudLedgerMigrationCoordinator(modelContext: modelContext)
        do {
            try await requireAvailableAccount()
            try await transport.deleteZoneIfPresent(sharedLedger.zoneID)
            try coordinator.cancelAfterConfirmedRemoteCleanup()
        } catch {
            let failure = classify(error)
            switch failure {
            case .recoverable(let code):
                _ = try? coordinator.recordRecoverableFailure(code: code, now: now)
                if case CloudLedgerSetupRunnerError.iCloudUnavailable = error {
                    throw error
                }
                throw CloudLedgerSetupRunnerError.operationFailed(code: code)
            case .terminal(let code):
                _ = try? coordinator.recordTerminalFailure(code: code, now: now)
                throw CloudLedgerSetupRunnerError.operationFailed(code: code)
            }
        }
    }

    private func requireAvailableAccount() async throws {
        let status = try await transport.accountStatus()
        let code: String
        switch status {
        case .available:
            return
        case .noAccount:
            code = "no-icloud-account"
        case .restricted:
            code = "icloud-restricted"
        case .couldNotDetermine:
            code = "icloud-status-unknown"
        case .temporarilyUnavailable:
            code = "icloud-temporarily-unavailable"
        @unknown default:
            code = "icloud-status-unknown"
        }
        throw CloudLedgerSetupRunnerError.iCloudUnavailable(code: code)
    }

    private func sharedLedger(householdID: UUID) throws -> SharedLedgerState? {
        try modelContext.fetch(FetchDescriptor<SharedLedgerState>()).first {
            $0.householdID == householdID
        }
    }

    private func classify(_ error: any Error) -> CloudLedgerSetupTransportError {
        if let failure = error as? CloudLedgerSetupTransportError {
            return failure
        }
        if case CloudLedgerSetupRunnerError.iCloudUnavailable(let code) = error {
            return .recoverable(code: code)
        }
        if case CloudLedgerMigrationError.pendingInitialRecords = error {
            return .recoverable(code: "initial-upload-incomplete")
        }
        if let cloudError = error as? CKError {
            let code = "cloudkit-\(String(describing: cloudError.code))"
            switch cloudError.code {
            case .networkFailure, .networkUnavailable, .zoneBusy, .serviceUnavailable,
                    .requestRateLimited, .operationCancelled,
                    .accountTemporarilyUnavailable, .batchRequestFailed:
                return .recoverable(code: code)
            default:
                return .terminal(code: code)
            }
        }
        if let runnerError = error as? CloudLedgerSetupRunnerError {
            switch runnerError {
            case .invalidMigrationState:
                return .terminal(code: "invalid-migration-state")
            case .iCloudUnavailable(let code), .operationFailed(let code):
                return .recoverable(code: code)
            }
        }
        return .terminal(code: "setup-operation-failed")
    }
}

/// Real CloudKit transport for the setup runner. Keeping its construction out
/// of app startup ensures this code cannot upload a user's ledger yet.
@MainActor
final class CloudLedgerLiveSetupTransport: CloudLedgerSetupTransport {
    private let container: CKContainer
    private let database: CKDatabase
    private let modelContext: ModelContext

    init(
        modelContext: ModelContext,
        container: CKContainer = CKContainer(
            identifier: FamilySharingProbe.containerIdentifier
        )
    ) {
        self.modelContext = modelContext
        self.container = container
        self.database = container.privateCloudDatabase
    }

    func accountStatus() async throws -> CKAccountStatus {
        try await withCheckedThrowingContinuation { continuation in
            container.accountStatus { status, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: status)
                }
            }
        }
    }

    func ensurePrivateZone(_ zoneID: CKRecordZone.ID) async throws {
        let results = try await database.modifyRecordZones(
            saving: [CKRecordZone(zoneID: zoneID)],
            deleting: []
        )
        guard let result = results.saveResults[zoneID] else {
            throw CloudLedgerSetupTransportError.terminal(code: "missing-zone-save-result")
        }
        _ = try result.get()
    }

    func uploadPendingChanges(householdID: UUID) async throws {
        let runtime = try CloudLedgerSyncEngineRuntime(
            database: database,
            modelContext: modelContext,
            householdID: householdID
        )
        try await runtime.engine.sendChanges()
    }

    func ensureZoneShare(
        zoneID: CKRecordZone.ID,
        title: String
    ) async throws -> CKShare {
        let shareID = CKRecord.ID(
            recordName: CKRecordNameZoneWideShare,
            zoneID: zoneID
        )
        do {
            guard let share = try await database.record(for: shareID) as? CKShare else {
                throw CloudLedgerSetupTransportError.terminal(
                    code: "unexpected-share-record"
                )
            }
            return share
        } catch let error as CKError where error.code == .unknownItem {
            let share = CKShare(recordZoneID: zoneID)
            share.publicPermission = .none
            share[CKShare.SystemFieldKey.title] = title
            let results = try await database.modifyRecords(
                saving: [share],
                deleting: [],
                savePolicy: .ifServerRecordUnchanged,
                atomically: true
            )
            guard let result = results.saveResults[share.recordID] else {
                throw CloudLedgerSetupTransportError.terminal(
                    code: "missing-share-save-result"
                )
            }
            guard let savedShare = try result.get() as? CKShare else {
                throw CloudLedgerSetupTransportError.terminal(
                    code: "unexpected-share-record"
                )
            }
            return savedShare
        }
    }

    func deleteZoneIfPresent(_ zoneID: CKRecordZone.ID) async throws {
        do {
            let results = try await database.modifyRecordZones(
                saving: [],
                deleting: [zoneID]
            )
            guard let result = results.deleteResults[zoneID] else {
                throw CloudLedgerSetupTransportError.terminal(
                    code: "missing-zone-delete-result"
                )
            }
            try result.get()
        } catch let error as CKError where error.code == .unknownItem {
            return
        }
    }
}
