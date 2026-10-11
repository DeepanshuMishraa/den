import Foundation
import Testing
@testable import DenApp

@Suite struct PathQueryTests {
    let home = "/Users/me"

    @Test func folderWithTrailingSlashLists() {
        #expect(PathQuery.parse("~/Apps/web/", home: home) == PathQuery(directory: "/Users/me/Apps/web", fragment: ""))
    }

    @Test func trailingWordIsTheFragment() {
        #expect(PathQuery.parse("~/Apps/web/lic", home: home) == PathQuery(directory: "/Users/me/Apps/web", fragment: "lic"))
        #expect(PathQuery.parse("/etc/ho", home: home) == PathQuery(directory: "/etc", fragment: "ho"))
        #expect(PathQuery.parse("/ho", home: home) == PathQuery(directory: "/", fragment: "ho"))
    }

    @Test func bareWordSearchesEverywhere() {
        #expect(PathQuery.parse("License.ts", home: home) == PathQuery(directory: nil, fragment: "License.ts"))
    }

    @Test func insertionIsRelativeInsideTheWorkingDirectory() {
        #expect(PathQuery.insertion(for: "/Users/me/web/apps/src/License.ts", cwd: "/Users/me/web", home: home) == "apps/src/License.ts")
    }

    @Test func insertionAbbreviatesHomeOutsideIt() {
        #expect(PathQuery.insertion(for: "/Users/me/notes/todo.md", cwd: "/Users/me/web", home: home) == "~/notes/todo.md")
        #expect(PathQuery.insertion(for: "/etc/hosts", cwd: "/Users/me/web", home: home) == "/etc/hosts")
    }

    /// A sibling sharing the cwd's prefix isn't inside it.
    @Test func siblingWithSharedPrefixIsNotRelative() {
        #expect(PathQuery.insertion(for: "/Users/me/web2/a", cwd: "/Users/me/web", home: home) == "~/web2/a")
    }

    @Test func insertionEscapesShellCharacters() {
        #expect(PathQuery.insertion(for: "/Users/me/web/My File (1).txt", cwd: "/Users/me/web", home: home) == "My\\ File\\ \\(1\\).txt")
    }

    @Test func listingRanksAndHidesDotfiles() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        try FileManager.default.createDirectory(atPath: dir + "/apps", withIntermediateDirectories: true)
        for f in ["Dockerfile", "docker-compose.yml", ".env", "LICENSE"] {
            FileManager.default.createFile(atPath: dir + "/" + f, contents: nil)
        }
        defer { try? FileManager.default.removeItem(atPath: dir) }

        #expect(PathEntry.listing(of: dir, matching: "").map(\.name) == ["apps", "docker-compose.yml", "Dockerfile", "LICENSE"])
        #expect(PathEntry.listing(of: dir, matching: "").first?.isDirectory == true)
        #expect(PathEntry.listing(of: dir, matching: "lic").map(\.name) == ["LICENSE"])
        #expect(PathEntry.listing(of: dir, matching: ".e").map(\.name).first == ".env")
    }
}

@Suite struct SearchHitRankingTests {
    private func entry(_ path: String, dir: Bool = false) -> PathEntry { PathEntry(path: path, isDirectory: dir) }

    @Test func folderNamedLikeTheQueryComesBeforeItsContents() {
        let hits = [
            entry("/Users/me/Desktop/files/fgiles/files", dir: true),
            entry("/Users/me/Desktop/desk-notes.md"),
            entry("/Users/me/Desktop", dir: true),
        ]
        let ranked = PathEntry.ranked(hits, matching: "Desk", under: "/Users/me")
        #expect(ranked.first?.path == "/Users/me/Desktop")
    }

    /// A hit only matched through a parent folder's name isn't shown.
    @Test func hitsMustMatchByTheirOwnName() {
        let hits = [entry("/Users/me/Desktop/files/fgiles/files", dir: true), entry("/Users/me/Desktop", dir: true)]
        #expect(PathEntry.ranked(hits, matching: "Desk", under: nil).map(\.path) == ["/Users/me/Desktop"])
    }

    @Test func shallowerWinsAmongEqualNames() {
        let hits = [entry("/Users/me/a/b/src", dir: true), entry("/Users/me/src", dir: true)]
        #expect(PathEntry.ranked(hits, matching: "src", under: "/Users/me").map(\.path) == ["/Users/me/src", "/Users/me/a/b/src"])
    }
}
