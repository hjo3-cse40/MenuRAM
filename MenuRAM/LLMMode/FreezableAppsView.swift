import SwiftUI

/// Apps whose renderer processes can be paused to stop them competing with a model.
struct FreezableAppsView: View {
    @ObservedObject var freezer: ProcessFreezer
    @Binding var hoverInfo: HoverInfo?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("Freezable Apps")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if freezer.hasFrozenProcesses {
                    Button("Resume all") { freezer.resumeAll() }
                        .buttonStyle(.link)
                        .font(.caption2)
                }
            }
            .hoverTooltip(
                $hoverInfo,
                text: "Freezing pauses tabs and renderers (SIGSTOP). Windows stay open; switching to the app resumes it. Frozen memory is not freed, but macOS can compress it cheaply."
            )

            if freezer.groups.isEmpty {
                Text("No large browser or Electron renderers.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(freezer.groups) { group in
                    row(group)
                }
            }

            if let error = freezer.lastError {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
    }

    private func row(_ group: FreezableGroup) -> some View {
        HStack(spacing: 6) {
            Image(systemName: group.isFrozen ? "snowflake" : "macwindow")
                .foregroundStyle(group.isFrozen ? Color.cyan : Color.secondary)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 0) {
                Text(group.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\(group.rendererPids.count) renderer\(group.rendererPids.count == 1 ? "" : "s") · \(MemoryFormat.bytes(group.rendererBytes))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer(minLength: 6)
            Button(group.isFrozen ? "Resume" : "Freeze") {
                freezer.toggle(group)
            }
            .controlSize(.small)
            .disabled(group.isFrontmost && !group.isFrozen)
            .help(group.isFrontmost ? "Switch to another app before freezing this one." : "")
        }
        .font(.caption)
    }
}
