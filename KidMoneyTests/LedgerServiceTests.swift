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

    @Test func cloudRecordDecodingRoundTripsAndRejectsInvalidMoney() throws {
        let container = try AppModelContainer.make(inMemory: true)
        let context = ModelContext(container)
        let child = Child(
            id: UUID(),
            name: "Rebecca",
            createdAt: Date(timeIntervalSinceReferenceDate: 10),
            sortOrder: 2
        )
        child.lastModifiedAt = Date(timeIntervalSinceReferenceDate: 20)
        let transaction = LedgerTransaction(
            id: UUID(),
            amountCents: -25,
            createdAt: Date(timeIntervalSinceReferenceDate: 30),
            note: "Book",
            source: .siri,
            child: child
        )
        let sharedLedger = try makeSharedLedger(context: context)

        let decodedChild = try CloudLedgerRecordDecoder.child(
            CloudLedgerRecordMapper.child(child, zoneID: sharedLedger.zoneID)
        )
        let transactionRecord = try #require(
            CloudLedgerRecordMapper.transaction(transaction, zoneID: sharedLedger.zoneID)
        )
        let decodedTransaction = try CloudLedgerRecordDecoder.transaction(transactionRecord)

        #expect(decodedChild.id == child.id)
        #expect(decodedChild.name == "Rebecca")
        #expect(decodedChild.sortOrder == 2)
        #expect(decodedChild.lastModifiedAt == child.lastModifiedAt)
        #expect(decodedTransaction.id == transaction.id)
        #expect(decodedTransaction.childID == child.id)
        #expect(decodedTransaction.amountCents == -25)
        #expect(decodedTransaction.note == "Book")
        #expect(decodedTransaction.source == .siri)

        transactionRecord[CloudLedgerSchema.Field.amountCents] = NSNumber(value: 0)
        #expect(throws: CloudLedgerRecordDecodingError.missingOrInvalidField(
            CloudLedgerSchema.Field.amountCents
        )) {
            try CloudLedgerRecordDecoder.transaction(transactionRecord)
        }
    }

    @Test func remoteChildMergeUsesDeterministicLastWriteWinsWithoutQueueEcho() throws {
        let container = try AppModelContainer.make(inMemory: true)
        let context = ModelContext(container)
        let sharedLedger = try makeSharedLedger(context: context)
        let service = LedgerService(modelContext: context)
        let local = try service.addChild(named: "Rebecca")
        let timestamp = Date(timeIntervalSinceReferenceDate: 100)
        local.lastModifiedAt = timestamp
        for pending in try context.fetch(FetchDescriptor<PendingCloudChange>()) {
            context.delete(pending)
        }
        try context.save()

        let remote = Child(
            id: local.id,
            name: "Zoe",
            createdAt: local.createdAt,
            sortOrder: 3,
            isArchived: true
        )
        remote.lastModifiedAt = timestamp
        let record = CloudLedgerRecordMapper.child(remote, zoneID: sharedLedger.zoneID)

        let first = try CloudLedgerMergeService(modelContext: context).merge(
            records: [record],
            into: sharedLedger
        )
        #expect(first.updatedChildren == 1)
        #expect(local.name == "Zoe")
        #expect(local.sortOrder == 3)
        #expect(local.isArchived)
        #expect(try context.fetch(FetchDescriptor<PendingCloudChange>()).isEmpty)

        let losingRemote = Child(
            id: local.id,
            name: "Amy",
            createdAt: local.createdAt,
            sortOrder: 0
        )
        losingRemote.lastModifiedAt = timestamp
        let second = try CloudLedgerMergeService(modelContext: context).merge(
            records: [CloudLedgerRecordMapper.child(losingRemote, zoneID: sharedLedger.zoneID)],
            into: sharedLedger
        )
        #expect(second.updatedChildren == 0)
        #expect(second.unchangedRecords == 1)
        #expect(local.name == "Zoe")
    }

    @Test func remoteTransactionsMergeIdempotentlyWithoutQueueEcho() throws {
        let container = try AppModelContainer.make(inMemory: true)
        let context = ModelContext(container)
        let sharedLedger = try makeSharedLedger(context: context)
        let child = Child(
            id: UUID(),
            name: "Rebecca",
            createdAt: Date(timeIntervalSinceReferenceDate: 10),
            sortOrder: 0
        )
        let transaction = LedgerTransaction(
            id: UUID(),
            amountCents: 35,
            createdAt: Date(timeIntervalSinceReferenceDate: 20),
            note: "Allowance",
            source: .siri,
            child: child
        )
        let childRecord = CloudLedgerRecordMapper.child(child, zoneID: sharedLedger.zoneID)
        let transactionRecord = try #require(
            CloudLedgerRecordMapper.transaction(transaction, zoneID: sharedLedger.zoneID)
        )
        let merger = CloudLedgerMergeService(modelContext: context)

        let first = try merger.merge(
            records: [transactionRecord, childRecord],
            into: sharedLedger
        )
        let second = try merger.merge(
            records: [childRecord, transactionRecord],
            into: sharedLedger
        )
        let persistedChild = try #require(
            context.fetch(FetchDescriptor<Child>()).first { $0.id == child.id }
        )

        #expect(first.insertedChildren == 1)
        #expect(first.insertedTransactions == 1)
        #expect(second.insertedChildren == 0)
        #expect(second.insertedTransactions == 0)
        #expect(try context.fetch(FetchDescriptor<LedgerTransaction>()).count == 1)
        #expect(LedgerService(modelContext: context).balance(for: persistedChild) == 35)
        #expect(try context.fetch(FetchDescriptor<PendingCloudChange>()).isEmpty)
    }

    @Test func missingChildTransactionIsDurablyDeferredUntilChildArrives() throws {
        let storeURL = FileManager.default.temporaryDirectory
            .appending(path: "KidMoneyRemoteQueue-\(UUID().uuidString).store")
        defer {
            for suffix in ["", "-shm", "-wal"] {
                try? FileManager.default.removeItem(atPath: storeURL.path + suffix)
            }
        }

        let child = Child(name: "Rebecca", sortOrder: 0)
        let transaction = LedgerTransaction(
            amountCents: 15,
            note: "Remote",
            source: .manual,
            child: child
        )
        let householdID: UUID
        let childRecord: CKRecord

        do {
            let container = try AppModelContainer.make(storeURL: storeURL)
            let context = ModelContext(container)
            let sharedLedger = try makeSharedLedger(context: context)
            householdID = sharedLedger.householdID
            childRecord = CloudLedgerRecordMapper.child(child, zoneID: sharedLedger.zoneID)
            let transactionRecord = try #require(
                CloudLedgerRecordMapper.transaction(transaction, zoneID: sharedLedger.zoneID)
            )

            let result = try CloudLedgerMergeService(modelContext: context).merge(
                records: [transactionRecord],
                into: sharedLedger
            )
            #expect(result.deferredTransactions == 1)
            #expect(try context.fetch(FetchDescriptor<DeferredCloudTransaction>()).count == 1)
            #expect(try context.fetch(FetchDescriptor<LedgerTransaction>()).isEmpty)
        }

        do {
            let container = try AppModelContainer.make(storeURL: storeURL)
            let context = ModelContext(container)
            let sharedLedger = try #require(
                context.fetch(FetchDescriptor<SharedLedgerState>()).first {
                    $0.householdID == householdID
                }
            )
            let result = try CloudLedgerMergeService(modelContext: context).merge(
                records: [childRecord],
                into: sharedLedger
            )

            #expect(result.insertedChildren == 1)
            #expect(result.insertedTransactions == 1)
            #expect(result.deferredTransactions == 0)
            #expect(try context.fetch(FetchDescriptor<DeferredCloudTransaction>()).isEmpty)
        }
    }

    @Test func immutableTransactionConflictRollsBackTheWholeRemoteBatch() throws {
        let container = try AppModelContainer.make(inMemory: true)
        let context = ModelContext(container)
        let service = LedgerService(modelContext: context)
        let localChild = try service.addChild(named: "Rebecca")
        let localTransaction = try service.addTransaction(cents: 10, to: localChild)
        let sharedLedger = try makeSharedLedger(context: context)
        let additionalChild = Child(name: "Daniel", sortOrder: 1)
        let conflictingRecord = try #require(
            CloudLedgerRecordMapper.transaction(localTransaction, zoneID: sharedLedger.zoneID)
        )
        conflictingRecord[CloudLedgerSchema.Field.amountCents] = NSNumber(value: 20)

        #expect(throws: CloudLedgerMergeError.immutableTransactionConflict(localTransaction.id)) {
            try CloudLedgerMergeService(modelContext: context).merge(
                records: [
                    CloudLedgerRecordMapper.child(additionalChild, zoneID: sharedLedger.zoneID),
                    conflictingRecord
                ],
                into: sharedLedger
            )
        }
        #expect(try context.fetch(FetchDescriptor<Child>()).count == 1)
        #expect(try context.fetch(FetchDescriptor<LedgerTransaction>()).count == 1)
        #expect(localTransaction.amountCents == 10)
    }

    @Test func remoteUndoCanonicalizesLegacyIdentityWithoutChangingBalance() throws {
        let container = try AppModelContainer.make(inMemory: true)
        let context = ModelContext(container)
        let service = LedgerService(modelContext: context)
        let child = try service.addChild(named: "Rebecca")
        let original = try service.addTransaction(cents: 10, to: child)
        let legacyUndo = try service.addTransaction(
            id: UUID(),
            cents: -10,
            to: child,
            reversesTransactionID: original.id
        )
        let sharedLedger = try makeSharedLedger(context: context)
        let remoteRecord = try #require(
            CloudLedgerRecordMapper.transaction(legacyUndo, zoneID: sharedLedger.zoneID)
        )

        let result = try CloudLedgerMergeService(modelContext: context).merge(
            records: [remoteRecord],
            into: sharedLedger
        )
        let transactions = try context.fetch(FetchDescriptor<LedgerTransaction>())

        #expect(result.canonicalizedUndoTransactions == 1)
        #expect(transactions.count == 2)
        #expect(transactions.contains {
            $0.id == CloudLedgerTransactionIdentity.undo(reversing: original.id)
        })
        #expect(service.balance(for: child) == 0)
    }

    @Test func queueDrainSavesEveryChangeAndPersistsSyncedState() async throws {
        let container = try AppModelContainer.make(inMemory: true)
        let context = ModelContext(container)
        let sharedLedger = try makeSharedLedger(context: context)
        let service = LedgerService(modelContext: context)
        let child = try service.addChild(named: "Rebecca")
        try service.addTransaction(cents: 20, to: child)
        let transport = CloudLedgerQueueTransportStub(actions: [.save, .save])
        let now = Date(timeIntervalSinceReferenceDate: 500)

        let result = try await CloudLedgerQueueProcessor(modelContext: context).drain(
            sharedLedger: sharedLedger,
            transport: transport,
            now: now
        )
        let state = try #require(context.fetch(FetchDescriptor<CloudLedgerSyncState>()).first)
        let saveCount = await transport.saveCount

        #expect(result.savedChanges == 2)
        #expect(result.remainingChanges == 0)
        #expect(result.status == .synced)
        #expect(state.status == .synced)
        #expect(state.lastSuccessAt == now)
        #expect(try context.fetch(FetchDescriptor<PendingCloudChange>()).isEmpty)
        #expect(saveCount == 2)
    }

    @Test func queueRetryBackoffSurvivesStoreReopen() async throws {
        let storeURL = FileManager.default.temporaryDirectory
            .appending(path: "KidMoneyRetry-\(UUID().uuidString).store")
        defer {
            for suffix in ["", "-shm", "-wal"] {
                try? FileManager.default.removeItem(atPath: storeURL.path + suffix)
            }
        }
        let now = Date(timeIntervalSinceReferenceDate: 1_000)
        let householdID: UUID

        do {
            let container = try AppModelContainer.make(storeURL: storeURL)
            let context = ModelContext(container)
            let sharedLedger = try makeSharedLedger(context: context)
            householdID = sharedLedger.householdID
            _ = try LedgerService(modelContext: context).addChild(named: "Rebecca")
            let transport = CloudLedgerQueueTransportStub(actions: [
                .retry(after: nil, code: "network")
            ])

            let result = try await CloudLedgerQueueProcessor(modelContext: context).drain(
                sharedLedger: sharedLedger,
                transport: transport,
                now: now
            )
            let pending = try #require(
                context.fetch(FetchDescriptor<PendingCloudChange>()).first
            )
            let state = try #require(
                context.fetch(FetchDescriptor<CloudLedgerSyncState>()).first
            )

            #expect(result.status == .pending)
            #expect(pending.attemptCount == 1)
            #expect(pending.lastErrorCode == "network")
            #expect(state.nextRetryAt == now.addingTimeInterval(5))
        }

        do {
            let container = try AppModelContainer.make(storeURL: storeURL)
            let context = ModelContext(container)
            let sharedLedger = try #require(
                context.fetch(FetchDescriptor<SharedLedgerState>()).first {
                    $0.householdID == householdID
                }
            )
            let transport = CloudLedgerQueueTransportStub(actions: [.save])
            let early = try await CloudLedgerQueueProcessor(modelContext: context).drain(
                sharedLedger: sharedLedger,
                transport: transport,
                now: now.addingTimeInterval(4)
            )
            let earlySaveCount = await transport.saveCount
            #expect(early.remainingChanges == 1)
            #expect(earlySaveCount == 0)

            let completed = try await CloudLedgerQueueProcessor(modelContext: context).drain(
                sharedLedger: sharedLedger,
                transport: transport,
                now: now.addingTimeInterval(5)
            )
            let completedSaveCount = await transport.saveCount
            #expect(completed.status == .synced)
            #expect(completed.remainingChanges == 0)
            #expect(completedSaveCount == 1)
        }
    }

    @Test func restrictedAccountStopsSyncAndSharedMutations() async throws {
        let container = try AppModelContainer.make(inMemory: true)
        let context = ModelContext(container)
        let sharedLedger = try makeSharedLedger(context: context)
        let service = LedgerService(modelContext: context)
        let child = try service.addChild(named: "Rebecca")
        let transport = CloudLedgerQueueTransportStub(
            accountState: .restricted,
            actions: []
        )

        let result = try await CloudLedgerQueueProcessor(modelContext: context).drain(
            sharedLedger: sharedLedger,
            transport: transport
        )
        let saveCount = await transport.saveCount

        #expect(result.status == .attentionRequired)
        #expect(sharedLedger.phase == .attentionRequired)
        #expect(throws: LedgerError.sharedLedgerUnavailable) {
            try service.addTransaction(cents: 10, to: child)
        }
        #expect(saveCount == 0)
    }

    @Test func serverWinningChildConflictUpdatesLocalAndCompletesChange() async throws {
        let container = try AppModelContainer.make(inMemory: true)
        let context = ModelContext(container)
        let sharedLedger = try makeSharedLedger(context: context)
        let child = try LedgerService(modelContext: context).addChild(named: "Rebecca")
        child.lastModifiedAt = Date(timeIntervalSinceReferenceDate: 10)
        try context.save()
        let serverChild = Child(
            id: child.id,
            name: "Becca",
            createdAt: child.createdAt,
            sortOrder: child.sortOrder
        )
        serverChild.lastModifiedAt = Date(timeIntervalSinceReferenceDate: 20)
        let serverRecord = CloudLedgerRecordMapper.child(
            serverChild,
            zoneID: sharedLedger.zoneID
        )
        let transport = CloudLedgerQueueTransportStub(actions: [.conflict(serverRecord)])

        let result = try await CloudLedgerQueueProcessor(modelContext: context).drain(
            sharedLedger: sharedLedger,
            transport: transport
        )
        let saveCount = await transport.saveCount

        #expect(result.resolvedConflicts == 1)
        #expect(result.remainingChanges == 0)
        #expect(child.name == "Becca")
        #expect(saveCount == 1)
    }

    @Test func localWinningChildConflictRetriesUsingServerRecord() async throws {
        let container = try AppModelContainer.make(inMemory: true)
        let context = ModelContext(container)
        let sharedLedger = try makeSharedLedger(context: context)
        let child = try LedgerService(modelContext: context).addChild(named: "Rebecca")
        child.lastModifiedAt = Date(timeIntervalSinceReferenceDate: 20)
        try context.save()
        let serverChild = Child(
            id: child.id,
            name: "Older Name",
            createdAt: child.createdAt,
            sortOrder: child.sortOrder
        )
        serverChild.lastModifiedAt = Date(timeIntervalSinceReferenceDate: 10)
        let serverRecord = CloudLedgerRecordMapper.child(
            serverChild,
            zoneID: sharedLedger.zoneID
        )
        let transport = CloudLedgerQueueTransportStub(actions: [
            .conflict(serverRecord),
            .save
        ])

        let result = try await CloudLedgerQueueProcessor(modelContext: context).drain(
            sharedLedger: sharedLedger,
            transport: transport
        )
        let received = await transport.receivedRecords
        let retriedChild = try CloudLedgerRecordDecoder.child(try #require(received.last))

        #expect(result.resolvedConflicts == 1)
        #expect(result.savedChanges == 1)
        #expect(result.remainingChanges == 0)
        #expect(received.count == 2)
        #expect(retriedChild.name == "Rebecca")
        #expect(retriedChild.lastModifiedAt == child.lastModifiedAt)
    }

    @Test func immutableQueueConflictRequiresAttentionAndPreservesChange() async throws {
        let container = try AppModelContainer.make(inMemory: true)
        let context = ModelContext(container)
        let service = LedgerService(modelContext: context)
        let child = try service.addChild(named: "Rebecca")
        let transaction = try service.addTransaction(cents: 10, to: child)
        let sharedLedger = try makeSharedLedger(context: context)
        let recordName = CloudLedgerRecordName.transaction(
            id: transaction.id,
            reversesTransactionID: nil
        )
        context.insert(PendingCloudChange(
            householdID: sharedLedger.householdID,
            operation: .save,
            recordType: .ledgerTransaction,
            recordName: recordName
        ))
        try context.save()
        let serverRecord = try #require(
            CloudLedgerRecordMapper.transaction(transaction, zoneID: sharedLedger.zoneID)
        )
        serverRecord[CloudLedgerSchema.Field.amountCents] = NSNumber(value: 20)
        let transport = CloudLedgerQueueTransportStub(actions: [.conflict(serverRecord)])

        await #expect(throws: CloudLedgerQueueProcessorError.immutableConflict(transaction.id)) {
            try await CloudLedgerQueueProcessor(modelContext: context).drain(
                sharedLedger: sharedLedger,
                transport: transport
            )
        }

        #expect(sharedLedger.phase == .attentionRequired)
        #expect(try context.fetch(FetchDescriptor<PendingCloudChange>()).count == 1)
        let state = try #require(context.fetch(FetchDescriptor<CloudLedgerSyncState>()).first)
        #expect(state.status == .attentionRequired)
    }

    private func makeSharedLedger(context: ModelContext) throws -> SharedLedgerState {
        let householdID = UUID()
        let sharedLedger = SharedLedgerState(
            householdID: householdID,
            displayName: "Family Ledger",
            zoneName: "KidMoneyHousehold-\(householdID.uuidString)",
            zoneOwnerName: CKCurrentUserDefaultName,
            role: .owner,
            databaseScope: .privateDatabase,
            phase: .active,
            createdAt: Date(timeIntervalSinceReferenceDate: 1)
        )
        context.insert(sharedLedger)
        try context.save()
        return sharedLedger
    }
}

private enum CloudLedgerQueueTransportStubAction: @unchecked Sendable {
    case save
    case conflict(CKRecord)
    case retry(after: TimeInterval?, code: String)
    case attention(code: String)
}

private actor CloudLedgerQueueTransportStub: CloudLedgerQueueTransport {
    let configuredAccountState: CloudLedgerTransportAccountState
    var actions: [CloudLedgerQueueTransportStubAction]
    var receivedRecords: [CKRecord] = []

    init(
        accountState: CloudLedgerTransportAccountState = .available,
        actions: [CloudLedgerQueueTransportStubAction]
    ) {
        self.configuredAccountState = accountState
        self.actions = actions
    }

    var saveCount: Int { receivedRecords.count }

    func accountState() async -> CloudLedgerTransportAccountState {
        configuredAccountState
    }

    func save(_ record: CKRecord) async -> CloudLedgerTransportSaveResult {
        receivedRecords.append(record)
        guard !actions.isEmpty else {
            return .attentionRequired(code: "unexpected-save")
        }
        switch actions.removeFirst() {
        case .save: return .saved(record)
        case .conflict(let serverRecord): return .conflict(serverRecord)
        case .retry(let retryAfter, let code): return .retry(after: retryAfter, code: code)
        case .attention(let code): return .attentionRequired(code: code)
        }
    }
}
