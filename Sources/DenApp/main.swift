import AppKit

// When ssh runs Den as its askpass helper, answer and exit before any UI.
Askpass.runIfRequested()

signal(SIGPIPE, SIG_IGN)

// Run as `den` (the bundle's link) or with a command word: the CLI, no UI.
DenCLI.runIfRequested()

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
