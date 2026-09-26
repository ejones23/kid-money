import CloudKit
import Foundation
import SwiftData

enum CloudLedgerParticipantAdoptionPhase: String, Codable {
    case awaitingAcceptance
    case awaitingInitialFetch
    case readyToActivate
    case completed
    case attentionRequired
}

@Model
final class CloudLedgerParticipantAdoptionState {
    @Attribute(.unique) var shareKey: String
    var containerIdentifier: String
    var shareRecordName: String
    var zoneName: String
    var zoneOwnerName: String
    var metadataArchive: Data?
    var phaseRawValue: String
    var householdID: UUID?
    var startedAt: Date
    var lastErrorCode: String?
    var attemptCount: Int

    init(invitation: CloudLedgerInvitation, startedAt: Date = .now) {
        self.shareKey = invitation.shareKey
        self.containerIdentifier = invitation.containerIdentifier
        self.shareRecordName = invitation.shareRecordName
        self.zoneName = invitation.zoneID.zoneName
        self.zoneOwnerName = invitation.zoneID.ownerName
        self.metadataArchive = invitation.metadataArchive
        self.phaseRawValue = CloudLedgerParticipantAdoptionPhase.awaitingAcceptance.rawValue
        self.startedAt = startedAt
        self.attemptCount = 0
    }

    var phase: CloudLedgerParticipantAdoptionPhase? {
        CloudLedgerParticipantAdoptionPhase(rawValue: phaseRawValue)
    }

    var zoneID: CKRecordZone.ID {
        CKRecordZone.ID(zoneName: zoneName, ownerName: zoneOwnerName)
    }
}

struct CloudLedgerInvitation {
    let containerIdentifier: String
    let shareRecordName: String
    let zoneID: CKRecordZone.ID
    let isZoneWide: Bool
    let isReadWrite: Bool
    let metadataArchive: Data?

    init(metadata: CKShare.Metadata) throws {
        self.containerIdentifier = metadata.containerIdentifier
        self.shareRecordName = metadata.share.recordID.recordName
        self.zoneID = metadata.share.recordID.zoneID
        self.isZoneWide = metadata.hierarchicalRootRecordID == nil
        self.isReadWrite = metadata.participantPermission == .readWrite
        self.metadataArchive = try NSKeyedArchiver.archivedData(
            withRootObject: metadata,
            requiringSecureCoding: true
        )
    }

    /// Tests use this initializer because CloudKit does not permit callers to
    /// construct CKShare.Metadata directly.
    init(
        containerIdentifier: String,
        zoneID: CKRecordZone.ID,
        shareRecordName: String = CKRecordNameZoneWideShare,
        isZoneWide: Bool = true,
        isReadWrite: Bool = true,
        metadataArchive: Data? = nil
    ) {
        self.containerIdentifier = containerIdentifier
        self.shareRecordName = shareRecordName
        self.zoneID = zoneID
        self.isZoneWide = isZoneWide
        self.isReadWrite = isReadWrite
        self.metadataArchive = metadataArchive
    }

    var shareKey: String {
        "\(zoneID.ownerName)|\(zoneID.zoneName)|\(shareRecordName)"
    }
}

enum CloudLedgerParticipantAdoptionError: Error, Equatable {
    case invalidInvitation
    case unrelatedLedgerPresent
    case differentInvitationInProgress
    case missingInvitation
    case invalidState
    case iCloudUnavailable
    case missingHousehold
    case duplicateHousehold
    case householdZoneMismatch
    case unexpectedZone
    case initialFetchIncomplete
}

@MainActor
protocol CloudLedgerParticipantTransport: AnyObject {
    func accountStatus() async throws -> CKAccountStatus
    func accept(_ adoption: CloudLedgerParticipantAdoptionState) async throws
    func initialRecords(in zoneID: CKRecordZone.ID) async throws -> [CKRecord]
}

/// Dormant participant setup. It persists the invitation before contacting
/// CloudKit, so a lost acceptance response can be recovered after relaunch.
@MainActor
struct CloudLedgerParticipantAdoptionCoordinator {
    let modelContext: ModelContext
    let transport: any CloudLedgerParticipantTransport

    @discardableResult
    func stage(
        _ invitation: CloudLedgerInvitation,
        now: Date = .now
    ) throws -> CloudLedgerParticipantAdoptionState {
        guard invitation.containerIdentifier == FamilySharingProbe.containerIdentifier,
              invitation.isZoneWide,
              invitation.isReadWrite,
              invitation.shareRecordName == CKRecordNameZoneWideShare,
              invitation.zoneID.ownerName != CKCurrentUserDefaultName,
              invitation.zoneID.zoneName.hasPrefix("KidMoneyHousehold-") else {
            throw CloudLedgerParticipantAdoptionError.invalidInvitation
        }
        if let existing = try modelContext.fetch(
            FetchDescriptor<CloudLedgerParticipantAdoptionState>()
        ).first {
            guard existing.shareKey == invitation.shareKey else {
                throw CloudLedgerParticipantAdoptionError.differentInvitationInProgress
            }
            return existing
        }
        guard try modelContext.fetch(FetchDescriptor<SharedLedgerState>()).isEmpty,
              try modelContext.fetch(FetchDescriptor<CloudLedgerMigrationState>()).isEmpty else {
            throw CloudLedgerParticipantAdoptionError.unrelatedLedgerPresent
        }
        try CloudLedgerMigrationCoordinator(modelContext: modelContext)
            .validateEmptyLocalLedgerForParticipantAdoption()
        let state = CloudLedgerParticipantAdoptionState(invitation: invitation, startedAt: now)
        modelContext.insert(state)
        try modelContext.save()
        return state
    }

    @discardableResult
    func resume() async throws -> CloudLedgerParticipantAdoptionState {
        let states = try modelContext.fetch(
            FetchDescriptor<CloudLedgerParticipantAdoptionState>()
        )
        guard let state = states.first else {
            throw CloudLedgerParticipantAdoptionError.missingInvitation
        }
        guard states.count == 1, let phase = state.phase,
              phase != .attentionRequired else {
            throw CloudLedgerParticipantAdoptionError.invalidState
        }
        if phase == .completed { return state }
        guard try await transport.accountStatus() == .available else {
            state.attemptCount += 1
            state.lastErrorCode = "icloud-unavailable"
            try modelContext.save()
            throw CloudLedgerParticipantAdoptionError.iCloudUnavailable
        }

        do {
            if state.phase == .awaitingAcceptance {
                try await transport.accept(state)
                state.phaseRawValue = CloudLedgerParticipantAdoptionPhase
                    .awaitingInitialFetch.rawValue
                try modelContext.save()
            }
            if state.phase == .awaitingInitialFetch {
                let records = try await transport.initialRecords(in: state.zoneID)
                try mergeInitialSnapshot(records, into: state)
            }
            guard state.phase == .readyToActivate else {
                throw CloudLedgerParticipantAdoptionError.initialFetchIncomplete
            }
            return state
        } catch {
            state.attemptCount += 1
            state.lastErrorCode = String(describing: error)
            try? modelContext.save()
            throw error
        }
    }

    private func mergeInitialSnapshot(
        _ records: [CKRecord],
        into adoption: CloudLedgerParticipantAdoptionState
    ) throws {
        guard records.allSatisfy({ $0.recordID.zoneID == adoption.zoneID }) else {
            throw CloudLedgerParticipantAdoptionError.unexpectedZone
        }
        let households = try records
            .filter { $0.recordType == CloudLedgerRecordType.household.rawValue }
            .map(CloudLedgerRecordDecoder.household)
        guard let household = households.first else {
            throw CloudLedgerParticipantAdoptionError.missingHousehold
        }
        guard households.count == 1 else {
            throw CloudLedgerParticipantAdoptionError.duplicateHousehold
        }
        guard adoption.zoneName == "KidMoneyHousehold-\(household.id.uuidString)",
              try modelContext.fetch(FetchDescriptor<SharedLedgerState>()).isEmpty else {
            throw CloudLedgerParticipantAdoptionError.householdZoneMismatch
        }

        let sharedLedger = SharedLedgerState(
            householdID: household.id,
            displayName: household.displayName,
            zoneName: adoption.zoneName,
            zoneOwnerName: adoption.zoneOwnerName,
            role: .participant,
            databaseScope: .sharedDatabase,
            phase: .preparing,
            schemaVersion: household.schemaVersion,
            createdAt: household.createdAt
        )
        modelContext.insert(sharedLedger)
        do {
            _ = try CloudLedgerMergeService(modelContext: modelContext).merge(
                records: records,
                into: sharedLedger,
                saveChanges: false
            )
            adoption.householdID = household.id
            adoption.phaseRawValue = CloudLedgerParticipantAdoptionPhase
                .readyToActivate.rawValue
            adoption.lastErrorCode = nil
            try modelContext.save()
        } catch {
            modelContext.rollback()
            adoption.householdID = nil
            adoption.phaseRawValue = CloudLedgerParticipantAdoptionPhase
                .awaitingInitialFetch.rawValue
            throw error
        }
    }
}

/// The live transport is not instantiated by the app. Initial fetches always
/// start at the beginning of exactly the invited zone; a retry can merge the
/// same deterministic records without duplicating transactions.
@MainActor
final class CloudLedgerLiveParticipantTransport: CloudLedgerParticipantTransport {
    private let container: CKContainer
    private let database: CKDatabase

    init(container: CKContainer = CKContainer(
        identifier: FamilySharingProbe.containerIdentifier
    )) {
        self.container = container
        self.database = container.sharedCloudDatabase
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

    func accept(_ adoption: CloudLedgerParticipantAdoptionState) async throws {
        let shareID = CKRecord.ID(
            recordName: adoption.shareRecordName,
            zoneID: adoption.zoneID
        )
        if let existing = try? await database.record(for: shareID),
           existing is CKShare {
            return
        }
        guard let data = adoption.metadataArchive,
              let metadata = try NSKeyedUnarchiver.unarchivedObject(
                ofClass: CKShare.Metadata.self,
                from: data
              ),
              metadata.containerIdentifier == adoption.containerIdentifier,
              metadata.share.recordID == shareID else {
            throw CloudLedgerParticipantAdoptionError.invalidInvitation
        }
        _ = try await container.accept(metadata)
    }

    func initialRecords(in zoneID: CKRecordZone.ID) async throws -> [CKRecord] {
        var token: CKServerChangeToken?
        var recordsByID: [CKRecord.ID: CKRecord] = [:]
        while true {
            let page = try await database.recordZoneChanges(
                inZoneWith: zoneID,
                since: token
            )
            for (id, result) in page.modificationResultsByID {
                recordsByID[id] = try result.get().record
            }
            for deletion in page.deletions {
                recordsByID.removeValue(forKey: deletion.recordID)
            }
            guard page.moreComing else { break }
            token = page.changeToken
        }
        return Array(recordsByID.values)
    }
}
