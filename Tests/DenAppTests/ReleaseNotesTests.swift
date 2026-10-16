import Foundation
import Testing
@testable import DenApp

@Suite struct ReleaseNotesTests {
    @Test func announcesOnlyANewVersionOnAMacThatRanDenBefore() {
        #expect(WhatsNew.versionToAnnounce(current: "1.0.7", lastLaunched: "1.0.6", launchedBefore: true) == "1.0.7")
        #expect(WhatsNew.versionToAnnounce(current: "1.0.7", lastLaunched: "1.0.7", launchedBefore: true) == nil)
        // A fresh install has nothing to announce.
        #expect(WhatsNew.versionToAnnounce(current: "1.0.7", lastLaunched: nil, launchedBefore: false) == nil)
        // Updated from a version that didn't record itself yet.
        #expect(WhatsNew.versionToAnnounce(current: "1.0.7", lastLaunched: nil, launchedBefore: true) == "1.0.7")
        // Dev builds and CI's placeholder version.
        #expect(WhatsNew.versionToAnnounce(current: nil, lastLaunched: "1.0.6", launchedBefore: true) == nil)
        #expect(WhatsNew.versionToAnnounce(current: "0.0.0", lastLaunched: "1.0.6", launchedBefore: true) == nil)
    }

    @Test func repositoryComesFromTheUpdateFeed() {
        let feed = URL(string: "https://github.com/DeepanshuMishraa/den/releases/latest/download/appcast.xml")
        #expect(ReleaseNotes.repository(feed: feed) == "DeepanshuMishraa/den")
        #expect(ReleaseNotes.repository(feed: URL(string: "https://example.com/a/b/appcast.xml")) == nil)
        #expect(ReleaseNotes.repository(feed: nil) == nil)
        #expect(ReleaseNotes.page(repository: "a/b", version: "1.2.3")?.absoluteString == "https://github.com/a/b/releases/tag/v1.2.3")
    }

    @Test func parsesHeadingsBulletsAndParagraphs() throws {
        let blocks = ReleaseNotes.parse("""
        ## What's new

        - **Links**: click to open
          in the browser
        * Faster `seq`

        A closing line
        that wraps.
        """)
        try #require(blocks.count == 4)
        #expect(blocks[0] == .heading("What's new"))
        guard case .bullet(let links) = blocks[1], case .bullet(let seq) = blocks[2], case .paragraph(let closing) = blocks[3] else {
            Issue.record("unexpected blocks: \(blocks)")
            return
        }
        #expect(String(links.characters) == "Links: click to open in the browser")
        #expect(links.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true })
        #expect(String(seq.characters) == "Faster seq")
        #expect(String(closing.characters) == "A closing line that wraps.")
    }

    @Test func emptyNotesHaveNoBlocks() {
        #expect(ReleaseNotes.parse("\n  \n").isEmpty)
    }
}

@Suite struct DendRestartTests {
    @Test func peerPIDNamesTheProcessAcrossTheSocket() throws {
        var fds: [Int32] = [0, 0]
        try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
        defer { fds.forEach { close($0) } }
        #expect(DendLauncher.peerPID(fds[0]) == getpid())
    }

    /// It runs inside `sh -c '…'`.
    @Test func remoteRestartScriptHasNoSingleQuotesInside() {
        let script = RemoteSetup.restartCommand.dropFirst("sh -c '".count).dropLast()
        #expect(!script.contains("'"))
        #expect(script.contains("pgrep -u"))
    }
}
