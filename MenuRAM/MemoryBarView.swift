import AppKit
import SwiftUI

enum MemoryPressureLevel: String, Equatable {
    case normal = "Normal"
    case warning = "Warning"
    case critical = "Critical"

    var color: Color {
        switch self {
        case .normal:
            return .green
        case .warning:
            return .orange
        case .critical:
            return .red
        }
    }

    var helpText: String {
        switch self {
        case .normal:
            return "macOS has enough free memory. Fine to open more apps or load models."
        case .warning:
            return "Memory is getting tight. macOS may compress or reclaim caches soon."
        case .critical:
            return "macOS is under memory pressure. Expect hitches; large new loads may struggle."
        }
    }

    /// Concrete colors for menu bar rendering (SF Symbols are forced to template/monochrome there).
    var nsColor: NSColor {
        switch self {
        case .normal:
            return NSColor.systemGreen
        case .warning:
            return NSColor.systemOrange
        case .critical:
            return NSColor.systemRed
        }
    }

    /// Non-template bitmap so the menu bar keeps the real pressure color.
    func menuBarDotImage(diameter: CGFloat = 8) -> NSImage {
        let size = NSSize(width: diameter, height: diameter)
        let image = NSImage(size: size, flipped: false) { bounds in
            self.nsColor.setFill()
            NSBezierPath(ovalIn: bounds.insetBy(dx: 0.5, dy: 0.5)).fill()
            return true
        }
        image.isTemplate = false
        return image
    }
}

struct MemoryBarView: View {
    let appBytes: UInt64
    let wiredBytes: UInt64
    let compressedBytes: UInt64
    let totalBytes: UInt64
    @Binding var hoverInfo: HoverInfo?

    private var otherBytes: UInt64 {
        let used = appBytes + wiredBytes + compressedBytes
        return totalBytes > used ? totalBytes - used : 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { proxy in
                let width = max(proxy.size.width, 1)
                HStack(spacing: 1) {
                    segment(bytes: appBytes, color: Color(red: 0.25, green: 0.55, blue: 0.95), totalWidth: width)
                    segment(bytes: wiredBytes, color: Color(red: 0.70, green: 0.40, blue: 0.85), totalWidth: width)
                    segment(bytes: compressedBytes, color: Color(red: 0.95, green: 0.55, blue: 0.20), totalWidth: width)
                    segment(bytes: otherBytes, color: Color.primary.opacity(0.18), totalWidth: width)
                }
            }
            .frame(height: 10)
            .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
            .hoverTooltip(
                $hoverInfo,
                text: "Share of physical RAM by category. Other is leftover (cache/free-ish)."
            )

            VStack(alignment: .leading, spacing: 3) {
                legendRow(
                    color: Color(red: 0.25, green: 0.55, blue: 0.95),
                    title: "App",
                    bytes: appBytes,
                    help: "Memory held by apps (anonymous/internal pages)."
                )
                legendRow(
                    color: Color(red: 0.70, green: 0.40, blue: 0.85),
                    title: "Wired",
                    bytes: wiredBytes,
                    help: "Locked system memory that usually cannot be paged out."
                )
                legendRow(
                    color: Color(red: 0.95, green: 0.55, blue: 0.20),
                    title: "Compressed",
                    bytes: compressedBytes,
                    help: "Idle pages squeezed in RAM. Better than swap, still a stress signal."
                )
                legendRow(
                    color: Color.primary.opacity(0.35),
                    title: "Other",
                    bytes: otherBytes,
                    help: "Remaining RAM not counted in App, Wired, or Compressed."
                )
            }
            .font(.caption)
        }
    }

    @ViewBuilder
    private func segment(bytes: UInt64, color: Color, totalWidth: CGFloat) -> some View {
        let fraction = totalBytes == 0 ? 0 : CGFloat(bytes) / CGFloat(totalBytes)
        let width = max(0, totalWidth * fraction)
        if width > 0.5 {
            Rectangle()
                .fill(color)
                .frame(width: width)
        }
    }

    private func legendRow(color: Color, title: String, bytes: UInt64, help: String) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(title)
            Spacer(minLength: 8)
            Text(MemoryFormat.bytes(bytes))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .hoverTooltip($hoverInfo, text: help)
    }
}

enum MemoryFormat {
    static func gb(_ bytes: UInt64) -> String {
        let value = Double(bytes) / 1_073_741_824.0
        return String(format: "%.1f", value)
    }

    /// Show MB under 0.1 GB so small values stay readable.
    static func bytes(_ bytes: UInt64) -> String {
        let gb = Double(bytes) / 1_073_741_824.0
        if gb < 0.1 {
            let mb = Double(bytes) / 1_048_576.0
            return String(format: "%.0f MB", mb)
        }
        return String(format: "%.1f GB", gb)
    }
}
