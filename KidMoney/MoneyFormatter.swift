import Foundation

enum MoneyFormatter {
    static func string(cents: Int64, locale: Locale = .current) -> String {
        let amount = Decimal(cents) / 100
        return amount.formatted(.currency(code: "USD").locale(locale))
    }
}

