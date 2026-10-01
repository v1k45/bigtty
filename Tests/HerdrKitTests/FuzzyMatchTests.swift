import Testing
@testable import HerdrKit

@Suite struct FuzzyMatchTests {
    @Test func lettersInOrder() {
        #expect(FuzzyMatch.match("ghr", in: "goatherder") != nil)
        #expect(FuzzyMatch.match("rhg", in: "goatherder") == nil)
        #expect(FuzzyMatch.match("", in: "anything")?.score == 0)
        #expect(FuzzyMatch.match("GOAT", in: "goatherder") != nil)
    }

    @Test func positionsPointAtTheLetters() {
        let result = FuzzyMatch.match("go", in: "goatherder")
        #expect(result?.positions == [0, 1])
        let words = FuzzyMatch.match("ah", in: "api-handler")
        #expect(words?.positions == [0, 4])
    }

    @Test func prefixBeatsMiddle() throws {
        let prefix = try #require(FuzzyMatch.match("api", in: "api-server"))
        let middle = try #require(FuzzyMatch.match("api", in: "rapid-deploy"))
        #expect(prefix.score > middle.score)
    }

    @Test func wordStartsBeatScattered() throws {
        let starts = try #require(FuzzyMatch.match("bmm", in: "build-matrix-mode"))
        let scattered = try #require(FuzzyMatch.match("bmm", in: "abamamam"))
        #expect(starts.score > scattered.score)
    }

    @Test func consecutiveBeatsScattered() throws {
        let run = try #require(FuzzyMatch.match("herd", in: "goatherder"))
        let spread = try #require(FuzzyMatch.match("herd", in: "shxexrxdx"))
        #expect(run.score > spread.score)
    }

    @Test func shorterWinsTies() throws {
        let short = try #require(FuzzyMatch.match("docs", in: "docs"))
        let long = try #require(FuzzyMatch.match("docs", in: "docs-internal-archive-2024"))
        #expect(short.score > long.score)
    }

    @Test func everyWordMustMatch() {
        #expect(FuzzyMatch.matchWords("tests load", in: "backend-load-tests") != nil)
        #expect(FuzzyMatch.matchWords("tests golf", in: "backend-load-tests") == nil)
    }

    @Test func wholeWordBeatsScatteredLetters() throws {
        let result = try #require(FuzzyMatch.match("coupon", in: "Checkout coupon field"))
        #expect(result.positions == Array(9..<15))
    }

    @Test func picksTheBestAlignment() throws {
        // "ts" should use the word start of "status", not the first t.
        let result = try #require(FuzzyMatch.match("ls", in: "platform-live-status"))
        #expect(result.positions == [9, 14])
    }
}
