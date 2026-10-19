import SwiftUI

enum LLMPalette {
    static let systemWired = Color.gray.opacity(0.75)
    static let model = Color(red: 0.25, green: 0.55, blue: 0.95)
    static let kv = Color(red: 0.62, green: 0.40, blue: 0.90)
    static let freezable = Color(red: 0.96, green: 0.68, blue: 0.20)
    static let otherApps = Color.primary.opacity(0.22)
    static let ceiling = Color.red
}

/// Wired-side memory on the left (what counts toward the GPU ceiling), everything else to the right.
struct UnifiedMemoryBarView: View {
    let segments: UnifiedBarSegments
    let swapActivity: SwapActivity
    let swapBytesPerSecond: Double
    @Binding var hoverInfo: HoverInfo?

    private var stackedBytes: UInt64 {
        segments.systemWired + segments.loadedModels + segments.plannedWeights
            + segments.plannedKV + segments.freezable + segments.otherApps
    }

    private var overflowBytes: UInt64 {
        stackedBytes > segments.total ? stackedBytes - segments.total : 0
    }

    /// Bar spans total RAM, or the whole planned stack when it overflows (with a tick at 100%).
    private var scaleBytes: UInt64 { max(segments.total, stackedBytes) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Unified Memory")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                swapBadge
            }

            GeometryReader { proxy in
                let width = max(proxy.size.width, 1)
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(Color.primary.opacity(0.06))
                    HStack(spacing: 1) {
                        segment(segments.systemWired, LLMPalette.systemWired, width)
                        segment(segments.loadedModels, LLMPalette.model, width)
                        segment(segments.plannedWeights, LLMPalette.model.opacity(0.65), width)
                        segment(segments.plannedKV, LLMPalette.kv, width)
                        segment(segments.freezable, LLMPalette.freezable, width)
                        segment(segments.otherApps, LLMPalette.otherApps, width)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))

                    if overflowBytes > 0 {
                        marker(at: segments.total, width: width, color: .primary, dash: [])
                    }
                    marker(at: segments.gpuCeiling, width: width, color: LLMPalette.ceiling, dash: [3, 2])
                }
            }
            .frame(height: 14)
            .clipped()
            .hoverTooltip(
                $hoverInfo,
                text: "Left of the red line: wired memory the GPU can use. The planned model and its KV cache must fit before it."
            )

            if overflowBytes > 0 {
                Text("Planned load exceeds RAM (white tick) by \(MemoryFormat.bytes(overflowBytes)); macOS would compress or swap.")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            legend
        }
    }

    private var swapBadge: some View {
        let (label, color): (String, Color) = {
            switch swapActivity {
            case .quiet: return ("Swap idle", .green)
            case .active: return ("Swapping \(rate)", .orange)
            case .thrashing: return ("Swap thrash \(rate)", .red)
            }
        }()
        return HStack(spacing: 4) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label).monospacedDigit()
        }
        .font(.caption2)
        .foregroundStyle(swapActivity == .quiet ? .secondary : color)
        .hoverTooltip(
            $hoverInfo,
            text: "Live swap-in + swap-out rate. Total swap is harmless; sustained swapping during generation is what kills tokens/sec."
        )
    }

    private var rate: String {
        "\(MemoryFormat.bytes(UInt64(swapBytesPerSecond)))/s"
    }

    private var legend: some View {
        let columns = [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)]
        return LazyVGrid(columns: columns, alignment: .leading, spacing: 3) {
            legendItem(LLMPalette.systemWired, "System wired", segments.systemWired, "Kernel and GPU memory not owned by a model.")
            legendItem(LLMPalette.model, "Models", segments.loadedModels + segments.plannedWeights, "Loaded models plus the planned model's weights and compute buffers.")
            legendItem(LLMPalette.kv, "KV cache", segments.plannedKV, "Projected KV cache at the chosen context and KV type.")
            legendItem(LLMPalette.freezable, "Freezable", segments.freezable, "Browser tabs and Electron renderers that can be paused.")
            legendItem(LLMPalette.otherApps, "Other used", segments.otherApps, "Remaining app memory and the compressor.")
            legendItem(LLMPalette.ceiling, "GPU ceiling", segments.gpuCeiling, "Max memory Metal will wire for the GPU (iogpu.wired_limit_mb, or the macOS default).")
        }
        .font(.caption2)
    }

    private func legendItem(_ color: Color, _ title: String, _ bytes: UInt64, _ help: String) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 8, height: 8)
            Text(title)
            Spacer(minLength: 4)
            Text(MemoryFormat.bytes(bytes))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.trailing, 6)
        .hoverTooltip($hoverInfo, text: help)
    }

    @ViewBuilder
    private func segment(_ bytes: UInt64, _ color: Color, _ totalWidth: CGFloat) -> some View {
        let fraction = scaleBytes == 0 ? 0 : CGFloat(bytes) / CGFloat(scaleBytes)
        let width = max(0, totalWidth * fraction)
        if width > 0.5 {
            Rectangle().fill(color).frame(width: width)
        }
    }

    private func marker(at bytes: UInt64, width: CGFloat, color: Color, dash: [CGFloat]) -> some View {
        let fraction = scaleBytes == 0 ? 0 : CGFloat(bytes) / CGFloat(scaleBytes)
        return Path { path in
            path.move(to: CGPoint(x: 0, y: 0))
            path.addLine(to: CGPoint(x: 0, y: 14))
        }
        .stroke(color, style: StrokeStyle(lineWidth: 1.5, dash: dash))
        .frame(width: 1.5)
        .offset(x: min(width - 1.5, width * fraction))
    }
}
