import Foundation
import Testing
@testable import DenProtocol

@Suite struct FDWriterTests {
    /// Frames come back intact however the stream is split, including past
    /// the decoder's compaction point.
    @Test func decoderSplitsFramesAcrossArbitraryReads() throws {
        var rng = SplitMix64(seed: 85)
        let payloads = (0 ..< 3000).map { i in Data((0 ..< Int(rng.next() % 700)).map { UInt8(truncatingIfNeeded: $0 ^ i) }) }
        let stream = payloads.reduce(into: Data()) { $0.append(Frame.wrap($1)) }
        var decoder = FrameDecoder()
        var out: [Data] = []
        var i = 0
        while i < stream.count {
            let end = min(stream.count, i + 1 + Int(rng.next() % 9000))
            decoder.append(stream.subdata(in: i ..< end))
            while let p = try decoder.next() { out.append(p) }
            i = end
        }
        #expect(out == payloads)
    }

    /// A backlog far past the socket buffer drains completely and in order.
    @Test func backlogDrainsInOrder() async throws {
        var fds: [Int32] = [-1, -1]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
        defer { close(fds[0]); close(fds[1]) }
        _ = fcntl(fds[0], F_SETFL, fcntl(fds[0], F_GETFL) | O_NONBLOCK)

        let queue = DispatchQueue(label: "fdwriter.test")
        let writer = FDWriter(fd: fds[0], queue: queue)
        var expected = Data()
        queue.sync {
            for i in 0 ..< 2000 {
                // Uneven sizes so partial writes land mid-chunk.
                let chunk = Data((0 ..< (1 + i * 37 % 4093)).map { UInt8(truncatingIfNeeded: $0 &+ i) })
                expected.append(chunk)
                writer.write(chunk)
            }
        }
        #expect(queue.sync { writer.pendingBytes } > 0)

        var received = Data()
        var buffer = [UInt8](repeating: 0, count: 1500)
        while received.count < expected.count {
            let n = read(fds[1], &buffer, buffer.count)
            #expect(n > 0)
            if n <= 0 { break }
            received.append(contentsOf: buffer[0 ..< n])
        }
        #expect(received == expected)
        #expect(queue.sync { writer.pendingBytes } == 0)
    }
}
