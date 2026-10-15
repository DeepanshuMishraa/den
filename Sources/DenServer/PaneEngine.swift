import Foundation
import DenVT

/// A pane's authoritative terminal, parsed on its own serial queue so PTY
/// reads and broadcasts never wait for the parser. Work runs in submission
/// order: `sync` sees every byte written before it, so a snapshot taken
/// there matches the point in the stream where it is sent.
final class PaneEngine: @unchecked Sendable {
    private let queue: DispatchQueue
    /// Touched only on `queue`.
    private let terminal: VTTerminal

    init(_ terminal: VTTerminal, label: String) {
        self.terminal = terminal
        queue = DispatchQueue(label: label, qos: .userInitiated)
    }

    /// Parses `bytes` after everything written before; `done` runs on the
    /// engine queue once they're in.
    func write(_ bytes: Data, done: @escaping @Sendable () -> Void) {
        queue.async { [self] in
            terminal.write(bytes)
            scheduleSynchronizedCommit()
            done()
        }
    }

    /// Touched only on `queue`.
    private var commitScheduled = false

    /// A synchronized update (?2026) the program never ends is applied at
    /// its deadline anyway, answering any queries buffered in it. libtermy
    /// has no timer of its own.
    private func scheduleSynchronizedCommit() {
        guard !commitScheduled, let remaining = terminal.synchronizedUpdateDeadline else { return }
        commitScheduled = true
        queue.asyncAfter(deadline: .now() + .milliseconds(Int(clamping: remaining) + 1)) { [self] in
            commitScheduled = false
            terminal.commitDueSynchronizedUpdate()
            scheduleSynchronizedCommit()
        }
    }

    /// Runs `body` against the terminal once all earlier writes are parsed.
    func sync<T>(_ body: (VTTerminal) -> T) -> T {
        queue.sync { body(terminal) }
    }

    /// Like `sync`, without waiting: `body` runs on the engine queue once
    /// earlier writes are parsed. Hop before touching server state.
    func async(_ body: @escaping @Sendable (VTTerminal) -> Void) {
        queue.async { [self] in body(terminal) }
    }

    /// Effects and `onTitle` fire on the engine queue; hop before touching
    /// server state. `onTitle` gets the new OSC 0/2 title.
    func setEffects(_ effects: VTEffects, onTitle: @escaping @Sendable (String?) -> Void) {
        var effects = effects
        effects.titleChanged = onTitle
        queue.sync { terminal.effects = effects }
    }
}
