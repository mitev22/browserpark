// Test helper: logs the PID of every app that becomes active. It moves nothing.
import AppKit

setbuf(stdout, nil)
NSWorkspace.shared.notificationCenter.addObserver(
    forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
) { note in
    let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
    print(app?.processIdentifier ?? 0)
}
_ = NSApplication.shared
RunLoop.main.run()
