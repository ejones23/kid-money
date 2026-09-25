import CloudKit
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

    @Test func renameAndArchivePreserveLedgerHistory() throws {
        let container = try AppModelContainer.make(inMemory: true)
        let context = ModelContext(container)
        let service = LedgerService(modelContext: context)
        let child = try service.addChild(named: "Rebecca")
        try service.addTransaction(cents: 25, to: child, note: "Dishwasher")

        try service.renameChild(child, to: "  Becca  ")
        #expect(child.name == "Becca")
        #expect(try service.children(matching: "becca").map(\.id) == [child.id])

        try service.archiveChild(child)
        #expect(try service.activeChildren().isEmpty)
        #expect(try service.children(matching: "Becca").isEmpty)
        #expect(service.balance(for: child) == 25)
        #expect(try service.transactions(for: child).count == 1)
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

    @Test func duplicateExactNamesAreReturnedTogetherBeforePartialMatches() throws {
        let container = try AppModelContainer.make(inMemory: true)
        let context = ModelContext(container)
        let service = LedgerService(modelContext: context)
        let firstRebecca = try service.addChild(named: "Rebecca")
        let secondRebecca = try service.addChild(named: "REBECCA")
        _ = try service.addChild(named: "Rebecca Ann")

        #expect(Set(try service.children(matching: "rebecca").map(\.id)) == [
            firstRebecca.id,
            secondRebecca.id
        ])
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

    @Test func manyContextsShareOnePersistentStoreWithoutLosingTransactions() throws {
        let storeURL = FileManager.default.temporaryDirectory
            .appending(path: "KidMoneyStress-\(UUID().uuidString).store")
        defer {
            for suffix in ["", "-shm", "-wal"] {
                try? FileManager.default.removeItem(atPath: storeURL.path + suffix)
            }
        }

        let container = try AppModelContainer.make(storeURL: storeURL)
        let setupService = LedgerService(modelContext: ModelContext(container))
        let childID = try setupService.addChild(named: "Rebecca").id

        for _ in 0..<100 {
            let context = ModelContext(container)
            let service = LedgerService(modelContext: context)
            let persistedChild = try service.child(id: childID)
            let child = try #require(persistedChild)
            try service.addTransaction(cents: 1, to: child, source: .siri)
        }

        let verificationContext = ModelContext(container)
        let verificationService = LedgerService(modelContext: verificationContext)
        let persistedChild = try verificationService.child(id: childID)
        let child = try #require(persistedChild)
        #expect(verificationService.balance(for: child) == 100)
        #expect(try verificationService.transactions(for: child).count == 100)
    }

    @Test func moneyFormattingDoesNotUseFloatingPoint() {
        #expect(MoneyFormatter.string(cents: 5, locale: Locale(identifier: "en_US")) == "$0.05")
        #expect(MoneyFormatter.string(cents: 135, locale: Locale(identifier: "en_US")) == "$1.35")
    }

    @Test func usdAmountsConvertToExactCents() throws {
        #expect(try MoneyConversion.usdCents(from: Decimal(string: "0.10")!, currencyCode: "USD") == 10)
        #expect(try MoneyConversion.usdCents(from: Decimal(string: "12.34")!, currencyCode: "usd") == 1_234)
    }

    @Test func manualAmountTextUsesLocaleAndExactCentValidation() throws {
        #expect(try MoneyConversion.usdCents(
            from: " 12.34 ",
            locale: Locale(identifier: "en_US")
        ) == 1_234)
        #expect(try MoneyConversion.usdCents(
            from: "12,34",
            locale: Locale(identifier: "de_DE")
        ) == 1_234)
        #expect(throws: MoneyConversionError.invalidAmount) {
            try MoneyConversion.usdCents(from: "not money", locale: Locale(identifier: "en_US"))
        }
        #expect(throws: MoneyConversionError.fractionalCent) {
            try MoneyConversion.usdCents(from: "0.001", locale: Locale(identifier: "en_US"))
        }
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

    @Test func compositeSiriAmountRecognizesNaturalPhrases() {
        let tenCentEntity = LedgerAdjustmentEntity(
            childID: UUID(),
            childName: "Rebecca",
            amount: .tenCents
        )
        let fifteenCentEntity = LedgerAdjustmentEntity(
            childID: UUID(),
            childName: "Rebecca",
            amount: .fifteenCents
        )

        #expect(tenCentEntity.matches("Rebecca ten cents"))
        #expect(tenCentEntity.matches("Rebecca 10 cents"))
        #expect(tenCentEntity.matches("Rebecca a dime"))
        #expect(tenCentEntity.matches("ten cents from Rebecca"))
        #expect(tenCentEntity.matches("TEN-CENTS TO RÉBECCA"))
        #expect(!tenCentEntity.matches("Rebecca twenty cents"))
        #expect(fifteenCentEntity.matches("Rebecca fifteen cents"))
        #expect(fifteenCentEntity.matches("15 cents from Rebecca"))
    }

    @Test func compositeSiriAmountsCoverEveryFiveCentsThroughOneDollar() {
        for cents in stride(from: 5, through: 100, by: 5) {
            #expect(LedgerVoiceAmount(rawValue: Int64(cents)) != nil)
        }
    }

    @Test func undoCreatesACompensatingTransaction() throws {
        let container = try AppModelContainer.make(inMemory: true)
        let context = ModelContext(container)
        let service = LedgerService(modelContext: context)
        let rebecca = try service.addChild(named: "Rebecca")
        let original = try service.addTransaction(cents: 25, to: rebecca)

        let result = try service.undoLastTransaction(source: .siri)
        let transactions = try service.transactions(for: rebecca)

        #expect(result.child.id == rebecca.id)
        #expect(result.originalAmountCents == 25)
        #expect(result.newBalanceCents == 0)
        #expect(transactions.count == 2)
        let compensation = try #require(transactions.first { $0.reversesTransactionID == original.id })
        #expect(compensation.id == CloudLedgerTransactionIdentity.undo(reversing: original.id))
        #expect(compensation.amountCents == -25)
        #expect(compensation.source == .siri)
        #expect(transactions.contains { $0.id == original.id })
    }

    @Test func transactionRejectsBalanceOverflowWithoutPersisting() throws {
        let container = try AppModelContainer.make(inMemory: true)
        let context = ModelContext(container)
        let service = LedgerService(modelContext: context)
        let child = try service.addChild(named: "Rebecca")

        try service.addTransaction(cents: .max, to: child)
        #expect(throws: LedgerError.balanceOutOfRange) {
            try service.addTransaction(cents: 1, to: child)
        }
        #expect(service.balance(for: child) == .max)
        #expect(try service.transactions(for: child).count == 1)
    }

    @Test func undoRejectsMinimumIntegerWithoutWritingCompensation() throws {
        let container = try AppModelContainer.make(inMemory: true)
        let context = ModelContext(container)
        let service = LedgerService(modelContext: context)
        let child = try service.addChild(named: "Rebecca")

        try service.addTransaction(cents: .min, to: child)
        #expect(throws: LedgerError.transactionAmountOutOfRange) {
            try service.undoLastTransaction()
        }
        #expect(service.balance(for: child) == .min)
        #expect(try service.transactions(for: child).count == 1)
    }

    @Test func repeatedUndoWalksBackThroughUnreversedTransactions() throws {
        let container = try AppModelContainer.make(inMemory: true)
        let context = ModelContext(container)
        let service = LedgerService(modelContext: context)
        let rebecca = try service.addChild(named: "Rebecca")
        let first = try service.addTransaction(cents: 10, to: rebecca, note: "First")
        first.createdAt = Date(timeIntervalSince1970: 1)
        let second = try service.addTransaction(cents: -5, to: rebecca, note: "Second")
        second.createdAt = Date(timeIntervalSince1970: 2)
        try context.save()

        let firstUndo = try service.undoLastTransaction()
        let secondUndo = try service.undoLastTransaction()

        #expect(firstUndo.originalAmountCents == -5)
        #expect(firstUndo.newBalanceCents == 10)
        #expect(secondUndo.originalAmountCents == 10)
        #expect(secondUndo.newBalanceCents == 0)
        #expect(try service.transactions(for: rebecca).count == 4)
        #expect(throws: LedgerError.nothingToUndo) {
            try service.undoLastTransaction()
        }
    }

    @Test func undoUsesTheMostRecentTransactionAcrossChildren() throws {
        let container = try AppModelContainer.make(inMemory: true)
        let context = ModelContext(container)
        let service = LedgerService(modelContext: context)
        let rebecca = try service.addChild(named: "Rebecca")
        let daniel = try service.addChild(named: "Daniel")
        try service.addTransaction(
            cents: 10,
            to: rebecca,
            note: "Earlier",
            source: .manual
        ).createdAt = Date(timeIntervalSince1970: 1)
        try service.addTransaction(
            cents: 25,
            to: daniel,
            note: "Later",
            source: .manual
        ).createdAt = Date(timeIntervalSince1970: 2)
        try context.save()

        let result = try service.undoLastTransaction()

        #expect(result.child.id == daniel.id)
        #expect(result.originalAmountCents == 25)
        #expect(service.balance(for: rebecca) == 10)
        #expect(service.balance(for: daniel) == 0)
    }

    @Test func undoRejectsAnEmptyLedger() throws {
        let container = try AppModelContainer.make(inMemory: true)
        let service = LedgerService(modelContext: ModelContext(container))

        #expect(throws: LedgerError.nothingToUndo) {
            try service.undoLastTransaction()
        }
    }

    @Test func cloudRecordNamesAreDeterministicAndUndoUsesOriginalIdentity() throws {
        let childID = try #require(UUID(uuidString: "11111111-2222-3333-4444-555555555555"))
        let firstUndoID = try #require(UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"))
        let secondUndoID = try #require(UUID(uuidString: "99999999-8888-7777-6666-555555555555"))

        #expect(
            CloudLedgerRecordName.child(childID)
                == "child-11111111-2222-3333-4444-555555555555"
        )
        #expect(
            CloudLedgerRecordName.transaction(id: firstUndoID, reversesTransactionID: childID)
                == CloudLedgerRecordName.transaction(id: secondUndoID, reversesTransactionID: childID)
        )
        #expect(
            CloudLedgerRecordName.transaction(id: firstUndoID, reversesTransactionID: childID)
                == "undo-11111111-2222-3333-4444-555555555555"
        )
        #expect(
            CloudLedgerTransactionIdentity.undo(reversing: childID)
                == CloudLedgerTransactionIdentity.undo(reversing: childID)
        )
        #expect(
            CloudLedgerTransactionIdentity.undo(reversing: childID)
                != CloudLedgerTransactionIdentity.undo(reversing: firstUndoID)
        )
    }

    @Test func cloudRecordMappingPreservesExactLedgerValues() throws {
        let container = try AppModelContainer.make(inMemory: true)
        let context = ModelContext(container)
        let service = LedgerService(modelContext: context)
        let child = try service.addChild(named: "Rebecca")
        let transaction = try service.addTransaction(
            cents: -25,
            to: child,
            note: "Book",
            source: .siri
        )
        let zoneID = CKRecordZone.ID(
            zoneName: "KidMoney-test-zone",
            ownerName: CKCurrentUserDefaultName
        )
        let householdID = UUID()
        let state = SharedLedgerState(
            householdID: householdID,
            displayName: "Family Ledger",
            zoneName: zoneID.zoneName,
            zoneOwnerName: zoneID.ownerName,
            role: .owner,
            databaseScope: .privateDatabase,
            phase: .preparing
        )

        let householdRecord = CloudLedgerRecordMapper.household(state)
        let childRecord = CloudLedgerRecordMapper.child(child, zoneID: zoneID)
        let transactionRecord = try #require(
            CloudLedgerRecordMapper.transaction(transaction, zoneID: zoneID)
        )

        #expect(
            householdRecord.recordID.recordName
                == CloudLedgerRecordName.household(householdID)
        )
        #expect(householdRecord.recordID.zoneID == zoneID)
        #expect(householdRecord[CloudLedgerSchema.Field.displayName] as? String == "Family Ledger")
        #expect(
            (householdRecord[CloudLedgerSchema.Field.schemaVersion] as? NSNumber)?.intValue
                == CloudLedgerSchema.currentVersion
        )
        #expect(childRecord.recordID.recordName == CloudLedgerRecordName.child(child.id))
        #expect(childRecord.recordID.zoneID == zoneID)
        #expect(childRecord[CloudLedgerSchema.Field.name] as? String == "Rebecca")
        #expect((childRecord[CloudLedgerSchema.Field.isArchived] as? NSNumber)?.boolValue == false)
        #expect(
            transactionRecord.recordID.recordName
                == CloudLedgerRecordName.transaction(id: transaction.id, reversesTransactionID: nil)
        )
        #expect(
            (transactionRecord[CloudLedgerSchema.Field.amountCents] as? NSNumber)?.int64Value == -25
        )
        #expect(transactionRecord[CloudLedgerSchema.Field.note] as? String == "Book")
        #expect(transactionRecord[CloudLedgerSchema.Field.source] as? String == "siri")
        #expect(
            transactionRecord[CloudLedgerSchema.Field.childIdentifier] as? String
                == child.id.uuidString.lowercased()
        )
    }

    @Test func localOnlyMutationsDoNotCreatePendingCloudChanges() throws {
        let container = try AppModelContainer.make(inMemory: true)
        let context = ModelContext(container)
        let service = LedgerService(modelContext: context)
        let child = try service.addChild(named: "Rebecca")
        try service.addTransaction(cents: 10, to: child)
        try service.renameChild(child, to: "Becca")

        #expect(try context.fetch(FetchDescriptor<PendingCloudChange>()).isEmpty)
    }

    @Test func preparingSharedLedgerDoesNotQueueOrdinaryMutations() throws {
        let container = try AppModelContainer.make(inMemory: true)
        let context = ModelContext(container)
        let householdID = UUID()
        context.insert(SharedLedgerState(
            householdID: householdID,
            displayName: "Family Ledger",
            zoneName: "KidMoneyHousehold-\(householdID.uuidString)",
            zoneOwnerName: CKCurrentUserDefaultName,
            role: .owner,
            databaseScope: .privateDatabase,
            phase: .preparing
        ))
        try context.save()

        let service = LedgerService(modelContext: context)
        let child = try service.addChild(named: "Rebecca")
        try service.addTransaction(cents: 10, to: child)

        #expect(try context.fetch(FetchDescriptor<PendingCloudChange>()).isEmpty)
    }

    @Test func activeSharedLedgerQueuesAndCoalescesDurableChanges() throws {
        let storeURL = FileManager.default.temporaryDirectory
            .appending(path: "KidMoneyQueue-\(UUID().uuidString).store")
        defer {
            for suffix in ["", "-shm", "-wal"] {
                try? FileManager.default.removeItem(atPath: storeURL.path + suffix)
            }
        }

        let householdID = UUID()
        let childID: UUID
        let transactionID: UUID

        do {
            let container = try AppModelContainer.make(storeURL: storeURL)
            let context = ModelContext(container)
            context.insert(SharedLedgerState(
                householdID: householdID,
                displayName: "Family Ledger",
                zoneName: "KidMoneyHousehold-\(householdID.uuidString)",
                zoneOwnerName: CKCurrentUserDefaultName,
                role: .owner,
                databaseScope: .privateDatabase,
                phase: .active
            ))
            try context.save()

            let service = LedgerService(modelContext: context)
            let child = try service.addChild(named: "Rebecca")
            childID = child.id
            try service.renameChild(child, to: "Becca")
            transactionID = try service.addTransaction(cents: 10, to: child).id

            let pending = try context.fetch(FetchDescriptor<PendingCloudChange>())
            #expect(pending.count == 2)
            #expect(pending.filter { $0.recordType == .child }.count == 1)
            #expect(pending.filter { $0.recordType == .ledgerTransaction }.count == 1)
        }

        do {
            let container = try AppModelContainer.make(storeURL: storeURL)
            let context = ModelContext(container)
            let pending = try context.fetch(FetchDescriptor<PendingCloudChange>())

            #expect(Set(pending.map(\.householdID)) == [householdID])
            #expect(Set(pending.map(\.recordName)) == [
                CloudLedgerRecordName.child(childID),
                CloudLedgerRecordName.transaction(id: transactionID, reversesTransactionID: nil)
            ])
        }
    }

    @Test func undoQueueCoalescesByOriginalTransactionIdentity() throws {
        let container = try AppModelContainer.make(inMemory: true)
        let context = ModelContext(container)
        let householdID = UUID()
        context.insert(SharedLedgerState(
            householdID: householdID,
            displayName: "Family Ledger",
            zoneName: "KidMoneyHousehold-\(householdID.uuidString)",
            zoneOwnerName: CKCurrentUserDefaultName,
            role: .owner,
            databaseScope: .privateDatabase,
            phase: .active
        ))
        try context.save()

        let service = LedgerService(modelContext: context)
        let child = try service.addChild(named: "Rebecca")
        let original = try service.addTransaction(cents: 10, to: child)
        _ = try service.addTransaction(
            cents: -10,
            to: child,
            reversesTransactionID: original.id
        )
        _ = try service.addTransaction(
            cents: -10,
            to: child,
            reversesTransactionID: original.id
        )

        let pending = try context.fetch(FetchDescriptor<PendingCloudChange>())
        let undoName = CloudLedgerRecordName.transaction(
            id: UUID(),
            reversesTransactionID: original.id
        )
        #expect(pending.filter { $0.recordName == undoName }.count == 1)
    }
}
