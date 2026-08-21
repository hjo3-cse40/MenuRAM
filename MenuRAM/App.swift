import AppKit
import SwiftUI

@main
struct MenuRAMApp: App {
    @StateObject private var monitor = MemoryMonitor()
    @State private var hoverInfo: HoverInfo?

    var body: some Scene {
        MenuBarExtra {
            panel
                .padding(12)
                .frame(width: 280)
                .overlay {
                    GeometryReader { proxy in
                        HoverTooltipOverlay(info: hoverInfo, panelSize: proxy.size)
                    }
                }
                .coordinateSpace(name: "panel")
        } label: {
            // Menu bar forces SF Symbols to template (monochrome). Use a bitmap dot instead.
            HStack(spacing: 5) {
                Image(nsImage: monitor.pressure.menuBarDotImage())
                Text(monitor.menuBarTitle)
            }
        }
        .menuBarExtraStyle(.window)
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(monitor.availableText)
                    .font(.body.weight(.medium))
                    .hoverTooltip($hoverInfo, text: HoverHint.available)

                HStack(spacing: 6) {
                    Circle()
                        .fill(monitor.pressure.color)
                        .frame(width: 8, height: 8)
                    Text(monitor.pressureText)
                }
                .foregroundStyle(.secondary)
                .hoverTooltip($hoverInfo, text: monitor.pressure.helpText)

                Text(monitor.swapText)
                    .foregroundStyle(.secondary)
                    .hoverTooltip($hoverInfo, text: HoverHint.swap)
            }

            Divider()

            MemoryBarView(
                appBytes: monitor.appBytes,
                wiredBytes: monitor.wiredBytes,
                compressedBytes: monitor.compressedBytes,
                totalBytes: monitor.totalBytes,
                hoverInfo: $hoverInfo
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
                                Text(MemoryFormat.bytes(process.bytes))
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
    }
}

private enum HoverHint {
    static let available = "Free + reclaimable cache. Rough room for new apps or model loads."
    static let swap = "Memory paged out to disk. Rising swap usually means the Mac is thrashing."
}
