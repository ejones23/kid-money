import SwiftData

enum AppModelContainer {
    static func make(inMemory: Bool = false) throws -> ModelContainer {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: inMemory)
        return try ModelContainer(for: Child.self, LedgerTransaction.self, configurations: configuration)
    }
}

