import Foundation

enum MoneyFormatter {
    static func string(cents: Int64, locale: Locale = .current) -> String {
        let amount = Decimal(cents) / 100
        return amount.formatted(.currency(code: "USD").locale(locale))
    }

    static func absoluteString(cents: Int64, locale: Locale = .current) -> String {
        let signedAmount = Decimal(cents)
        let amount = (signedAmount < 0 ? -signedAmount : signedAmount) / 100
        return amount.formatted(.currency(code: "USD").locale(locale))
    }
}
