import AppKit

/// System Settings' Privacy & Security panes that Den's shells need.
/// The grants go to dend, not Den.app: dend is its own launchd job, so
/// macOS holds it responsible for everything the shells open.
enum PrivacySettings {
    enum Pane {
        case fullDiskAccess, screenRecording

        var url: URL? {
            switch self {
            case .fullDiskAccess: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")
            case .screenRecording: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
            }
        }
    }

    static func open(_ pane: Pane) {
        if let url = pane.url { NSWorkspace.shared.open(url) }
    }

    /// dend, beside the Den executable.
    static var dendURL: URL? {
        Bundle.main.executableURL?.deletingLastPathComponent().appending(path: "dend")
    }

    /// Full Disk Access has no prompt: macOS only lets you add the program
    /// yourself. Opens the list and selects dend in Finder to drag into it.
    static func grantFullDiskAccess() {
        open(.fullDiskAccess)
        if let dend = dendURL { NSWorkspace.shared.activateFileViewerSelecting([dend]) }
    }
}
