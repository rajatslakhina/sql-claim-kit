import XCTest
@testable import SQLClaimKit

private let users = """
CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT NOT NULL, email TEXT, team_id INTEGER, score REAL);
INSERT INTO users VALUES
  (1, 'Ann', 'ann@example.com', 1, 9.5),
  (2, 'bob', NULL, 2, NULL),
  (3, 'Cy', NULL, NULL, 7.0);
CREATE TABLE teams (id INTEGER PRIMARY KEY, name TEXT);
INSERT INTO teams VALUES (1, 'Core'), (2, 'Apps'), (3, 'Data');
"""

private func answer(_ query: String, _ shown: String, lead: String = "") -> String {
    lead + "```sql\n" + users + "\n" + query + "\n```\n" + shown
}

final class EvaluatorTests: XCTestCase {
    private func finding(_ text: String, policy: SQLPolicy = .standard) throws -> SQLFinding {
        let findings = SQLClaimChecker(policy: policy).check(text).findings
        return try XCTUnwrap(findings.last)
    }

    func testResultsThatHold() throws {
        let exact = try finding(answer("SELECT name FROM users ORDER BY id;", "| name |\n|---|\n| Ann |\n| bob |\n| Cy |"))
        XCTAssertEqual(exact.outcome, .exact)
        XCTAssertEqual(exact.explanation, "`SELECT name FROM users ORDER BY id;` holds.")
        let unordered = try finding(answer("SELECT name FROM users;", "| name |\n|---|\n| Cy |\n| Ann |\n| bob |"))
        XCTAssertEqual(unordered.outcome, .equivalent, "no ORDER BY, so any order holds")
        let rounded = try finding(answer("SELECT score FROM users WHERE id = 1;", "| score |\n|---|\n| 9.50 |"))
        XCTAssertEqual(rounded.outcome, .equivalent)
        XCTAssertEqual(try finding(answer("SELECT count(*) FROM users;", "This returns one row.")).outcome, .exact)
        let value = try finding("```sql\nSELECT 7 / 2.0; -- 3.5\n```")
        XCTAssertEqual(value.outcome, .exact)
        XCTAssertEqual(value.actual, "3.5")
    }

    func testTheUsualSlipsAreNamed() throws {
        let cases: [(String, String, SQLFinding.Slip)] = [
            ("SELECT name FROM users WHERE email = NULL;", "| name |\n|---|\n| bob |\n| Cy |", .nullComparison),
            ("SELECT count(email) FROM users;", "| count |\n|---|\n| 3 |", .countColumn),
            ("SELECT name FROM teams WHERE id NOT IN (SELECT team_id FROM users);", "| name |\n|---|\n| Data |",
             .notInNull),
            ("SELECT t.name, u.name FROM teams t LEFT JOIN users u ON u.team_id = t.id WHERE u.score > 5;",
             "| team | user |\n|---|---|\n| Core | Ann |\n| Apps | NULL |\n| Data | NULL |", .leftJoinFilter),
            ("SELECT id FROM users WHERE id BETWEEN 1 AND 3;", "| id |\n|---|\n| 2 |", .betweenInclusive)
        ]
        for (query, shown, slip) in cases {
            let result = try finding(answer(query, shown))
            XCTAssertEqual(result.outcome, .wrong(slip), query)
            XCTAssertEqual(result.slip, slip)
        }
        let null = try finding(answer("SELECT name FROM users WHERE email = NULL;", "| name |\n|---|\n| bob |"))
        XCTAssertEqual(null.explanation, "`SELECT name FROM users WHERE email = NULL;` returns no rows, not 1 row: "
            + "bob (= NULL is never true; use IS NULL or IS NOT NULL).")
        let plain = try finding(answer("SELECT name FROM users WHERE id = 1;", "| name |\n|---|\n| Bob |"))
        XCTAssertEqual(plain.outcome, .wrong(nil))
        XCTAssertNil(plain.slip)
        XCTAssertEqual(plain.explanation, "`SELECT name FROM users WHERE id = 1;` returns 1 row: Ann, not 1 row: Bob.")
    }

    func testEngineDependentResultsAreCaveatsUntilSQLiteIsNamed() throws {
        let division = "```sql\nSELECT 7 / 2; -- 3.5\n```"
        let caveat = try finding(division)
        XCTAssertEqual(caveat.outcome, .caveat(.engineDependent(.integerDivision)))
        XCTAssertEqual(caveat.slip, .integerDivision)
        XCTAssertEqual(caveat.explanation, "`SELECT 7 / 2;` gives 3 in SQLite, not 3.5; engines differ here (SQLite, "
            + "PostgreSQL and SQL Server divide two integers as integers, while MySQL's / returns a decimal), so name "
            + "the engine the answer is for.")
        let wrong = try finding("In SQLite:\n" + division)
        XCTAssertEqual(wrong.outcome, .wrong(.integerDivision))
        XCTAssertEqual(wrong.explanation, "`SELECT 7 / 2;` gives 3, not 3.5 (SQLite divides two integers as "
            + "integers; make one side a real, as in 7 / 2.0).")
        let like = answer("SELECT name FROM users WHERE name LIKE 'b%';", "This returns no rows.")
        XCTAssertEqual(try finding(like).outcome, .caveat(.engineDependent(.likeCase)))
        XCTAssertEqual(try finding("SQLite:\n" + like).outcome, .wrong(.likeCase))
        let concat = "```sql\nSELECT 'a' || 'b'; -- 1\n```"
        XCTAssertEqual(try finding(concat).outcome, .caveat(.engineDependent(.concatOperator)))
        let nulls = answer("SELECT score FROM users ORDER BY score;", "| score |\n|---|\n| 7.0 |\n| 9.5 |\n| NULL |")
        XCTAssertEqual(try finding(nulls).outcome, .caveat(.engineDependent(.nullOrdering)))
        XCTAssertEqual(try finding("In SQLite\n" + nulls).outcome, .wrong(.nullOrdering))
        XCTAssertEqual(SQLFinding.engineNote(.syntax), "engines differ on this")
    }

    func testOrderAndLimitCaveats() throws {
        let order = try finding(answer("SELECT name FROM users ORDER BY id DESC;",
                                       "| name |\n|---|\n| Ann |\n| bob |\n| Cy |"))
        XCTAssertEqual(order.outcome, .caveat(.rowOrder))
        XCTAssertTrue(order.explanation.hasSuffix("returns the rows shown in another order: 3 rows: Cy, bob, Ann; "
            + "rows that tie on the ORDER BY columns can come back in any order."))
        let limit = try finding(answer("SELECT name FROM users LIMIT 1;", "| name |\n|---|\n| Cy |"))
        XCTAssertEqual(limit.outcome, .caveat(.unorderedLimit))
        XCTAssertTrue(limit.explanation.contains("without ORDER BY, which rows LIMIT keeps is up to the engine"))
        let strict = try finding(answer("SELECT name FROM users;", "| name |\n|---|\n| Cy |\n| Ann |\n| bob |"),
                                 policy: .strict)
        XCTAssertEqual(strict.outcome, .caveat(.rowOrder))
        let lenient = try finding(answer("SELECT name FROM users LIMIT 1;", "| name |\n|---|\n| Cy |"), policy: .lenient)
        XCTAssertEqual(lenient.outcome, .unchecked("the result depends on something the answer leaves open"))
    }

    func testErrorsAndWhatTheyMean() throws {
        let column = try finding(answer("SELECT phone FROM users;", "| phone |\n|---|\n| 555 |"))
        XCTAssertEqual(column.outcome, .wrong(.missingColumn))
        XCTAssertEqual(column.explanation, "`SELECT phone FROM users;` raises an error in SQLite: no such column: "
            + "phone; the answer shows 1 row: 555 (the table as created has no such column).")
        let constraint = try finding(answer("INSERT INTO users (id) VALUES (9);", "This runs as is."))
        XCTAssertEqual(constraint.outcome, .wrong(.constraint))
        XCTAssertEqual(constraint.explanation, "The SQL said to run raises an error in SQLite: NOT NULL constraint "
            + "failed: users.name (the schema shown rejects the row).")
        let other = try finding("```sql\nSELECT max(1) FROM (SELECT 1) GROUP BY max(1);\n```")
        XCTAssertEqual(other.outcome, .wrong(.raises))
        XCTAssertEqual(other.explanation, "The SQL shown raises an error in SQLite: aggregate functions are not allowed "
            + "in the GROUP BY clause.")
        let syntax = try finding("```sql\nSELEC 1;\n```\nThis runs as is.")
        XCTAssertEqual(syntax.outcome, .caveat(.otherSyntax))
        XCTAssertEqual(syntax.explanation, "`SELEC 1;` does not parse in SQLite (near \"SELEC\": syntax error); if it "
            + "is meant for another engine, name it.")
        XCTAssertEqual(try finding("SQLite:\n```sql\nSELEC 1;\n```").outcome, .wrong(.syntax))
        XCTAssertEqual(try finding("```sql\nSELEC 1;\n```\nThis fails with a syntax error.").outcome, .exact)
        let runs = try finding("```sql\nSELECT 1;\n```\nThis fails with an error.")
        XCTAssertEqual(runs.outcome, .wrong(.runs))
        XCTAssertEqual(runs.explanation, "The SQL said to fail runs without an error in SQLite.")
        let width = try finding(answer("SELECT id, name FROM users WHERE id = 1;", "| name |\n|---|\n| Ann |"))
        XCTAssertEqual(width.outcome, .wrong(.columnCount))
    }

    func testWhatCannotBeCheckedIsSaidSo() throws {
        let missing = try finding("```sql\nSELECT name FROM people;\n```\n| name |\n|---|\n| Ann |")
        XCTAssertEqual(missing.outcome, .unchecked("the answer does not create the table people"))
        XCTAssertEqual(missing.explanation, "`SELECT name FROM people;` was not checked: the answer does not create "
            + "the table people.")
        XCTAssertEqual(SQLClaimChecker().check("```sql\nSELECT name FROM people;\n```").findings, [],
                       "no schema, no claim")
        let function = try finding("```sql\nSELECT now(); -- 1\n```")
        XCTAssertEqual(function.outcome, .unchecked("the SQLite the checker runs has no function now"))
        XCTAssertEqual(try finding("SQLite:\n```sql\nSELECT date_trunc('month', 1); -- 1\n```").outcome, .wrong(.raises))
        let postgres = try finding("```postgresql\nSELECT 7 / 2; -- 3\n```")
        XCTAssertEqual(postgres.outcome, .unchecked("the answer is about PostgreSQL, and the checker runs SQLite"))
        let budget = try finding("```sql\nWITH RECURSIVE c(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM c) "
            + "SELECT count(*) FROM c; -- 9\n```")
        XCTAssertEqual(budget.outcome, .unchecked("it ran past the checker's step budget"))
        let nothing = try finding(answer("INSERT INTO teams VALUES (4, 'Ops');", "This returns one row."))
        XCTAssertEqual(nothing.outcome, .unchecked(SQLEvaluator.noRows))
        let claim = SQLClaim(kind: .result, script: [SQLStatement(text: "DELETE FROM t;", comments: [])], target: 0,
                             shown: .table(ShownTable(header: nil, rows: [["1"]])))
        let table = SQLEvaluator(policy: .standard).judge(claim)
        XCTAssertEqual(table.outcome, .unchecked("the answer does not create the table t"))
        let created = SQLClaim(kind: .result, script: SQLText.statements(in: "CREATE TABLE t (a); DELETE FROM t;"),
                               target: 1, shown: .table(ShownTable(header: nil, rows: [["1"]])))
        XCTAssertEqual(SQLEvaluator(policy: .standard).judge(created).outcome, .unchecked(SQLEvaluator.noRows))
        let closed = SQLEvaluator(policy: .standard, databasePath: "/nonexistent-dir-\(UUID().uuidString)/x.db")
        XCTAssertEqual(closed.judge(created).outcome, .unchecked("SQLite could not open a database"))
    }

    func testEarlierBlocksRunTheWayTheShellRunsAFile() throws {
        let text = "```sql\nCREATE TABLE t (a);\nINSERT INTO t VALUES (1), (2);\nSELEC oops;\n```\n\n"
            + "```sql\nSELECT count(*) FROM t; -- 2\n```"
        let report = SQLClaimChecker().check(text)
        XCTAssertEqual(report.findings.map(\.outcome), [.exact],
                       "the first block's syntax caveat is not kept, and its error does not stop the second block")
        let named = SQLClaimChecker().check("SQLite:\n" + text)
        XCTAssertEqual(named.findings.map(\.outcome), [.wrong(.syntax), .exact])
        XCTAssertEqual(named.findings[0].explanation, "The SQL shown raises an error in SQLite: near \"SELEC\": "
            + "syntax error.")
        let quiet = SQLClaimChecker().check("```sql\nSELECT * FROM t WHERE d > now() - interval '7 days';\n```")
        XCTAssertEqual(quiet.findings, [], "SQL that may be for another engine and claims nothing is left alone")
        let holds = SQLClaimChecker().check("```sql\nCREATE TABLE t (a);\n```")
        XCTAssertEqual(holds.summary, "1 claim checked, 1 hold")
    }

    func testDiagnosisLooksAtTheRightPlace() {
        let shape = SQLEvaluator.Shape(shown: 1, actual: 1, shownCells: [["2.5", "x"]], actualCells: [[.text("2"), .text("x")]])
        XCTAssertFalse(Diagnosis.integerShownAsDecimal(shape))
        XCTAssertNil(Diagnosis.slip("SELECT a / b FROM t", shape: shape))
        XCTAssertNil(Diagnosis.slip("SELECT * FROM t WHERE a NOT IN (1)", shape: SQLEvaluator.Shape(shown: 1, actual: 2)))
    }
}
