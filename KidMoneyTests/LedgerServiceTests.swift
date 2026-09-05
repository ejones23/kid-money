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

    @Test func moneyFormattingDoesNotUseFloatingPoint() {
        #expect(MoneyFormatter.string(cents: 5, locale: Locale(identifier: "en_US")) == "$0.05")
        #expect(MoneyFormatter.string(cents: 135, locale: Locale(identifier: "en_US")) == "$1.35")
    }
}
