import CloudKit
import Combine
import Foundation
import OSLog
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

/// The only entry point for ordinary real-ledger network work. The app-scoped
/// coordinator retains one session for automatic and explicit work. Setup uses
/// a separate nonautomatic transport, while an active household rechecks
/// access between its immediate fetch and send.
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

@MainActor
protocol CloudLedgerSyncRunning: AnyObject {
    @discardableResult
    func run(now: Date, ignoreBackoff: Bool) async throws -> CloudLedgerSyncStatus
}

extension CloudLedgerSyncSession: CloudLedgerSyncRunning {}

/// Owns the single long-lived production sync engine for an active household.
/// Foreground work is immediate, local mutations are debounced, and the same
/// guarded session backs the explicit Sync Now recovery action.
@MainActor
final class CloudLedgerAutomaticSyncCoordinator: ObservableObject {
    typealias SessionFactory = @MainActor () -> any CloudLedgerSyncRunning

    private static let logger = Logger(
        subsystem: "io.github.ejones23.KidMoney",
        category: "AutomaticSync"
    )

    private let debounceNanoseconds: UInt64
    private let notificationCenter: NotificationCenter
    private let makeSession: SessionFactory
    private var session: (any CloudLedgerSyncRunning)?
    private var runningTask: Task<CloudLedgerSyncStatus, any Error>?
    private var runningToken: UUID?
    private var debounceTask: Task<Void, Never>?
    private var mutationObserver: NSObjectProtocol?

    convenience init(
        modelContext: ModelContext,
        debounceNanoseconds: UInt64 = 750_000_000
    ) {
        self.init(debounceNanoseconds: debounceNanoseconds) {
            let transport = CloudLedgerLiveSyncSessionTransport(
                modelContext: modelContext,
                automaticallySync: true
            )
            return CloudLedgerSyncSession(
                modelContext: modelContext,
                accessTransport: CloudLedgerLiveActivationTransport(),
                syncTransport: transport
            )
        }
    }

    init(
        debounceNanoseconds: UInt64,
        notificationCenter: NotificationCenter = .default,
        makeSession: @escaping SessionFactory
    ) {
        self.debounceNanoseconds = debounceNanoseconds
        self.notificationCenter = notificationCenter
        self.makeSession = makeSession
    }

    func start() {
        guard mutationObserver == nil else { return }
        mutationObserver = notificationCenter.addObserver(
            forName: .kidMoneyLedgerDidMutate,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.scheduleAfterLocalMutation()
            }
        }
        Task { @MainActor [weak self] in
            await self?.syncWhenAppBecomesActive()
        }
    }

    func syncWhenAppBecomesActive() async {
        do {
            _ = try await run(ignoreBackoff: true)
        } catch CloudLedgerSyncSessionError.invalidLedger {
            resetSession()
        } catch {
            Self.logger.error(
                "Foreground synchronization did not complete: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    func scheduleAfterLocalMutation() {
        debounceTask?.cancel()
        debounceTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(nanoseconds: debounceNanoseconds)
                try Task.checkCancellation()
                _ = try await runAfterCurrentWork(ignoreBackoff: false)
            } catch is CancellationError {
                return
            } catch CloudLedgerSyncSessionError.invalidLedger {
                resetSession()
            } catch {
                Self.logger.error(
                    "Debounced synchronization did not complete: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    @discardableResult
    func syncNow() async throws -> CloudLedgerSyncStatus {
        debounceTask?.cancel()
        return try await run(ignoreBackoff: true)
    }

    func sharedLedgerStateDidChange() {
        resetSession()
        Task { @MainActor [weak self] in
            await self?.syncWhenAppBecomesActive()
        }
    }

    private func run(ignoreBackoff: Bool) async throws -> CloudLedgerSyncStatus {
        if let runningTask {
            return try await runningTask.value
        }
        return try await beginRun(ignoreBackoff: ignoreBackoff)
    }

    /// A mutation that lands while an older fetch/send is in flight must get a
    /// later send opportunity. Joining the older task alone can miss a queue
    /// entry added after that task materialized its send batch.
    private func runAfterCurrentWork(
        ignoreBackoff: Bool
    ) async throws -> CloudLedgerSyncStatus {
        if let runningTask {
            _ = try? await runningTask.value
        }
        return try await beginRun(ignoreBackoff: ignoreBackoff)
    }

    private func beginRun(ignoreBackoff: Bool) async throws -> CloudLedgerSyncStatus {
        let session = session ?? makeSession()
        self.session = session
        let token = UUID()
        let task = Task { @MainActor in
            try await session.run(now: .now, ignoreBackoff: ignoreBackoff)
        }
        runningTask = task
        runningToken = token
        defer {
            if runningToken == token {
                runningTask = nil
                runningToken = nil
            }
        }
        do {
            return try await task.value
        } catch CloudLedgerSyncSessionError.invalidLedger {
            resetSession()
            throw CloudLedgerSyncSessionError.invalidLedger
        }
    }

    private func resetSession() {
        debounceTask?.cancel()
        debounceTask = nil
        session = nil
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

/// Retains one engine for a session and restores its persisted state. Explicit
/// setup transports leave automatic scheduling off; the app-scoped active-
/// household coordinator opts in.
@MainActor
final class CloudLedgerLiveSyncSessionTransport: CloudLedgerSyncSessionTransport {
    let modelContext: ModelContext
    let container: CKContainer
    let automaticallySync: Bool
    private var retainedRuntime: CloudLedgerSyncEngineRuntime?

    init(
        modelContext: ModelContext,
        container: CKContainer = CKContainer(
            identifier: FamilySharingProbe.containerIdentifier
        ),
        automaticallySync: Bool = false
    ) {
        self.modelContext = modelContext
        self.container = container
        self.automaticallySync = automaticallySync
    }

    func fetchChanges(for ledger: SharedLedgerState) async throws {
        let runtime = try runtime(for: ledger)
        try await runtime.engine.fetchChanges()
    }

    func sendChanges(for ledger: SharedLedgerState) async throws {
        let runtime = try runtime(for: ledger)
        try runtime.refreshPendingChangesFromQueue()
        try await runtime.engine.sendChanges()
    }

    func runtime(for ledger: SharedLedgerState) throws -> CloudLedgerSyncEngineRuntime {
        if let retainedRuntime {
            guard retainedRuntime.delegate.store.householdID == ledger.householdID,
                  retainedRuntime.delegate.zoneID == ledger.zoneID else {
                throw CloudLedgerSyncSessionError.invalidLedger
            }
            return retainedRuntime
        }
        let database: CKDatabase
        switch ledger.databaseScope {
        case .privateDatabase:
            database = container.privateCloudDatabase
        case .sharedDatabase:
            database = container.sharedCloudDatabase
        case nil:
            throw CloudLedgerSyncSessionError.invalidLedger
        }
        let runtime = try CloudLedgerSyncEngineRuntime(
            database: database,
            modelContext: modelContext,
            householdID: ledger.householdID,
            automaticallySync: automaticallySync
        )
        retainedRuntime = runtime
        return runtime
    }
}
