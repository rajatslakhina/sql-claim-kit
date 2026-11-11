extension SQLFinding {
    static let hints: [Slip: String] = [
        .nullComparison: "= NULL is never true; use IS NULL or IS NOT NULL",
        .integerDivision: "SQLite divides two integers as integers; make one side a real, as in 7 / 2.0",
        .countColumn: "COUNT(column) skips NULLs; COUNT(*) counts every row",
        .notInNull: "NOT IN finds nothing when the list or subquery holds a NULL; use NOT EXISTS, or leave the "
            + "NULLs out",
        .leftJoinFilter: "a WHERE condition on the right table of a LEFT JOIN drops the rows with no match; move "
            + "it into the ON clause",
        .nullOrdering: "SQLite sorts NULLs first in ascending order; add NULLS LAST to put them at the end",
        .likeCase: "SQLite's LIKE ignores case for ASCII letters; use GLOB for a case-sensitive match",
        .betweenInclusive: "BETWEEN includes both ends",
        .concatOperator: "|| joins strings in SQLite",
        .missingColumn: "the table as created has no such column",
        .constraint: "the schema shown rejects the row",
        .columnCount: "the output shown has a different number of columns than the query returns"
    ]

    /// What engines do differently for a slip they disagree on.
    static func engineNote(_ slip: Slip) -> String {
        switch slip {
        case .integerDivision:
            "SQLite, PostgreSQL and SQL Server divide two integers as integers, while MySQL's / returns a decimal"
        case .nullOrdering: "SQLite and MySQL sort NULLs first in ascending order, PostgreSQL and Oracle last"
        case .likeCase: "LIKE ignores case in SQLite and with MySQL's default collations, and not in PostgreSQL"
        case .concatOperator: "|| joins strings in SQLite and PostgreSQL, while MySQL reads it as OR by default"
        default: "engines differ on this"
        }
    }

    /// One sentence saying what is wrong or what to look at; a holding claim gets a short confirmation.
    public var explanation: String {
        let subject = Self.quoted(claim.statement)
        switch outcome {
        case .exact, .equivalent:
            return "\(subject) holds."
        case let .unchecked(reason):
            return "\(subject) was not checked: \(reason)."
        case let .caveat(caveat):
            return caveatSentence(caveat, subject: subject)
        case let .wrong(slip):
            return wrongSentence(slip, subject: subject)
        }
    }

    static func quoted(_ text: String) -> String {
        "`" + SQLClaim.shortened(text).replacingOccurrences(of: "`", with: "'") + "`"
    }

    func caveatSentence(_ caveat: Caveat, subject: String) -> String {
        let actual = actualText
        switch caveat {
        case let .engineDependent(slip):
            return "\(subject) gives \(actual) in SQLite, not \(claim.claimed); engines differ here ("
                + Self.engineNote(slip) + "), so name the engine the answer is for."
        case .unorderedLimit:
            return "\(subject) returns \(actual) in SQLite, not \(claim.claimed); without ORDER BY, which rows "
                + "LIMIT keeps is up to the engine, so add an ORDER BY."
        case .rowOrder:
            return "\(subject) returns the rows shown in another order: \(actual); rows that tie on the ORDER BY "
                + "columns can come back in any order."
        case let .doubleQuotedText(name):
            return "\(subject) uses \"\(name)\" as text, but double quotes mark a column name in SQL; this SQLite "
                + "reads it as a missing column (some builds fall back to text, other engines do not), so write "
                + "'\(name)'."
        case .otherSyntax:
            return "\(subject) does not parse in SQLite (\(detail)); if it is meant for another "
                + "engine, name it."
        }
    }

    func wrongSentence(_ slip: Slip?, subject: String) -> String {
        let hint = slip.flatMap { Self.hints[$0] }.map { " (\($0))" } ?? ""
        if case .runs(true) = claim.shown {
            let what = claim.isExplicit ? "The SQL said to run" : "The SQL shown"
            return "\(what) raises an error in SQLite: \(detail)\(hint)."
        }
        if case .runs(false) = claim.shown {
            return "The SQL said to fail runs without an error in SQLite."
        }
        if failure != nil {
            return "\(subject) raises an error in SQLite: \(detail); the answer shows "
                + "\(claim.claimed)\(hint)."
        }
        let verb = claim.kind == .value ? "gives" : "returns"
        return "\(subject) \(verb) \(actualText), not \(claim.claimed)\(hint)."
    }
}
