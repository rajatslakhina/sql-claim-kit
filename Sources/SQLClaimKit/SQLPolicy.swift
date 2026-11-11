/// How strictly claims are held.
public struct SQLPolicy: Sendable, Hashable {
    /// Whether a SQL block with no other claim about it counts as SQL shown to run.
    public var checksSQLBlocks: Bool
    /// Whether results that depend on the engine, the row order or a `LIMIT` are reported as caveats
    /// (otherwise they are unchecked).
    public var reportsCaveats: Bool
    /// Whether rows must come back in the order shown even when the query has no `ORDER BY`.
    public var ordersRows: Bool

    public init(checksSQLBlocks: Bool = true, reportsCaveats: Bool = true, ordersRows: Bool = false) {
        self.checksSQLBlocks = checksSQLBlocks
        self.reportsCaveats = reportsCaveats
        self.ordersRows = ordersRows
    }

    /// SQL blocks checked, caveats reported, rows compared as a set unless the query orders them.
    public static let standard = SQLPolicy()

    /// Only what an answer shows as output or says in words; caveats let through as unchecked.
    public static let lenient = SQLPolicy(checksSQLBlocks: false, reportsCaveats: false)

    /// Rows must come back in the order shown.
    public static let strict = SQLPolicy(ordersRows: true)
}
