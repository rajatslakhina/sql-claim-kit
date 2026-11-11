import Foundation
import SQLite3
import XCTest
@testable import SQLClaimKit

final class SandboxTests: XCTestCase {
    private func sandbox(stepLimit: Int = 2_000, rowCap: Int = 1_000) throws -> SQLiteSandbox {
        try XCTUnwrap(SQLiteSandbox(stepLimit: stepLimit, rowCap: rowCap))
    }

    func testValuesComeBackInTheirStorageClass() throws {
        let run = try sandbox().run([
            "CREATE TABLE t (a, b, c, d, e);",
            "INSERT INTO t VALUES (1, 2.5, 'Ann', X'00FF', NULL);",
            "SELECT a, b, c, d, e AS missing FROM t;"
        ])
        XCTAssertNil(run.failure)
        let result = try XCTUnwrap(run.results[2])
        XCTAssertEqual(result.columns, ["a", "b", "c", "d", "missing"])
        XCTAssertEqual(result.rows, [[.integer(1), .real(2.5), .text("Ann"), .blob([0, 255]), .null]])
        XCTAssertEqual(result.rows[0].map(\.rendered), ["1", "2.5", "Ann", "X'00FF'", "NULL"])
        XCTAssertNil(run.results[0], "a statement that returns no columns has no result")
        XCTAssertEqual(try sandbox().run(["-- only a comment"]).results, [:])
    }

    func testFailuresAreClassified() throws {
        let cases: [(String, SQLFailure)] = [
            ("SELECT * FROM users;", .missingTable("users")),
            ("SELECT date_trunc('month', 1);", .missingFunction("date_trunc")),
            ("SELEC 1;", .syntax("near \"SELEC\": syntax error")),
            ("SELECT 'abc;", .syntax("unrecognized token: \"'abc;\"")),
            ("SELECT (1", .syntax("incomplete input"))
        ]
        for (sql, expected) in cases {
            XCTAssertEqual(try sandbox().run([sql]).failure, expected, sql)
        }
        let column = try sandbox().run(["CREATE TABLE t (a);", "SELECT b FROM t;"])
        XCTAssertEqual(column.failure, .missingColumn("b"))
        XCTAssertEqual(column.failedAt, 1)
        let unique = try sandbox().run(["CREATE TABLE t (a UNIQUE);", "INSERT INTO t VALUES (1), (1);"])
        XCTAssertEqual(unique.failure, .constraint("UNIQUE constraint failed: t.a"))
        let other = try sandbox().run(["SELECT max(1) FROM (SELECT 1) GROUP BY max(1);"])
        XCTAssertEqual(other.failure, .other("aggregate functions are not allowed in the GROUP BY clause"))
        XCTAssertEqual(SQLFailure.classify("not authorized", code: SQLITE_AUTH), .denied("not authorized"))
    }

    func testTheSandboxReachesNoFiles() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let attach = directory.appendingPathComponent("attach.db").path
        let vacuum = directory.appendingPathComponent("vacuum.db").path
        let box = try sandbox()
        XCTAssertEqual(box.run(["ATTACH DATABASE '\(attach)' AS other;"]).failure,
                       .denied("ATTACH is not run by the checker"))
        XCTAssertEqual(box.run(["CREATE TABLE t (a);", "  vacuum into '\(vacuum)';"]).failure,
                       .denied("VACUUM is not run by the checker"))
        XCTAssertEqual(box.run(["PRAGMA writable_schema = 1;"]).failure, .denied("PRAGMA is not run by the checker"))
        XCTAssertEqual(box.run(["DETACH other;"]).failure, .denied("DETACH is not run by the checker"))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
    }

    func testTheAuthorizerRefusesWhatTheKeywordCheckCannotSee() {
        XCTAssertEqual(SQLiteSandbox.authorize(action: SQLITE_ATTACH, name: nil), SQLITE_DENY)
        XCTAssertEqual(SQLiteSandbox.authorize(action: SQLITE_PRAGMA, name: nil), SQLITE_DENY)
        "load_extension".withCString { name in
            XCTAssertEqual(SQLiteSandbox.authorize(action: SQLITE_FUNCTION, name: name), SQLITE_DENY)
        }
        "upper".withCString { name in
            XCTAssertEqual(SQLiteSandbox.authorize(action: SQLITE_FUNCTION, name: name), SQLITE_OK)
        }
        XCTAssertEqual(SQLiteSandbox.authorize(action: SQLITE_SELECT, name: nil), SQLITE_OK)
        XCTAssertEqual(SQLiteSandbox.text(nil), "")
        XCTAssertEqual(SQLiteSandbox.tick(nil), 1, "no budget means stop")
    }

    func testRunawayQueriesStop() throws {
        let forever = "WITH RECURSIVE c(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM c) SELECT count(*) FROM c;"
        XCTAssertEqual(try sandbox().run([forever]).failure, .budget)
        let many = "WITH RECURSIVE c(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM c LIMIT 50) SELECT n FROM c;"
        XCTAssertEqual(try sandbox(rowCap: 10).run([many]).failure, .budget)
        XCTAssertEqual(try sandbox(rowCap: 50).run([many]).results[0]?.rows.count, 50)
    }

    func testAnUnopenableDatabaseIsNil() {
        XCTAssertNil(SQLiteSandbox(path: "/nonexistent-\(UUID().uuidString)/x.db"))
    }

    func testFailureMessagesAndScope() {
        XCTAssertEqual(SQLFailure.budget.message, "it ran past the checker's step budget")
        XCTAssertEqual(SQLFailure.missingColumn("b").message, "no such column: b")
        XCTAssertEqual(SQLFailure.missingFunction("now").message, "no such function: now")
        XCTAssertEqual(SQLFailure.denied("x").message, "x")
        XCTAssertTrue(SQLFailure.missingTable("t").isOutsideTheAnswer)
        XCTAssertFalse(SQLFailure.other("x").isOutsideTheAnswer)
    }
}
