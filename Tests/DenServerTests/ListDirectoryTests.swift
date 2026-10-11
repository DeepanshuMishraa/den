import Foundation
import Testing
import DenProtocol
@testable import DenServer

@Suite struct ListDirectoryTests {
    @Test func listsEntriesWithKinds() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "den-list-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appending(path: "src"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: dir.appending(path: "README.md"))
        defer { try? FileManager.default.removeItem(at: dir) }

        let (path, entries) = DenServer.listDirectory(dir.path)
        #expect(path == dir.path)
        #expect(entries == [DirectoryEntry(name: "README.md", isDirectory: false), DirectoryEntry(name: "src", isDirectory: true)])
    }

    @Test func expandsHome() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        #expect(DenServer.listDirectory("~").0 == home)
        #expect(DenServer.listDirectory("~/").0 == home + "/")
    }

    @Test func unreadableFolderIsEmpty() {
        #expect(DenServer.listDirectory("/nonexistent-\(UUID().uuidString)").1.isEmpty)
    }
}
