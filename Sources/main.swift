import AppKit
import UniformTypeIdentifiers

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate()
app.delegate = delegate
app.run()

final class AppDelegate: NSObject, NSApplicationDelegate {
    var controller: WorkspaceController!
    func applicationDidFinishLaunching(_ notification: Notification) {
        if controller == nil { controller = WorkspaceController() }
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        if CommandLine.arguments.contains("--demo") { controller.loadDemo() }
        if let i = CommandLine.arguments.firstIndex(of: "--open"), i + 1 < CommandLine.arguments.count {
            controller.importURLs(CommandLine.arguments.dropFirst(i + 1).map { URL(fileURLWithPath: $0) })
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        if controller == nil { controller = WorkspaceController(); controller.showWindow(nil) }
        controller.importURLs(filenames.map { URL(fileURLWithPath: $0) })
    }
}
