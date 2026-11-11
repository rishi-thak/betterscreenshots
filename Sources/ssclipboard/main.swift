import AppKit

// Only one agent may run at a time. Two copies (e.g. the LaunchAgent plus a
// Login Item) each install a key tap and fight over shortcuts and overlays.
// A second copy blocks here instead of exiting, so launchd's KeepAlive doesn't
// relaunch it in a loop; it takes over if the running copy ever quits.
let lockFD = open(NSTemporaryDirectory() + "com.rishi.ssclipboard.lock", O_CREAT | O_RDWR, 0o600)
if lockFD >= 0, flock(lockFD, LOCK_EX | LOCK_NB) != 0 {
    SSCLog.app.info("another instance is running; waiting for it to exit")
    flock(lockFD, LOCK_EX)
}

let app = NSApplication.shared
let delegate = AppDelegate()

app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
