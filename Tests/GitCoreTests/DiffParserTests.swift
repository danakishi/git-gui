import Testing
@testable import GitCore

@Suite("DiffParser")
struct DiffParserTests {
    @Test func parsesModifiedFileWithTwoHunks() {
        let text = """
        diff --git a/src/a.swift b/src/a.swift
        index 1111..2222 100644
        --- a/src/a.swift
        +++ b/src/a.swift
        @@ -1,3 +1,4 @@ func header()
         let a = 1
        -let b = 2
        +let b = 3
        +let c = 4
         let d = 5
        @@ -10,2 +11,2 @@
         x
        -y
        +z
        \\ No newline at end of file
        """
        let files = DiffParser.parse(text)
        #expect(files.count == 1)
        let f = files[0]
        #expect(f.path == "src/a.swift")
        #expect(f.status == .modified)
        #expect(f.hunks.count == 2)
        #expect(f.additions == 3)
        #expect(f.deletions == 2)

        let h = f.hunks[0]
        #expect(h.header.hasSuffix("func header()"))
        #expect(h.lines[0].oldNumber == 1 && h.lines[0].newNumber == 1)
        #expect(h.lines[1].kind == .deletion && h.lines[1].oldNumber == 2 && h.lines[1].newNumber == nil)
        #expect(h.lines[2].kind == .addition && h.lines[2].newNumber == 2)
        #expect(h.lines[4].kind == .context && h.lines[4].oldNumber == 3 && h.lines[4].newNumber == 4)
        #expect(f.hunks[1].lines.last?.kind == .meta)
    }

    @Test func detectsAddedDeletedRenamedAndBinary() {
        let text = """
        diff --git a/new.txt b/new.txt
        new file mode 100644
        --- /dev/null
        +++ b/new.txt
        @@ -0,0 +1 @@
        +hello
        diff --git a/gone.txt b/gone.txt
        deleted file mode 100644
        --- a/gone.txt
        +++ /dev/null
        @@ -1 +0,0 @@
        -bye
        diff --git a/old name.txt b/new name.txt
        similarity index 100%
        rename from old name.txt
        rename to new name.txt
        diff --git a/img.png b/img.png
        index 1111..2222 100644
        Binary files a/img.png and b/img.png differ
        """
        let files = DiffParser.parse(text)
        #expect(files.map(\.status) == [.added, .deleted, .renamed, .modified])
        #expect(files[0].oldPath == nil && files[0].newPath == "new.txt")
        #expect(files[1].newPath == nil && files[1].oldPath == "gone.txt")
        #expect(files[2].oldPath == "old name.txt" && files[2].newPath == "new name.txt")
        #expect(files[2].hunks.isEmpty)
        #expect(files[3].isBinary)
    }

    @Test func additionsOnlyBuildsOneHunk() {
        let f = DiffParser.additionsOnly(path: "x.txt", text: "a\nb\n")
        #expect(f.status == .added)
        #expect(f.additions == 2)
        #expect(f.hunks[0].lines.map(\.newNumber) == [1, 2])
        #expect(DiffParser.additionsOnly(path: "e", text: "").hunks.isEmpty)
    }
}
