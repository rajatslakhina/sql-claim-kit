import Foundation

/// Runs a claim's script in a fresh sandbox and judges what comes out against what the answer shows.
struct SQLEvaluator: Sendable {
    let policy: SQLPolicy
    var databasePath = ":memory:"

    func judge(_ claim: SQLClaim) -> SQLFinding {
        guard claim.dialect.runsInSQLite else {
            return SQLFinding(claim: claim, outcome: .unchecked(
                "the answer is about \(claim.dialect.name), and the checker runs SQLite"
            ))
        }
        guard let sandbox = SQLiteSandbox(path: databasePath) else {
            return SQLFinding(claim: claim, outcome: .unchecked("SQLite could not open a database"))
        }
        let run = sandbox.run(claim.script.map(\.text), from: claim.blockStart)
        if let failure = run.failure {
            return judge(claim, failure: failure)
        }
        let result = run.results[claim.target]
        switch claim.shown {
        case let .runs(runs):
            return SQLFinding(claim: claim, outcome: runs ? .exact : .wrong(.runs))
        case let .count(count):
            guard let result else { return SQLFinding(claim: claim, outcome: .unchecked(Self.noRows)) }
            if result.rows.count == count { return SQLFinding(claim: claim, outcome: .exact, actual: result.rendered) }
            let shape = Shape(shown: count, actual: result.rows.count)
            return mismatch(claim, slip: Diagnosis.slip(claim.statement, shape: shape), actual: result.rendered)
        case let .table(table):
            guard let result else { return SQLFinding(claim: claim, outcome: .unchecked(Self.noRows)) }
            return compare(claim, table: table, result: result)
        }
    }

    static let noRows = "the statement returns no rows to compare"

    struct Shape {
        let shown: Int
        let actual: Int
        var shownCells: [[String]] = []
        var actualCells: [[SQLValue]] = []
    }

    private func judge(_ claim: SQLClaim, failure: SQLFailure) -> SQLFinding {
        if failure.isOutsideTheAnswer {
            if case .missingFunction = failure, claim.dialect == .sqlite {
                return SQLFinding(claim: claim, outcome: .wrong(.raises), failure: failure)
            }
            return SQLFinding(claim: claim, outcome: .unchecked(Self.reason(failure)), failure: failure)
        }
        if claim.shown == .runs(false) {
            return SQLFinding(claim: claim, outcome: .exact, failure: failure)
        }
        let slip: SQLFinding.Slip = switch failure {
        case .missingColumn: .missingColumn
        case .constraint: .constraint
        case .syntax: .syntax
        default: .raises
        }
        if slip == .syntax, claim.dialect == .unnamed {
            return reported(SQLFinding(claim: claim, outcome: .caveat(.otherSyntax), failure: failure))
        }
        return SQLFinding(claim: claim, outcome: .wrong(slip), failure: failure)
    }

    static func reason(_ failure: SQLFailure) -> String {
        switch failure {
        case let .missingTable(name): "the answer does not create the table \(name)"
        case let .missingFunction(name): "the SQLite the checker runs has no function \(name)"
        default: failure.message
        }
    }

    private func compare(_ claim: SQLClaim, table: ShownTable, result: SQLResult) -> SQLFinding {
        let actual = claim.kind == .value && result.rows.count == 1
            ? SQLResult.row(result.rows[0].map(\.rendered)) : result.rendered
        guard table.width == result.columns.count else {
            return SQLFinding(claim: claim, outcome: .wrong(.columnCount), actual: actual)
        }
        let ordered = policy.ordersRows || SQLText.hasTopLevel("ORDER BY", in: claim.statement)
        let inOrder = table.rows.count == result.rows.count
            && zip(table.rows, result.rows).allSatisfy { Self.matches($0, $1) }
        if inOrder {
            let exact = zip(table.rows, result.rows).allSatisfy { shown, row in
                zip(shown, row).allSatisfy { $0 == $1.rendered }
            }
            return SQLFinding(claim: claim, outcome: exact ? .exact : .equivalent, actual: actual)
        }
        let sameRows = Self.sameMultiset(table.rows, result.rows)
        if sameRows, !ordered {
            return SQLFinding(claim: claim, outcome: .equivalent, actual: actual)
        }
        if sameRows {
            let slip: SQLFinding.Slip? = result.hasNull && SQLText.hasTopLevel("ORDER BY", in: claim.statement)
                ? .nullOrdering : nil
            guard let slip else {
                return reported(SQLFinding(claim: claim, outcome: .caveat(.rowOrder), actual: actual))
            }
            return mismatch(claim, slip: slip, actual: actual)
        }
        if SQLText.hasTopLevel("LIMIT", in: claim.statement), !ordered {
            return reported(SQLFinding(claim: claim, outcome: .caveat(.unorderedLimit), actual: actual))
        }
        let shape = Shape(shown: table.rows.count, actual: result.rows.count,
                          shownCells: table.rows, actualCells: result.rows)
        return mismatch(claim, slip: Diagnosis.slip(claim.statement, shape: shape), actual: actual)
    }

    private func mismatch(_ claim: SQLClaim, slip: SQLFinding.Slip?, actual: String) -> SQLFinding {
        if let slip, Diagnosis.engineDependent.contains(slip), claim.dialect == .unnamed {
            return reported(SQLFinding(claim: claim, outcome: .caveat(.engineDependent(slip)), actual: actual))
        }
        return SQLFinding(claim: claim, outcome: .wrong(slip), actual: actual)
    }

    /// A caveat as it is reported under the policy: as is, or as unchecked when caveats are let through.
    private func reported(_ finding: SQLFinding) -> SQLFinding {
        guard !policy.reportsCaveats else { return finding }
        let reason = "the result depends on something the answer leaves open"
        return SQLFinding(claim: finding.claim, outcome: .unchecked(reason), actual: finding.actual,
                          failure: finding.failure)
    }

    static func matches(_ shown: [String], _ row: [SQLValue]) -> Bool {
        shown.count == row.count && zip(row, shown).allSatisfy { $0.matches($1) }
    }

    static func sameMultiset(_ shown: [[String]], _ rows: [[SQLValue]]) -> Bool {
        guard shown.count == rows.count else { return false }
        var unused = rows
        for cells in shown {
            guard let index = unused.firstIndex(where: { matches(cells, $0) }) else { return false }
            unused.remove(at: index)
        }
        return true
    }
}

/// Names the usual slip behind a result that does not match, from the statement and the two results.
enum Diagnosis {
    /// Slips on which engines disagree: with no engine named, these are caveats, not mistakes.
    static let engineDependent: Set<SQLFinding.Slip> = [
        .integerDivision, .nullOrdering, .likeCase, .concatOperator
    ]

    static func slip(_ statement: String, shape: SQLEvaluator.Shape) -> SQLFinding.Slip? {
        let upper = SQLText.stripped(statement)
        func has(_ pattern: String) -> Bool {
            upper.range(of: pattern, options: .regularExpression) != nil
        }
        let fewer = shape.actual < shape.shown
        let more = shape.actual > shape.shown
        if has(#"(=|<>|!=)\s*NULL\b"#) { return .nullComparison }
        if upper.contains("/"), integerShownAsDecimal(shape) { return .integerDivision }
        if has(#"\bCOUNT\s*\(\s*(DISTINCT\s+)?[A-Z_"`\[]"#) { return .countColumn }
        if has(#"\bNOT\s+IN\b"#), fewer { return .notInNull }
        if has(#"\bLEFT\s+(OUTER\s+)?JOIN\b"#), SQLText.hasTopLevel("WHERE", in: statement), fewer {
            return .leftJoinFilter
        }
        if has(#"\bBETWEEN\b"#), more { return .betweenInclusive }
        if has(#"\bLIKE\b"#), more { return .likeCase }
        if upper.contains("||") { return .concatOperator }
        return nil
    }

    /// Whether a cell shows a decimal where SQLite returned an integer in the same place.
    static func integerShownAsDecimal(_ shape: SQLEvaluator.Shape) -> Bool {
        zip(shape.shownCells, shape.actualCells).contains { shown, row in
            zip(shown, row).contains { cell, value in
                guard case .integer = value, let number = SQLValue.number(cell) else { return false }
                return number != number.rounded()
            }
        }
    }
}
