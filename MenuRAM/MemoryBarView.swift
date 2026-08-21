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

            VStack(alignment: .leading, spacing: 3) {
                legendRow(color: Color(red: 0.25, green: 0.55, blue: 0.95), title: "App", bytes: appBytes)
                legendRow(color: Color(red: 0.70, green: 0.40, blue: 0.85), title: "Wired", bytes: wiredBytes)
                legendRow(color: Color(red: 0.95, green: 0.55, blue: 0.20), title: "Compressed", bytes: compressedBytes)
                legendRow(color: Color.primary.opacity(0.35), title: "Other", bytes: otherBytes)
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

    private func legendRow(color: Color, title: String, bytes: UInt64) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(title)
            Spacer(minLength: 8)
            Text(MemoryFormat.gb(bytes) + " GB")
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }
}

enum MemoryFormat {
    static func gb(_ bytes: UInt64) -> String {
        let value = Double(bytes) / 1_073_741_824.0
        return String(format: "%.1f", value)
    }
}
