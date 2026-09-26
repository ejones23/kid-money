import CloudKit
import Foundation
import SwiftData

enum CloudLedgerAccessResult: Equatable {
    case available(accountRecordName: String)
    case offline(code: String)
    case denied(code: String)
}

@MainActor
protocol CloudLedgerActivationTransport: AnyObject {
    func checkAccess(to sharedLedger: SharedLedgerState) async -> CloudLedgerAccessResult
}

enum CloudLedgerActivationError: Error, Equatable {
    case invalidState
    case notReady
    case offline(code: String)
    case accessDenied(code: String)
    case accountChanged
    case deferredTransactions(Int)
}

/// Dormant activation gate. No caller in the app constructs this coordinator.
/// A successful check is required before a prepared ledger can be made writable.
@MainActor
struct CloudLedgerActivationCoordinator {
    let modelContext: ModelContext
    let transport: any CloudLedgerActivationTransport

    func activate(now: Date = .now) async throws {
        let shared = try singleSharedLedger()
        guard shared.phase == .preparing else {
            throw CloudLedgerActivationError.invalidState
        }
        let migration = try singleMigration()
        let adoption = try singleAdoption()
        switch shared.role {
        case .owner:
            guard shared.databaseScope == .privateDatabase,
                  migration?.householdID == shared.householdID,
                  migration?.phase == .readyToActivate,
                  adoption == nil else {
                throw CloudLedgerActivationError.notReady
            }
        case .participant:
            guard shared.databaseScope == .sharedDatabase,
                  adoption?.householdID == shared.householdID,
                  adoption?.zoneID == shared.zoneID,
                  adoption?.phase == .readyToActivate,
                  migration == nil else {
                throw CloudLedgerActivationError.notReady
            }
            let deferredCount = try modelContext.fetch(
                FetchDescriptor<DeferredCloudTransaction>()
            ).count
            guard deferredCount == 0 else {
                throw CloudLedgerActivationError.deferredTransactions(deferredCount)
            }
        case nil:
            throw CloudLedgerActivationError.invalidState
        }

        let accountName = try await requireAccess(to: shared)
        shared.accountRecordName = accountName
        if shared.role == .owner {
            // Owner phase and ledger activation are saved together by this method.
            migration?.phaseRawValue = CloudLedgerMigrationPhase.completed.rawValue
            migration?.activatedAt = now
            migration?.lastErrorCode = nil
        } else {
            adoption?.phaseRawValue = CloudLedgerParticipantAdoptionPhase.completed.rawValue
            adoption?.lastErrorCode = nil
        }
        shared.phaseRawValue = SharedLedgerPhase.active.rawValue
        try modelContext.save()
    }

    /// Call before starting a sync session and after account/share change events.
    /// Temporary outages leave the ledger writable and its queue intact.
    @discardableResult
    func checkActiveAccess(now: Date = .now) async throws -> CloudLedgerAccessResult {
        let shared = try singleSharedLedger()
        guard shared.phase == .active, shared.accountRecordName != nil else {
            throw CloudLedgerActivationError.invalidState
        }
        let result = await transport.checkAccess(to: shared)
        switch result {
        case .available(let accountName):
            guard accountName == shared.accountRecordName else {
                try markAttention(shared, code: "icloud-account-changed", now: now)
                throw CloudLedgerActivationError.accountChanged
            }
        case .offline(let code):
            let sync = try syncState(for: shared)
            sync.statusRawValue = CloudLedgerSyncStatus.offline.rawValue
            sync.lastAttemptAt = now
            sync.lastErrorCode = code
            try modelContext.save()
        case .denied(let code):
            try markAttention(shared, code: code, now: now)
        }
        return result
    }

    private func requireAccess(to shared: SharedLedgerState) async throws -> String {
        switch await transport.checkAccess(to: shared) {
        case .available(let accountName) where !accountName.isEmpty:
            return accountName
        case .available:
            throw CloudLedgerActivationError.invalidState
        case .offline(let code):
            throw CloudLedgerActivationError.offline(code: code)
        case .denied(let code):
            throw CloudLedgerActivationError.accessDenied(code: code)
        }
    }

    private func markAttention(
        _ shared: SharedLedgerState,
        code: String,
        now: Date
    ) throws {
        shared.phaseRawValue = SharedLedgerPhase.attentionRequired.rawValue
        let sync = try syncState(for: shared)
        sync.statusRawValue = CloudLedgerSyncStatus.attentionRequired.rawValue
        sync.lastAttemptAt = now
        sync.lastErrorCode = code
        try modelContext.save()
    }

    private func syncState(for shared: SharedLedgerState) throws -> CloudLedgerSyncState {
        guard let scope = shared.databaseScope else {
            throw CloudLedgerActivationError.invalidState
        }
        let states = try modelContext.fetch(FetchDescriptor<CloudLedgerSyncState>())
            .filter { $0.householdID == shared.householdID }
        if let existing = states.first { return existing }
        let state = CloudLedgerSyncState(
            householdID: shared.householdID,
            databaseScope: scope
        )
        modelContext.insert(state)
        return state
    }

    private func singleSharedLedger() throws -> SharedLedgerState {
        let states = try modelContext.fetch(FetchDescriptor<SharedLedgerState>())
        guard states.count == 1, let state = states.first else {
            throw CloudLedgerActivationError.invalidState
        }
        return state
    }

    private func singleMigration() throws -> CloudLedgerMigrationState? {
        let states = try modelContext.fetch(FetchDescriptor<CloudLedgerMigrationState>())
        guard states.count <= 1 else { throw CloudLedgerActivationError.invalidState }
        return states.first
    }

    private func singleAdoption() throws -> CloudLedgerParticipantAdoptionState? {
        let states = try modelContext.fetch(FetchDescriptor<CloudLedgerParticipantAdoptionState>())
        guard states.count <= 1 else { throw CloudLedgerActivationError.invalidState }
        return states.first
    }
}

/// Intentionally unused by app startup until full live-sync recovery is tested.
@MainActor
final class CloudLedgerLiveActivationTransport: CloudLedgerActivationTransport {
    private let container: CKContainer

    init(container: CKContainer = CKContainer(
        identifier: FamilySharingProbe.containerIdentifier
    )) {
        self.container = container
    }

    func checkAccess(to sharedLedger: SharedLedgerState) async -> CloudLedgerAccessResult {
        do {
            let status = try await container.accountStatus()
            switch status {
            case .available:
                break
            case .noAccount, .restricted:
                return .denied(code: "icloud-account-unavailable")
            case .couldNotDetermine, .temporarilyUnavailable:
                return .offline(code: "icloud-status-unavailable")
            @unknown default:
                return .offline(code: "icloud-status-unknown")
            }
            let accountName = try await container.userRecordID().recordName
            let database: CKDatabase
            switch sharedLedger.databaseScope {
            case .privateDatabase:
                database = container.privateCloudDatabase
            case .sharedDatabase:
                database = container.sharedCloudDatabase
            case nil:
                return .denied(code: "invalid-database-scope")
            }
            let shareID = CKRecord.ID(
                recordName: CKRecordNameZoneWideShare,
                zoneID: sharedLedger.zoneID
            )
            guard let share = try await database.record(for: shareID) as? CKShare else {
                return .denied(code: "share-record-missing")
            }
            if sharedLedger.role == .participant,
               share.currentUserParticipant?.permission != .readWrite {
                return .denied(code: "share-write-access-lost")
            }
            return .available(accountRecordName: accountName)
        } catch let error as CKError {
            switch error.code {
            case .unknownItem, .permissionFailure, .notAuthenticated, .userDeletedZone:
                return .denied(code: "cloudkit-\(error.code.rawValue)")
            default:
                return .offline(code: "cloudkit-\(error.code.rawValue)")
            }
        } catch {
            return .offline(code: "access-check-failed")
        }
    }
}
