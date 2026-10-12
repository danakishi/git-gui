import Testing
@testable import GitCore

@Suite("Fuzzy search")
struct FuzzyMatchTests {
    @Test func matchesSubsequenceIgnoringCase() {
        #expect(FuzzyMatch.match("fp", in: "Fetch and Pull") != nil)
        #expect(FuzzyMatch.match("PUSH", in: "Push") != nil)
        #expect(FuzzyMatch.match("bran", in: "New Branch…") != nil)
        #expect(FuzzyMatch.match("pf", in: "Fetch") == nil)
        #expect(FuzzyMatch.match("fetchx", in: "Fetch") == nil)
    }

    @Test func emptyQueryMatchesEverything() {
        #expect(FuzzyMatch.match("", in: "anything")?.score == 0)
        #expect(FuzzyMatch.match("  ", in: "anything") != nil)
    }

    @Test func prefersWordStartsAndContiguousRuns() throws {
        // "main" in full at the end beats scattered letters.
        let r = try #require(FuzzyMatch.match("main", in: "my-api/origin/main"))
        #expect(r.positions == [14, 15, 16, 17])

        let exact = try #require(FuzzyMatch.match("push", in: "Push"))
        let scattered = try #require(FuzzyMatch.match("push", in: "Pull --rebase: update shared"))
        #expect(exact.score > scattered.score)

        let wordStart = try #require(FuzzyMatch.match("nb", in: "New branch"))
        let middle = try #require(FuzzyMatch.match("nb", in: "Unbranch"))
        #expect(wordStart.score > middle.score)
    }

    @Test func shorterTextWinsOnTie() throws {
        let short = try #require(FuzzyMatch.match("api", in: "api"))
        let long = try #require(FuzzyMatch.match("api", in: "api-gateway-for-everything-and-more"))
        #expect(short.score > long.score)
    }
}
