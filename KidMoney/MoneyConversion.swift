import Foundation

enum MoneyConversionError: LocalizedError, Equatable, Sendable {
    case unsupportedCurrency(String)
    case amountMustBePositive
    case fractionalCent
    case amountOutOfRange

    var errorDescription: String? {
        switch self {
        case .unsupportedCurrency:
            "Kid Money currently supports US dollars only."
        case .amountMustBePositive:
            "The amount must be greater than zero."
        case .fractionalCent:
            "The amount must be an exact number of cents."
        case .amountOutOfRange:
            "That amount is too large for Kid Money."
        }
    }
}

enum MoneyConversion {
    static func usdCents(from amount: Decimal, currencyCode: String) throws -> Int64 {
        guard currencyCode.caseInsensitiveCompare("USD") == .orderedSame else {
            throw MoneyConversionError.unsupportedCurrency(currencyCode)
        }
        guard amount > 0 else {
            throw MoneyConversionError.amountMustBePositive
        }

        var source = amount
        var cents = Decimal()
        let calculation = NSDecimalMultiplyByPowerOf10(&cents, &source, 2, .plain)
        guard calculation == .noError else {
            throw MoneyConversionError.amountOutOfRange
        }

        var wholeCents = Decimal()
        NSDecimalRound(&wholeCents, &cents, 0, .plain)
        guard wholeCents == cents else {
            throw MoneyConversionError.fractionalCent
        }
        guard wholeCents <= Decimal(Int64.max) else {
            throw MoneyConversionError.amountOutOfRange
        }

        return NSDecimalNumber(decimal: wholeCents).int64Value
    }
}
