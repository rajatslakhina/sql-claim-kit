import Foundation

/// One value SQLite returned, in the storage class it came back with.
public enum SQLValue: Sendable, Hashable {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob([UInt8])

    /// The value as the `sqlite3` shell prints it: `NULL`, `3`, `2.5`, `Alice`, `X'00FF'`.
    public var rendered: String {
        switch self {
        case .null: "NULL"
        case let .integer(value): String(value)
        case let .real(value): Self.render(value)
        case let .text(value): value
        case let .blob(bytes): "X'" + bytes.map { String(format: "%02X", $0) }.joined() + "'"
        }
    }

    static func render(_ value: Double) -> String {
        if value == value.rounded(), abs(value) < 1e15 {
            return String(Int64(value)) + ".0"
        }
        return String(value)
    }

    var isNull: Bool { self == .null }

    /// Whether a cell an answer shows means this value, allowing for the ways output is usually written:
    /// quotes around text, `NULL` written as `null` or left empty, `t`/`true` for 1, and a real shown
    /// rounded to the decimals the answer gives.
    func matches(_ shown: String) -> Bool {
        let cell = Self.unquoted(shown.trimmingCharacters(in: .whitespaces))
        switch self {
        case .null:
            return Self.nullWords.contains(cell.lowercased())
        case let .integer(value):
            if let bool = Self.booleans[cell.lowercased()] { return bool == value }
            return Self.number(cell).map { $0 == Double(value) } == true
        case let .real(value):
            guard let number = Self.number(cell) else { return false }
            if number == value { return true }
            let places = Self.decimalPlaces(cell)
            let scale = pow(10, Double(places))
            return (value * scale).rounded() / scale == number
        case let .text(value):
            return cell == value
        case .blob:
            return cell.uppercased() == rendered
        }
    }

    static let nullWords: Set<String> = ["null", "(null)", "none", "nil", ""]
    static let booleans: [String: Int64] = ["true": 1, "false": 0, "t": 1, "f": 0]

    static func unquoted(_ text: String) -> String {
        guard text.count >= 2, let first = text.first, first == text.last, first == "'" || first == "\"" else {
            return text
        }
        return String(text.dropFirst().dropLast())
    }

    static func number(_ text: String) -> Double? {
        let digits = text.replacingOccurrences(of: ",", with: "")
        guard digits.range(of: #"^[-+]?(\d+\.?\d*|\.\d+)([eE][-+]?\d+)?$"#, options: .regularExpression) != nil else {
            return nil
        }
        return Double(digits)
    }

    static func decimalPlaces(_ text: String) -> Int {
        guard let dot = text.firstIndex(of: ".") else { return 0 }
        return text[text.index(after: dot)...].prefix { $0.isNumber }.count
    }
}
