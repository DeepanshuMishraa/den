import Foundation
import Testing
@testable import DenVT

/// Headless VT-parse microbench: feeds `scripts/bench/corpus/*` through
/// `VTTerminal` in 64KB chunks (PTY-sized) and reports MB/s.
/// This isolates libtermy's parse cost from dend IPC + Metal rendering,
/// so a Den-vs-Ghostty gap larger than this is overhead outside the parser.
/// Run: `swift test --filter ParseBench`
@Suite struct ParseBench {
    static let corpus: URL = {
        let thisFile = URL(fileURLWithPath: #filePath)
        return thisFile
            .deletingLastPathComponent() // ParseBenchTests.swift
            .deletingLastPathComponent() // DenVTTests
            .deletingLastPathComponent() // Tests
            .appendingPathComponent("scripts/bench/corpus")
    }()

    @Test func parseCorpus() throws {
        let fm = FileManager.default
        let files = try fm.contentsOfDirectory(at: Self.corpus, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasSuffix(".bin") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        #expect(!files.isEmpty, "no corpus files in \(Self.corpus.path)")
        for url in files {
            let data = try Data(contentsOf: url)
            var best = Double.greatestFiniteMagnitude
            for _ in 0 ..< 3 { best = min(best, try Self.timeParse(data)) }
            let mb = Double(data.count) / 1_048_576
            print(String(format: "BENCH parse %-14@ %7.2f MB in %6.3f s = %6.1f MB/s",
                         url.lastPathComponent as NSString, mb, best, mb / best))
            // Snapshot + restore cost (what every Den attach pays once).
            let term = try VTTerminal(cols: 117, rows: 32)
            term.write(data)
            let s0 = ContinuousClock().now
            let snap = try term.snapshot()
            _ = try VTTerminal(snapshot: snap)
            let snapSecs = Self.seconds(since: s0)
            print(String(format: "BENCH snapshot %-14@ snapshot %.2f MB in %.3f s",
                         url.lastPathComponent as NSString, Double(snap.count) / 1_048_576, snapSecs))
        }
    }

    private static func timeParse(_ data: Data) throws -> Double {
        let term = try VTTerminal(cols: 117, rows: 32)
        let start = ContinuousClock().now
        var off = 0
        while off < data.count {
            let end = min(off + 64 * 1024, data.count)
            term.write(data[off ..< end])
            off = end
        }
        return Self.seconds(since: start)
    }

    private static func seconds(since start: ContinuousClock.Instant) -> Double {
        let d = ContinuousClock().now - start
        let c = d.components
        return Double(c.seconds) + Double(c.attoseconds) / 1e18
    }
}
