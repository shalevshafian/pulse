import AppKit
import PulseCore
import SwiftUI

/// Under what can be cleared: what takes the space and is not Pulse's to judge. A press shows it in Finder.
struct LargeFoldersTile: View {
    @ObservedObject var model: Model

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            TileLabel("Largest Library folders", count: model.largest.map { "\($0.folders.count)" })
            if let found = model.largest {
                if found.folders.isEmpty { Text("None over 1 GB").font(.system(size: 12)).foregroundStyle(.secondary) }
                Text(Self.note(found)).font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                ForEach(found.folders) { row($0) }
            } else {
                Text("Measuring…").font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
        .tile()
        .onAppear { model.measureLibrary() }
    }

    static func note(_ f: LargeFolders) -> String {
        var s = "Pulse only shows these. They may hold your work."
        if f.refused > 0 { s += " \(Plural.count(f.refused, "folder")) macOS keeps closed \(f.refused == 1 ? "is" : "are") not counted." }
        if !f.unfinished.isEmpty { s += " Too slow to measure: \(f.unfinished.joined(separator: ", "))." }
        return s
    }

    private func row(_ f: LargeFolders.Folder) -> some View {
        let app = model.appName(ofFolder: f.name)
        return Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: f.path)]) } label: {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(app ?? f.name).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                    Text(app == nil ? f.place : "\(f.place) · \(f.name)").font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 6)
                Text(Fmt.bytes(f.bytes)).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                Image(systemName: "arrow.up.right").font(.system(size: 9)).foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .help("Show in Finder")
    }
}
