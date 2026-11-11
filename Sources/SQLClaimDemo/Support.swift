import SQLClaimKit

/// Prints a report the same way for every scenario.
enum Printer {
    static func marker(_ finding: SQLFinding) -> String {
        switch finding.severity {
        case .holds: "ok   "
        case .unchecked: "skip "
        case .caution: "check"
        case .wrong: "WRONG"
        }
    }

    static func slip(_ finding: SQLFinding) -> String {
        switch finding.outcome {
        case let .wrong(slip?): " [\(slip.rawValue)]"
        case let .caveat(caveat): " [\(name(caveat))]"
        default: ""
        }
    }

    static func name(_ caveat: SQLFinding.Caveat) -> String {
        switch caveat {
        case let .engineDependent(slip): "engineDependent: \(slip.rawValue)"
        case .unorderedLimit: "unorderedLimit"
        case .rowOrder: "rowOrder"
        case .otherSyntax: "otherSyntax"
        case .doubleQuotedText: "doubleQuotedText"
        }
    }

    static func show(_ report: SQLReport, label: String) {
        print("    \(label): \(report.verdict.rawValue) (\(report.summary))")
        for finding in report.findings {
            print("      \(marker(finding)) \(finding.claim.excerpt)\(slip(finding))")
            if finding.severity >= .unchecked { print("            \(finding.explanation)") }
        }
    }

    static func scenario(_ number: Int, _ title: String) {
        print("")
        print("[\(number)] \(title)")
    }
}

/// An answer, and the rewrite the feedback asks for.
struct Scenario {
    let title: String
    let answer: String
    let rewrite: String
}
