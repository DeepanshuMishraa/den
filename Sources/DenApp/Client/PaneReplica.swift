import Foundation
import DenProtocol
import DenVT

/// The client's copy of one pane's terminal, advanced by the server stream.
@MainActor
final class PaneReplica {
    let id: PaneID
    private(set) var terminal: VTTerminal
    private(set) var theme: Theme
    private(set) var contrastCorrection: Bool
    /// Bumped on every change; views redraw when it moves.
    private(set) var generation = 0
    var onTitleChange: ((String?) -> Void)?
    var onBell: (() -> Void)?
    /// Several views (the pane, its peek and exposé thumbnails) can watch one replica.
    private var observers: [ObjectIdentifier: () -> Void] = [:]

    init(id: PaneID, snapshot: Data, theme: Theme, contrastCorrection: Bool) throws(VTError) {
        self.id = id
        self.theme = theme
        self.contrastCorrection = contrastCorrection
        terminal = try VTTerminal(snapshot: snapshot)
        configure()
    }

    func observe(_ owner: AnyObject, _ onChange: @escaping () -> Void) {
        observers[ObjectIdentifier(owner)] = onChange
    }

    func stopObserving(_ owner: AnyObject) {
        observers.removeValue(forKey: ObjectIdentifier(owner))
    }

    func reset(snapshot: Data) throws(VTError) {
        terminal = try VTTerminal(snapshot: snapshot)
        configure()
        changed()
    }

    private func configure() {
        terminal.setDefaultColors(foreground: theme.foreground, background: theme.background, cursor: theme.cursor, palette: theme.palette)
        terminal.effects = VTEffects(
            bell: { [weak self] in self?.onBell?() },
            titleChanged: { [weak self] in
                guard let self else { return }
                self.onTitleChange?(self.terminal.title)
            }
        )
    }

    func apply(theme: Theme, contrastCorrection: Bool) {
        self.theme = theme
        self.contrastCorrection = contrastCorrection
        terminal.setDefaultColors(foreground: theme.foreground, background: theme.background, cursor: theme.cursor, palette: theme.palette)
        changed()
    }

    func write(_ bytes: Data) {
        terminal.write(bytes)
        changed()
    }

    func resize(_ size: GridSize) throws(VTError) {
        try terminal.resize(cols: size.cols, rows: size.rows, cellWidthPx: size.cellWidthPx, cellHeightPx: size.cellHeightPx)
        changed()
    }

    func scroll(_ scroll: VTTerminal.Scroll) {
        terminal.scrollViewport(scroll)
        changed()
    }

    /// For local-only changes such as selection.
    func touch() { changed() }

    private func changed() {
        generation &+= 1
        for o in observers.values { o() }
    }
}
