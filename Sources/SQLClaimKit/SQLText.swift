import Foundation
import SQLite3

/// One statement of a SQL block, with the comments written after it.
public struct SQLStatement: Sendable, Hashable {
    /// The statement as written, ending with its `;` when it has one.
    public let text: String
    /// `--` comments after the statement: on the same line, and on the lines below it up to the next one.
    public let comments: [String]
}

/// Lexical helpers: splitting a block into statements and reading a statement without its strings and
/// comments. Quoting follows SQLite: `'...'` with `''` inside, `"..."`, `` `...` `` and `[...]` names,
/// `--` and `/* */` comments. A statement ends at a `;` that `sqlite3_complete` agrees ends one, so the
/// semicolons inside a trigger's `BEGIN ... END` do not split it.
enum SQLText {
    static func statements(in block: String) -> [SQLStatement] {
        var statements: [SQLStatement] = []
        var current = ""
        var pendingComments: [String] = []
        var scanner = Scanner(block)
        while let token = scanner.next() {
            switch token {
            case let .comment(text):
                if current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !statements.isEmpty {
                    pendingComments.append(text)
                } else {
                    current += "--" + text
                }
            case .newline:
                current += "\n"
            case let .other(text):
                if !text.allSatisfy(\.isWhitespace) { flush(&statements, &pendingComments) }
                current += text
            case .semicolon:
                current += ";"
                if sqlite3_complete(current) != 0 {
                    finish(&statements, &pendingComments, current)
                    current = ""
                }
            }
        }
        flush(&statements, &pendingComments)
        let rest = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !rest.isEmpty, !rest.hasPrefix("--") {
            statements.append(SQLStatement(text: rest, comments: []))
        }
        return statements
    }

    private static func finish(_ statements: inout [SQLStatement], _ comments: inout [String], _ text: String) {
        flush(&statements, &comments)
        statements.append(SQLStatement(text: text.trimmingCharacters(in: .whitespacesAndNewlines), comments: []))
    }

    private static func flush(_ statements: inout [SQLStatement], _ comments: inout [String]) {
        guard !comments.isEmpty, let last = statements.popLast() else { return }
        statements.append(SQLStatement(text: last.text, comments: last.comments + comments))
        comments = []
    }

    /// The statement's first word, upper-cased: `SELECT`, `WITH`, `ATTACH`.
    static func firstKeyword(_ statement: String) -> String? {
        stripped(statement).split(whereSeparator: { !$0.isLetter && $0 != "_" }).first.map { $0.uppercased() }
    }

    /// The statement upper-cased with string literals blanked and comments removed, for keyword searches.
    static func stripped(_ statement: String) -> String {
        var out = ""
        var scanner = Scanner(statement, blankStrings: true)
        while let token = scanner.next() {
            switch token {
            case .comment: out += " "
            case .newline: out += "\n"
            case .semicolon: out += ";"
            case let .other(text): out += text
            }
        }
        return out.uppercased()
    }

    /// Whether a keyword phrase (`ORDER BY`, `LIMIT`) appears outside every parenthesis.
    static func hasTopLevel(_ phrase: String, in statement: String) -> Bool {
        var depth = 0
        var flat = ""
        for character in stripped(statement) {
            if character == "(" { depth += 1 }
            flat.append(depth == 0 ? character : " ")
            if character == ")" { depth = max(0, depth - 1) }
        }
        let words = flat.split(whereSeparator: { !$0.isLetter && $0 != "_" }).joined(separator: " ")
        return (" " + words + " ").contains(" " + phrase + " ")
    }

    enum Token: Equatable {
        case comment(String)
        case newline
        case semicolon
        case other(String)
    }

    /// Splits SQL into comments, newlines, semicolons and everything else, keeping quoted text whole.
    struct Scanner {
        private let characters: [Character]
        private var index = 0
        private let blankStrings: Bool

        init(_ text: String, blankStrings: Bool = false) {
            characters = Array(text)
            self.blankStrings = blankStrings
        }

        mutating func next() -> Token? {
            guard index < characters.count else { return nil }
            let character = characters[index]
            if character == "\n" { index += 1; return .newline }
            if character == ";" { index += 1; return .semicolon }
            if character == "-", peek(1) == "-" { return .comment(lineComment()) }
            if character == "/", peek(1) == "*" { return .other(blockComment()) }
            if let close = Self.closers[character] { return .other(quoted(close)) }
            var text = ""
            while index < characters.count, !Self.stops.contains(characters[index]), !startsComment() {
                text.append(characters[index])
                index += 1
            }
            return .other(text)
        }

        static let closers: [Character: Character] = ["'": "'", "\"": "\"", "`": "`", "[": "]"]
        static let stops: Set<Character> = ["\n", ";", "'", "\"", "`", "["]

        private func peek(_ offset: Int) -> Character? {
            index + offset < characters.count ? characters[index + offset] : nil
        }

        private func startsComment() -> Bool {
            (characters[index] == "-" && peek(1) == "-") || (characters[index] == "/" && peek(1) == "*")
        }

        private mutating func lineComment() -> String {
            index += 2
            var text = ""
            while index < characters.count, characters[index] != "\n" {
                text.append(characters[index])
                index += 1
            }
            return text
        }

        private mutating func blockComment() -> String {
            index += 2
            while index < characters.count, !(characters[index] == "*" && peek(1) == "/") {
                index += 1
            }
            index = min(index + 2, characters.count)
            return " "
        }

        private mutating func quoted(_ close: Character) -> String {
            let open = characters[index]
            var text = String(open)
            index += 1
            while index < characters.count {
                let character = characters[index]
                index += 1
                if character == close {
                    if close == "'" || close == "\"", peek(0) == close {
                        text.append(character)
                        text.append(close)
                        index += 1
                        continue
                    }
                    text.append(character)
                    break
                }
                text.append(blankStrings && open == "'" ? " " : character)
            }
            return text
        }
    }
}
