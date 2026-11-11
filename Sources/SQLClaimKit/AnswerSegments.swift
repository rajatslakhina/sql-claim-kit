import Foundation

/// An answer cut into prose, fenced code blocks and markdown tables, in order.
enum Segment: Equatable {
    case prose(String)
    case code(label: String, body: String)
    case table([String])

    static func parse(_ text: String) -> [Segment] {
        var segments: [Segment] = []
        var prose: [String] = []
        var table: [String] = []
        var fence: Fence?
        func flushProse() {
            let joined = prose.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty { segments.append(.prose(joined)) }
            prose = []
        }
        func flushTable() {
            if !table.isEmpty { segments.append(.table(table)) }
            table = []
        }
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let open = fence {
                if trimmed == "```" {
                    segments.append(.code(label: open.label, body: open.lines.joined(separator: "\n")))
                    fence = nil
                } else {
                    fence?.lines.append(line)
                }
            } else if trimmed.hasPrefix("```") {
                flushProse()
                flushTable()
                let label = trimmed.drop { $0 == "`" }.trimmingCharacters(in: .whitespaces).lowercased()
                fence = Fence(label: label.split(separator: " ").first.map(String.init) ?? "", lines: [])
            } else if trimmed.hasPrefix("|") {
                flushProse()
                table.append(trimmed)
            } else {
                flushTable()
                prose.append(line)
            }
        }
        if let open = fence {
            segments.append(.code(label: open.label, body: open.lines.joined(separator: "\n")))
        }
        flushTable()
        flushProse()
        return segments
    }

    /// An open code fence: its label and the lines read so far.
    struct Fence {
        let label: String
        var lines: [String]
    }
}

/// Output an answer shows for a query: a markdown table, a psql-style box, or `sqlite3` list output.
public struct ShownTable: Sendable, Hashable {
    public let header: [String]?
    public let rows: [[String]]

    public init(header: [String]?, rows: [[String]]) {
        self.header = header
        self.rows = rows
    }

    /// Reads table lines. A line of dashes, `=`, `+` and `|` after the first line makes the first line a
    /// header; `(3 rows)` footers and box borders are dropped.
    static func parse(_ lines: [String]) -> ShownTable? {
        var cells: [[String]] = []
        var header: [String]?
        for line in lines.map({ $0.trimmingCharacters(in: .whitespaces) }) where !line.isEmpty {
            if line.allSatisfy({ "-=+|: ".contains($0) }) {
                if cells.count == 1, header == nil { header = cells.removeFirst() }
                continue
            }
            if line.range(of: #"^\(\d+ rows?\)$"#, options: .regularExpression) != nil { continue }
            cells.append(split(line))
        }
        guard header != nil || !cells.isEmpty else { return nil }
        return ShownTable(header: header, rows: cells)
    }

    static func split(_ line: String) -> [String] {
        var body = Substring(line)
        if body.hasPrefix("|") { body = body.dropFirst() }
        if body.hasSuffix("|") { body = body.dropLast() }
        return body.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    var width: Int {
        header?.count ?? rows.first?.count ?? 0
    }

    var rendered: String {
        SQLResult.describe(rows)
    }
}
