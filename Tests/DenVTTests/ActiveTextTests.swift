import Foundation
import Testing
@testable import DenVT

@Suite struct ActiveTextTests {
    /// Only the rows the cursor can reach, not what scrolled off.
    @Test func activeAreaWithoutScrollback() throws {
        let term = try VTTerminal(cols: 20, rows: 3)
        term.write(Data("one\r\ntwo\r\nthree\r\nfour   ".utf8))
        #expect(term.activeText() == "two\nthree\nfour")
    }
}
