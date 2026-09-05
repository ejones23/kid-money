import Foundation
import SwiftData

@Model
final class Child {
    @Attribute(.unique) var id: UUID
    var name: String
    var createdAt: Date
    var sortOrder: Int
    var isArchived: Bool

    @Relationship(deleteRule: .cascade, inverse: \LedgerTransaction.child)
    var transactions: [LedgerTransaction]

    init(
        id: UUID = UUID(),
        name: String,
        createdAt: Date = .now,
        sortOrder: Int,
        isArchived: Bool = false
    ) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.sortOrder = sortOrder
        self.isArchived = isArchived
        self.transactions = []
    }
}

@Model
final class LedgerTransaction {
    @Attribute(.unique) var id: UUID
    var amountCents: Int64
    var createdAt: Date
    var note: String?
    var sourceRawValue: String
    var child: Child?

    init(
        id: UUID = UUID(),
        amountCents: Int64,
        createdAt: Date = .now,
        note: String? = nil,
        source: TransactionSource,
        child: Child
    ) {
        self.id = id
        self.amountCents = amountCents
        self.createdAt = createdAt
        self.note = note
        self.sourceRawValue = source.rawValue
        self.child = child
    }

    var source: TransactionSource {
        TransactionSource(rawValue: sourceRawValue) ?? .manual
    }
}

enum TransactionSource: String, Codable, CaseIterable {
    case manual
    case siri
}

