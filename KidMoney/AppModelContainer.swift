import Foundation
import SwiftData

enum AppModelContainer {
    private static let productionContainer: Result<ModelContainer, Error> = Result {
        try make()
    }

    static func shared() throws -> ModelContainer {
        try productionContainer.get()
    }

    static func make(inMemory: Bool = false, storeURL: URL? = nil) throws -> ModelContainer {
        let configuration: ModelConfiguration
        if let storeURL {
            configuration = ModelConfiguration(url: storeURL, cloudKitDatabase: .none)
        } else {
            configuration = ModelConfiguration(
                isStoredInMemoryOnly: inMemory,
                cloudKitDatabase: .none
            )
        }
        return try ModelContainer(
            for: Child.self,
            LedgerTransaction.self,
            SharedLedgerState.self,
            PendingCloudChange.self,
            DeferredCloudTransaction.self,
            CloudLedgerSyncState.self,
            configurations: configuration
        )
    }
}
