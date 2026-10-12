import Foundation

public struct SessionID: Hashable, Sendable, CustomStringConvertible {
    public let raw: UUID
    public init(_ raw: UUID = UUID()) { self.raw = raw }
    public var description: String { "session:\(raw.uuidString.lowercased())" }
}

public struct TabID: Hashable, Sendable, CustomStringConvertible {
    public let raw: UUID
    public init(_ raw: UUID = UUID()) { self.raw = raw }
    public var description: String { "tab:\(raw.uuidString.lowercased())" }
}

public struct PaneID: Hashable, Sendable, CustomStringConvertible {
    public let raw: UUID
    public init(_ raw: UUID = UUID()) { self.raw = raw }
    public var description: String { "pane:\(raw.uuidString.lowercased())" }
}

public enum SplitAxis: UInt8, Sendable {
    /// Children side by side (vertical divider).
    case horizontal = 0
    /// Children stacked (horizontal divider).
    case vertical = 1
}

/// Binary tree of panes inside a tab ("deck").
public indirect enum SplitNode: Equatable, Sendable, Codable {
    case pane(PaneID)
    case split(axis: SplitAxis, ratio: Float, first: SplitNode, second: SplitNode)

    public var panes: [PaneID] {
        switch self {
        case .pane(let id): [id]
        case .split(_, _, let a, let b): a.panes + b.panes
        }
    }

    public func contains(_ pane: PaneID) -> Bool { panes.contains(pane) }

    /// Replaces `target` with a split of `target` and `new`.
    /// `newFirst` puts `new` left of or above `target` instead of after it.
    public func splitting(_ target: PaneID, with new: PaneID, axis: SplitAxis, newFirst: Bool = false) -> SplitNode {
        switch self {
        case .pane(let id) where id == target:
            newFirst
                ? .split(axis: axis, ratio: 0.5, first: .pane(new), second: .pane(id))
                : .split(axis: axis, ratio: 0.5, first: .pane(id), second: .pane(new))
        case .pane:
            self
        case .split(let ax, let r, let a, let b):
            .split(axis: ax, ratio: r, first: a.splitting(target, with: new, axis: axis, newFirst: newFirst),
                   second: b.splitting(target, with: new, axis: axis, newFirst: newFirst))
        }
    }

    /// Removes `target`; its sibling takes the parent's place. Returns nil
    /// when the tree held only `target`.
    public func removing(_ target: PaneID) -> SplitNode? {
        switch self {
        case .pane(let id):
            return id == target ? nil : self
        case .split(let ax, let r, let a, let b):
            let na = a.removing(target)
            let nb = b.removing(target)
            switch (na, nb) {
            case (nil, nil): return nil
            case (let x?, nil): return x
            case (nil, let y?): return y
            case (let x?, let y?): return .split(axis: ax, ratio: r, first: x, second: y)
            }
        }
    }
}

public struct TabLayout: Equatable, Sendable {
    public var id: TabID
    public var root: SplitNode
    /// User-chosen title; nil means "derive from the focused pane".
    public var title: String?
    public init(id: TabID, root: SplitNode, title: String? = nil) {
        self.id = id
        self.root = root
        self.title = title
    }
}

public struct SessionSummary: Equatable, Sendable {
    public var id: SessionID
    public var name: String
    public var tabCount: UInt32
    public init(id: SessionID, name: String, tabCount: UInt32) {
        self.id = id
        self.name = name
        self.tabCount = tabCount
    }
}

public struct SessionLayout: Equatable, Sendable {
    public var session: SessionSummary
    public var tabs: [TabLayout]
    public init(session: SessionSummary, tabs: [TabLayout]) {
        self.session = session
        self.tabs = tabs
    }
}

/// Server-observed facts about a pane's process, used for titles and icons.
public struct PaneMeta: Equatable, Sendable {
    public var process: String
    public var cwd: String?
    public init(process: String, cwd: String?) {
        self.process = process
        self.cwd = cwd
    }
}

public struct GridSize: Equatable, Sendable {
    public var cols: UInt16
    public var rows: UInt16
    public var cellWidthPx: UInt32
    public var cellHeightPx: UInt32
    public init(cols: UInt16, rows: UInt16, cellWidthPx: UInt32, cellHeightPx: UInt32) {
        self.cols = cols
        self.rows = rows
        self.cellWidthPx = cellWidthPx
        self.cellHeightPx = cellHeightPx
    }
}

/// Where a moved pane lands relative to the pane it's dropped on.
public enum PanePlacement: UInt8, Sendable {
    /// The two trade places; the tree keeps its shape.
    case swap = 0
    case left, right, above, below
}

public enum PaneDirection: Sendable {
    case left, right, up, down
}

extension SplitNode {
    /// Moves `pane` next to `target` (or swaps them). Nil when there's
    /// nothing to do: the same pane, or either one isn't in this tree.
    public func moving(_ pane: PaneID, to target: PaneID, placement: PanePlacement) -> SplitNode? {
        guard pane != target, contains(pane), contains(target) else { return nil }
        switch placement {
        case .swap:
            return mapPanes { $0 == pane ? target : $0 == target ? pane : $0 }
        case .left, .right, .above, .below:
            guard let rest = removing(pane) else { return nil }
            let axis: SplitAxis = placement == .left || placement == .right ? .horizontal : .vertical
            return rest.splitting(target, with: pane, axis: axis, newFirst: placement == .left || placement == .above)
        }
    }

    /// The pane across `pane`'s edge in `direction`: the nearest one that
    /// overlaps it sideways, the first in tree order on ties.
    /// The innermost split along `axis` holding `pane`: its path (0 first
    /// child, 1 second) and ratio. Moving its ratio moves the edge nearest
    /// the pane along that axis, like tmux's resize-pane.
    public func enclosingSplit(of pane: PaneID, axis: SplitAxis) -> (path: [UInt8], ratio: Float)? {
        enclosingSplit(of: pane, axis: axis, prefix: [])
    }

    private func enclosingSplit(of pane: PaneID, axis: SplitAxis, prefix: [UInt8]) -> (path: [UInt8], ratio: Float)? {
        guard case .split(let a, let ratio, let first, let second) = self else { return nil }
        let index: UInt8
        let child: SplitNode
        if first.contains(pane) { (index, child) = (0, first) } else if second.contains(pane) { (index, child) = (1, second) } else { return nil }
        if let inner = child.enclosingSplit(of: pane, axis: axis, prefix: prefix + [index]) { return inner }
        return a == axis ? (prefix, ratio) : nil
    }

    public func neighbor(of pane: PaneID, toward direction: PaneDirection) -> PaneID? {
        let frames = self.frames(Frame(x: 0, y: 0, w: 1, h: 1))
        guard let from = frames.first(where: { $0.pane == pane })?.frame else { return nil }
        let eps = 1e-6
        var best: (pane: PaneID, gap: Double)?
        for (other, f) in frames where other != pane {
            let gap: Double
            let overlaps: Bool
            switch direction {
            case .right: gap = f.x - (from.x + from.w); overlaps = f.y < from.y + from.h - eps && f.y + f.h > from.y + eps
            case .left: gap = from.x - (f.x + f.w); overlaps = f.y < from.y + from.h - eps && f.y + f.h > from.y + eps
            case .down: gap = f.y - (from.y + from.h); overlaps = f.x < from.x + from.w - eps && f.x + f.w > from.x + eps
            case .up: gap = from.y - (f.y + f.h); overlaps = f.x < from.x + from.w - eps && f.x + f.w > from.x + eps
            }
            guard overlaps, gap > -eps else { continue }
            if best.map({ gap < $0.gap - eps }) ?? true { best = (other, gap) }
        }
        return best?.pane
    }

    struct Frame { var x, y, w, h: Double }

    /// Each pane's rectangle within `rect`, in tree order.
    func frames(_ rect: Frame) -> [(pane: PaneID, frame: Frame)] {
        switch self {
        case .pane(let id):
            return [(id, rect)]
        case .split(let axis, let ratio, let a, let b):
            let r = Double(ratio)
            switch axis {
            case .horizontal:
                return a.frames(Frame(x: rect.x, y: rect.y, w: rect.w * r, h: rect.h))
                    + b.frames(Frame(x: rect.x + rect.w * r, y: rect.y, w: rect.w * (1 - r), h: rect.h))
            case .vertical:
                return a.frames(Frame(x: rect.x, y: rect.y, w: rect.w, h: rect.h * r))
                    + b.frames(Frame(x: rect.x, y: rect.y + rect.h * r, w: rect.w, h: rect.h * (1 - r)))
            }
        }
    }

    private func mapPanes(_ transform: (PaneID) -> PaneID) -> SplitNode {
        switch self {
        case .pane(let id): .pane(transform(id))
        case .split(let ax, let r, let a, let b): .split(axis: ax, ratio: r, first: a.mapPanes(transform), second: b.mapPanes(transform))
        }
    }
}

/// One child of a folder listed with `listDirectory`.
public struct DirectoryEntry: Equatable, Sendable {
    /// dend lists at most this many entries per folder.
    public static let maxPerListing: UInt32 = 5000

    public let name: String
    public let isDirectory: Bool

    public init(name: String, isDirectory: Bool) {
        self.name = name
        self.isDirectory = isDirectory
    }
}
