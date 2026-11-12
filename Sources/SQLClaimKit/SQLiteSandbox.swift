#if canImport(SQLite3)
import SQLite3
#else
import CSQLite
#endif

/// Why a statement did not run to the end.
public enum SQLFailure: Sendable, Hashable {
    /// A table the statement uses was never created (`no such table: users`).
    case missingTable(String)
    /// The table exists and has no such column.
    case missingColumn(String)
    /// SQLite has no function of that name (`date_trunc`, `now`).
    case missingFunction(String)
    /// SQLite could not parse the statement.
    case syntax(String)
    /// A `UNIQUE`, `NOT NULL`, `CHECK` or `PRIMARY KEY` constraint rejected a row.
    case constraint(String)
    /// The statement ran past the step budget or the row cap.
    case budget
    /// The statement does something the sandbox does not allow (`ATTACH`, `PRAGMA`, `VACUUM`).
    case denied(String)
    /// Any other error, with SQLite's message.
    case other(String)

    static func classify(_ message: String, code: Int32) -> SQLFailure {
        if code == SQLITE_INTERRUPT { return .budget }
        if code == SQLITE_AUTH { return .denied(message) }
        let prefixes: [(String, (String) -> SQLFailure)] = [
            ("no such table: ", SQLFailure.missingTable),
            ("no such column: ", SQLFailure.missingColumn),
            ("no such function: ", SQLFailure.missingFunction)
        ]
        for (prefix, make) in prefixes {
            if let range = message.range(of: prefix) { return make(String(message[range.upperBound...])) }
        }
        if message.contains("syntax error") || message.contains("incomplete input")
            || message.contains("unrecognized token") {
            return .syntax(message)
        }
        if message.contains("constraint failed") { return .constraint(message) }
        return .other(message)
    }

    /// Whether the failure says nothing about the SQL being wrong: the answer did not show its tables,
    /// leaned on a function another engine has, or ran into the sandbox's limits.
    var isOutsideTheAnswer: Bool {
        switch self {
        case .missingTable, .missingFunction, .budget, .denied: true
        case .missingColumn, .syntax, .constraint, .other: false
        }
    }

    /// SQLite's message, or a short description for the sandbox's own refusals.
    public var message: String {
        switch self {
        case let .missingTable(name): "no such table: \(name)"
        case let .missingColumn(name): "no such column: \(name)"
        case let .missingFunction(name): "no such function: \(name)"
        case let .syntax(text), let .constraint(text), let .other(text): text
        case .budget: "it ran past the checker's step budget"
        case let .denied(text): text
        }
    }
}

/// What running a list of statements came to: the rows each one returned, up to the first failure.
struct SQLRun: Sendable, Hashable {
    var results: [Int: SQLResult] = [:]
    var failure: SQLFailure?
    var failedAt: Int?
}

/// Counts progress-handler calls for one run; the handler stops the statement once the limit is passed.
final class StepBudget {
    let limit: Int
    var calls = 0

    init(limit: Int) {
        self.limit = limit
    }
}

/// A private in-memory SQLite database for one check. Nothing reaches the file system: `ATTACH`,
/// `DETACH`, `PRAGMA`, `VACUUM` and `load_extension` are refused before they run, no database can be
/// attached, and a step budget and a row cap stop runaway queries.
final class SQLiteSandbox {
    static let deniedKeywords: Set<String> = ["ATTACH", "DETACH", "PRAGMA", "VACUUM"]

    private let database: OpaquePointer
    private let budget: StepBudget
    let rowCap: Int

    init?(path: String = ":memory:", stepLimit: Int = 2_000, rowCap: Int = 1_000) {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK,
              let opened = handle else {
            sqlite3_close(handle)
            return nil
        }
        database = opened
        budget = StepBudget(limit: stepLimit)
        self.rowCap = rowCap
        sqlite3_limit(opened, SQLITE_LIMIT_ATTACHED, 0)
        sqlite3_limit(opened, SQLITE_LIMIT_LENGTH, 1_000_000)
        sqlite3_set_authorizer(opened, { _, action, _, name, _, _ in
            SQLiteSandbox.authorize(action: action, name: name)
        }, nil)
        let context = Unmanaged.passUnretained(budget).toOpaque()
        sqlite3_progress_handler(opened, 1_000, { context in
            SQLiteSandbox.tick(context)
        }, context)
    }

    deinit {
        sqlite3_close(database)
    }

    static func authorize(action: Int32, name: UnsafePointer<CChar>?) -> Int32 {
        switch action {
        case SQLITE_ATTACH, SQLITE_DETACH, SQLITE_PRAGMA:
            return SQLITE_DENY
        case SQLITE_FUNCTION where text(name).lowercased() == "load_extension":
            return SQLITE_DENY
        default:
            return SQLITE_OK
        }
    }

    static func tick(_ context: UnsafeMutableRawPointer?) -> Int32 {
        guard let context else { return 1 }
        let budget = Unmanaged<StepBudget>.fromOpaque(context).takeUnretainedValue()
        budget.calls += 1
        return budget.calls > budget.limit ? 1 : 0
    }

    static func text(_ pointer: UnsafePointer<CChar>?) -> String {
        guard let pointer else { return "" }
        return String(cString: pointer)
    }

    /// Runs the statements in order and stops at the first one that fails, from `first` on; a statement
    /// before `first` that fails is passed over, as the `sqlite3` shell passes over it in a file.
    func run(_ statements: [String], from first: Int = 0) -> SQLRun {
        var run = SQLRun()
        for (index, statement) in statements.enumerated() {
            switch execute(statement) {
            case let .success(result?):
                run.results[index] = result
            case .success(nil):
                continue
            case .failure where index < first:
                continue
            case let .failure(failure):
                run.failure = failure.reason
                run.failedAt = index
                return run
            }
        }
        return run
    }

    struct Failed: Error {
        let reason: SQLFailure
    }

    /// Runs one statement; its rows when it returns any, `nil` when it returns none.
    func execute(_ statement: String) -> Result<SQLResult?, Failed> {
        if let keyword = SQLText.firstKeyword(statement), Self.deniedKeywords.contains(keyword) {
            return .failure(Failed(reason: .denied("\(keyword) is not run by the checker")))
        }
        var prepared: OpaquePointer?
        let code = sqlite3_prepare_v2(database, statement, -1, &prepared, nil)
        defer { sqlite3_finalize(prepared) }
        guard code == SQLITE_OK else { return .failure(error(code)) }
        guard let prepared else { return .success(nil) }
        let width = Int(sqlite3_column_count(prepared))
        let columns = (0..<width).map { Self.text(sqlite3_column_name(prepared, Int32($0))) }
        var rows: [[SQLValue]] = []
        while true {
            let step = sqlite3_step(prepared)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { return .failure(error(step)) }
            guard rows.count < rowCap else { return .failure(Failed(reason: .budget)) }
            rows.append((0..<width).map { Self.value(prepared, Int32($0)) })
        }
        return .success(width == 0 ? nil : SQLResult(columns: columns, rows: rows))
    }

    private func error(_ code: Int32) -> Failed {
        Failed(reason: SQLFailure.classify(String(cString: sqlite3_errmsg(database)), code: code))
    }

    static func value(_ statement: OpaquePointer, _ column: Int32) -> SQLValue {
        switch sqlite3_column_type(statement, column) {
        case SQLITE_INTEGER:
            return .integer(sqlite3_column_int64(statement, column))
        case SQLITE_FLOAT:
            return .real(sqlite3_column_double(statement, column))
        case SQLITE_TEXT:
            let count = Int(sqlite3_column_bytes(statement, column))
            let bytes = UnsafeRawBufferPointer(start: sqlite3_column_text(statement, column), count: count)
            // SQLite hands TEXT back as UTF-8, and decoding repairs any invalid sequence, so a failable
            // initializer would only add a branch no value can reach.
            // swiftlint:disable:next optional_data_string_conversion
            return .text(String(decoding: bytes, as: UTF8.self))
        case SQLITE_BLOB:
            let count = Int(sqlite3_column_bytes(statement, column))
            return .blob(Array(UnsafeRawBufferPointer(start: sqlite3_column_blob(statement, column), count: count)))
        default:
            return .null
        }
    }
}
