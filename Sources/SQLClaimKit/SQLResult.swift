/// The rows one statement returned.
public struct SQLResult: Sendable, Hashable {
    public let columns: [String]
    public let rows: [[SQLValue]]

    public init(columns: [String], rows: [[SQLValue]]) {
        self.columns = columns
        self.rows = rows
    }

    /// The rows, short: `no rows`, `1 row: Alice`, `3 rows: (1, Ann), (2, Bob), (3, NULL)`.
    public var rendered: String {
        Self.describe(rows.map { $0.map(\.rendered) })
    }

    static func describe(_ rows: [[String]]) -> String {
        switch rows.count {
        case 0: return "no rows"
        case 1: return "1 row: " + row(rows[0])
        default:
            let shown = rows.prefix(4).map(row).joined(separator: ", ")
            return "\(rows.count) rows: " + shown + (rows.count > 4 ? ", ..." : "")
        }
    }

    static func row(_ cells: [String]) -> String {
        cells.count == 1 ? cells[0] : "(" + cells.joined(separator: ", ") + ")"
    }

    var hasNull: Bool {
        rows.contains { $0.contains(where: \.isNull) }
    }
}
