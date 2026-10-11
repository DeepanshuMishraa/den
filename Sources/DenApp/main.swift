import AppKit

// When ssh runs Den as its askpass helper, answer and exit before any UI.
Askpass.runIfRequested()

signal(SIGPIPE, SIG_IGN)

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
