import AppKit
import SwiftUI

@main
struct MenuRAMApp: App {
    @StateObject private var monitor = MemoryMonitor()

    var body: some Scene {
        MenuBarExtra {
            Text(monitor.availableText)
            Divider()
            Text(monitor.appText)
            Text(monitor.wiredText)
            Text(monitor.compressedText)
            Divider()
            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        } label: {
            Text(monitor.menuBarTitle)
        }
    }
}
