import Foundation
import SwiftData

enum AppModelContainer {
    static func make(inMemory: Bool = false, storeURL: URL? = nil) throws -> ModelContainer {
        let configuration: ModelConfiguration
        if let storeURL {
            configuration = ModelConfiguration(url: storeURL)
        } else {
            configuration = ModelConfiguration(isStoredInMemoryOnly: inMemory)
        }
        return try ModelContainer(for: Child.self, LedgerTransaction.self, configurations: configuration)
    }
}
