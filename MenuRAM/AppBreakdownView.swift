import SwiftUI

/// Top Apps list, with an expander that graphs Used memory by app and lists everything.
struct AppBreakdownView: View {
    let snapshot: ProcessMemorySnapshot
    let wiredBytes: UInt64
    @AppStorage("topAppsExpanded") private var expanded = false

    private static let collapsedCount = 5
    private static let graphedCount = 6
    private static let listedMinimumBytes: UInt64 = 10 * 1_048_576
    private static let palette: [Color] = [
        Color(red: 0.25, green: 0.55, blue: 0.95),
        Color(red: 0.95, green: 0.55, blue: 0.20),
        Color(red: 0.35, green: 0.75, blue: 0.45),
        Color(red: 0.70, green: 0.40, blue: 0.85),
        Color(red: 0.90, green: 0.35, blue: 0.45),
        Color(red: 0.25, green: 0.75, blue: 0.80),
    ]
    private static let otherColor = Color.primary.opacity(0.32)
    private static let systemColor = Color.primary.opacity(0.2)
    private static let wiredColor = Color.primary.opacity(0.1)

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header

            if snapshot.groups.isEmpty {
                Text("Scanning…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if expanded {
                graph
                allApps
            } else {
                ForEach(snapshot.groups.prefix(Self.collapsedCount)) { process in
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
    }

    private var header: some View {
        HStack {
            Text("Top Apps")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                HStack(spacing: 3) {
                    Text(expanded ? "Show less" : "Show all")
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                }
                .font(.caption2)
            }
            .buttonStyle(.borderless)
            .disabled(snapshot.groups.isEmpty)
        }
    }

    // MARK: - Graph

    private struct Slice: Identifiable {
        let id: String
        let name: String
        let bytes: UInt64
        let color: Color
    }

    private var slices: [Slice] {
        let top = snapshot.groups.prefix(Self.graphedCount)
        var result = top.enumerated().map { index, group in
            Slice(id: group.id, name: group.name, bytes: group.bytes, color: Self.palette[index % Self.palette.count])
        }
        let rest = snapshot.groups.dropFirst(top.count)
        let otherApps = rest.filter { $0.kind != .system }
        let services = rest.filter { $0.kind == .system }
        let otherBytes = otherApps.reduce(0) { $0 + $1.bytes }
        let serviceBytes = services.reduce(0) { $0 + $1.bytes }
        if otherBytes > 0 {
            result.append(Slice(id: "other", name: "\(otherApps.count) other apps & tools", bytes: otherBytes, color: Self.otherColor))
        }
        if serviceBytes > 0 {
            result.append(Slice(id: "services", name: "\(services.count) macOS services", bytes: serviceBytes, color: Self.systemColor))
        }
        if wiredBytes > 0 {
            result.append(Slice(id: "wired", name: "Wired (kernel & GPU)", bytes: wiredBytes, color: Self.wiredColor))
        }
        return result
    }

    private var graph: some View {
        let slices = slices
        let total = max(slices.reduce(0) { $0 + $1.bytes }, 1)
        return VStack(alignment: .leading, spacing: 5) {
            GeometryReader { proxy in
                HStack(spacing: 1) {
                    ForEach(slices) { slice in
                        let width = proxy.size.width * CGFloat(slice.bytes) / CGFloat(total)
                        if width > 0.5 {
                            Rectangle().fill(slice.color).frame(width: width)
                        }
                    }
                }
            }
            .frame(height: 12)
            .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                ForEach(slices) { slice in
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 2).fill(slice.color).frame(width: 8, height: 8)
                        Text(slice.name)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 6)
                        Text(percent(slice.bytes, of: total))
                            .foregroundStyle(.secondary)
                            .frame(width: 32, alignment: .trailing)
                        Text(MemoryFormat.bytes(slice.bytes))
                            .foregroundStyle(.secondary)
                            .frame(width: 52, alignment: .trailing)
                    }
                    .monospacedDigit()
                }
            }
            .font(.caption2)
        }
        .padding(.bottom, 2)
    }

    // MARK: - Full list

    private var listed: [ProcessMemoryInfo] {
        snapshot.groups.filter { $0.bytes >= Self.listedMinimumBytes }
    }

    private var allApps: some View {
        let largest = max(snapshot.groups.first?.bytes ?? 1, 1)
        return VStack(alignment: .leading, spacing: 4) {
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(listed) { process in
                        row(process, largest: largest)
                    }
                }
                .padding(.trailing, 8)
            }
            .frame(height: 220)

            Text(footnote)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func row(_ process: ProcessMemoryInfo, largest: UInt64) -> some View {
        VStack(alignment: .leading, spacing: 2) {
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

            Text(subtitle(process))
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)

            GeometryReader { proxy in
                Capsule()
                    .fill(color(for: process.kind).opacity(0.7))
                    .frame(width: max(2, proxy.size.width * CGFloat(process.bytes) / CGFloat(largest)))
            }
            .frame(height: 3)
        }
    }

    private func subtitle(_ process: ProcessMemoryInfo) -> String {
        var parts = [process.kind.rawValue]
        parts.append(process.processCount == 1 ? "1 process" : "\(process.processCount) processes")
        if let detail = process.detail {
            parts.append(detail)
        }
        return parts.joined(separator: " · ")
    }

    private func color(for kind: ProcessKind) -> Color {
        switch kind {
        case .app: return Self.palette[0]
        case .tool: return Self.palette[1]
        case .system: return Color.secondary
        }
    }

    private var footnote: String {
        let hidden = snapshot.groups.count - listed.count
        var text = "Sizes are memory footprint, like Activity Monitor; they include compressed memory, so the graph can total more than Used. \(snapshot.unreadableProcessCount) root processes (WindowServer, most daemons) need admin rights to read and aren't counted."
        if hidden > 0 {
            text += " \(hidden) apps under 10 MB not shown."
        }
        return text
    }

    private func percent(_ bytes: UInt64, of total: UInt64) -> String {
        let value = Double(bytes) / Double(total) * 100
        return value < 1 ? "<1%" : String(format: "%.0f%%", value)
    }
}
