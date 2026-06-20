import Testing

@testable import Advisor

@Test func searchEmptyQueryMatchesEverything() {
    #expect(SessionSearch.matches(query: "  ", tags: [], haystack: "anything"))
}

@Test func searchPlainTextMatchesHaystackSubstring() {
    #expect(SessionSearch.matches(query: "Effect", tags: [], haystack: "effect systems talk"))
    #expect(!SessionSearch.matches(query: "missing", tags: [], haystack: "effect systems talk"))
}

@Test func searchHashTagFiltersByTag() {
    #expect(SessionSearch.matches(query: "#work", tags: ["Work"], haystack: ""))
    #expect(!SessionSearch.matches(query: "#work", tags: ["Urgent"], haystack: "work work work"))
}

@Test func searchHashTagMatchesBySubstringAndIsCaseInsensitive() {
    #expect(SessionSearch.matches(query: "#WORK", tags: ["Workshop"], haystack: ""))
}

@Test func searchHashTagIsTagSpecificNotHaystack() {
    // "foo" appears in the transcript but is not a tag: plain matches, #foo does not.
    #expect(SessionSearch.matches(query: "foo", tags: ["bar"], haystack: "talk about foo"))
    #expect(!SessionSearch.matches(query: "#foo", tags: ["bar"], haystack: "talk about foo"))
}

@Test func searchCombinesHashTagAndText() {
    #expect(SessionSearch.matches(
        query: "#work systems", tags: ["Work"], haystack: "effect systems talk"))
    // Tag matches but the text doesn't → no match.
    #expect(!SessionSearch.matches(
        query: "#work missing", tags: ["Work"], haystack: "effect systems talk"))
}

@Test func searchMultipleHashTagsRequireAll() {
    #expect(SessionSearch.matches(query: "#a #b", tags: ["a", "b"], haystack: ""))
    #expect(!SessionSearch.matches(query: "#a #b", tags: ["a"], haystack: ""))
}
