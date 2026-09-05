import SwiftUI
import SwiftData

@main
struct KidMoneyApp: App {
    private let modelContainer: ModelContainer

    init() {
        do {
            modelContainer = try AppModelContainer.make()
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
