import SQLClaimKit

print("SQLClaimKit demo: checking what LLM answers say their SQL returns")
print("Each answer's SQL runs, on the data it shows, in a private in-memory SQLite database.")

let checker = SQLClaimChecker()
let pairs: [Scenario] = [
    Scenario(title: "WHERE email = NULL, said to find the customers with no email", answer: Scenarios.nullFilter,
             rewrite: Scenarios.nullFilterFixed),
    Scenario(title: "A LEFT JOIN that is meant to keep every customer, filtered in WHERE",
             answer: Scenarios.everyCustomer, rewrite: Scenarios.everyCustomerFixed),
    Scenario(title: "NOT IN over a subquery that holds a NULL", answer: Scenarios.notReferrers,
             rewrite: Scenarios.notReferrersFixed),
    Scenario(title: "COUNT(email) said to count every customer", answer: Scenarios.headcount,
             rewrite: Scenarios.headcountFixed)
]
for (number, scenario) in pairs.enumerated() {
    Printer.scenario(number + 1, scenario.title)
    let report = checker.check(scenario.answer)
    Printer.show(report, label: "answer")
    if number == 0, let feedback = report.feedback {
        print("    feedback sent back to the model:")
        for line in feedback.split(separator: "\n") { print("      | \(line)") }
    }
    Printer.show(checker.check(scenario.rewrite), label: "rewrite")
}

Printer.scenario(5, "245 / 3 said to be 81.67: no engine named, then SQLite named")
Printer.show(checker.check(Scenarios.average), label: "answer, no engine named")
Printer.show(checker.check(Scenarios.averageInSQLite), label: "answer, SQLite named")
Printer.show(checker.check(Scenarios.averageFixed), label: "rewrite")

Printer.scenario(6, "What is not checked: no schema, another engine, the sandbox's limits")
Printer.show(checker.check(Scenarios.noSchema), label: "a query with no tables shown")
Printer.show(checker.check(Scenarios.postgres), label: "PostgreSQL named")
Printer.show(checker.check(Scenarios.sandbox), label: "ATTACH and a query that never ends")

Printer.scenario(7, "A conversation: the same wrong claim after a correction was asked for")
let ledger = SQLLedger()
let first = await ledger.review(Scenarios.nullFilter)
print("    turn 1: \(first.summary)")
let second = await ledger.review(Scenarios.nullFilter)
print("    turn 2: \(second.summary)")
if let note = second.note { print("    note: \(note)") }
let stats = await ledger.statistics
print("    ledger: \(stats.reviews) reviews, \(stats.claims) claims, \(stats.flagged) flagged, "
      + "\(stats.repeated) repeated")
