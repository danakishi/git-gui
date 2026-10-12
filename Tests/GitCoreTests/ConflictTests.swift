import Foundation
import Testing
@testable import GitCore

@Suite("Conflict markers")
struct ConflictTests {
    let text = """
    one
    <<<<<<< HEAD
    ours 1
    ours 2
    =======
    theirs
    >>>>>>> feature
    two
    <<<<<<< HEAD
    =======
    added
    >>>>>>> feature

    """

    @Test func parsesChunks() throws {
        let file = try #require(ConflictFile.parse(text))
        #expect(file.endsWithNewline)
        #expect(file.conflicts.count == 2)
        #expect(file.conflicts[0].ours == ["ours 1", "ours 2"])
        #expect(file.conflicts[0].theirs == ["theirs"])
        #expect(file.conflicts[0].oursLabel == "HEAD")
        #expect(file.conflicts[0].theirsLabel == "feature")
        #expect(file.conflicts[1].ours.isEmpty)
        #expect(file.chunks.first == .common(["one"]))
    }

    @Test func resolvesChosenSidesAndKeepsTheRest() throws {
        let file = try #require(ConflictFile.parse(text))
        #expect(file.resolved([0: [.theirs], 1: [.theirs]]) == "one\ntheirs\ntwo\nadded\n")
        #expect(file.resolved([0: [.ours, .theirs], 1: []]) == "one\nours 1\nours 2\ntheirs\ntwo\n")
        // With no choice made, the markers stay as they were.
        #expect(file.resolved([:]) == text)
        #expect(ConflictFile.hasMarkers(file.resolved([0: [.ours]])))
        #expect(!ConflictFile.hasMarkers(file.resolved([0: [.ours], 1: [.theirs]])))
    }

    @Test func parsesDiff3Base() throws {
        let file = try #require(ConflictFile.parse("<<<<<<< ours\na\n||||||| base\nb\n=======\nc\n>>>>>>> theirs"))
        #expect(!file.endsWithNewline)
        #expect(file.conflicts[0].base == ["b"])
        #expect(file.resolved([0: [.theirs]]) == "c")
    }

    @Test func rejectsTextWithoutOrWithUnclosedMarkers() {
        #expect(ConflictFile.parse("plain\ntext\n") == nil)
        #expect(ConflictFile.parse("<<<<<<< HEAD\na\n=======\nb\n") == nil)
        // Similar lines are not markers.
        #expect(ConflictFile.parse("<<<<<<<< x\n========\n") == nil)
    }

    @Test func parsesRealMergeConflict() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "gitgui-conflict-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let repo = GitRepository(dir)
        try await repo.run(["init", "-q", "-b", "main"])
        try await repo.run(["config", "user.name", "Test"])
        try await repo.run(["config", "user.email", "test@example.com"])
        let file = dir.appending(path: "a.txt")
        try "1\n2\n3\n".write(to: file, atomically: true, encoding: .utf8)
        try await repo.stageAll()
        try await repo.commit(message: "init")
        try await repo.createBranch("feature", checkout: true)
        try "1\nfeature\n3\n".write(to: file, atomically: true, encoding: .utf8)
        try await repo.stageAll()
        try await repo.commit(message: "feature")
        try await repo.checkout(branch: "main")
        try "1\nmain\n3\n".write(to: file, atomically: true, encoding: .utf8)
        try await repo.stageAll()
        try await repo.commit(message: "main")
        await #expect(throws: GitError.self) { try await repo.merge("feature") }

        let parsed = try #require(ConflictFile.parse(try String(contentsOf: file, encoding: .utf8)))
        #expect(parsed.conflicts.map(\.ours) == [["main"]])
        #expect(parsed.conflicts.map(\.theirs) == [["feature"]])
        #expect(parsed.resolved([0: [.theirs, .ours]]) == "1\nfeature\nmain\n3\n")
        #expect(await repo.externalTools().contains("opendiff"))
    }
}
