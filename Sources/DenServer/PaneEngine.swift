import Foundation
import DenVT

/// A pane's authoritative terminal, parsed on its own serial queue so PTY
/// reads and broadcasts never wait for libghostty. Work runs in submission
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
            done()
        }
    }

    /// Runs `body` against the terminal once all earlier writes are parsed.
    func sync<T>(_ body: (VTTerminal) -> T) -> T {
        queue.sync { body(terminal) }
    }

    /// Effects and `onTitle` fire on the engine queue; hop before touching
    /// server state. `onTitle` gets the new OSC 0/2 title.
    func setEffects(_ effects: VTEffects, onTitle: @escaping @Sendable (String?) -> Void) {
        var effects = effects
        effects.titleChanged = { [unowned self] in onTitle(terminal.title) }
        queue.sync { terminal.effects = effects }
    }
}
