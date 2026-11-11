/// Reads what an answer says about its SQL and checks every claim by running it: the one call most
/// callers need.
public struct SQLClaimChecker: Sendable {
    public let policy: SQLPolicy
    public let reader: SQLClaimReader

    public init(policy: SQLPolicy = .standard) {
        self.policy = policy
        reader = SQLClaimReader(checksSQLBlocks: policy.checksSQLBlocks)
    }

    public func claims(in text: String) -> [SQLClaim] {
        reader.claims(in: text)
    }

    public func judge(_ claim: SQLClaim) -> SQLFinding {
        SQLEvaluator(policy: policy).judge(claim)
    }

    /// Every claim judged. SQL shown with no claim about it is kept only when SQLite settles it, holding or
    /// failing: when its tables are not in the answer, or it may be for another engine, it is dropped. No
    /// schema, no claim.
    public func check(_ text: String) -> SQLReport {
        SQLReport(findings: claims(in: text).map(judge).filter { finding in
            finding.claim.isExplicit || finding.severity == .holds || finding.severity == .wrong
        })
    }
}

/// Checks a conversation's answers one after another and remembers what it flagged, so a wrong claim
/// stated again after a correction was asked for is marked as repeated rather than new.
public actor SQLLedger {
    public struct Statistics: Sendable, Hashable {
        public var reviews = 0
        public var claims = 0
        public var flagged = 0
        public var repeated = 0
    }

    public nonisolated let checker: SQLClaimChecker
    public private(set) var statistics = Statistics()
    private var flaggedKeys: Set<String> = []

    public init(checker: SQLClaimChecker = SQLClaimChecker()) {
        self.checker = checker
    }

    public func review(_ text: String) -> SQLReport {
        var findings = checker.check(text).findings
        var keys: Set<String> = []
        for index in findings.indices where findings[index].severity >= .caution {
            let key = findings[index].key
            findings[index].isRepeated = flaggedKeys.contains(key)
            keys.insert(key)
        }
        flaggedKeys.formUnion(keys)
        let report = SQLReport(findings: findings)
        statistics.reviews += 1
        statistics.claims += findings.count
        statistics.flagged += report.flagged.count
        statistics.repeated += report.repeatedCount
        return report
    }

    /// Starts a new conversation: nothing flagged so far counts as a repeat.
    public func forget() {
        flaggedKeys.removeAll()
    }
}
