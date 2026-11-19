import Foundation
import Testing

@testable import Advisor

// Session notes can live in an Obsidian vault, which parses the frontmatter as
// YAML. A plain value such as `context: Meeting: plan` is not valid YAML, and
// `tags: a, b` is one string, not a list.

@Test func quotedWrapsAndEscapesAValue() {
    #expect(FrontmatterYAML.quoted("Meeting: plan the release") == "\"Meeting: plan the release\"")
    #expect(FrontmatterYAML.quoted(#"say "hi" \ bye"#) == #""say \"hi\" \\ bye""#)
}

@Test func quotedEscapesControlCharacters() {
    #expect(FrontmatterYAML.quoted("a\rb\u{1}c\td") == #""a\rb\u0001c\td""#)
}

@Test func scalarDecodesAQuotedValue() {
    #expect(FrontmatterYAML.scalar(#""say \"hi\" \\ bye""#) == #"say "hi" \ bye"#)
    #expect(FrontmatterYAML.scalar(#""a\rb\u0001c\td\n""#) == "a\rb\u{1}c\td\n")
    #expect(FrontmatterYAML.scalar("'it''s here'") == "it's here")
}

@Test func scalarKeepsAnOldPlainValue() {
    #expect(FrontmatterYAML.scalar("Effects") == "Effects")
    #expect(FrontmatterYAML.scalar("Talk at 10:30") == "Talk at 10:30")
    #expect(FrontmatterYAML.scalar("2026-06-18T17:00:00Z") == "2026-06-18T17:00:00Z")
}

@Test func scalarRoundTripsThroughQuoted() {
    for value in ["Meeting: plan", "#155 review", "[WIP] standup", "- draft", #"a "b" \c"#, "x\u{7}y"] {
        #expect(FrontmatterYAML.scalar(FrontmatterYAML.quoted(value)) == value)
    }
}

@Test func flowListQuotesEachItem() {
    #expect(FrontmatterYAML.flowList(["Work", "Client A"]) == #"["Work", "Client A"]"#)
    #expect(FrontmatterYAML.flowList([]) == "[]")
}

@Test func listParsesAFlowList() {
    #expect(FrontmatterYAML.list(#"["Work", "Client A"]"#) == ["Work", "Client A"])
    #expect(FrontmatterYAML.list(#"[ "a, b", 'it''s', plain ]"#) == ["a, b", "it's", "plain"])
    #expect(FrontmatterYAML.list("[]") == [])
}

@Test func listIsNilForAValueThatIsNotAFlowList() {
    #expect(FrontmatterYAML.list("work, urgent") == nil)
}

@Test func listRoundTripsThroughFlowList() {
    let items = ["Work", "Client A", #"q"uote"#, #"back\slash"#, "a]b"]
    #expect(FrontmatterYAML.list(FrontmatterYAML.flowList(items)) == items)
}

@Test func quotedEscapesNonPrintableCharacters() {
    // js-yaml (Obsidian) refuses a document that holds C1 controls or U+FFFE/F.
    #expect(FrontmatterYAML.quoted("a\u{80}b\u{9F}c\u{FFFF}d\u{2028}") == #""a\u0080b\u009Fc\uFFFFd\u2028""#)
    #expect(FrontmatterYAML.quoted("café 😀") == "\"café 😀\"")
}

@Test func scalarDecodesEveryYAMLEscape() {
    #expect(FrontmatterYAML.scalar(#""\b\a\e\v\f\N\_\L\P\ \U0001F600""#)
        == "\u{8}\u{7}\u{1B}\u{B}\u{C}\u{85}\u{A0}\u{2028}\u{2029} 😀")
}

@Test func scalarKeepsAValueWithAnUnknownEscape() {
    #expect(FrontmatterYAML.scalar(#""a\qb""#) == #""a\qb""#)
}

@Test func blockListReadsTheItemsUnderAKey() {
    #expect(FrontmatterYAML.blockList(["  - work", "  - \"Client A\"", "- 'it''s'"]) == ["work", "Client A", "it's"])
    #expect(FrontmatterYAML.blockList([]) == nil)
    #expect(FrontmatterYAML.blockList(["  more text"]) == nil)
}

@Test func blockListJoinsAnItemThatContinuesOnTheNextLine() {
    // YAML folds an indented line that is not an item into the item above it.
    #expect(FrontmatterYAML.blockList(["  - work", "  - a long", "    tag name", "  - urgent"])
        == ["work", "a long tag name", "urgent"])
    #expect(FrontmatterYAML.blockList(["  - \"a long", "    tag\""]) == ["a long tag"])
}

@Test func blockListIsNilWhenTheFirstLineIsNotAnItem() {
    #expect(FrontmatterYAML.blockList(["  text", "  - work"]) == nil)
}

@Test func scalarRefusesAHexEscapeWithASign() {
    #expect(FrontmatterYAML.scalar(#""\x+1""#) == #""\x+1""#)
    #expect(FrontmatterYAML.scalar(#""\u+041""#) == #""\u+041""#)
}

@Test func quotedEscapesAByteOrderMark() {
    #expect(FrontmatterYAML.quoted("\u{FEFF}Agenda") == #""\uFEFFAgenda""#)
}

@Test func entriesKeepABlankLineInsideABlockListWithItsKey() {
    #expect(FrontmatterYAML.entries(["a: 1", "tags:", "  - x", "", "  - y", "b: 2"])
        == [["a: 1"], ["tags:", "  - x", "", "  - y"], ["b: 2"]])
}

@Test func entriesStartAGroupForAKeyThatStartsWithADash() {
    #expect(FrontmatterYAML.entries(["tags: [\"a\"]", "-x: 1"]) == [["tags: [\"a\"]"], ["-x: 1"]])
}

@Test func blockListSkipsABlankLine() {
    #expect(FrontmatterYAML.blockList(["  - x", "", "  - y"]) == ["x", "y"])
}

@Test func scalarDecodesAValueThatStartsWithACombiningMark() {
    let value = "\u{301}Talk 'x'"
    #expect(FrontmatterYAML.scalar(FrontmatterYAML.quoted(value)) == value)
    #expect(FrontmatterYAML.scalar("'\u{301}Talk'") == "\u{301}Talk")
    #expect(FrontmatterYAML.list(FrontmatterYAML.flowList([value, "\u{301}b"])) == [value, "\u{301}b"])
}

@Test func listIsNilWhenAPlainItemHoldsABracket() {
    // An older comma-separated line such as `[WIP], [Done]` is not a flow list.
    #expect(FrontmatterYAML.list("[WIP], [Done]") == nil)
    #expect(FrontmatterYAML.list("[[a, b], c]") == nil)
}

@Test func linesThatStartWithACombiningMarkStayWithTheirKey() {
    #expect(FrontmatterYAML.entries(["tags:", "- \u{301}b", " \u{301}c"]) == [["tags:", "- \u{301}b", " \u{301}c"]])
    #expect(FrontmatterYAML.blockList(["- \u{301}b"]) == ["\u{301}b"])
    #expect(FrontmatterYAML.list("[a,\u{301}b]") == ["a", "\u{301}b"])
}
