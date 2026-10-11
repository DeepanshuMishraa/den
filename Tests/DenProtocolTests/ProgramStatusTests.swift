import Foundation
import Testing
@testable import DenProtocol

@Suite struct ProgramStatusTests {
    private func b64(_ s: String) -> String { Data(s.utf8).base64EncodedString() }
    private func parse(_ body: String) -> StatusReport? { StatusReport.parse(body[...]) }

    // MARK: Parsing

    @Test func parsesSpecExample() {
        let report = parse("state=blocked:kind=permission:app=terraform:msg=QXBwbHkgMyB0byBhZGQsIDEgdG8gY2hhbmdlLCAwIHRvIGRlc3Ryb3k/")
        #expect(report == .update(StatusRecord(phase: .blocked(.permission, progress: nil), app: "terraform", msg: "Apply 3 to add, 1 to change, 0 to destroy?")))
    }

    @Test func parsesChildRecordWithTitleAndProgress() {
        let report = parse("state=working:id=us-east:title=\(b64("US East")):progress=40:msg=\(b64("Pushing image"))")
        #expect(report == .update(StatusRecord(id: ["us-east"], phase: .working(progress: 40), title: "US East", msg: "Pushing image")))
    }

    @Test func queryIsRecognised() {
        #expect(parse("?") == .query)
        #expect(StatusReport.queryReply == Data("\u{1B}]7501;?:states=idle,working,done,blocked,error:kinds=permission,question,auth\u{1B}\\".utf8))
    }

    @Test func clearWithAndWithoutID() {
        #expect(parse("state=clear:id=eu-west") == .clear(id: ["eu-west"]))
        #expect(parse("state=clear") == .clear(id: nil))
    }

    @Test func missingOrUnknownStateDropsReport() {
        #expect(parse("app=cargo") == nil)
        #expect(parse("state=sleeping") == nil)
    }

    @Test func malformedPairsAreSkippedAndLastKeyWins() {
        #expect(parse("state=idle:nonsense:APP=x:state=done:weird=a b") == .update(StatusRecord(phase: .done)))
    }

    @Test func kindOnlyMeaningfulWhenBlockedAndProgressIsRangeChecked() {
        #expect(parse("state=working:kind=auth:progress=101") == .update(StatusRecord(phase: .working(progress: nil))))
        #expect(parse("state=blocked:kind=nope") == .update(StatusRecord(phase: .blocked(nil, progress: nil))))
    }

    @Test func invalidTextDropsWholeReport() {
        #expect(parse("state=done:msg=abc") == nil, "invalid base64")
        #expect(parse("state=done:msg=!!!") == .update(StatusRecord(phase: .done)), "outside the value charset: pair skipped")
        #expect(parse("state=done:msg=\(b64("line\nbreak"))") == nil, "control character")
        #expect(parse("state=done:title=\(b64(String(repeating: "x", count: 193)))") == nil, "title over 192 bytes")
    }

    @Test func invisibleFormattingIsDisarmed() {
        #expect(parse("state=done:msg=\(b64("ok\u{202E}cod.exe"))") == .update(StatusRecord(phase: .done, msg: "okcod.exe")))
    }

    @Test func idLimits() {
        #expect(parse("state=done:id=a/b/c") == .update(StatusRecord(id: ["a", "b", "c"], phase: .done)))
        #expect(parse("state=done:id=a//b") == nil)
        #expect(parse("state=done:id=\((1 ... 9).map(String.init).joined(separator: "/"))") == nil, "deeper than 8")
        #expect(parse("state=done:id=\(String(repeating: "a", count: 33))") == nil, "segment over 32")
    }

    // MARK: Records

    @Test func reportsReplaceRecordsAndClearRemovesSubtree() {
        var records = StatusRecords()
        records.apply(.update(StatusRecord(phase: .working(progress: nil), app: "deploy")))
        records.apply(.update(StatusRecord(id: ["us-east"], phase: .working(progress: 40))))
        records.apply(.update(StatusRecord(id: ["us-east", "db"], phase: .done)))
        records.apply(.update(StatusRecord(id: ["eu-west"], phase: .blocked(.permission, progress: nil))))
        records.apply(.update(StatusRecord(id: ["us-east"], phase: .done)))
        #expect(records.records.count == 4)
        #expect(records.records.last == StatusRecord(id: ["us-east"], phase: .done))
        #expect(records.app(for: StatusRecord(id: ["us-east", "db"], phase: .done)) == "deploy")

        let clearedSubtree = records.apply(.clear(id: ["us-east"]))
        #expect(clearedSubtree)
        #expect(records.records.map(\.id) == [[], ["eu-west"]])
        let clearedMissing = records.apply(.clear(id: ["missing"]))
        #expect(!clearedMissing)
        let clearedAll = records.apply(.clear(id: nil))
        #expect(clearedAll)
        #expect(records.records.isEmpty)
    }

    @Test func transientRecordsEndWithTheProcess() {
        var records = StatusRecords([
            StatusRecord(id: ["a"], phase: .working(progress: 3)),
            StatusRecord(id: ["b"], phase: .blocked(.auth, progress: nil)),
            StatusRecord(id: ["c"], phase: .done),
            StatusRecord(id: ["d"], phase: .error),
        ])
        let dropped = records.dropTransient()
        #expect(dropped)
        #expect(records.records.map(\.id) == [["c"], ["d"]])
        #expect(!records.hasTransient)
    }

    @Test func capacityEvictsLeastRecentlyUpdated() {
        var records = StatusRecords()
        for i in 0 ..< StatusRecords.capacity + 1 {
            records.apply(.update(StatusRecord(id: ["r\(i)"], phase: .done)))
        }
        #expect(records.records.count == StatusRecords.capacity)
        #expect(records.records.first?.id == ["r1"])
    }

    // MARK: Scanner

    @Test func scannerFindsReportsSplitAcrossReads() {
        var scanner = StatusScanner()
        let stream = Array("hi\u{1B}]7501;state=working:app=cargo\u{1B}\\more\u{1B}]7501;?\u{07}".utf8)
        var events: [StatusScanner.Event] = []
        for byte in stream { events += scanner.feed([byte]) }
        #expect(events == [.status(.update(StatusRecord(phase: .working(progress: nil), app: "cargo"))), .status(.query)])
    }

    @Test func scannerSeesPromptStartAndFullReset() {
        var scanner = StatusScanner()
        let events = scanner.feed(Array("\u{1B}]133;A\u{07}\u{1B}]133;B\u{07}\u{1B}]133;A;k=i\u{1B}\\\u{1B}c\u{1B}[0c".utf8))
        #expect(events == [.promptStart, .promptStart, .fullReset])
    }

    @Test func scannerIgnoresOtherAndOversizedOSCs() {
        var scanner = StatusScanner()
        let huge = String(repeating: "A", count: 5000)
        let events = scanner.feed(Array("\u{1B}]0;title\u{07}\u{1B}]7501;state=done:msg=\(huge)\u{07}\u{1B}]7501;state=done\u{07}".utf8))
        #expect(events == [.status(.update(StatusRecord(phase: .done)))])
    }

    @Test func abortedOSCHandsItsEscapeOn() {
        var scanner = StatusScanner()
        let events = scanner.feed(Array("\u{1B}]7501;state=done\u{1B}c".utf8))
        #expect(events == [.fullReset])
    }

    // MARK: Wire

    @Test func programStatusRoundTrips() throws {
        let records = [
            StatusRecord(phase: .working(progress: nil), app: "deploy", msg: "Deploying v2.4.1"),
            StatusRecord(id: ["us-east"], phase: .working(progress: 40), title: "US East"),
            StatusRecord(id: ["eu-west", "db"], phase: .blocked(.permission, progress: 10)),
            StatusRecord(id: ["x"], phase: .blocked(nil, progress: nil)),
            StatusRecord(id: ["y"], phase: .done),
            StatusRecord(id: ["z"], phase: .error),
            StatusRecord(id: ["i"], phase: .idle),
        ]
        let message = ServerMessage.programStatus(PaneID(), records)
        #expect(try ServerMessage.decode(message.encode()) == message)
    }

    // MARK: Headline

    @Test func headlinePrefersTheMostUrgentRecord() {
        let records = [
            StatusRecord(id: ["a"], phase: .done),
            StatusRecord(id: ["b"], phase: .blocked(.question, progress: nil)),
            StatusRecord(id: ["c"], phase: .working(progress: nil)),
            StatusRecord(id: ["d"], phase: .error),
            StatusRecord(id: ["e"], phase: .idle),
        ]
        #expect(StatusRecords(records).headline?.id == ["b"])
        #expect(StatusRecords(records.filter { $0.id != ["b"] }).headline?.id == ["d"])
    }

    @Test func headlineTakesTheLatestAmongEquals() {
        var records = StatusRecords()
        records.apply(.update(StatusRecord(id: ["a"], phase: .working(progress: nil), msg: "first")))
        records.apply(.update(StatusRecord(id: ["b"], phase: .working(progress: 50), msg: "second")))
        #expect(records.headline?.msg == "second")
        records.apply(.update(StatusRecord(id: ["a"], phase: .working(progress: nil), msg: "again")))
        #expect(records.headline?.msg == "again")
    }

    @Test func headlineOfNothingIsNil() {
        #expect(StatusRecords().headline == nil)
    }
}
