/// What checking one claim came to.
public struct SQLFinding: Sendable, Hashable {
    public enum Outcome: Sendable, Hashable {
        /// SQLite gives exactly what the answer shows.
        case exact
        /// The same values written another way: `2.50` for 2.5, `true` for 1, rows in another order where
        /// the query does not fix one.
        case equivalent
        /// Not checked, with the reason.
        case unchecked(String)
        /// Holds or not depending on something the answer leaves open.
        case caveat(Caveat)
        /// Does not hold; the slip behind it when it can be named.
        case wrong(Slip?)
    }

    public enum Caveat: Sendable, Hashable {
        /// SQLite gives something else, and engines differ on exactly this point.
        case engineDependent(Slip)
        /// Different rows than shown, from a `LIMIT` with no `ORDER BY`.
        case unorderedLimit
        /// The rows shown, in a different order; rows that tie on the `ORDER BY` columns may come back in
        /// any order.
        case rowOrder
        /// SQLite cannot parse it, and no engine is named, so another engine may accept it.
        case otherSyntax
    }

    public enum Slip: String, Sendable, Hashable, CaseIterable {
        /// `= NULL` or `<> NULL`, which is never true.
        case nullComparison
        /// Two integers divided as integers.
        case integerDivision
        /// `COUNT(column)` taken to count rows where the column is NULL.
        case countColumn
        /// `NOT IN` over a list or subquery that holds a NULL.
        case notInNull
        /// A `WHERE` condition on the right table of a `LEFT JOIN`, which drops the unmatched rows.
        case leftJoinFilter
        /// NULLs placed last in an ascending sort.
        case nullOrdering
        /// `LIKE` taken to be case-sensitive.
        case likeCase
        /// `BETWEEN` taken to leave out its ends.
        case betweenInclusive
        /// `||` read as string concatenation where an engine reads it as OR.
        case concatOperator
        /// A column the schema shown does not have.
        case missingColumn
        /// A constraint in the schema shown rejects a row.
        case constraint
        /// SQLite cannot parse the SQL.
        case syntax
        /// The output has a different number of columns than the query returns.
        case columnCount
        /// The SQL raises an error where the answer shows a result.
        case raises
        /// The SQL said to fail runs.
        case runs
    }

    public enum Severity: Int, Sendable, Hashable, Comparable {
        case holds
        case unchecked
        case caution
        case wrong

        public static func < (lhs: Severity, rhs: Severity) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    public let claim: SQLClaim
    public let outcome: Outcome
    /// What SQLite returned, in words, when it ran.
    public var actual: String? { actualText.isEmpty ? nil : actualText }
    /// The error SQLite raised, when it raised one.
    public let failure: SQLFailure?
    let actualText: String
    /// SQLite's message for `failure`, or empty.
    let detail: String
    /// Flagged in an earlier review of the same conversation (set by `SQLLedger`).
    public internal(set) var isRepeated = false

    init(claim: SQLClaim, outcome: Outcome, actual: String? = nil, failure: SQLFailure? = nil) {
        self.claim = claim
        self.outcome = outcome
        actualText = actual ?? ""
        self.failure = failure
        detail = failure?.message ?? ""
    }

    public var severity: Severity {
        switch outcome {
        case .exact, .equivalent: .holds
        case .unchecked: .unchecked
        case .caveat: .caution
        case .wrong: .wrong
        }
    }

    /// The slip behind a wrong finding or an engine-dependent caveat.
    public var slip: Slip? {
        switch outcome {
        case let .wrong(slip): slip
        case let .caveat(.engineDependent(slip)): slip
        default: nil
        }
    }

    /// Identifies the same claim across rewrites.
    var key: String {
        "\(claim.kind)|\(SQLClaim.shortened(claim.statement, limit: 500))|\(claim.claimed)".lowercased()
    }
}
