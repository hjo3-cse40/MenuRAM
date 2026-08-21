import SwiftUI

struct HoverInfo: Equatable {
    let text: String
    let frame: CGRect
}

/// Floating description card. Drawn as an overlay so it cannot resize the popover.
struct HoverTooltipOverlay: View {
    let info: HoverInfo?
    let panelSize: CGSize

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let info {
                tooltip(info)
                    .offset(tooltipOffset(for: info))
            }
        }
        .frame(width: panelSize.width, height: panelSize.height, alignment: .topLeading)
        .allowsHitTesting(false)
    }

    private func tooltip(_ info: HoverInfo) -> some View {
        Text(info.text)
            .font(.caption)
            .foregroundStyle(.primary)
            .multilineTextAlignment(.leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(width: 252, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(.white.opacity(0.12), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.28), radius: 8, y: 2)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func tooltipOffset(for info: HoverInfo) -> CGSize {
        let estimatedHeight: CGFloat = 48
        let gap: CGFloat = 6
        let x: CGFloat = 14
        let below = info.frame.maxY + gap
        let y: CGFloat
        if below + estimatedHeight > panelSize.height - 8 {
            y = max(8, info.frame.minY - estimatedHeight - gap)
        } else {
            y = below
        }
        return CGSize(width: x, height: y)
    }
}

private struct HoverTooltipModifier: ViewModifier {
    @Binding var info: HoverInfo?
    let text: String
    @State private var frame: CGRect = .zero

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .background(
                GeometryReader { proxy in
                    Color.clear
                        .onAppear {
                            frame = proxy.frame(in: .named("panel"))
                        }
                        .onChange(of: proxy.size) { _, _ in
                            frame = proxy.frame(in: .named("panel"))
                        }
                }
            )
            .onHover { hovering in
                if hovering {
                    info = HoverInfo(text: text, frame: frame)
                } else if info?.text == text {
                    info = nil
                }
            }
    }
}

extension View {
    func hoverTooltip(_ info: Binding<HoverInfo?>, text: String) -> some View {
        modifier(HoverTooltipModifier(info: info, text: text))
    }
}
