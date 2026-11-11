import Foundation

/// Finds the claims an answer makes about its SQL.
///
/// - **result**: a markdown table, or a fenced output block (`text`, `output`, `console` or unlabeled),
///   right after a SQL block, with at most one short line of prose between them ("This returns:").
/// - **rowCount**: "returns 3 rows" in the prose right after a SQL block.
/// - **value**: a `--` comment after a query that gives a value: `-- 3.5`, `-- 'Ann'`, `-- NULL`, or any
///   value after `returns`, `result:`, `=>` or `→`.
/// - **runs**: "this is valid SQL", "this runs", or "this fails"/"raises an error" next to a SQL block; and,
///   when `checksSQLBlocks` is on, every SQL block with no other claim about it, as SQL shown to run.
///
/// Blocks labeled `sql`, `sqlite`, `postgresql`, `mysql` and the other engine names count as SQL. The
/// claim's script is every SQL block up to and including the one it is about, so a schema shown first is
/// there when the query runs.
public struct SQLClaimReader: Sendable {
    public let checksSQLBlocks: Bool

    public init(checksSQLBlocks: Bool = true) {
        self.checksSQLBlocks = checksSQLBlocks
    }

    static let sqlLabels: Set<String> = Set(SQLDialect.labels.keys).union(["sql"])
    static let outputLabels: Set<String> = ["", "text", "txt", "output", "console", "plaintext", "result"]

    public func claims(in text: String) -> [SQLClaim] {
        let segments = Segment.parse(text)
        let blocks = segments.enumerated().compactMap { index, segment -> Block? in
            guard case let .code(label, body) = segment, Self.sqlLabels.contains(label) else { return nil }
            return Block(position: index, label: label, body: body)
        }
        let prose = segments.compactMap { segment -> String? in
            guard case let .prose(text) = segment else { return nil }
            return text
        }.joined(separator: "\n")
        let dialect = SQLDialect.detect(
            labels: blocks.map(\.label), prose: prose, sql: blocks.map(\.body).joined(separator: "\n")
        )
        var script: [SQLStatement] = []
        var claims: [SQLClaim] = []
        for block in blocks {
            let statements = SQLText.statements(in: block.body)
            let first = script.count
            script += statements
            guard !statements.isEmpty else { continue }
            let context = Context(
                segments: segments, position: block.position, script: script, first: first, dialect: dialect
            )
            var found = valueClaims(context) + followingClaims(context)
            if let runs = runsClaim(context) { found.append(runs) }
            if found.isEmpty, checksSQLBlocks {
                found = [SQLClaim(kind: .runs, script: script, target: script.count - 1, blockStart: first,
                                  shown: .runs(true), isExplicit: false, dialect: dialect)]
            }
            claims += found
        }
        return claims
    }

    /// A SQL code block and where it sits among the answer's segments.
    struct Block {
        let position: Int
        let label: String
        let body: String
    }

    struct Context {
        let segments: [Segment]
        let position: Int
        let script: [SQLStatement]
        let first: Int
        let dialect: SQLDialect

        /// The block's last statement that can return rows, or its last statement.
        var lastQuery: Int {
            (first..<script.count).last { SQLClaimReader.isQuery(script[$0].text) } ?? script.count - 1
        }

        func claim(_ kind: SQLClaim.Kind, _ shown: SQLClaim.Shown, target: Int? = nil) -> SQLClaim {
            SQLClaim(kind: kind, script: Array(script.prefix((target ?? lastQuery) + 1)),
                     target: target ?? lastQuery, blockStart: first, shown: shown, dialect: dialect)
        }

        func segment(_ offset: Int) -> Segment? {
            let index = position + offset
            return segments.indices.contains(index) ? segments[index] : nil
        }
    }

    static func isQuery(_ statement: String) -> Bool {
        ["SELECT", "WITH", "VALUES"].contains(SQLText.firstKeyword(statement) ?? "")
            || SQLText.stripped(statement).contains(" RETURNING ")
    }

    func valueClaims(_ context: Context) -> [SQLClaim] {
        (context.first..<context.script.count).compactMap { index in
            let statement = context.script[index]
            guard Self.isQuery(statement.text), let comment = statement.comments.first,
                  let shown = Self.shownValue(comment) else { return nil }
            return context.claim(shown.kind, shown.shown, target: index)
        }
    }

    static let valuePrefixes = ["returns:", "returns", "result:", "output:", "gives", "=>", "->", "→", "="]

    /// What a comment after a query says comes out, if it says anything: a value, a row, or a row count.
    static func shownValue(_ comment: String) -> (kind: SQLClaim.Kind, shown: SQLClaim.Shown)? {
        var text = comment.trimmingCharacters(in: .whitespaces)
        let prefix = valuePrefixes.first { text.lowercased().hasPrefix($0) }
        if let prefix { text = String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces) }
        if let count = rowCount(in: text) { return (.rowCount, .count(count)) }
        let cells = ShownTable.split(text)
        guard prefix != nil || cells.allSatisfy(isLiteral) else { return nil }
        return (.value, .table(ShownTable(header: nil, rows: [cells])))
    }

    static func isLiteral(_ cell: String) -> Bool {
        SQLValue.number(cell) != nil || ["null", "true", "false"].contains(cell.lowercased())
            || (cell.count >= 2 && cell.first == "'" && cell.last == "'")
    }

    static let countWords = ["no": 0, "zero": 0, "one": 1, "a single": 1, "two": 2, "three": 3, "four": 4,
                             "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10]

    // swiftlint:disable:next force_try
    static let rowCountPattern = try! NSRegularExpression(
        pattern: #"(?:\b(?:returns?|gives?|produces?|yields?|gets?)\s+(?:exactly\s+|only\s+|just\s+)?|^\(?)"#
            + #"(\d+|no|zero|one|a single|two|three|four|five|six|seven|eight|nine|ten)\s+rows?\b"#,
        options: [.caseInsensitive]
    )

    /// "3 rows", "no rows", "(2 rows)", "returns one row".
    static func rowCount(in text: String) -> Int? {
        let range = NSRange(text.startIndex..., in: text)
        guard let match = rowCountPattern.firstMatch(in: text, range: range),
              let group = Range(match.range(at: 1), in: text) else { return nil }
        let word = text[group].lowercased()
        return countWords[word] ?? Int(word)
    }

    func followingClaims(_ context: Context) -> [SQLClaim] {
        var claims: [SQLClaim] = []
        var offset = 1
        if case let .prose(text)? = context.segment(1) {
            if let count = Self.rowCount(in: Self.firstSentence(text)) {
                claims.append(context.claim(.rowCount, .count(count)))
            }
            guard text.count <= 200 else { return claims }
            offset = 2
        }
        switch context.segment(offset) {
        case let .table(lines)?:
            if let table = ShownTable.parse(lines) { claims.append(context.claim(.result, .table(table))) }
        case let .code(label, body)? where Self.outputLabels.contains(label):
            if let table = ShownTable.parse(body.components(separatedBy: "\n")) {
                claims.append(context.claim(.result, .table(table)))
            }
        default:
            break
        }
        return claims
    }

    static func firstSentence(_ text: String) -> String {
        String(text.prefix { $0 != "\n" }).components(separatedBy: ". ")[0]
    }

    static let positive = [
        #"\bvalid (SQL|SQLite)\b"#,
        #"\bruns (as is|as written|without (an )?errors?)\b"#,
        #"\b(this|it) (runs|works)\b"#,
        #"\bexecutes without (an )?errors?\b"#
    ]
    static let negative = [
        #"\b(won't|will not|doesn't|does not) (run|work|parse)\b"#,
        #"\b(fails|raises|throws|gives|returns) (an? )?(error|exception)\b"#,
        #"\bsyntax error\b"#,
        #"\bis (invalid|not valid)\b"#,
        #"\bwill fail\b"#,
        #"\bfails with\b"#,
        #"\berrors out\b"#
    ]

    /// "This is valid SQL:" just before a block, or "This runs as is." / "This fails." just after it.
    func runsClaim(_ context: Context) -> SQLClaim? {
        let before: String? = if case let .prose(text)? = context.segment(-1), text.hasSuffix(":") {
            text.components(separatedBy: "\n")[text.components(separatedBy: "\n").count - 1]
        } else { nil }
        let after: String? = if case let .prose(text)? = context.segment(1) { Self.firstSentence(text) } else { nil }
        let options: String.CompareOptions = [.regularExpression, .caseInsensitive]
        for sentence in [before, after].compactMap({ $0 }) {
            if Self.negative.contains(where: { sentence.range(of: $0, options: options) != nil }) {
                return context.claim(.runs, .runs(false), target: context.script.count - 1)
            }
            if Self.positive.contains(where: { sentence.range(of: $0, options: options) != nil }) {
                return context.claim(.runs, .runs(true), target: context.script.count - 1)
            }
        }
        return nil
    }
}
