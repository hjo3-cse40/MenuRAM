import AppKit
import ServiceManagement
import SwiftUI

@main
struct MenuRAMApp: App {
    @StateObject private var monitor = MemoryMonitor()
    @State private var hoverInfo: HoverInfo?
    @State private var launchAtLogin = false
    @State private var loginNeedsApproval = false

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

            AppBreakdownView(
                snapshot: monitor.processSnapshot,
                wiredBytes: monitor.wiredBytes
            )

            Divider()

            Toggle("Launch at Login", isOn: launchAtLoginBinding)

            if loginNeedsApproval {
                Button("Allow in Login Items…") {
                    SMAppService.openSystemSettingsLoginItems()
                }
                .font(.caption)
            }

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .onAppear(perform: refreshLoginItemState)
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { launchAtLogin },
            set: { setLaunchAtLogin($0) }
        )
    }

    private func refreshLoginItemState() {
        let status = SMAppService.mainApp.status
        launchAtLogin = status == .enabled
        loginNeedsApproval = status == .requiresApproval
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else if SMAppService.mainApp.status != .notRegistered {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // Refresh below snaps the toggle back if macOS rejected the change.
        }
        refreshLoginItemState()
    }
}

private enum HoverHint {
    static let available = "Free + reclaimable cache. Rough room for new apps or model loads."
    static let swap = "Memory paged out to disk. Rising swap usually means the Mac is thrashing."
}
