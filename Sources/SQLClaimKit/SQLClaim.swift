/// One thing an answer says about SQL that can be checked by running it.
public struct SQLClaim: Sendable, Hashable {
    public enum Kind: String, Sendable, Hashable, CaseIterable {
        /// A table of output shown for a query.
        case result
        /// "This returns 3 rows."
        case rowCount
        /// A value written in a comment after a query: `SELECT 7 / 2;  -- 3.5`.
        case value
        /// That the SQL runs, or that it fails: said in words, or implied by showing it.
        case runs
    }

    /// What the answer says comes out.
    public enum Shown: Sendable, Hashable {
        case table(ShownTable)
        case count(Int)
        case runs(Bool)
    }

    public let kind: Kind
    /// Every statement of the answer's SQL blocks up to the one the claim is about, in order.
    public let script: [SQLStatement]
    /// The statement the claim is about (an index into `script`).
    public let target: Int
    /// Where the claim's own block starts in `script`. Earlier blocks run the way the `sqlite3` shell runs a
    /// file: a statement that fails is reported there and the next one still runs.
    public let blockStart: Int
    public let shown: Shown
    /// Said in words or shown as output (`true`), or only implied by showing SQL (`false`).
    public let isExplicit: Bool
    public let dialect: SQLDialect

    public init(
        kind: Kind,
        script: [SQLStatement],
        target: Int,
        blockStart: Int = 0,
        shown: Shown,
        isExplicit: Bool = true,
        dialect: SQLDialect = .unnamed
    ) {
        self.kind = kind
        self.script = script
        self.target = target
        self.blockStart = blockStart
        self.shown = shown
        self.isExplicit = isExplicit
        self.dialect = dialect
    }

    /// The statement the claim is about.
    public var statement: String {
        script[target].text
    }

    /// What the answer says comes out, in words.
    public var claimed: String {
        switch shown {
        case let .table(table): kind == .value && table.rows.count == 1 ? SQLResult.row(table.rows[0]) : table.rendered
        case let .count(count): count == 1 ? "1 row" : "\(count) rows"
        case let .runs(runs): runs ? "runs" : "raises an error"
        }
    }

    /// A one-line excerpt for logs and demos.
    public var excerpt: String {
        "\(kind.rawValue): \(Self.shortened(statement)) -> \(claimed)"
    }

    static func shortened(_ text: String, limit: Int = 90) -> String {
        let flat = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return flat.count > limit ? String(flat.prefix(limit - 4)) + " ..." : flat
    }
}
