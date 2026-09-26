import CloudKit
import Foundation
import SwiftData

enum CloudLedgerMigrationPhase: String, Codable {
    case awaitingZoneCreation
    case uploadingInitialLedger
    case awaitingShareCreation
    case readyToActivate
    case completed
    case attentionRequired
}

@Model
final class CloudLedgerMigrationState {
    @Attribute(.unique) var householdID: UUID
    var phaseRawValue: String
    var expectedRecordCount: Int
    var stagedAt: Date
    var lastAttemptAt: Date?
    var attemptCount: Int
    var lastErrorCode: String?
    var zoneCreatedAt: Date?
    var initialUploadCompletedAt: Date?
    var shareCreatedAt: Date?
    var activatedAt: Date?

    init(
        householdID: UUID,
        phase: CloudLedgerMigrationPhase = .awaitingZoneCreation,
        expectedRecordCount: Int = 0,
        stagedAt: Date = .now
    ) {
        self.householdID = householdID
        self.phaseRawValue = phase.rawValue
        self.expectedRecordCount = expectedRecordCount
        self.stagedAt = stagedAt
        self.attemptCount = 0
    }

    var phase: CloudLedgerMigrationPhase? {
        CloudLedgerMigrationPhase(rawValue: phaseRawValue)
    }
}

enum CloudLedgerMigrationError: Error, Equatable {
    case migrationAlreadyExists
    case missingMigration
    case missingSharedLedger
    case invalidMigrationState
    case invalidPhase(expected: CloudLedgerMigrationPhase, actual: CloudLedgerMigrationPhase?)
    case pendingInitialRecords(Int)
    case localLedgerNotEmpty(children: Int, transactions: Int)
    case orphanedTransaction(UUID)
    case duplicateRecordName(String)
    case remoteCleanupRequired
    case cleanupNotAllowed
}

struct CloudLedgerMigrationSummary: Equatable {
    let householdID: UUID
    let phase: CloudLedgerMigrationPhase
    let expectedRecordCount: Int
    let pendingRecordCount: Int
}

/// Durably stages an existing local ledger for private CloudKit sharing.
///
/// This coordinator performs no CloudKit work. Network-facing code advances the
/// persisted phases only after each corresponding remote operation succeeds.
/// The local `Child` and `LedgerTransaction` objects are never rewritten or
/// deleted by migration setup or cancellation.
@MainActor
struct CloudLedgerMigrationCoordinator {
    let modelContext: ModelContext

    @discardableResult
    func beginOwnerMigration(
        displayName: String,
        householdID: UUID = UUID(),
        now: Date = .now
    ) throws -> CloudLedgerMigrationSummary {
        guard try modelContext.fetch(FetchDescriptor<SharedLedgerState>()).isEmpty,
              try modelContext.fetch(FetchDescriptor<CloudLedgerMigrationState>()).isEmpty else {
            throw CloudLedgerMigrationError.migrationAlreadyExists
        }

        let manifest = try initialManifest(householdID: householdID)
        let sharedLedger = SharedLedgerState(
            householdID: householdID,
            displayName: displayName,
            zoneName: "KidMoneyHousehold-\(householdID.uuidString)",
            zoneOwnerName: CKCurrentUserDefaultName,
            role: .owner,
            databaseScope: .privateDatabase,
            phase: .preparing,
            createdAt: now
        )
        let migration = CloudLedgerMigrationState(
            householdID: householdID,
            expectedRecordCount: manifest.count,
            stagedAt: now
        )
        modelContext.insert(sharedLedger)
        modelContext.insert(migration)
        try insertMissingChanges(from: manifest, householdID: householdID, now: now)
        try modelContext.save()
        return try summary(for: migration)
    }

    /// Reopens an interrupted migration and repairs its durable initial queue.
    /// Re-queueing an already uploaded deterministic record is intentional and
    /// safe; saved CloudKit system fields or conflict handling make it an update.
    @discardableResult
    func resumeOwnerMigration(now: Date = .now) throws -> CloudLedgerMigrationSummary {
        let migration = try requireMigration()
        switch migration.phase {
        case .awaitingZoneCreation, .uploadingInitialLedger:
            let manifest = try initialManifest(householdID: migration.householdID)
            try insertMissingChanges(
                from: manifest,
                householdID: migration.householdID,
                now: now
            )
            migration.expectedRecordCount = manifest.count
            try modelContext.save()
        case .awaitingShareCreation, .readyToActivate, .completed, .attentionRequired:
            break
        case nil:
            throw CloudLedgerMigrationError.invalidMigrationState
        }
        return try summary(for: migration)
    }

    @discardableResult
    func recordZoneCreated(now: Date = .now) throws -> CloudLedgerMigrationSummary {
        let migration = try requireMigration()
        switch migration.phase {
        case .awaitingZoneCreation:
            migration.phaseRawValue = CloudLedgerMigrationPhase.uploadingInitialLedger.rawValue
            migration.zoneCreatedAt = now
            migration.lastErrorCode = nil
            try modelContext.save()
        case .uploadingInitialLedger, .awaitingShareCreation, .readyToActivate, .completed:
            break
        case .attentionRequired, nil:
            throw CloudLedgerMigrationError.invalidPhase(
                expected: .awaitingZoneCreation,
                actual: migration.phase
            )
        }
        return try summary(for: migration)
    }

    @discardableResult
    func recordInitialUploadCompleted(now: Date = .now) throws -> CloudLedgerMigrationSummary {
        let migration = try requireMigration()
        switch migration.phase {
        case .uploadingInitialLedger:
            let pendingCount = try pendingChanges(householdID: migration.householdID).count
            guard pendingCount == 0 else {
                throw CloudLedgerMigrationError.pendingInitialRecords(pendingCount)
            }
            migration.phaseRawValue = CloudLedgerMigrationPhase.awaitingShareCreation.rawValue
            migration.initialUploadCompletedAt = now
            migration.lastErrorCode = nil
            try modelContext.save()
        case .awaitingShareCreation, .readyToActivate, .completed:
            break
        case .awaitingZoneCreation, .attentionRequired, nil:
            throw CloudLedgerMigrationError.invalidPhase(
                expected: .uploadingInitialLedger,
                actual: migration.phase
            )
        }
        return try summary(for: migration)
    }

    @discardableResult
    func recordShareCreated(now: Date = .now) throws -> CloudLedgerMigrationSummary {
        let migration = try requireMigration()
        switch migration.phase {
        case .awaitingShareCreation:
            migration.phaseRawValue = CloudLedgerMigrationPhase.readyToActivate.rawValue
            migration.shareCreatedAt = now
            migration.lastErrorCode = nil
            try modelContext.save()
        case .readyToActivate, .completed:
            break
        case .awaitingZoneCreation, .uploadingInitialLedger, .attentionRequired, nil:
            throw CloudLedgerMigrationError.invalidPhase(
                expected: .awaitingShareCreation,
                actual: migration.phase
            )
        }
        return try summary(for: migration)
    }

    @discardableResult
    func recordRecoverableFailure(
        code: String,
        now: Date = .now
    ) throws -> CloudLedgerMigrationSummary {
        let migration = try requireMigration()
        guard migration.phase != .completed, migration.phase != .attentionRequired,
              migration.phase != nil else {
            throw CloudLedgerMigrationError.invalidMigrationState
        }
        migration.attemptCount += 1
        migration.lastAttemptAt = now
        migration.lastErrorCode = code
        try modelContext.save()
        return try summary(for: migration)
    }

    @discardableResult
    func retryCurrentStep(now: Date = .now) throws -> CloudLedgerMigrationSummary {
        let migration = try requireMigration()
        guard migration.phase != .completed, migration.phase != .attentionRequired,
              migration.phase != nil else {
            throw CloudLedgerMigrationError.invalidMigrationState
        }
        migration.lastAttemptAt = now
        migration.lastErrorCode = nil
        try modelContext.save()
        return try resumeOwnerMigration(now: now)
    }

    @discardableResult
    func recordTerminalFailure(
        code: String,
        now: Date = .now
    ) throws -> CloudLedgerMigrationSummary {
        let migration = try requireMigration()
        guard migration.phase != .completed, migration.phase != nil else {
            throw CloudLedgerMigrationError.invalidMigrationState
        }
        let sharedLedger = try requireSharedLedger(householdID: migration.householdID)
        migration.phaseRawValue = CloudLedgerMigrationPhase.attentionRequired.rawValue
        migration.attemptCount += 1
        migration.lastAttemptAt = now
        migration.lastErrorCode = code
        sharedLedger.phaseRawValue = SharedLedgerPhase.attentionRequired.rawValue
        try modelContext.save()
        return try summary(for: migration)
    }

    /// Cancels only while no remote resources can exist. Ledger rows are kept.
    func cancelBeforeRemoteChanges() throws {
        let migration = try requireMigration()
        guard migration.phase == .awaitingZoneCreation else {
            throw CloudLedgerMigrationError.remoteCleanupRequired
        }
        let sharedLedger = try requireSharedLedger(householdID: migration.householdID)
        for change in try pendingChanges(householdID: migration.householdID) {
            modelContext.delete(change)
        }
        modelContext.delete(migration)
        modelContext.delete(sharedLedger)
        try modelContext.save()
    }

    /// Removes only synchronization setup after a caller has confirmed that
    /// the remote zone no longer exists. The local ledger remains untouched.
    func cancelAfterConfirmedRemoteCleanup() throws {
        let migration = try requireMigration()
        guard migration.phase != .completed else {
            throw CloudLedgerMigrationError.cleanupNotAllowed
        }
        let sharedLedger = try requireSharedLedger(householdID: migration.householdID)
        guard sharedLedger.phase != .active else {
            throw CloudLedgerMigrationError.cleanupNotAllowed
        }

        let householdID = migration.householdID
        for change in try pendingChanges(householdID: householdID) {
            modelContext.delete(change)
        }
        for deferred in try modelContext.fetch(FetchDescriptor<DeferredCloudTransaction>())
            where deferred.householdID == householdID {
            modelContext.delete(deferred)
        }
        for state in try modelContext.fetch(FetchDescriptor<CloudLedgerSyncState>())
            where state.householdID == householdID {
            modelContext.delete(state)
        }
        for metadata in try modelContext.fetch(FetchDescriptor<CloudLedgerRecordMetadata>())
            where metadata.householdID == householdID {
            modelContext.delete(metadata)
        }
        modelContext.delete(migration)
        modelContext.delete(sharedLedger)
        try modelContext.save()
    }

    /// Invitations must never silently merge a second independent local ledger.
    func validateEmptyLocalLedgerForParticipantAdoption() throws {
        let childCount = try modelContext.fetch(FetchDescriptor<Child>()).count
        let transactionCount = try modelContext.fetch(
            FetchDescriptor<LedgerTransaction>()
        ).count
        guard childCount == 0, transactionCount == 0 else {
            throw CloudLedgerMigrationError.localLedgerNotEmpty(
                children: childCount,
                transactions: transactionCount
            )
        }
    }

    private struct ManifestItem {
        let recordType: CloudLedgerRecordType
        let recordName: String
    }

    private func initialManifest(householdID: UUID) throws -> [ManifestItem] {
        let children = try modelContext.fetch(FetchDescriptor<Child>()).sorted {
            $0.id.uuidString < $1.id.uuidString
        }
        let transactions = try modelContext.fetch(
            FetchDescriptor<LedgerTransaction>()
        ).sorted { lhs, rhs in
            let lhsName = CloudLedgerRecordName.transaction(
                id: lhs.id,
                reversesTransactionID: lhs.reversesTransactionID
            )
            let rhsName = CloudLedgerRecordName.transaction(
                id: rhs.id,
                reversesTransactionID: rhs.reversesTransactionID
            )
            return lhsName < rhsName
        }

        for transaction in transactions where transaction.child == nil {
            throw CloudLedgerMigrationError.orphanedTransaction(transaction.id)
        }

        var manifest = [ManifestItem(
            recordType: .household,
            recordName: CloudLedgerRecordName.household(householdID)
        )]
        manifest.append(contentsOf: children.map {
            ManifestItem(recordType: .child, recordName: CloudLedgerRecordName.child($0.id))
        })
        manifest.append(contentsOf: transactions.map {
            ManifestItem(
                recordType: .ledgerTransaction,
                recordName: CloudLedgerRecordName.transaction(
                    id: $0.id,
                    reversesTransactionID: $0.reversesTransactionID
                )
            )
        })

        var seen = Set<String>()
        for item in manifest where !seen.insert(item.recordName).inserted {
            throw CloudLedgerMigrationError.duplicateRecordName(item.recordName)
        }
        return manifest
    }

    private func insertMissingChanges(
        from manifest: [ManifestItem],
        householdID: UUID,
        now: Date
    ) throws {
        let existingKeys = Set(try pendingChanges(householdID: householdID).map(\.deduplicationKey))
        for (index, item) in manifest.enumerated() {
            let key = PendingCloudChange.makeDeduplicationKey(
                householdID: householdID,
                operation: .save,
                recordName: item.recordName
            )
            guard !existingKeys.contains(key) else { continue }
            modelContext.insert(PendingCloudChange(
                householdID: householdID,
                operation: .save,
                recordType: item.recordType,
                recordName: item.recordName,
                enqueuedAt: now.addingTimeInterval(Double(index) / 1_000_000)
            ))
        }
    }

    private func requireMigration() throws -> CloudLedgerMigrationState {
        let migrations = try modelContext.fetch(FetchDescriptor<CloudLedgerMigrationState>())
        guard let migration = migrations.first else {
            throw CloudLedgerMigrationError.missingMigration
        }
        guard migrations.count == 1 else {
            throw CloudLedgerMigrationError.invalidMigrationState
        }
        return migration
    }

    private func requireSharedLedger(householdID: UUID) throws -> SharedLedgerState {
        guard let sharedLedger = try modelContext.fetch(
            FetchDescriptor<SharedLedgerState>()
        ).first(where: { $0.householdID == householdID }) else {
            throw CloudLedgerMigrationError.missingSharedLedger
        }
        return sharedLedger
    }

    private func pendingChanges(householdID: UUID) throws -> [PendingCloudChange] {
        try modelContext.fetch(FetchDescriptor<PendingCloudChange>()).filter {
            $0.householdID == householdID
        }
    }

    private func summary(
        for migration: CloudLedgerMigrationState
    ) throws -> CloudLedgerMigrationSummary {
        guard let phase = migration.phase else {
            throw CloudLedgerMigrationError.invalidMigrationState
        }
        return CloudLedgerMigrationSummary(
            householdID: migration.householdID,
            phase: phase,
            expectedRecordCount: migration.expectedRecordCount,
            pendingRecordCount: try pendingChanges(householdID: migration.householdID).count
        )
    }
}
