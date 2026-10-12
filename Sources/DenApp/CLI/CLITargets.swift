import Foundation
import DenProtocol

/// Turns what the user typed into sessions, tabs and panes in dend's state.
/// A reference can be a name or label, an ID (`pane:…`, a full UUID or a
/// unique prefix of at least 4 hex digits), or for tabs a 1-based number.
struct CLITargets {
    let state: DenState
    let environment: [String: String]

    init(state: DenState, environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.state = state
        self.environment = environment
    }

    /// The pane this command runs in, when it runs inside Den.
    private var currentPane: PaneID? {
        environment["DEN_PANE_ID"].flatMap(UUID.init(uuidString:)).map(PaneID.init)
    }

    private var currentSession: SessionID? {
        if let pane = currentPane, let session = state.sessions.first(where: { $0.panes.contains { $0.id == pane } }) { return session.id }
        return environment["DEN_SESSION_ID"].flatMap(UUID.init(uuidString:)).map(SessionID.init)
    }

    /// Without a reference: the session this shell runs in, else the only
    /// session.
    func session(_ ref: String?) throws(CLIError) -> SessionState {
        guard let ref else {
            if let id = currentSession, let session = state.sessions.first(where: { $0.id == id }) { return session }
            if state.sessions.count == 1 { return state.sessions[0] }
            if state.sessions.isEmpty { throw CLIError(message: "There are no sessions. Create one with `den new NAME`.") }
            throw .usage("Several sessions are running; pick one with -s NAME (\(state.sessions.map(\.name).joined(separator: ", "))).")
        }
        let matches = Self.match(ref, in: state.sessions, id: { $0.id.raw }, names: { [$0.name] })
        return try Self.one(matches, ref: ref, kind: "session", list: state.sessions.map(\.name)) { $0.name }
    }

    /// Without a reference: this shell's pane if it's in `session`, else
    /// the pane created last.
    func pane(_ ref: String?, in session: SessionState) throws(CLIError) -> PaneState {
        let panes = session.panes
        guard let ref else {
            if let id = currentPane, let pane = panes.first(where: { $0.id == id }) { return pane }
            guard let newest = panes.max(by: { $0.createdAt < $1.createdAt }) else {
                throw CLIError(message: "Session “\(session.name)” has no panes.")
            }
            return newest
        }
        let matches = Self.match(ref, in: panes, id: { $0.id.raw }, names: { [$0.label].compactMap { $0 } })
        if !matches.isEmpty { return try Self.one(matches, ref: ref, kind: "pane", list: panes.map(Self.paneName)) { Self.paneName($0) } }
        // Unlabelled panes answer to their program's name.
        let byProcess = panes.filter { $0.label == nil && $0.process == ref }
        return try Self.one(byProcess, ref: ref, kind: "pane", list: panes.map(Self.paneName)) { Self.paneName($0) }
    }

    func tab(_ ref: String?, in session: SessionState) throws(CLIError) -> TabState {
        guard let ref else {
            if let id = currentPane, let tab = session.tabs.first(where: { $0.panes.contains { $0.id == id } }) { return tab }
            if session.tabs.count == 1 { return session.tabs[0] }
            throw .usage("Session “\(session.name)” has \(session.tabs.count) tabs; pick one with -t NUMBER, TITLE or ID.")
        }
        if let n = Int(ref) {
            guard session.tabs.indices.contains(n - 1) else {
                throw CLIError(message: "Session “\(session.name)” has \(session.tabs.count) tab(s); there is no tab \(n).")
            }
            return session.tabs[n - 1]
        }
        let matches = Self.match(ref, in: session.tabs, id: { $0.id.raw }, names: { [$0.title].compactMap { $0 } })
        return try Self.one(matches, ref: ref, kind: "tab", list: session.tabs.indices.map { "\($0 + 1)" }) { $0.title ?? $0.id.description }
    }

    /// Which session holds `pane`.
    func session(of pane: PaneID) -> SessionState? {
        state.sessions.first { $0.panes.contains { $0.id == pane } }
    }

    static func paneName(_ pane: PaneState) -> String { pane.label ?? pane.process }

    static func shortID(_ uuid: UUID) -> String { String(uuid.uuidString.lowercased().prefix(8)) }

    // MARK: Matching

    private static func match<T>(_ ref: String, in items: [T], id: (T) -> UUID, names: (T) -> [String]) -> [T] {
        let exact = items.filter { names($0).contains(ref) }
        if !exact.isEmpty { return exact }
        let folded = items.filter { names($0).contains { $0.caseInsensitiveCompare(ref) == .orderedSame } }
        if !folded.isEmpty { return folded }
        // "session:…", "pane:…" and "tab:…" as printed by den and dend.
        let bare = ref.split(separator: ":", maxSplits: 1).last.map(String.init)?.lowercased() ?? ref.lowercased()
        guard bare.count >= 4, bare.allSatisfy({ $0.isHexDigit || $0 == "-" }) else { return [] }
        return items.filter { id($0).uuidString.lowercased().hasPrefix(bare) }
    }

    private static func one<T>(_ matches: [T], ref: String, kind: String, list: [String], name: (T) -> String) throws(CLIError) -> T {
        switch matches.count {
        case 1: return matches[0]
        case 0:
            let known = list.isEmpty ? "there are none" : "known: \(list.joined(separator: ", "))"
            throw CLIError(message: "No \(kind) “\(ref)” (\(known)).")
        default:
            throw CLIError(message: "“\(ref)” matches \(matches.count) \(kind)s (\(matches.map(name).joined(separator: ", "))); use a longer ID or a label.")
        }
    }
}
