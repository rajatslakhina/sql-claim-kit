import Foundation

/// The database engine an answer is written for.
public enum SQLDialect: String, Sendable, Hashable, CaseIterable {
    /// No engine named: plain SQL. SQLite runs it, and results that differ between engines are caveats.
    case unnamed
    case sqlite
    case postgresql
    case mysql
    case sqlServer
    case oracle
    /// Another engine (DuckDB, Snowflake, BigQuery, Redshift).
    case other

    public var name: String {
        switch self {
        case .unnamed: "plain SQL"
        case .sqlite: "SQLite"
        case .postgresql: "PostgreSQL"
        case .mysql: "MySQL"
        case .sqlServer: "SQL Server"
        case .oracle: "Oracle"
        case .other: "another engine"
        }
    }

    /// Whether SQLite's result settles a claim: SQLite named, or no engine named.
    var runsInSQLite: Bool {
        self == .unnamed || self == .sqlite
    }

    static let labels: [String: SQLDialect] = [
        "sqlite": .sqlite, "sqlite3": .sqlite, "postgresql": .postgresql, "postgres": .postgresql,
        "psql": .postgresql, "pgsql": .postgresql, "plpgsql": .postgresql, "mysql": .mysql, "mariadb": .mysql,
        "tsql": .sqlServer, "mssql": .sqlServer, "sqlserver": .sqlServer, "plsql": .oracle, "oracle": .oracle
    ]

    static let names: [(String, SQLDialect)] = [
        (#"\bSQLite3?\b"#, .sqlite), (#"\bPostgre(SQL|s)\b"#, .postgresql), (#"\b(MySQL|MariaDB)\b"#, .mysql),
        (#"\b(SQL Server|T-SQL|MSSQL)\b"#, .sqlServer), (#"\bOracle\b"#, .oracle),
        (#"\b(DuckDB|Snowflake|BigQuery|Redshift)\b"#, .other)
    ]

    static let markers: [(String, SQLDialect)] = [
        (#"\b(BIG)?SERIAL\b|::\s*[A-Z]|\bILIKE\b|\bDATE_TRUNC\s*\("#, .postgresql),
        (#"\bAUTO_INCREMENT\b|\bENGINE\s*="#, .mysql),
        (#"\bSELECT\s+TOP\s+\d|\bGETDATE\s*\(|\bIDENTITY\s*\("#, .sqlServer)
    ]

    /// The engine an answer is for: a block's label first, then an engine named in the prose (SQLite wins
    /// when several are), then syntax only one engine has.
    static func detect(labels blockLabels: [String], prose: String, sql: String) -> SQLDialect {
        if let labeled = blockLabels.compactMap({ labels[$0] }).first { return labeled }
        let named = names.filter { prose.range(of: $0.0, options: .regularExpression) != nil }.map(\.1)
        if named.contains(.sqlite) { return .sqlite }
        if let first = named.first { return first }
        let upper = SQLText.stripped(sql)
        return markers.first { upper.range(of: $0.0, options: .regularExpression) != nil }?.1 ?? .unnamed
    }
}
