import XCTest
@testable import SQLClaimKit

final class TextAndValueTests: XCTestCase {
    func testStatementsSplitWithTheirComments() {
        let block = """
        -- set up
        CREATE TABLE t (a TEXT); -- the table
        INSERT INTO t VALUES ('x;y'), ('it''s'), ("q""q");
        /* a block comment; with a semicolon */
        SELECT a FROM t; -- 3 rows
        -- x;y
        SELECT `a`, [a] FROM t
        """
        let statements = SQLText.statements(in: block)
        XCTAssertEqual(statements.map(\.text), [
            "-- set up\nCREATE TABLE t (a TEXT);",
            "INSERT INTO t VALUES ('x;y'), ('it''s'), (\"q\"\"q\");",
            "SELECT a FROM t;",
            "SELECT `a`, [a] FROM t"
        ])
        XCTAssertEqual(statements.map(\.comments), [[" the table"], [], [" 3 rows", " x;y"], []])
        XCTAssertEqual(SQLText.statements(in: "SELECT 1;\n-- trailing note"), [
            SQLStatement(text: "SELECT 1;", comments: [" trailing note"])
        ])
        XCTAssertEqual(SQLText.statements(in: "-- nothing here"), [])
        XCTAssertEqual(SQLText.statements(in: "SELECT 1 /* unclosed"), [SQLStatement(text: "SELECT 1  ", comments: [])]
            .map { SQLStatement(text: $0.text.trimmingCharacters(in: .whitespaces), comments: []) })
    }

    func testATriggerBodyIsOneStatement() {
        let block = """
        CREATE TABLE t (a);
        CREATE TRIGGER tr AFTER INSERT ON t BEGIN
          UPDATE t SET a = a + 1;
        END;
        SELECT a FROM t;
        """
        XCTAssertEqual(SQLText.statements(in: block).count, 3)
    }

    func testKeywordsAreReadOutsideStringsAndParentheses() {
        XCTAssertEqual(SQLText.firstKeyword("  -- note\n with x AS (SELECT 1) SELECT * FROM x"), "WITH")
        XCTAssertNil(SQLText.firstKeyword("(1);"))
        XCTAssertEqual(SQLText.stripped("SELECT 'order by' -- order by\nFROM t;"), "SELECT '        '  \nFROM T;")
        XCTAssertTrue(SQLText.hasTopLevel("ORDER BY", in: "SELECT a FROM t ORDER BY a"))
        XCTAssertFalse(SQLText.hasTopLevel("ORDER BY", in: "SELECT a FROM (SELECT a FROM t ORDER BY a)"))
        XCTAssertFalse(SQLText.hasTopLevel("ORDER BY", in: "SELECT 'order by' FROM t"))
        XCTAssertTrue(SQLText.hasTopLevel("LIMIT", in: "SELECT a) LIMIT FROM"),
                       "an unbalanced parenthesis keeps the depth at zero")
    }

    func testShownCellsMatchValues() {
        XCTAssertTrue(SQLValue.null.matches("NULL"))
        XCTAssertTrue(SQLValue.null.matches(" "))
        XCTAssertFalse(SQLValue.null.matches("0"))
        XCTAssertTrue(SQLValue.integer(1).matches("true"))
        XCTAssertTrue(SQLValue.integer(0).matches("f"))
        XCTAssertTrue(SQLValue.integer(1200).matches("1,200"))
        XCTAssertTrue(SQLValue.integer(3).matches("3.0"))
        XCTAssertFalse(SQLValue.integer(3).matches("3.5"))
        XCTAssertFalse(SQLValue.integer(3).matches("three"))
        XCTAssertTrue(SQLValue.real(2.5).matches("2.50"))
        XCTAssertTrue(SQLValue.real(2.0 / 3.0).matches("0.67"))
        XCTAssertTrue(SQLValue.real(3).matches("3"))
        XCTAssertFalse(SQLValue.real(2.5).matches("2.6"))
        XCTAssertFalse(SQLValue.real(2.5).matches("x"))
        XCTAssertTrue(SQLValue.text("Ann").matches("'Ann'"))
        XCTAssertTrue(SQLValue.text("Ann").matches("\"Ann\""))
        XCTAssertFalse(SQLValue.text("Ann").matches("ann"))
        XCTAssertTrue(SQLValue.blob([1]).matches("x'01'"))
        XCTAssertEqual(SQLValue.unquoted("'"), "'")
        XCTAssertEqual(SQLValue.unquoted("'a\""), "'a\"")
        XCTAssertNil(SQLValue.number("1.2.3"))
        XCTAssertEqual(SQLValue.number(".5"), 0.5)
        XCTAssertEqual(SQLValue.number("-1e3"), -1000)
    }

    func testValuesRenderAsTheShellPrintsThem() {
        XCTAssertEqual(SQLValue.real(3).rendered, "3.0")
        XCTAssertEqual(SQLValue.real(0.1).rendered, "0.1")
        XCTAssertEqual(SQLValue.real(1e20).rendered, "1e+20")
        XCTAssertEqual(SQLResult(columns: ["a"], rows: []).rendered, "no rows")
        XCTAssertEqual(SQLResult(columns: ["a"], rows: [[.integer(1)]]).rendered, "1 row: 1")
        let five = (1...5).map { [SQLValue.integer(Int64($0)), .text("x")] }
        XCTAssertEqual(SQLResult(columns: ["a", "b"], rows: five).rendered,
                       "5 rows: (1, x), (2, x), (3, x), (4, x), ...")
        XCTAssertEqual(SQLResult(columns: ["a"], rows: [[.integer(1)], [.null]]).rendered, "2 rows: 1, NULL")
    }
}
