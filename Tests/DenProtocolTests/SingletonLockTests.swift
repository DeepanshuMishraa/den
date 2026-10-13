import Foundation
import Testing
@testable import DenProtocol

@Suite struct SingletonLockTests {
    @Test func secondAcquirerLosesWhileFirstHolds() throws {
        let path = FileManager.default.temporaryDirectory
            .appending(path: "dend-lock-test-\(UUID().uuidString).sock").path
        defer { try? FileManager.default.removeItem(atPath: path + ".lock") }
        let first = try UnixSocket.acquireSingletonLock(path)
        #expect(first != nil)
        #expect(try UnixSocket.acquireSingletonLock(path) == nil)
        #expect(UnixSocket.lockHolderPid(path) == "\(ProcessInfo.processInfo.processIdentifier)")
        if let fd = first { close(fd) }
        let third = try UnixSocket.acquireSingletonLock(path)
        #expect(third != nil)
        if let fd = third { close(fd) }
    }
}
