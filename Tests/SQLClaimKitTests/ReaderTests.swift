import XCTest
@testable import SQLClaimKit

final class ReaderTests: XCTestCase {
    private let reader = SQLClaimReader()

    func testAnswersAreCutIntoProseCodeAndTables() {
        let text = "Intro\n```SQL extra\nSELECT 1;\n```\n| a |\n|---|\n| 1 |\nOutro\n```text\nunclosed"
        XCTAssertEqual(Segment.parse(text), [
            .prose("Intro"), .code(label: "sql", body: "SELECT 1;"), .table(["| a |", "|---|", "| 1 |"]),
            .prose("Outro"), .code(label: "text", body: "unclosed")
        ])
        XCTAssertEqual(Segment.parse("```\nx\n```\n| a |"), [.code(label: "", body: "x"), .table(["| a |"])])
    }

    func testShownTablesReadMarkdownBoxesAndListOutput() {
        XCTAssertEqual(ShownTable.parse(["| name | n |", "|:--|--:|", "| Ann | 1 |"]),
                       ShownTable(header: ["name", "n"], rows: [["Ann", "1"]]))
        let box = ["+----+------+", "| id | name |", "+----+------+", "|  1 | Ann  |", "+----+------+", "(1 row)"]
        XCTAssertEqual(ShownTable.parse(box), ShownTable(header: ["id", "name"], rows: [["1", "Ann"]]))
        XCTAssertEqual(ShownTable.parse([" id | name ", "----+------", "  1 | Ann", "(1 row)"]),
                       ShownTable(header: ["id", "name"], rows: [["1", "Ann"]]))
        XCTAssertEqual(ShownTable.parse(["1|Ann", "2|Bob", ""]), ShownTable(header: nil, rows: [["1", "Ann"], ["2", "Bob"]]))
        XCTAssertNil(ShownTable.parse(["(0 rows)"]))
        XCTAssertEqual(ShownTable.parse(["| n |", "|---|"])?.rows, [])
        XCTAssertEqual(ShownTable(header: nil, rows: []).width, 0)
    }

    func testTheEngineIsReadFromLabelsProseAndSyntax() {
        XCTAssertEqual(SQLDialect.detect(labels: ["sql", "postgresql"], prose: "SQLite", sql: ""), .postgresql)
        XCTAssertEqual(SQLDialect.detect(labels: ["sql"], prose: "Unlike MySQL, SQLite does", sql: ""), .sqlite)
        XCTAssertEqual(SQLDialect.detect(labels: ["sql"], prose: "In SQL Server", sql: ""), .sqlServer)
        XCTAssertEqual(SQLDialect.detect(labels: ["sql"], prose: "", sql: "SELECT x::text"), .postgresql)
        XCTAssertEqual(SQLDialect.detect(labels: ["sql"], prose: "", sql: "id INT AUTO_INCREMENT"), .mysql)
        XCTAssertEqual(SQLDialect.detect(labels: ["sql"], prose: "", sql: "SELECT TOP 5 * FROM t"), .sqlServer)
        XCTAssertEqual(SQLDialect.detect(labels: ["sql"], prose: "", sql: "SELECT '::text'"), .unnamed)
        XCTAssertEqual(SQLDialect.allCases.map(\.name), [
            "plain SQL", "SQLite", "PostgreSQL", "MySQL", "SQL Server", "Oracle", "another engine"
        ])
    }

    func testAResultTableAfterAQueryIsAClaim() throws {
        let text = """
        ```sql
        CREATE TABLE t (a);
        SELECT a FROM t;
        INSERT INTO t VALUES (1);
        ```
        This returns 2 rows:

        | a |
        |---|
        | 1 |
        | 2 |
        """
        let claims = reader.claims(in: text)
        XCTAssertEqual(claims.map(\.kind), [.rowCount, .result])
        XCTAssertEqual(claims[1].statement, "SELECT a FROM t;", "the block's last query, not its last statement")
        XCTAssertEqual(claims[1].script.count, 2)
        XCTAssertEqual(claims[1].claimed, "2 rows: 1, 2")
        XCTAssertEqual(claims[0].claimed, "2 rows")
        XCTAssertTrue(claims[1].excerpt.hasPrefix("result: SELECT a FROM t; -> 2 rows"))
    }

    func testOutputBlocksAndLongProse() {
        let output = "```sql\nSELECT 1, 2;\n```\n```output\n1|2\n```"
        XCTAssertEqual(reader.claims(in: output).map(\.kind), [.result])
        let long = "```sql\nSELECT 1;\n```\n" + String(repeating: "word ", count: 50) + "\n| 1 |"
        XCTAssertEqual(reader.claims(in: long).map(\.kind), [.runs], "a table after long prose is not this query's")
        XCTAssertFalse(reader.claims(in: long)[0].isExplicit)
        let python = "```sql\nSELECT 1;\n```\n```python\nprint(1)\n```"
        XCTAssertEqual(reader.claims(in: python).map(\.kind), [.runs])
    }

    func testCommentsAfterAQueryGiveValues() throws {
        let block = """
        ```sql
        SELECT 7 / 2;  -- 3.5
        SELECT 'a' || 'b'; -- returns 'ab'
        SELECT NULL; -- => NULL
        SELECT 1, 'x'; -- 1 | 'x'
        SELECT count(*) FROM (SELECT 1); -- (1 row)
        SELECT 2; -- the answer
        CREATE TABLE t (a); -- 3
        ```
        """
        let claims = reader.claims(in: block)
        XCTAssertEqual(claims.map(\.kind), [.value, .value, .value, .value, .rowCount])
        XCTAssertEqual(claims.map(\.claimed), ["3.5", "'ab'", "NULL", "(1, 'x')", "1 row"])
        XCTAssertEqual(claims.map(\.target), [0, 1, 2, 3, 4])
    }

    func testRowCountsAreReadInWords() {
        XCTAssertEqual(SQLClaimReader.rowCount(in: "It returns no rows."), 0)
        XCTAssertEqual(SQLClaimReader.rowCount(in: "This gives exactly one row"), 1)
        XCTAssertEqual(SQLClaimReader.rowCount(in: "(12 rows)"), 12)
        XCTAssertEqual(SQLClaimReader.rowCount(in: "returns a single row"), 1)
        XCTAssertNil(SQLClaimReader.rowCount(in: "it reads 3 rows of data"))
        XCTAssertNil(SQLClaimReader.shownValue("count the users"))
    }

    func testWordsBeforeOrAfterABlockSayItRunsOrFails() {
        let runs = "This is valid SQL:\n```sql\nSELECT 1;\n```"
        XCTAssertEqual(reader.claims(in: runs).map(\.shown), [.runs(true)])
        XCTAssertTrue(reader.claims(in: runs)[0].isExplicit)
        let fails = "```sql\nSELECT 1;\n```\nThis fails with an error. Use the other one."
        XCTAssertEqual(reader.claims(in: fails).map(\.shown), [.runs(false)])
        let notAboutIt = "Here it is\n```sql\nSELECT 1;\n```\nNice weather."
        XCTAssertEqual(reader.claims(in: notAboutIt).map(\.isExplicit), [false])
        XCTAssertEqual(SQLClaimReader(checksSQLBlocks: false).claims(in: notAboutIt), [])
        XCTAssertEqual(reader.claims(in: "```sql\n-- only a comment\n```"), [])
        XCTAssertEqual(reader.claims(in: "```sql\nCREATE TABLE t (a);\n```")[0].statement, "CREATE TABLE t (a);")
    }

    func testWordsAreNotValuesAndCountsMustEndThePhrase() {
        let schema = "CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT, active INTEGER);\n"
        let prose = [
            "```sql\n" + schema + "SELECT name FROM users WHERE active = 1; -- returns the active users\n```",
            "```sql\n" + schema + "SELECT name FROM users;\n-- ===== orders =====\nSELECT 1;\n```",
            "```sql\n" + schema + "SELECT count(*) FROM users; -- gives the total\n```",
            "```sql\n" + schema + "SELECT name FROM users; -- -> sorted by id\n```",
            "```sql\n" + schema + "SELECT name, active FROM users;\n```\nThis returns one row per customer.",
            "```sql\n" + schema + "SELECT name FROM users;\n```\nThis returns a row for each active user.",
            "```sql\n" + schema + "SELECT name FROM users;\n```\nIt returns 2 rows for the active ones if you filter."
        ]
        for text in prose {
            XCTAssertEqual(reader.claims(in: text).map(\.kind), [.runs], text)
        }
        XCTAssertEqual(SQLClaimReader.rowCount(in: "This returns 2 rows: Ann and Cy"), 2)
        XCTAssertEqual(SQLClaimReader.rowCount(in: "It gives no rows, because"), 0)
        XCTAssertNil(SQLClaimReader.shownValue("Ann"))
        XCTAssertNotNil(SQLClaimReader.shownValue("=> 'Ann'"))
    }

    func testQueriesAreRecognized() {
        XCTAssertTrue(SQLClaimReader.isQuery("VALUES (1)"))
        XCTAssertTrue(SQLClaimReader.isQuery("INSERT INTO t VALUES (1) RETURNING id"))
        XCTAssertFalse(SQLClaimReader.isQuery("(1)"))
        XCTAssertEqual(SQLClaimReader.firstSentence("One. Two.\nThree"), "One")
    }
}
