import AppKit
import SwiftUI

@main
struct MenuRAMApp: App {
    @StateObject private var monitor = MemoryMonitor()

    var body: some Scene {
        MenuBarExtra {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(monitor.availableText)
                        .font(.body.weight(.medium))
                    HStack(spacing: 6) {
                        Circle()
                            .fill(monitor.pressure.color)
                            .frame(width: 8, height: 8)
                        Text(monitor.pressureText)
                    }
                    .foregroundStyle(.secondary)
                }

                Divider()

                MemoryBarView(
                    appBytes: monitor.appBytes,
                    wiredBytes: monitor.wiredBytes,
                    compressedBytes: monitor.compressedBytes,
                    totalBytes: monitor.totalBytes
                )

                Divider()

                VStack(alignment: .leading, spacing: 4) {
                    Text("Top Apps")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    if monitor.topProcesses.isEmpty {
                        Text("Scanning…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(monitor.topProcesses) { process in
                            HStack {
                                Text(process.name)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer(minLength: 8)
                                Text("\(MemoryFormat.gb(process.bytes)) GB")
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                            .font(.caption)
                        }
                    }
                }

                Divider()

                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
                .keyboardShortcut("q")
            }
            .padding(12)
            .frame(width: 280)
        } label: {
            // Menu bar forces SF Symbols to template (monochrome). Use a bitmap dot instead.
            HStack(spacing: 5) {
                Image(nsImage: monitor.pressure.menuBarDotImage())
                Text(monitor.menuBarTitle)
            }
        }
        .menuBarExtraStyle(.window)
    }
}
