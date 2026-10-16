import Foundation

/// "What's new" after an update: the version Den was updated to and its
/// GitHub release notes, which are the notes we write when publishing.
struct WhatsNew: Equatable {
    enum Notes: Equatable {
        case loading
        case loaded([ReleaseNotes.Block])
        /// Why they couldn't be shown; the release page still opens.
        case unavailable(String)
    }

    let version: String
    let page: URL
    var notes: Notes

    /// Defaults key: the version that last launched, so the next one can
    /// tell it was updated.
    static let lastLaunchedKey = "lastLaunchedVersion"
    /// Sparkle sets this on any launch of a release build, including ones
    /// from before Den remembered its version.
    static let sparkleLaunchedKey = "SUHasLaunchedBefore"

    /// The version to announce on this launch: a new one, on a Mac that ran
    /// Den before. Nothing on a first install or a relaunch.
    static func versionToAnnounce(current: String?, lastLaunched: String?, launchedBefore: Bool) -> String? {
        guard let current, !current.isEmpty, current != "0.0.0" else { return nil }
        if let lastLaunched { return lastLaunched == current ? nil : current }
        return launchedBefore ? current : nil
    }
}

/// A release's notes from GitHub, as blocks the dialog lays out.
enum ReleaseNotes {
    enum Block: Equatable {
        case heading(String)
        case bullet(AttributedString)
        case paragraph(AttributedString)
    }

    struct FetchError: Error, CustomStringConvertible {
        let description: String
    }

    /// `owner/repo` from the update feed (Info.plist `SUFeedURL`), which
    /// lives on the same GitHub repository as the releases.
    static func repository(feed: URL?) -> String? {
        guard let feed, feed.host == "github.com" else { return nil }
        let parts = feed.pathComponents.filter { $0 != "/" }
        return parts.count >= 2 ? "\(parts[0])/\(parts[1])" : nil
    }

    static func page(repository: String, version: String) -> URL? {
        URL(string: "https://github.com/\(repository)/releases/tag/v\(version)")
    }

    /// The release body for `v<version>`.
    static func fetch(repository: String, version: String) async -> Result<[Block], FetchError> {
        guard let url = URL(string: "https://api.github.com/repos/\(repository)/releases/tags/v\(version)") else {
            return .failure(FetchError(description: "No release address for \(repository) v\(version)."))
        }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let data: Data, response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            return .failure(FetchError(description: "The release notes couldn't be loaded (\(error.localizedDescription))."))
        }
        guard let status = (response as? HTTPURLResponse)?.statusCode, status == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            return .failure(FetchError(description: "GitHub answered \(code) for the v\(version) release notes."))
        }
        struct Release: Decodable { let body: String? }
        guard let release = try? JSONDecoder().decode(Release.self, from: data) else {
            return .failure(FetchError(description: "GitHub's reply for v\(version) wasn't a release Den can read."))
        }
        let blocks = parse(release.body ?? "")
        return blocks.isEmpty ? .failure(FetchError(description: "This release has no notes.")) : .success(blocks)
    }

    /// Headings, bullets and paragraphs from release-note Markdown, with
    /// inline styling (bold, code, links) kept. Wrapped lines join the
    /// block above them.
    static func parse(_ markdown: String) -> [Block] {
        func inline(_ text: String) -> AttributedString {
            (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
                ?? AttributedString(text)
        }
        var blocks: [Block] = []
        // Raw text of the block being read, so continuation lines can join it.
        var open: (kind: Character, text: String)?
        func flush() {
            guard let block = open else { return }
            blocks.append(block.kind == "-" ? .bullet(inline(block.text)) : .paragraph(inline(block.text)))
            open = nil
        }
        for raw in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                flush()
            } else if line.hasPrefix("#") {
                flush()
                let title = line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
                if !title.isEmpty { blocks.append(.heading(title)) }
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                flush()
                open = ("-", String(line.dropFirst(2)))
            } else if let current = open {
                open = (current.kind, current.text + " " + line)
            } else {
                open = ("p", line)
            }
        }
        flush()
        return blocks
    }
}
