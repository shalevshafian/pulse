import PulseCore
import SwiftUI

/// What launchd holds now: the items of the folders and those that live inside apps. A list, no controls.
struct StartupTile: View {
    let items: [StartupItem]

    var body: some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 7) {
                TileLabel("Starts with this Mac, and is loaded now", count: "\(items.count)")
                ForEach(Array(items.enumerated()), id: \.offset) { _, i in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(i.app ?? i.label).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                        Text(i.signer ?? "Signer not known").font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .help(i.label + "\n" + i.program)
                }
            }
            .tile()
        }
    }
}
