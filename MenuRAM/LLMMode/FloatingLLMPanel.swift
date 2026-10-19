import AppKit
import SwiftUI

/// Detached LLM dashboard that survives clicks outside the menu bar popover.
@MainActor
final class FloatingLLMPanelController: NSObject, NSWindowDelegate {
    static let shared = FloatingLLMPanelController()

    private var panel: NSPanel?
    private weak var model: LLMModeModel?

    func show(model: LLMModeModel) {
        self.model = model
        if let panel {
            panel.orderFrontRegardless()
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 480),
            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel, .utilityWindow, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = "MenuRAM · LLM Mode"
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.minSize = NSSize(width: 620, height: 420)
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: FloatingLLMPanelView(model: model, panel: panel))
        panel.center()
        panel.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)

        self.panel = panel
        model.setSurface(.panel, active: true)
    }

    func windowWillClose(_ notification: Notification) {
        model?.setSurface(.panel, active: false)
        panel = nil
    }
}

private struct FloatingLLMPanelView: View {
    @ObservedObject var model: LLMModeModel
    let panel: NSPanel
    @State private var hoverInfo: HoverInfo?
    @State private var alwaysOnTop = true

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Spacer()
                Toggle(isOn: $alwaysOnTop) {
                    Label("Always on Top", systemImage: alwaysOnTop ? "pin.fill" : "pin")
                }
                .toggleStyle(.button)
                .controlSize(.small)
                .onChange(of: alwaysOnTop) { _, onTop in
                    panel.level = onTop ? .floating : .normal
                }
            }
            ScrollView {
                LLMDashboardView(model: model, layout: .wide, hoverInfo: $hoverInfo)
                    .padding(.trailing, 4)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 28)
        .padding(.bottom, 14)
        .frame(minWidth: 620, minHeight: 420)
        .background(.regularMaterial)
        .overlay {
            GeometryReader { proxy in
                HoverTooltipOverlay(info: hoverInfo, panelSize: proxy.size)
            }
        }
        .coordinateSpace(name: "panel")
    }
}
