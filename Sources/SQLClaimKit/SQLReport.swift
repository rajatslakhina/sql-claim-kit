/// Everything one answer's claims about its SQL came to.
public struct SQLReport: Sendable, Hashable {
    public enum Verdict: String, Sendable, Hashable, CaseIterable {
        /// Nothing said about SQL that could be checked.
        case noClaims
        /// Every claim holds.
        case verified
        /// Nothing wrong, but a claim could not be checked.
        case unchecked
        /// Nothing wrong, but something needs a second look.
        case caution
        /// At least one claim is wrong.
        case wrong
    }

    public let findings: [SQLFinding]
    public let verdict: Verdict

    public init(findings: [SQLFinding]) {
        self.findings = findings
        verdict = switch findings.map(\.severity).max() {
        case nil: .noClaims
        case .holds?: .verified
        case .unchecked?: .unchecked
        case .caution?: .caution
        case .wrong?: .wrong
        }
    }

    /// The findings that need a correction or a second look.
    public var flagged: [SQLFinding] {
        findings.filter { $0.severity >= .caution }
    }

    /// Flagged findings that were already flagged earlier in the conversation.
    public var repeatedCount: Int {
        flagged.filter(\.isRepeated).count
    }

    /// One sentence per flagged finding.
    public var corrections: [String] {
        flagged.map(\.explanation)
    }

    /// A note for the person reading the answer; `nil` when nothing is flagged.
    public var note: String? {
        guard !flagged.isEmpty else { return nil }
        let again = repeatedCount > 0 ? " Some of this was stated again after a correction was asked for." : ""
        return "SQL check: " + corrections.joined(separator: " ") + again
    }

    /// A message asking the model to redo what it got wrong; `nil` when there is nothing to redo.
    public var feedback: String? {
        guard !flagged.isEmpty else { return nil }
        let lines = corrections.map { "- " + $0 }.joined(separator: "\n")
        return "Some of what your answer says about its SQL does not hold:\n" + lines
            + "\nRun each query on the data the answer shows, correct the output and every statement that depends "
            + "on it, and keep the rest of the answer as it is."
    }

    /// A short line for a trace or a log.
    public var summary: String {
        guard !findings.isEmpty else { return "no claims about SQL" }
        let counts = Dictionary(grouping: findings, by: \.severity).mapValues(\.count)
        let noun = findings.count == 1 ? "claim" : "claims"
        var parts = ["\(findings.count) \(noun) checked", "\(counts[.holds, default: 0]) hold"]
        if let unchecked = counts[.unchecked] { parts.append("\(unchecked) unchecked") }
        if let caution = counts[.caution] { parts.append("\(caution) to check") }
        if let wrong = counts[.wrong] { parts.append("\(wrong) wrong") }
        if repeatedCount > 0 { parts.append("\(repeatedCount) repeated") }
        return parts.joined(separator: ", ")
    }
}
