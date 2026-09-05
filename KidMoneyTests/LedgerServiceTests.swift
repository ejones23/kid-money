import Foundation
import SwiftData
import Testing
@testable import KidMoney

@MainActor
struct LedgerServiceTests {
    @Test func balanceUsesSignedIntegerCents() throws {
        let container = try AppModelContainer.make(inMemory: true)
        let context = ModelContext(container)
        let service = LedgerService(modelContext: context)
        let rebecca = try service.addChild(named: "Rebecca")

        try service.addTransaction(cents: 10, to: rebecca)
        try service.addTransaction(cents: 25, to: rebecca)
        try service.addTransaction(cents: -5, to: rebecca)

        #expect(service.balance(for: rebecca) == 30)
    }

    @Test func childrenHaveIndependentBalances() throws {
        let container = try AppModelContainer.make(inMemory: true)
        let context = ModelContext(container)
        let service = LedgerService(modelContext: context)
        let rebecca = try service.addChild(named: "Rebecca")
        let daniel = try service.addChild(named: "Daniel")

        try service.addTransaction(cents: 10, to: rebecca)
        try service.addTransaction(cents: 25, to: daniel)

        #expect(service.balance(for: rebecca) == 10)
        #expect(service.balance(for: daniel) == 25)
    }

    @Test func childLookupIsCaseInsensitiveAndExcludesArchivedChildren() throws {
        let container = try AppModelContainer.make(inMemory: true)
        let context = ModelContext(container)
        let service = LedgerService(modelContext: context)
        let rebecca = try service.addChild(named: "Rebecca")
        let archivedRebecca = try service.addChild(named: "REBECCA")
        archivedRebecca.isArchived = true
        try context.save()

        #expect(try service.children(matching: "  rebecca  ").map(\.id) == [rebecca.id])
        #expect(try service.children(matching: "becca").map(\.id) == [rebecca.id])
        #expect(try service.children(matching: "").isEmpty)
    }

    @Test func balanceSurvivesStoreReopen() throws {
        let storeURL = FileManager.default.temporaryDirectory
            .appending(path: "KidMoneyTests-\(UUID().uuidString).store")
        defer {
            for suffix in ["", "-shm", "-wal"] {
                try? FileManager.default.removeItem(atPath: storeURL.path + suffix)
            }
        }

        do {
            let container = try AppModelContainer.make(storeURL: storeURL)
            let service = LedgerService(modelContext: ModelContext(container))
            let rebecca = try service.addChild(named: "Rebecca")
            try service.addTransaction(cents: 30, to: rebecca)
        }

        do {
            let container = try AppModelContainer.make(storeURL: storeURL)
            let context = ModelContext(container)
            let service = LedgerService(modelContext: context)
            let rebecca = try #require(context.fetch(FetchDescriptor<Child>()).first)

            #expect(service.balance(for: rebecca) == 30)
        }
    }

    @Test func moneyFormattingDoesNotUseFloatingPoint() {
        #expect(MoneyFormatter.string(cents: 5, locale: Locale(identifier: "en_US")) == "$0.05")
        #expect(MoneyFormatter.string(cents: 135, locale: Locale(identifier: "en_US")) == "$1.35")
    }

    @Test func usdAmountsConvertToExactCents() throws {
        #expect(try MoneyConversion.usdCents(from: Decimal(string: "0.10")!, currencyCode: "USD") == 10)
        #expect(try MoneyConversion.usdCents(from: Decimal(string: "12.34")!, currencyCode: "usd") == 1_234)
    }

    @Test func invalidMoneyAmountsAreRejected() {
        #expect(throws: MoneyConversionError.fractionalCent) {
            try MoneyConversion.usdCents(from: Decimal(string: "0.001")!, currencyCode: "USD")
        }
        #expect(throws: MoneyConversionError.amountMustBePositive) {
            try MoneyConversion.usdCents(from: 0, currencyCode: "USD")
        }
        #expect(throws: MoneyConversionError.unsupportedCurrency("EUR")) {
            try MoneyConversion.usdCents(from: 1, currencyCode: "EUR")
        }
        #expect(throws: MoneyConversionError.amountOutOfRange) {
            try MoneyConversion.usdCents(
                from: Decimal(string: "92233720368547758.08")!,
                currencyCode: "USD"
            )
        }
    }
}
