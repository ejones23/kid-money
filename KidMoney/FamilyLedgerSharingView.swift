import CloudKit
import SwiftData
import SwiftUI
import UIKit

private enum OwnerSharingPreflightError: Error {
    case unavailable(CKAccountStatus)
}

@MainActor
struct FamilyLedgerSharingView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var children: [Child]
    @Query private var transactions: [LedgerTransaction]
    @Query private var sharedLedgers: [SharedLedgerState]
    @Query private var migrations: [CloudLedgerMigrationState]
    @Query private var adoptions: [CloudLedgerParticipantAdoptionState]
    @Query private var syncStates: [CloudLedgerSyncState]
    @Query private var pendingChanges: [PendingCloudChange]

    @State private var isShowingConsent = false
    @State private var isShowingShare = false
    @State private var presentedShare: CKShare?
    @State private var isWorking = false
    @State private var errorMessage: String?

    private var sharedLedger: SharedLedgerState? { sharedLedgers.first }
    private var migration: CloudLedgerMigrationState? { migrations.first }
    private var adoption: CloudLedgerParticipantAdoptionState? { adoptions.first }
    private var syncState: CloudLedgerSyncState? { syncStates.first }

    var body: some View {
        List {
            if let sharedLedger {
                currentHousehold(sharedLedger)
            } else if let adoption {
                invitationSection(adoption)
            } else {
                ownerOptInSection
            }

            Section("Connection Test") {
                NavigationLink("Open Counter-Only Test") {
                    FamilySharingProbeView()
                }
                Text("This older test shares only a disposable counter, not your family ledger.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Sharing")
        .overlay {
            if isWorking {
                ProgressView("Contacting iCloud…")
                    .padding()
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .sheet(isPresented: $isShowingConsent) {
            OwnerSharingConsentView(
                childNames: children.map(\.name).sorted(),
                transactionCount: transactions.count,
                onConfirm: {
                    isShowingConsent = false
                    Task { await perform(startOwnerSharing) }
                }
            )
        }
        .sheet(isPresented: $isShowingShare, onDismiss: { presentedShare = nil }) {
            if let presentedShare {
                FamilyLedgerCloudSharingController(share: presentedShare)
            }
        }
        .alert("Family Sharing", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var ownerOptInSection: some View {
        Section("Private Family Ledger") {
            Text("Your children and transactions are on this phone only. Sharing is optional.")
            LabeledContent("Children", value: "\(children.count)")
            LabeledContent("Transactions", value: "\(transactions.count)")
            Button("Share Family Ledger", systemImage: "person.2.badge.plus") {
                isShowingConsent = true
            }
            .disabled(isWorking)
        }
    }

    @ViewBuilder
    private func currentHousehold(_ ledger: SharedLedgerState) -> some View {
        Section("Family Ledger") {
            LabeledContent("Role", value: ledger.role == .owner ? "Owner" : "Participant")
            LabeledContent("Status", value: statusDescription(for: ledger))
            if let syncState, ledger.phase == .active {
                LabeledContent("Sync", value: syncDescription(syncState.status))
            }
            if ledger.phase == .attentionRequired {
                Text("Sharing needs attention. Your local history and pending changes are preserved. Kid Money will not start a new share or switch iCloud accounts automatically.")
                    .foregroundStyle(.secondary)
            }
        }

        if ledger.phase == .preparing, ledger.role == .owner {
            Section("Owner Setup") {
                LabeledContent("Step", value: migrationDescription(migration?.phase))
                Button("Resume Sharing Setup", systemImage: "arrow.clockwise") {
                    Task { await perform(resumeOwnerSharing) }
                }
                Button("Cancel Sharing Setup", role: .destructive) {
                    Task { await perform(cancelOwnerSharing) }
                }
                Text("Cancellation keeps every child and transaction. After iCloud work begins, Kid Money must confirm that the setup zone was removed.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .disabled(isWorking)
        }

        if ledger.phase == .preparing, ledger.role == .participant,
           let adoption {
            invitationSection(adoption)
        }

        if ledger.phase == .active {
            Section("Actions") {
                LabeledContent("Changes waiting to sync", value: "\(pendingChanges.count)")
                Button("Sync Now", systemImage: "arrow.triangle.2.circlepath") {
                    Task { await perform(syncNow) }
                }
                if ledger.role == .owner {
                    Button("Invite or Manage Participants", systemImage: "person.2") {
                        Task { await perform(showOwnerShare) }
                    }
                }
            }
            .disabled(isWorking)
        }
    }

    private func invitationSection(
        _ invitation: CloudLedgerParticipantAdoptionState
    ) -> some View {
        Section("Family Invitation") {
            Text("Another parent invited this iCloud account to a private, read-write family ledger. Joining downloads that ledger to this phone.")
            LabeledContent("Step", value: adoptionDescription(invitation.phase))
            if children.isEmpty && transactions.isEmpty {
                if invitation.phase == .awaitingAcceptance
                    || invitation.phase == .awaitingInitialFetch
                    || invitation.phase == .readyToActivate {
                    Button("Join Family Ledger", systemImage: "person.crop.circle.badge.checkmark") {
                        Task { await perform(joinFamilyLedger) }
                    }
                    .disabled(isWorking)
                }
            } else {
                Text("This phone already has a local ledger. Kid Money will not replace or merge it automatically. Your data is unchanged.")
                    .foregroundStyle(.secondary)
            }
            if invitation.phase == .awaitingAcceptance {
                Button("Keep My Local Ledger", role: .cancel) {
                    Task { await perform(declineInvitation) }
                }
                .disabled(isWorking)
            }
        }
    }

    private func startOwnerSharing() async throws {
        let status = try await CloudLedgerLiveSetupTransport(modelContext: modelContext)
            .accountStatus()
        guard status == .available else {
            throw OwnerSharingPreflightError.unavailable(status)
        }
        try CloudLedgerMigrationCoordinator(modelContext: modelContext)
            .beginOwnerMigration(displayName: "Family Ledger")
        try await resumeOwnerSharing()
    }

    private func resumeOwnerSharing() async throws {
        let result = try await CloudLedgerSetupRunner(
            modelContext: modelContext,
            transport: CloudLedgerLiveSetupTransport(modelContext: modelContext)
        ).run()
        try await CloudLedgerActivationCoordinator(
            modelContext: modelContext,
            transport: CloudLedgerLiveActivationTransport()
        ).activate()
        if let share = result.share {
            presentedShare = share
            isShowingShare = true
        }
    }

    private func cancelOwnerSharing() async throws {
        try await CloudLedgerSetupRunner(
            modelContext: modelContext,
            transport: CloudLedgerLiveSetupTransport(modelContext: modelContext)
        ).cancelSetup()
    }

    private func joinFamilyLedger() async throws {
        let coordinator = CloudLedgerParticipantAdoptionCoordinator(
            modelContext: modelContext,
            transport: CloudLedgerLiveParticipantTransport()
        )
        _ = try await coordinator.resume()
        try await CloudLedgerActivationCoordinator(
            modelContext: modelContext,
            transport: CloudLedgerLiveActivationTransport()
        ).activate()
    }

    private func declineInvitation() throws {
        try CloudLedgerParticipantAdoptionCoordinator(
            modelContext: modelContext,
            transport: CloudLedgerLiveParticipantTransport()
        ).declineUnacceptedInvitation()
    }

    private func syncNow() async throws {
        _ = try await CloudLedgerSyncSession(
            modelContext: modelContext,
            accessTransport: CloudLedgerLiveActivationTransport(),
            syncTransport: CloudLedgerLiveSyncSessionTransport(modelContext: modelContext)
        ).run(ignoreBackoff: true)
    }

    private func showOwnerShare() async throws {
        guard let ledger = sharedLedger, ledger.role == .owner,
              ledger.phase == .active else {
            throw CloudLedgerSyncSessionError.invalidLedger
        }
        let access = try await CloudLedgerActivationCoordinator(
            modelContext: modelContext,
            transport: CloudLedgerLiveActivationTransport()
        ).checkActiveAccess()
        guard case .available = access else {
            throw CloudLedgerActivationError.accessDenied(code: "share-unavailable")
        }
        let container = CKContainer(identifier: FamilySharingProbe.containerIdentifier)
        let shareID = CKRecord.ID(
            recordName: CKRecordNameZoneWideShare,
            zoneID: ledger.zoneID
        )
        guard let share = try await container.privateCloudDatabase.record(for: shareID) as? CKShare
        else {
            throw CloudLedgerActivationError.accessDenied(code: "share-record-missing")
        }
        presentedShare = share
        isShowingShare = true
    }

    private func perform(_ operation: () async throws -> Void) async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            try await operation()
        } catch {
            errorMessage = userMessage(for: error)
        }
    }

    private func userMessage(for error: any Error) -> String {
        if case CloudLedgerActivationError.offline = error {
            return "iCloud is temporarily unavailable. Your local ledger is safe; try again later."
        }
        if case CloudLedgerActivationError.accountChanged = error {
            return "The iCloud account changed. Sharing is paused and no local ledger data was deleted."
        }
        if case CloudLedgerParticipantAdoptionError.iCloudUnavailable = error {
            return "Sign in to an available iCloud account, then try joining again."
        }
        if case OwnerSharingPreflightError.unavailable(let status) = error {
            if status == .restricted {
                return "This device restricts iCloud access. No family ledger upload was started."
            }
            return "Sign in to iCloud or try again when iCloud is available. No family ledger upload was started."
        }
        if case CloudLedgerSetupRunnerError.iCloudUnavailable = error {
            return "iCloud became unavailable during setup. Your local ledger is safe; open Sharing to resume or cancel."
        }
        if case CloudLedgerSetupRunnerError.operationFailed = error {
            return "iCloud could not finish sharing. Your local ledger is safe. Open Sharing to resume or cancel setup."
        }
        if case CloudLedgerMigrationError.localLedgerNotEmpty = error {
            return "This phone already has a local ledger. Kid Money will not replace it automatically."
        }
        return "Sharing could not finish: \(error.localizedDescription). Your local ledger data was not deleted."
    }

    private func statusDescription(for ledger: SharedLedgerState) -> String {
        switch ledger.phase {
        case .preparing: "Setting up"
        case .active: "Sharing enabled"
        case .attentionRequired: "Attention required"
        case nil: "Unknown"
        }
    }

    private func syncDescription(_ status: CloudLedgerSyncStatus?) -> String {
        switch status {
        case .idle: "Not yet synced"
        case .syncing: "Syncing"
        case .pending: "Changes pending"
        case .offline: "Offline"
        case .iCloudUnavailable: "iCloud unavailable"
        case .attentionRequired: "Attention required"
        case .synced: "Synced"
        case nil: "Unknown"
        }
    }

    private func migrationDescription(_ phase: CloudLedgerMigrationPhase?) -> String {
        switch phase {
        case .awaitingZoneCreation: "Creating private iCloud space"
        case .uploadingInitialLedger: "Uploading existing ledger"
        case .awaitingShareCreation: "Creating private invitation"
        case .readyToActivate: "Checking share access"
        case .completed: "Complete"
        case .attentionRequired: "Attention required"
        case nil: "Unknown"
        }
    }

    private func adoptionDescription(_ phase: CloudLedgerParticipantAdoptionPhase?) -> String {
        switch phase {
        case .awaitingAcceptance: "Ready to review"
        case .awaitingInitialFetch: "Downloading family ledger"
        case .readyToActivate: "Checking share access"
        case .completed: "Complete"
        case .attentionRequired: "Attention required"
        case nil: "Unknown"
        }
    }
}

@MainActor
private struct OwnerSharingConsentView: View {
    @Environment(\.dismiss) private var dismiss
    let childNames: [String]
    let transactionCount: Int
    let onConfirm: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section("What will be uploaded") {
                    Text("Your children, transaction history, and any notes will be copied to your private iCloud storage. Balances are derived from those transactions.")
                    LabeledContent("Children", value: "\(childNames.count)")
                    LabeledContent("Transactions", value: "\(transactionCount)")
                    if !childNames.isEmpty {
                        Text(childNames.joined(separator: ", "))
                            .foregroundStyle(.secondary)
                    }
                }
                Section("Who can see it") {
                    Text("Only your iCloud account can access the ledger until you invite someone. An invited adult will be able to read and edit it using their own iCloud account. Kid Money does not receive your family data on a developer-operated server.")
                }
                Section {
                    Button("Upload My Ledger to iCloud") { onConfirm() }
                        .buttonStyle(.borderedProminent)
                }
            }
            .navigationTitle("Share Family Ledger")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Not Now") { dismiss() }
                }
            }
        }
    }
}

private struct FamilyLedgerCloudSharingController: UIViewControllerRepresentable {
    let share: CKShare

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

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, UICloudSharingControllerDelegate {
        func itemTitle(for csc: UICloudSharingController) -> String? {
            "Kid Money Family Ledger"
        }

        func cloudSharingController(
            _ csc: UICloudSharingController,
            failedToSaveShareWithError error: any Error
        ) {
            Task { @MainActor in
                CloudLedgerInvitationNotice.shared.message =
                    "Apple could not save the invitation. The family ledger remains on this phone and in the owner's private iCloud storage. Try inviting again."
            }
        }
    }
}
