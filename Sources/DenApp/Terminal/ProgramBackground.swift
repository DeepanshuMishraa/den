import DenVT

/// The background a full-screen program paints, matched to its pane and
/// header the way Rex matches program backgrounds.
///
/// A program has a background when it sets the terminal's default background
/// (OSC 11), or when one background covers at least 35% of the grid, as
/// editors and monitors do when they flood the screen.
enum ProgramBackground {
    /// Share of the grid one background must cover to count.
    static let coverage = 0.35
    /// A current background still covering this much of the grid is kept
    /// through near-ties: monitors repaint close shades as their content
    /// changes, and following every flip would strobe the pane.
    static let hold = 0.20
    /// How much more of the grid another background needs before it takes
    /// over from the current one.
    static let margin = 0.10

    /// - Parameters:
    ///   - theme: the theme background, which the terminal uses until a
    ///     program changes it.
    ///   - defaultBackground: the terminal's default background (OSC 11).
    ///   - counts: cells each explicit background covers this frame.
    ///   - cellCount: cells in the grid.
    ///   - previous: the background detected last frame, kept while it still
    ///     covers enough of the grid and nothing clearly outgrows it.
    static func detect(theme: RGB, defaultBackground: RGB, counts: [RGB: Int],
                       cellCount: Int, previous: RGB? = nil) -> RGB? {
        if defaultBackground != theme { return defaultBackground }
        let cells = Double(max(cellCount, 1))
        guard let top = counts.max(by: { $0.value < $1.value }) else { return nil }
        if let previous, previous != top.key, let held = counts[previous],
           Double(held) >= cells * hold,
           Double(top.value) < Double(held) + cells * margin {
            return previous
        }
        guard Double(top.value) >= cells * coverage else { return nil }
        return top.key
    }
}
