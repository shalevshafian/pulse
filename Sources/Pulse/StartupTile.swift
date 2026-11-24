import AppKit
import PulseCore
import SwiftUI

/// Startup items with who signed them. A press shows the program in Finder; nothing is changed.
struct StartupTile: View {
    let title: String
    let items: [StartupItem]

    var body: some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 7) {
                TileLabel(title, count: "\(items.count)")
                ForEach(Array(items.enumerated()), id: \.offset) { _, i in
                    let there = !i.program.isEmpty && FileManager.default.fileExists(atPath: i.program)
                    Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: i.program)]) } label: {
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(i.app ?? i.label).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                                Text(i.missing ? "Its program is gone" : i.signer ?? "Signer not known").font(.system(size: 10)).foregroundStyle(i.missing ? Color.primary : Color.secondary).lineLimit(1)
                            }
                            Spacer(minLength: 6)
                            Image(systemName: "arrow.up.right").font(.system(size: 9)).foregroundStyle(.secondary).opacity(there ? 1 : 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PressStyle()).disabled(!there)
                    .help(i.label + "\n" + i.program)
                }
            }
            .tile()
        }
    }
}
