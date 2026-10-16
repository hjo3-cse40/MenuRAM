import SwiftUI

/// LLM Mode content. `.compact` stacks vertically for the popover; `.wide` uses two columns for the HUD.
struct LLMDashboardView: View {
    enum Layout {
        case compact
        case wide
    }

    @ObservedObject var model: LLMModeModel
    let layout: Layout
    @Binding var hoverInfo: HoverInfo?

    var body: some View {
        switch layout {
        case .compact:
            VStack(alignment: .leading, spacing: 10) {
                status
                Divider()
                ContextSimulatorView(model: model, hoverInfo: $hoverInfo)
                Divider()
                FreezableAppsView(freezer: model.freezer, hoverInfo: $hoverInfo)
            }
        case .wide:
            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 12) {
                    status
                    Divider()
                    FreezableAppsView(freezer: model.freezer, hoverInfo: $hoverInfo)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity)
                ContextSimulatorView(model: model, hoverInfo: $hoverInfo)
                    .frame(width: 320)
            }
        }
    }

    private var status: some View {
        VStack(alignment: .leading, spacing: 10) {
            UnifiedMemoryBarView(
                segments: model.segments,
                swapActivity: model.snapshot.swapActivity,
                swapBytesPerSecond: model.snapshot.swapBytesPerSecond,
                hoverInfo: $hoverInfo
            )
            ceilingLine
            loadedModels
        }
    }

    private var ceilingLine: some View {
        let snapshot = model.snapshot
        let headroom = snapshot.gpuCeilingBytes > snapshot.wiredBytes ? snapshot.gpuCeilingBytes - snapshot.wiredBytes : 0
        let source = snapshot.gpuCeilingSource == .sysctlOverride ? "sysctl override" : "macOS default"
        return HStack {
            Text("GPU ceiling \(MemoryFormat.bytes(snapshot.gpuCeilingBytes)) (\(source))")
            Spacer()
            Text("\(MemoryFormat.bytes(headroom)) unwired")
                .foregroundStyle(.secondary)
        }
        .font(.caption)
        .monospacedDigit()
        .hoverTooltip(
            $hoverInfo,
            text: "Metal only uses wired RAM. Raising the ceiling needs `sudo sysctl iogpu.wired_limit_mb=N` and resets on reboot; MenuRAM only reads it."
        )
    }

    private var loadedModels: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Loaded Models")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if model.runner.loaded.isEmpty {
                Text(runnerSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.runner.loaded) { loaded in
                    HStack {
                        Text(loaded.name)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 6)
                        if let context = loaded.contextLength {
                            Text(ContextFormat.tokens(context))
                                .foregroundStyle(.secondary)
                        }
                        Text(MemoryFormat.bytes(loaded.residentBytes))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    .font(.caption)
                    .hoverTooltip($hoverInfo, text: "\(loaded.runner.rawValue)\(loaded.pid.map { " · PID \($0)" } ?? "")")
                }
            }
        }
    }

    private var runnerSummary: String {
        var found: [String] = []
        if model.runner.ollamaReachable { found.append("Ollama") }
        if model.runner.lmStudioReachable { found.append("LM Studio") }
        if found.isEmpty { return "No local runner detected." }
        return "\(found.joined(separator: " and ")) running, no model loaded."
    }
}
