import PulseCore
import SwiftUI

/// Startup items with who signed them. A list, no controls.
struct StartupTile: View {
    let title: String
    let items: [StartupItem]

    var body: some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 7) {
                TileLabel(title, count: "\(items.count)")
                ForEach(Array(items.enumerated()), id: \.offset) { _, i in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(i.app ?? i.label).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                        Text(i.missing ? "Its program is gone" : i.signer ?? "Signer not known").font(.system(size: 10)).foregroundStyle(i.missing ? Color.primary : Color.secondary).lineLimit(1)
                    }
                    .help(i.label + "\n" + i.program)
                }
            }
            .tile()
        }
    }
}
