import Foundation

/// Whole-disk path search through fsearch (github.com/noahdunnagan/fsearch,
/// MIT, bundled in Den.app from vendor/fsearch):
/// one long-lived `fsearch stdio` process, which starts fsearch's daemon on
/// first use, answering JSON lines matched up by request id.
@MainActor
final class PathSearch {
    enum Failure: Error, Equatable {
        /// fsearch isn't installed; callers fall back to folder listings.
        case notInstalled
        /// The first run is still listing the disk.
        case indexing(String)
        case failed(String)
    }

    static let shared = PathSearch()

    private var process: Process?
    private var input: FileHandle?
    private var buffer = Data()
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<Result<[PathEntry], Failure>, Never>] = [:]

    /// The copy bundled next to Den's executable first, then a user install.
    static let candidates: [String] = {
        let bundled = Bundle.main.executableURL.map { $0.deletingLastPathComponent().appendingPathComponent("fsearch").path(percentEncoded: false) }
        return [bundled, NSHomeDirectory() + "/.local/bin/fsearch", "/opt/homebrew/bin/fsearch", "/usr/local/bin/fsearch"].compactMap { $0 }
    }()

    var isInstalled: Bool { Self.binary != nil }

    private static var binary: String? {
        candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Paths matching `query` (fsearch's fuzzy, typo-tolerant name search),
    /// best first, optionally only inside `directory` or only folders.
    func search(_ query: String, in directory: String? = nil, foldersOnly: Bool = false, limit: Int = 40) async -> Result<[PathEntry], Failure> {
        guard !query.isEmpty else { return .success([]) }
        switch ensureRunning() {
        case .failure(let failure): return .failure(failure)
        case .success(let input):
            let id = nextID
            nextID += 1
            var request: [String: Any] = ["q": query, "limit": limit, "id": id]
            if let directory { request["in"] = directory }
            if foldersOnly { request["kind"] = "dir" }
            guard var line = try? JSONSerialization.data(withJSONObject: request) else { return .failure(.failed("could not encode the request")) }
            line.append(0x0A)
            return await withCheckedContinuation { continuation in
                pending[id] = continuation
                do {
                    try input.write(contentsOf: line)
                } catch {
                    pending.removeValue(forKey: id)
                    stop()
                    continuation.resume(returning: .failure(.failed("fsearch stopped reading requests: \(error.localizedDescription)")))
                }
            }
        }
    }

    private func ensureRunning() -> Result<FileHandle, Failure> {
        if let input, process?.isRunning == true { return .success(input) }
        guard let binary = Self.binary else { return .failure(.notInstalled) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["stdio"]
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            Task { @MainActor in self?.receive(data) }
        }
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor in self?.stop() }
        }
        do {
            try process.run()
        } catch {
            return .failure(.failed("could not start \(binary): \(error.localizedDescription)"))
        }
        self.process = process
        input = stdin.fileHandleForWriting
        return .success(stdin.fileHandleForWriting)
    }

    private func receive(_ data: Data) {
        guard !data.isEmpty else { stop(); return }
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex ..< newline]
            buffer.removeSubrange(buffer.startIndex ... newline)
            guard let reply = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let id = reply["id"] as? Int, let continuation = pending.removeValue(forKey: id) else { continue }
            continuation.resume(returning: Self.parse(reply))
        }
    }

    private static func parse(_ reply: [String: Any]) -> Result<[PathEntry], Failure> {
        guard reply["ok"] as? Bool == true else {
            let message = reply["error"] as? String ?? "fsearch gave no reason"
            return .failure(message.hasPrefix("indexing") ? .indexing(message) : .failed(message))
        }
        let hits = reply["hits"] as? [[String: Any]] ?? []
        return .success(hits.compactMap { hit in
            (hit["path"] as? String).map { PathEntry(path: $0, isDirectory: hit["kind"] as? String == "dir") }
        })
    }

    /// The process went away: fail what's waiting; the next search restarts it.
    private func stop() {
        process?.terminate()
        process = nil
        input = nil
        buffer.removeAll()
        let waiting = pending
        pending.removeAll()
        for continuation in waiting.values { continuation.resume(returning: .failure(.failed("fsearch exited"))) }
    }
}
