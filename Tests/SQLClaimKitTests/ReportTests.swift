import XCTest
@testable import SQLClaimKit

final class ReportTests: XCTestCase {
    private let wrongAnswer = "In SQLite:\n```sql\nSELECT 7 / 2; -- 3.5\n```"
    private let fixedAnswer = "In SQLite:\n```sql\nSELECT 7 / 2.0; -- 3.5\n```"

    func testVerdictsSummariesNotesAndFeedback() {
        let checker = SQLClaimChecker()
        let none = checker.check("No SQL here.")
        XCTAssertEqual(none.verdict, .noClaims)
        XCTAssertEqual(none.summary, "no claims about SQL")
        XCTAssertNil(none.note)
        XCTAssertNil(none.feedback)
        XCTAssertEqual(checker.check(fixedAnswer).verdict, .verified)
        XCTAssertEqual(checker.check(fixedAnswer).summary, "1 claim checked, 1 hold")
        let unchecked = checker.check("```sql\nSELECT now(); -- 1\n```")
        XCTAssertEqual(unchecked.verdict, .unchecked)
        XCTAssertEqual(unchecked.summary, "1 claim checked, 0 hold, 1 unchecked")
        let caution = checker.check("```sql\nSELECT 7 / 2; -- 3.5\n```")
        XCTAssertEqual(caution.verdict, .caution)
        XCTAssertEqual(caution.summary, "1 claim checked, 0 hold, 1 to check")
        let wrong = checker.check(wrongAnswer + "\n```sql\nSELECT 1; -- 1\n```")
        XCTAssertEqual(wrong.verdict, .wrong)
        XCTAssertEqual(wrong.summary, "2 claims checked, 1 hold, 1 wrong")
        XCTAssertEqual(wrong.note, "SQL check: `SELECT 7 / 2;` gives 3, not 3.5 (SQLite divides two integers as "
            + "integers; make one side a real, as in 7 / 2.0).")
        XCTAssertEqual(wrong.feedback, "Some of what your answer says about its SQL does not hold:\n- `SELECT 7 / 2;` "
            + "gives 3, not 3.5 (SQLite divides two integers as integers; make one side a real, as in 7 / 2.0).\nRun "
            + "each query on the data the answer shows, correct the output and every statement that depends on it, "
            + "and keep the rest of the answer as it is.")
        XCTAssertEqual(checker.claims(in: wrongAnswer).count, 1)
        XCTAssertEqual(checker.judge(checker.claims(in: wrongAnswer)[0]).severity, .wrong)
        XCTAssertTrue(SQLFinding.Severity.holds < .wrong)
    }

    func testTheLedgerMarksRepeats() async {
        let ledger = SQLLedger()
        let first = await ledger.review(wrongAnswer)
        XCTAssertEqual(first.repeatedCount, 0)
        let again = await ledger.review(wrongAnswer)
        XCTAssertEqual(again.repeatedCount, 1)
        XCTAssertEqual(again.summary, "1 claim checked, 0 hold, 1 wrong, 1 repeated")
        XCTAssertTrue(again.note?.hasSuffix("Some of this was stated again after a correction was asked for.") == true)
        _ = await ledger.review(fixedAnswer)
        let statistics = await ledger.statistics
        XCTAssertEqual(statistics, SQLLedger.Statistics(reviews: 3, claims: 3, flagged: 2, repeated: 1))
        await ledger.forget()
        let fresh = await ledger.review(wrongAnswer)
        XCTAssertEqual(fresh.repeatedCount, 0)
        XCTAssertEqual(ledger.checker.policy, .standard)
    }

    func testClaimsDescribeThemselves() {
        let statement = SQLStatement(text: "SELECT 1;", comments: [])
        let runs = SQLClaim(kind: .runs, script: [statement], target: 0, shown: .runs(false))
        XCTAssertEqual(runs.claimed, "raises an error")
        XCTAssertEqual(SQLClaim(kind: .runs, script: [statement], target: 0, shown: .runs(true)).claimed, "runs")
        XCTAssertEqual(SQLClaim(kind: .rowCount, script: [statement], target: 0, shown: .count(1)).claimed, "1 row")
        XCTAssertEqual(SQLClaim.shortened(String(repeating: "a ", count: 60)).count, 90)
        let finding = SQLFinding(claim: runs, outcome: .exact)
        XCTAssertNil(finding.actual)
        XCTAssertNil(finding.slip)
        XCTAssertEqual(SQLFinding.quoted("SELECT `a`"), "`SELECT 'a'`")
    }
}
