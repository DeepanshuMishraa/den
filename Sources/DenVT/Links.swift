import Foundation
import CTermyEngine

/// A link on screen: an OSC 8 hyperlink, or a URL found in the text.
public struct TerminalLink: Equatable, Sendable {
    /// Viewport cells the link covers on one row, both ends inclusive.
    public struct Span: Equatable, Sendable {
        public var row: Int
        public var columns: ClosedRange<Int>
    }

    public var target: String
    public var spans: [Span]

    /// Only these open: OSC 8 lets programs name any scheme, and some
    /// launch apps or run actions.
    static let openableSchemes: Set<String> = ["http", "https", "mailto", "ftp"]

    /// The target as a URL to open, nil when it isn't one Den opens.
    public var url: URL? {
        guard let url = URL(string: target), let scheme = url.scheme?.lowercased(),
              Self.openableSchemes.contains(scheme) else { return nil }
        return url
    }

    public func contains(row: Int, col: Int) -> Bool {
        spans.contains { $0.row == row && $0.columns.contains(col) }
    }
}

extension VTTerminal {
    /// The link under a viewport cell, if any. OSC 8 hyperlinks win over
    /// URLs in the text.
    public func link(atCol col: Int, row: Int) -> TerminalLink? {
        try? frame.refresh(handle)
        guard frame.cells.count == frame.rows * frame.cols,
              (0 ..< frame.rows).contains(row), (0 ..< frame.cols).contains(col) else { return nil }
        return hyperlink(atCol: col, row: row) ?? textLink(atCol: col, row: row)
    }

    /// Whether a cell is drawn: renderers skip blanks and concealed text.
    private func isShown(_ index: Int) -> Bool {
        frame.cells[index].flags & UInt16(TERMY_ENGINE_CELL_BLANK | TERMY_ENGINE_CELL_INVISIBLE) == 0
    }

    private func isWrapped(_ index: Int) -> Bool {
        frame.cells[index].flags & UInt16(TERMY_ENGINE_CELL_WRAPPED) != 0
    }

    private func hyperlink(atCol col: Int, row: Int) -> TerminalLink? {
        let cols = frame.cols, index = row * cols + col
        guard isShown(index), let link = frame.hyperlinks[index] else { return nil }
        func linked(_ i: Int) -> Bool { isShown(i) && frame.hyperlinks[i] == link }
        // An id ties every run of it together. Without one, only the run
        // through this cell belongs, followed across soft wraps.
        var cells = 0 ..< frame.cells.count
        if link.id.isEmpty {
            var first = index, last = index
            while first > 0, linked(first - 1), first % cols != 0 || isWrapped(first - 1) { first -= 1 }
            while last + 1 < frame.cells.count, linked(last + 1), (last + 1) % cols != 0 || isWrapped(last) { last += 1 }
            cells = first ..< last + 1
        }
        var spans: [TerminalLink.Span] = []
        for i in cells where linked(i) {
            let r = i / cols, c = i % cols
            if let s = spans.indices.last, spans[s].row == r, spans[s].columns.upperBound == c - 1 {
                spans[s].columns = spans[s].columns.lowerBound ... c
            } else {
                spans.append(.init(row: r, columns: c ... c))
            }
        }
        return TerminalLink(target: link.uri, spans: spans)
    }

    private func textLink(atCol col: Int, row: Int) -> TerminalLink? {
        let cols = frame.cols
        func wraps(_ r: Int) -> Bool { isWrapped(r * cols + cols - 1) }
        // The logical line: rows joined across soft wraps.
        var top = row
        while top > 0, wraps(top - 1) { top -= 1 }
        var bottom = row
        while bottom < frame.rows - 1, wraps(bottom) { bottom += 1 }

        var scalars: [Unicode.Scalar] = []
        var places: [(row: Int, first: Int, last: Int)] = []
        for r in top ... bottom {
            for c in 0 ..< cols {
                let cell = frame.cells[r * cols + c]
                let width = Int32(cell.width)
                if width == TERMY_ENGINE_CELL_SPACER_TAIL || width == TERMY_ENGINE_CELL_SPACER_HEAD { continue }
                let last = width == TERMY_ENGINE_CELL_WIDE ? min(c + 1, cols - 1) : c
                // Concealed text reads as a space, so it ends any URL.
                let shown = isShown(r * cols + c)
                for value in shown ? [cell.codepoint] + (frame.clusters[r * cols + c] ?? []) : [0x20] {
                    scalars.append(Unicode.Scalar(value) ?? " ")
                    places.append((r, c, last))
                }
            }
        }

        for range in Self.urlRanges(in: scalars) {
            let covered = places[range]
            guard covered.contains(where: { $0.row == row && ($0.first ... $0.last).contains(col) }) else { continue }
            var spans: [TerminalLink.Span] = []
            for place in covered {
                if let i = spans.indices.last, spans[i].row == place.row {
                    spans[i].columns = spans[i].columns.lowerBound ... place.last
                } else {
                    spans.append(.init(row: place.row, columns: place.first ... place.last))
                }
            }
            var target = String.UnicodeScalarView()
            target.append(contentsOf: scalars[range])
            return TerminalLink(target: String(target), spans: spans)
        }
        return nil
    }

    static let urlPrefixes = ["https://", "http://", "ftp://", "mailto:"].map { Array($0.unicodeScalars) }

    /// URLs in `text`: a known scheme at a word start, up to whitespace or a
    /// character URLs don't carry, without trailing punctuation or an
    /// unmatched closing bracket.
    static func urlRanges(in text: [Unicode.Scalar]) -> [Range<Int>] {
        func lower(_ s: Unicode.Scalar) -> Unicode.Scalar {
            ("A" ... "Z").contains(s) ? Unicode.Scalar(s.value + 32) ?? s : s
        }
        func isURLScalar(_ s: Unicode.Scalar) -> Bool {
            if s.value <= 0x20 || (0x7F ... 0x9F).contains(s.value) || s.properties.isWhitespace { return false }
            // Box drawing and blocks: TUI borders right after a URL.
            if (0x2500 ... 0x259F).contains(s.value) { return false }
            return !"<>\"'`|\\^{}".unicodeScalars.contains(s)
        }

        var ranges: [Range<Int>] = []
        var i = 0
        while i < text.count {
            let atWordStart = i == 0 || !(text[i - 1].properties.isAlphabetic || ("0" ... "9").contains(text[i - 1]))
            guard atWordStart, let prefix = urlPrefixes.first(where: { p in
                i + p.count <= text.count && zip(p, text[i ..< i + p.count]).allSatisfy { $0 == lower($1) }
            }) else {
                i += 1
                continue
            }
            var end = i + prefix.count
            while end < text.count, isURLScalar(text[end]) { end += 1 }
            // Trailing sentence punctuation and closers the URL didn't open.
            while end > i + prefix.count {
                let last = text[end - 1]
                if ".,:;!?'\"".unicodeScalars.contains(last) {
                    end -= 1
                    continue
                }
                let pairs: [Unicode.Scalar: Unicode.Scalar] = [")": "(", "]": "[", "}": "{"]
                if let open = pairs[last] {
                    let body = text[i ..< end]
                    if body.filter({ $0 == last }).count > body.filter({ $0 == open }).count {
                        end -= 1
                        continue
                    }
                }
                break
            }
            if end > i + prefix.count { ranges.append(i ..< end) }
            i = max(end, i + 1)
        }
        return ranges
    }
}
