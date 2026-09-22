import CloudKit
import Observation
import OSLog
import SwiftUI
import UIKit

enum FamilySharingProbeError: LocalizedError {
    case incompleteOwnerSetupReset
    case iCloudUnavailable(CKAccountStatus)
    case invalidSavedState
    case missingCloudResult
    case unexpectedRecordType
    case wrongContainer

    var errorDescription: String? {
        switch self {
        case .incompleteOwnerSetupReset:
            "The earlier connection test did not finish, so Kid Money reset only the test connection. Tap Create Connection Test to try again."
        case .iCloudUnavailable(let status):
            switch status {
            case .noAccount:
                "Sign in to an iCloud account before testing family sharing."
            case .restricted:
                "This device restricts access to iCloud."
            case .couldNotDetermine:
                "Kid Money couldn't determine this device's iCloud status."
            case .temporarilyUnavailable:
                "iCloud is temporarily unavailable. Try again later."
            case .available:
                "iCloud is available."
            @unknown default:
                "This device can't access iCloud right now."
            }
        case .invalidSavedState:
            "The saved family-sharing test state is incomplete."
        case .missingCloudResult:
            "CloudKit didn't return the expected saved record."
        case .unexpectedRecordType:
            "CloudKit returned an unexpected record type."
        case .wrongContainer:
            "That invitation belongs to a different iCloud container."
        }
    }
}

@MainActor
@Observable
final class FamilySharingProbe {
    static let shared = FamilySharingProbe()
    static let containerIdentifier = "iCloud.io.github.ejones23.KidMoney"

    enum Role: String {
        case owner
        case participant

        var displayName: String {
            switch self {
            case .owner: "Owner"
            case .participant: "Participant"
            }
        }
    }

    private enum DefaultsKey {
        static let role = "FamilySharingProbe.role"
        static let zoneName = "FamilySharingProbe.zoneName"
        static let zoneOwnerName = "FamilySharingProbe.zoneOwnerName"
    }

    private static let recordName = "connection-test"
    private static let logger = Logger(
        subsystem: "io.github.ejones23.KidMoney",
        category: "FamilySharingProbe"
    )

    private let container = CKContainer(identifier: containerIdentifier)
    private let defaults: UserDefaults

    var accountDescription = "Checking iCloud…"
    var role: Role?
    var counter: Int64?
    var lastUpdatedAt: Date?
    var isWorking = false
    var errorMessage: String?
    var preparedShare: CKShare?

    private var zoneName: String?
    private var zoneOwnerName: String?

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        role = defaults.string(forKey: DefaultsKey.role).flatMap(Role.init(rawValue:))
        zoneName = defaults.string(forKey: DefaultsKey.zoneName)
        zoneOwnerName = defaults.string(forKey: DefaultsKey.zoneOwnerName)
    }

    var hasConnection: Bool {
        role != nil && zoneName != nil && zoneOwnerName != nil
    }

    var connectionDescription: String {
        guard let role else { return "Not configured" }
        return "Connected as \(role.displayName)"
    }

    func refresh() async {
        await perform {
            let status = try await self.accountStatus()
            self.accountDescription = Self.description(for: status)
            guard status == .available else {
                throw FamilySharingProbeError.iCloudUnavailable(status)
            }
            if self.hasConnection {
                do {
                    try await self.fetchProbeRecord()
                } catch {
                    if try await self.recoverIncompleteOwnerSetupIfNeeded(after: error) {
                        throw FamilySharingProbeError.incompleteOwnerSetupReset
                    }
                    throw error
                }
            }
        }
    }

    func prepareOwnerShare() async {
        await perform {
            let status = try await self.accountStatus()
            self.accountDescription = Self.description(for: status)
            guard status == .available else {
                throw FamilySharingProbeError.iCloudUnavailable(status)
            }

            if self.role == .participant {
                throw FamilySharingProbeError.invalidSavedState
            }

            let zoneID = self.ownerZoneIDForPreparation()
            let database = self.container.privateCloudDatabase
            try await self.saveZoneIfNeeded(zoneID, in: database)

            if let existingShare = try await self.fetchShare(in: database, zoneID: zoneID) {
                self.persist(role: .owner, zoneID: zoneID)
                self.preparedShare = existingShare
                try await self.fetchProbeRecord()
                return
            }

            let probeID = CKRecord.ID(recordName: Self.recordName, zoneID: zoneID)
            let probe = CKRecord(recordType: "FamilySharingProbe", recordID: probeID)
            probe["counter"] = NSNumber(value: 0)
            probe["updatedAt"] = Date.now
            probe["updatedByRole"] = Role.owner.rawValue

            let share = CKShare(recordZoneID: zoneID)
            share.publicPermission = .none
            share[CKShare.SystemFieldKey.title] = "Kid Money Family Sharing Test"

            let results = try await database.modifyRecords(
                saving: [probe, share],
                deleting: [],
                savePolicy: .ifServerRecordUnchanged,
                atomically: true
            )
            _ = try Self.savedRecord(probe.recordID, from: results.saveResults)
            let savedShareRecord = try Self.savedRecord(share.recordID, from: results.saveResults)
            guard let savedShare = savedShareRecord as? CKShare else {
                throw FamilySharingProbeError.unexpectedRecordType
            }

            self.persist(role: .owner, zoneID: zoneID)
            self.preparedShare = savedShare
            self.counter = 0
            self.lastUpdatedAt = probe["updatedAt"] as? Date
            Self.logger.info("Created isolated family-sharing test zone")
        }
    }

    func incrementCounter() async {
        await perform {
            let database = try self.connectedDatabase()
            let recordID = try self.probeRecordID()
            let record = try await database.record(for: recordID)
            let current = (record["counter"] as? NSNumber)?.int64Value ?? 0
            record["counter"] = NSNumber(value: current + 1)
            record["updatedAt"] = Date.now
            record["updatedByRole"] = self.role?.rawValue ?? "unknown"

            let results = try await database.modifyRecords(
                saving: [record],
                deleting: [],
                savePolicy: .ifServerRecordUnchanged,
                atomically: true
            )
            let saved = try Self.savedRecord(recordID, from: results.saveResults)
            self.applyProbeRecord(saved)
            Self.logger.info("Saved family-sharing counter update")
        }
    }

    func showExistingShare() async {
        await perform {
            let database = try self.connectedDatabase()
            let zoneID = try self.savedZoneID()
            guard let share = try await self.fetchShare(in: database, zoneID: zoneID) else {
                throw FamilySharingProbeError.missingCloudResult
            }
            self.preparedShare = share
        }
    }

    func accept(_ metadata: CKShare.Metadata) async {
        await perform {
            guard metadata.containerIdentifier == Self.containerIdentifier else {
                throw FamilySharingProbeError.wrongContainer
            }
            let acceptedShare = try await self.container.accept(metadata)
            let zoneID = acceptedShare.recordID.zoneID
            self.persist(role: .participant, zoneID: zoneID)
            self.preparedShare = acceptedShare
            try await self.fetchProbeRecord()
            Self.logger.info("Accepted family-sharing test invitation")
        }
    }

    func clearPreparedShare() {
        preparedShare = nil
    }

    private func perform(_ operation: () async throws -> Void) async {
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }

        do {
            try await operation()
        } catch {
            errorMessage = error.localizedDescription
            Self.logger.error("Family-sharing test failed: \(error.localizedDescription, privacy: .private)")
        }
    }

    private func accountStatus() async throws -> CKAccountStatus {
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

    private func ownerZoneIDForPreparation() -> CKRecordZone.ID {
        if let zoneName, let zoneOwnerName {
            return CKRecordZone.ID(zoneName: zoneName, ownerName: zoneOwnerName)
        }

        return CKRecordZone.ID(
            zoneName: "KidMoneyProbe-\(UUID().uuidString)",
            ownerName: CKCurrentUserDefaultName
        )
    }

    private func recoverIncompleteOwnerSetupIfNeeded(after error: any Error) async throws -> Bool {
        guard role == .owner,
              let cloudKitError = error as? CKError,
              cloudKitError.code == .unknownItem
        else {
            return false
        }

        let zoneID = try savedZoneID()
        let database = container.privateCloudDatabase
        guard try await fetchShare(in: database, zoneID: zoneID) == nil else {
            return false
        }

        clearPersistedConnection()
        Self.logger.notice("Cleared incomplete family-sharing test setup")
        return true
    }

    private func saveZoneIfNeeded(_ zoneID: CKRecordZone.ID, in database: CKDatabase) async throws {
        let results = try await database.modifyRecordZones(
            saving: [CKRecordZone(zoneID: zoneID)],
            deleting: []
        )
        guard let result = results.saveResults[zoneID] else {
            throw FamilySharingProbeError.missingCloudResult
        }
        _ = try result.get()
    }

    private func fetchProbeRecord() async throws {
        let database = try connectedDatabase()
        let record = try await database.record(for: probeRecordID())
        applyProbeRecord(record)
    }

    private func applyProbeRecord(_ record: CKRecord) {
        counter = (record["counter"] as? NSNumber)?.int64Value
        lastUpdatedAt = record["updatedAt"] as? Date
    }

    private func fetchShare(in database: CKDatabase, zoneID: CKRecordZone.ID) async throws -> CKShare? {
        let shareID = CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: zoneID)
        do {
            let record = try await database.record(for: shareID)
            guard let share = record as? CKShare else {
                throw FamilySharingProbeError.unexpectedRecordType
            }
            return share
        } catch let error as CKError where error.code == .unknownItem {
            return nil
        }
    }

    private func connectedDatabase() throws -> CKDatabase {
        switch role {
        case .owner:
            container.privateCloudDatabase
        case .participant:
            container.sharedCloudDatabase
        case nil:
            throw FamilySharingProbeError.invalidSavedState
        }
    }

    private func probeRecordID() throws -> CKRecord.ID {
        CKRecord.ID(recordName: Self.recordName, zoneID: try savedZoneID())
    }

    private func savedZoneID() throws -> CKRecordZone.ID {
        guard let zoneName, let zoneOwnerName else {
            throw FamilySharingProbeError.invalidSavedState
        }
        return CKRecordZone.ID(zoneName: zoneName, ownerName: zoneOwnerName)
    }

    private func persist(role: Role, zoneID: CKRecordZone.ID) {
        self.role = role
        zoneName = zoneID.zoneName
        zoneOwnerName = zoneID.ownerName
        defaults.set(role.rawValue, forKey: DefaultsKey.role)
        defaults.set(zoneID.zoneName, forKey: DefaultsKey.zoneName)
        defaults.set(zoneID.ownerName, forKey: DefaultsKey.zoneOwnerName)
    }

    private func clearPersistedConnection() {
        role = nil
        zoneName = nil
        zoneOwnerName = nil
        counter = nil
        lastUpdatedAt = nil
        preparedShare = nil
        defaults.removeObject(forKey: DefaultsKey.role)
        defaults.removeObject(forKey: DefaultsKey.zoneName)
        defaults.removeObject(forKey: DefaultsKey.zoneOwnerName)
    }

    private static func savedRecord(
        _ recordID: CKRecord.ID,
        from results: [CKRecord.ID: Result<CKRecord, any Error>]
    ) throws -> CKRecord {
        guard let result = results[recordID] else {
            throw FamilySharingProbeError.missingCloudResult
        }
        return try result.get()
    }

    private static func description(for status: CKAccountStatus) -> String {
        switch status {
        case .available: "iCloud is available"
        case .noAccount: "No iCloud account"
        case .restricted: "iCloud access is restricted"
        case .couldNotDetermine: "iCloud status is unknown"
        case .temporarilyUnavailable: "iCloud is temporarily unavailable"
        @unknown default: "Unknown iCloud status"
        }
    }
}

struct FamilySharingProbeView: View {
    @State private var probe = FamilySharingProbe.shared
    @State private var isShowingShare = false

    var body: some View {
        List {
            Section("Purpose") {
                Text("This isolated connection test shares only a counter. It does not upload child names, balances, or transactions.")
            }

            Section("iCloud") {
                LabeledContent("Account", value: probe.accountDescription)
                LabeledContent("Connection", value: probe.connectionDescription)
            }

            if probe.hasConnection {
                Section("Two-way Test") {
                    LabeledContent("Shared counter", value: probe.counter.map(String.init) ?? "Not loaded")
                    if let lastUpdatedAt = probe.lastUpdatedAt {
                        LabeledContent(
                            "Last updated",
                            value: lastUpdatedAt.formatted(date: .abbreviated, time: .shortened)
                        )
                    }

                    Button("Increment Shared Counter", systemImage: "plus.circle") {
                        Task { await probe.incrementCounter() }
                    }
                    Button("Refresh from iCloud", systemImage: "arrow.clockwise") {
                        Task { await probe.refresh() }
                    }
                    Button("Manage Test Participants", systemImage: "person.2") {
                        Task {
                            await probe.showExistingShare()
                            isShowingShare = probe.preparedShare != nil
                        }
                    }
                }
            } else {
                Section("Owner Setup") {
                    Button("Create Connection Test", systemImage: "person.2.badge.plus") {
                        Task {
                            await probe.prepareOwnerShare()
                            isShowingShare = probe.preparedShare != nil
                        }
                    }
                    Text("Create this on one phone, then invite the other parent with read-write access.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Family Sharing Test")
        .overlay {
            if probe.isWorking {
                ProgressView("Contacting iCloud…")
                    .padding()
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .task { await probe.refresh() }
        .sheet(isPresented: $isShowingShare, onDismiss: probe.clearPreparedShare) {
            if let share = probe.preparedShare {
                CloudSharingControllerView(share: share)
            }
        }
        .alert("Family Sharing Test", isPresented: Binding(
            get: { probe.errorMessage != nil },
            set: { if !$0 { probe.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(probe.errorMessage ?? "")
        }
    }
}

private struct CloudSharingControllerView: UIViewControllerRepresentable {
    let share: CKShare

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIViewController(context: Context) -> UICloudSharingController {
        let controller = UICloudSharingController(
            share: share,
            container: CKContainer(identifier: FamilySharingProbe.containerIdentifier)
        )
        controller.availablePermissions = [.allowPrivate, .allowReadWrite]
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: UICloudSharingController, context: Context) {}

    final class Coordinator: NSObject, UICloudSharingControllerDelegate {
        func itemTitle(for csc: UICloudSharingController) -> String? {
            "Kid Money Family Sharing Test"
        }

        func cloudSharingController(
            _ csc: UICloudSharingController,
            failedToSaveShareWithError error: any Error
        ) {
            Task { @MainActor in
                FamilySharingProbe.shared.errorMessage = error.localizedDescription
            }
        }
    }
}

final class KidMoneyAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(
            name: nil,
            sessionRole: connectingSceneSession.role
        )
        configuration.delegateClass = KidMoneySceneDelegate.self
        return configuration
    }
}

final class KidMoneySceneDelegate: NSObject, UIWindowSceneDelegate {
    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        if let metadata = connectionOptions.cloudKitShareMetadata {
            accept(metadata)
        }
    }

    func windowScene(
        _ windowScene: UIWindowScene,
        userDidAcceptCloudKitShareWith cloudKitShareMetadata: CKShare.Metadata
    ) {
        accept(cloudKitShareMetadata)
    }

    private func accept(_ metadata: CKShare.Metadata) {
        Task { @MainActor in
            await FamilySharingProbe.shared.accept(metadata)
        }
    }
}
