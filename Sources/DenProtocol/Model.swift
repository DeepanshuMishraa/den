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
public indirect enum SplitNode: Equatable, Sendable {
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
    public func splitting(_ target: PaneID, with new: PaneID, axis: SplitAxis) -> SplitNode {
        switch self {
        case .pane(let id) where id == target:
            .split(axis: axis, ratio: 0.5, first: .pane(id), second: .pane(new))
        case .pane:
            self
        case .split(let ax, let r, let a, let b):
            .split(axis: ax, ratio: r, first: a.splitting(target, with: new, axis: axis), second: b.splitting(target, with: new, axis: axis))
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
