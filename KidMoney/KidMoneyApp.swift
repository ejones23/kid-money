import SwiftUI
import SwiftData

@main
struct KidMoneyApp: App {
    @UIApplicationDelegateAdaptor(KidMoneyAppDelegate.self) private var appDelegate
    @StateObject private var syncCoordinator: CloudLedgerAutomaticSyncCoordinator
    private let modelContainer: ModelContainer

    init() {
        do {
            let container = try AppModelContainer.shared()
            let coordinator = CloudLedgerAutomaticSyncCoordinator(
                modelContext: container.mainContext
            )
            coordinator.start()
            modelContainer = container
            _syncCoordinator = StateObject(wrappedValue: coordinator)
            KidMoneyShortcuts.updateAppShortcutParameters()
        } catch {
            fatalError("Unable to create the Kid Money data store: \(error.localizedDescription)")
        }
    }

    var body: some Scene {
        WindowGroup {
            KidMoneyRootView()
                .environmentObject(syncCoordinator)
        }
        .modelContainer(modelContainer)
    }
}

@MainActor
private struct KidMoneyRootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var syncCoordinator: CloudLedgerAutomaticSyncCoordinator

    var body: some View {
        ChildListView()
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active else { return }
                Task {
                    await syncCoordinator.syncWhenAppBecomesActive()
                }
            }
    }
}
