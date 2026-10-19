import AppKit
import SwiftUI

/// Pick a model, drag context, choose KV type, and see whether it fits right now.
struct ContextSimulatorView: View {
    @ObservedObject var model: LLMModeModel
    @Binding var hoverInfo: HoverInfo?
    @State private var copied = false

    private var steps: [Int] {
        let limit = model.profileContextLimit ?? 262_144
        let allowed = ContextPlanner.contextSteps.filter { $0 <= limit }
        return allowed.isEmpty ? [ContextPlanner.contextSteps[0]] : allowed
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Context Planner")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            modelPicker

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("Context")
                    Spacer()
                    Text("\(ContextFormat.tokens(model.context)) tokens")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
                Slider(value: contextIndex, in: 0...Double(max(steps.count - 1, 1)), step: 1)
                    .controlSize(.small)
                    .disabled(steps.count < 2)
            }

            Picker("KV cache", selection: $model.quant) {
                ForEach(KVQuant.allCases) { quant in
                    Text(quant.label).tag(quant)
                }
            }
            .pickerStyle(.segmented)
            .controlSize(.small)
            .font(.caption)

            if let plan = model.plan {
                breakdown(plan)
                banner(plan)
                maxContextTable(plan)
            } else {
                Text("Reading model architecture…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            launchCommand
        }
    }

    // MARK: - Pieces

    private var modelPicker: some View {
        Picker("Model", selection: $model.selectedModelID) {
            ForEach(sections, id: \.title) { section in
                Section(section.title) {
                    ForEach(section.models) { item in
                        Text(label(for: item)).tag(item.id)
                    }
                }
            }
        }
        .labelsHidden()
        .controlSize(.small)
        .font(.caption)
    }

    private var sections: [(title: String, models: [CatalogModel])] {
        let loaded = model.runner.loaded
        let isLoaded: (CatalogModel) -> Bool = { item in
            loaded.contains { entry in
                if let key = entry.modelKey { return item.name == key || item.aliases.contains(key) }
                return entry.runner == item.runner && entry.name == item.name
            }
        }
        let groups: [(String, [CatalogModel])] = [
            ("Loaded now", model.catalog.filter(isLoaded)),
            ("Ollama", model.catalog.filter { $0.runner == .ollama && !isLoaded($0) }),
            ("LM Studio & Bionic", model.catalog.filter { $0.runner == .lmStudio && !isLoaded($0) }),
            ("Typical sizes", model.catalog.filter { $0.id.hasPrefix("preset:") }),
        ]
        return groups.filter { !$0.1.isEmpty }.map { (title: $0.0, models: $0.1) }
    }

    private func label(for item: CatalogModel) -> String {
        let quant = item.quantization.map { " · \($0)" } ?? ""
        return "\(item.label) (\(MemoryFormat.bytes(item.weightsBytes))\(quant))"
    }

    private var contextIndex: Binding<Double> {
        Binding(
            get: {
                let index = steps.lastIndex { $0 <= model.context } ?? 0
                return Double(index)
            },
            set: { newValue in
                let index = min(max(Int(newValue.rounded()), 0), steps.count - 1)
                model.context = steps[index]
            }
        )
    }

    private func breakdown(_ plan: ContextPlan) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            row("Weights + buffers", plan.weightsBytes + plan.overheadBytes, LLMPalette.model)
            row("KV cache", plan.kvBytes, LLMPalette.kv)
            HStack {
                Text("Needs")
                Spacer()
                Text("\(MemoryFormat.bytes(plan.neededBytes)) of \(MemoryFormat.bytes(plan.hardLimitBytes)) GPU room")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .hoverTooltip(
                $hoverInfo,
                text: "GPU room = ceiling − current wired − 1 GB safety buffer. Architecture from \(model.profile?.source.rawValue ?? "unknown")."
            )
        }
        .font(.caption)
    }

    private func row(_ title: String, _ bytes: UInt64, _ color: Color) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 8, height: 8)
            Text(title)
            Spacer()
            Text(MemoryFormat.bytes(bytes))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func banner(_ plan: ContextPlan) -> some View {
        let content = bannerContent(plan)
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: content.symbol)
                .foregroundStyle(content.color)
            VStack(alignment: .leading, spacing: 4) {
                Text(content.message)
                    .fixedSize(horizontal: false, vertical: true)
                if let action = content.action {
                    Button(action.title, action: action.perform)
                        .controlSize(.small)
                }
            }
            Spacer(minLength: 0)
        }
        .font(.caption)
        .padding(7)
        .background(content.color.opacity(0.12), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private struct BannerAction {
        let title: String
        let perform: () -> Void
    }

    private func bannerContent(_ plan: ContextPlan) -> (symbol: String, color: Color, message: String, action: BannerAction?) {
        switch plan.recommendation {
        case .fits:
            let spare = plan.comfortLimitBytes > plan.neededBytes ? plan.comfortLimitBytes - plan.neededBytes : 0
            return ("checkmark.circle.fill", .green, "Fits in free memory with \(MemoryFormat.bytes(spare)) to spare.", nil)
        case .tight(let squeeze):
            return ("exclamationmark.circle.fill", .yellow,
                    "Fits under the GPU ceiling, but macOS must compress ~\(MemoryFormat.bytes(squeeze)) of other apps first. Expect a slow load.", nil)
        case .useQuant(let quant):
            return ("arrow.down.circle.fill", .orange,
                    "Short by \(MemoryFormat.bytes(shortfall(plan))). \(quant.label) KV cache fits.",
                    BannerAction(title: "Use \(quant.label)") { model.quant = quant })
        case .freezeApps(let quant):
            let names = model.freezer.groups.filter { !$0.isFrozen && !$0.isFrontmost }.prefix(2).map(\.name)
            let who = names.isEmpty ? "background apps" : names.joined(separator: " & ")
            let suffix = quant == model.quant ? "" : " and switch to \(quant.label)"
            return ("snowflake", .orange,
                    "Tight on RAM. Freezing \(who) (~\(MemoryFormat.bytes(model.freezeReclaimBytes)) compressible)\(suffix) makes room.",
                    BannerAction(title: "Freeze\(suffix.isEmpty ? "" : " + \(quant.label)")") { applyFreeze(quant) })
        case .reduceContext(let context, let quant):
            return ("arrow.left.circle.fill", .red,
                    "Too large for the GPU ceiling. Max is \(ContextFormat.tokens(context)) at \(quant.label).",
                    BannerAction(title: "Use \(ContextFormat.tokens(context)) · \(quant.label)") { applyContext(context, quant) })
        case .modelTooLarge(let short):
            return ("xmark.octagon.fill", .red,
                    "Weights alone exceed GPU room by \(MemoryFormat.bytes(short)). Pick a smaller quant or model.", nil)
        }
    }

    private func shortfall(_ plan: ContextPlan) -> UInt64 {
        let limit = plan.fitsHard ? plan.comfortLimitBytes : plan.hardLimitBytes
        return plan.neededBytes > limit ? plan.neededBytes - limit : 0
    }

    private func applyFreeze(_ quant: KVQuant) {
        for group in model.freezer.groups where !group.isFrozen && !group.isFrontmost {
            model.freezer.freeze(group)
        }
        model.quant = quant
    }

    private func applyContext(_ context: Int, _ quant: KVQuant) {
        model.quant = quant
        let rounded = ContextPlanner.contextSteps.last { $0 <= context } ?? context
        model.context = rounded
    }

    private func maxContextTable(_ plan: ContextPlan) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("Max context").frame(maxWidth: .infinity, alignment: .leading)
                Text("Now").frame(width: 50, alignment: .trailing)
                Text("Frozen").frame(width: 50, alignment: .trailing)
                Text("GPU max").frame(width: 56, alignment: .trailing)
            }
            .foregroundStyle(.secondary)
            ForEach(KVQuant.allCases) { quant in
                HStack {
                    Text(quant.label).frame(maxWidth: .infinity, alignment: .leading)
                    cell(plan.maxComfortContext[quant] ?? 0, width: 50)
                    cell(plan.maxComfortContextIfFrozen[quant] ?? 0, width: 50)
                    cell(plan.maxContext[quant] ?? 0, width: 56)
                }
                .fontWeight(quant == model.quant ? .semibold : .regular)
            }
        }
        .font(.caption2)
        .monospacedDigit()
        .hoverTooltip(
            $hoverInfo,
            text: "Now: fits in free RAM. Frozen: after freezing listed apps. GPU max: the hard ceiling, but macOS squeezes other apps to get there."
        )
    }

    private func cell(_ tokens: Int, width: CGFloat) -> some View {
        Text(tokens == 0 ? "—" : ContextFormat.tokens(tokens))
            .frame(width: width, alignment: .trailing)
    }

    private var launchCommand: some View {
        HStack {
            Button(copied ? "Copied" : "Copy launch command") {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(model.launchCommand, forType: .string)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
            }
            .controlSize(.small)
            .disabled(model.selectedModel == nil)
            Spacer()
        }
        .hoverTooltip($hoverInfo, text: model.launchCommand)
    }
}
