import SwiftUI
import SwiftData

@main
struct KidMoneyApp: App {
    @UIApplicationDelegateAdaptor(KidMoneyAppDelegate.self) private var appDelegate
    private let modelContainer: ModelContainer

    init() {
        do {
            modelContainer = try AppModelContainer.shared()
            KidMoneyShortcuts.updateAppShortcutParameters()
        } catch {
            fatalError("Unable to create the Kid Money data store: \(error.localizedDescription)")
        }
    }

    var body: some Scene {
        WindowGroup {
            ChildListView()
        }
        .modelContainer(modelContainer)
    }
}
