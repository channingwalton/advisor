import Foundation

/// The YAML forms that a session note's frontmatter uses. A note can live in an
/// Obsidian vault, which parses the frontmatter as YAML. So free text (`name`,
/// `context`) is written as a double-quoted string, and `tags` as a flow list of
/// double-quoted strings. The reader also accepts a single-quoted string and the
/// plain (unquoted) values that older notes hold. Pure, for testability.
enum FrontmatterYAML {
    /// `value` as a YAML double-quoted string: `\` and `"` escaped, and each
    /// character that a YAML reader can refuse (control characters, U+FFFE and
    /// U+FFFF) or read as a line break (U+2028, U+2029) written as an escape.
    static func quoted(_ value: String) -> String {
        var out = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case _ where needsEscape(scalar.value):
                out += String(format: "\\u%04X", scalar.value)
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }

    private static func needsEscape(_ v: UInt32) -> Bool {
        v < 0x20 || (0x7F...0x9F).contains(v) || v == 0x2028 || v == 0x2029
            || v == 0xFEFF || v == 0xFFFE || v == 0xFFFF
    }

    /// The text of a frontmatter value: a double- or single-quoted string is
    /// decoded, and any other value is returned as it stands (the plain form
    /// that older notes hold).
    static func scalar(_ raw: String) -> String {
        var rest = Substring(raw)
        return quotedString(&rest).flatMap { rest.isEmpty ? $0 : nil } ?? raw
    }

    /// `items` as a YAML flow list of double-quoted strings: `["a", "b"]`.
    static func flowList(_ items: [String]) -> String {
        "[" + items.map(quoted).joined(separator: ", ") + "]"
    }

    /// The items of a YAML flow list (`[a, "b", 'c']`), each decoded as by
    /// `scalar`. `nil` when `raw` is not a flow list, or when a plain item holds
    /// a bracket or a brace: an older comma-separated line such as
    /// `[WIP], [Done]`, or a nested list, which no tag can be.
    static func list(_ raw: String) -> [String]? {
        guard raw.hasPrefix("["), raw.hasSuffix("]") else { return nil }
        var rest = raw.dropFirst().dropLast()
        var items: [String] = []
        while true {
            rest = droppingSpace(rest)
            if rest.isEmpty { return items }
            let item: String
            if let text = quotedString(&rest) {
                item = text
            } else {
                let plain = rest.unicodeScalars.prefix { $0 != "," }
                guard !plain.contains(where: { "[]{}".unicodeScalars.contains($0) })
                else { return nil }
                item = String(plain).trimmingCharacters(in: .whitespaces)
                rest = Substring(rest.unicodeScalars.dropFirst(plain.count))
            }
            items.append(item)
            rest = droppingSpace(rest)
            if rest.unicodeScalars.first == "," {
                rest = Substring(rest.unicodeScalars.dropFirst())
            } else if !rest.isEmpty {
                return nil
            }
        }
    }

    /// The items of a YAML block list: the lines under a key with no value,
    /// each `- item` (indented or not), each item decoded as by `scalar`. This is
    /// the form Obsidian writes for `tags`. A line that is not an item continues
    /// the item above it, joined with a space, as YAML folds a multi-line value;
    /// so no line is lost when the list is written again. `nil` when `lines` is
    /// empty or its first line is not an item.
    static func blockList(_ lines: [String]) -> [String]? {
        var raw: [String] = []
        for line in lines {
            let text = droppingSpace(Substring(line))
            if text.isEmpty { continue }
            if isItem(text) {
                raw.append(String(text.unicodeScalars.dropFirst()).trimmingCharacters(in: .whitespaces))
            } else if !raw.isEmpty {
                raw[raw.count - 1] += " " + text.trimmingCharacters(in: .whitespaces)
            } else {
                return nil
            }
        }
        return raw.isEmpty ? nil : raw.map(scalar)
    }

    /// The lines of a frontmatter block, grouped by key: each `key:` line with
    /// the lines that belong to it (blank lines, indented lines, and the
    /// `- item` lines of a block list). Any other line starts a group.
    static func entries(_ lines: [String]) -> [[String]] {
        var groups: [[String]] = []
        for line in lines {
            let first = line.unicodeScalars.first
            let continues = first == nil || first == " " || first == "\t" || isItem(Substring(line))
            if continues, !groups.isEmpty {
                groups[groups.count - 1].append(line)
            } else {
                groups.append([line])
            }
        }
        return groups
    }

    /// `text` without its leading spaces and tabs.
    private static func droppingSpace(_ text: Substring) -> Substring {
        Substring(text.unicodeScalars.drop { $0 == " " || $0 == "\t" })
    }

    /// Whether `text` is a block-list item: `-` alone, or `-` and a space or tab.
    private static func isItem(_ text: Substring) -> Bool {
        let scalars = text.unicodeScalars
        guard scalars.first == "-" else { return false }
        let next = scalars.dropFirst().first
        return next == nil || next == " " || next == "\t"
    }

    /// Reads a quoted string from the start of `text` and removes it from
    /// `text`. `nil`, with `text` unchanged, when `text` does not start with a
    /// complete quoted string. Each reader walks Unicode scalars, not
    /// Characters: a quote followed by a combining mark is one Character, and
    /// it must still read as a quote.
    private static func quotedString(_ text: inout Substring) -> String? {
        switch text.unicodeScalars.first {
        case "\"": return doubleQuoted(&text)
        case "'": return singleQuoted(&text)
        default: return nil
        }
    }

    private static func doubleQuoted(_ text: inout Substring) -> String? {
        var scalars = text.unicodeScalars.dropFirst()
        var out = String.UnicodeScalarView()
        while let c = scalars.popFirst() {
            if c == "\"" {
                text = Substring(scalars)
                return String(out)
            }
            guard c == "\\" else {
                out.append(c)
                continue
            }
            guard let e = scalars.popFirst() else { return nil }
            switch e {
            case "n": out.append("\n")
            case "r": out.append("\r")
            case "t": out.append("\t")
            case "0": out.append("\0")
            case "a": out.append("\u{7}")
            case "b": out.append("\u{8}")
            case "e": out.append("\u{1B}")
            case "v": out.append("\u{B}")
            case "f": out.append("\u{C}")
            case "N": out.append("\u{85}")
            case "_": out.append("\u{A0}")
            case "L": out.append("\u{2028}")
            case "P": out.append("\u{2029}")
            case "\"", "\\", "/", " ", "\t": out.append(e)
            case "u", "x", "U":
                let width = e == "x" ? 2 : e == "u" ? 4 : 8
                let hex = String(scalars.prefix(width))
                guard hex.count == width, hex.allSatisfy(\.isHexDigit),
                    let v = UInt32(hex, radix: 16),
                    let u = Unicode.Scalar(v)
                else { return nil }
                out.append(u)
                scalars = scalars.dropFirst(width)
            default: return nil // not a YAML escape
            }
        }
        return nil
    }

    private static func singleQuoted(_ text: inout Substring) -> String? {
        var rest = text.unicodeScalars.dropFirst()
        var out = String.UnicodeScalarView()
        while let c = rest.popFirst() {
            if c == "'" {
                if rest.first == "'" {
                    out.append("'")
                    rest = rest.dropFirst()
                } else {
                    text = Substring(rest)
                    return String(out)
                }
            } else {
                out.append(c)
            }
        }
        return nil
    }
}
