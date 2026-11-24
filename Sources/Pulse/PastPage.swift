import PulseCore
import SwiftUI

enum Past {
    /// "1.4 h CPU", "12 min CPU", "40 s CPU".
    static func cpu(_ s: Double) -> String {
        s >= 3600 ? String(format: "%.1f h CPU", s / 3600) : s >= 60 ? String(format: "%.0f min CPU", s / 60) : String(format: "%.0f s CPU", s)
    }

    static func note(since: Date?) -> String {
        guard let since else { return "Counted from now on, while Pulse is running." }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "HH:mm"
        return "CPU time since \(f.string(from: since)), counted while Pulse was running. Under each, the most memory it held."
    }
}

/// A row of the last twelve hours. What runs now has its close control, like everywhere.
struct PastRow<Trailing: View>: View {
    let row: LoadHistory.Row
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 8) {
            Glyph(kind: row.kind == .session ? .lines : row.kind == .app ? .block : row.kind == .runtime ? .cross : .slash)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.name).font(.system(size: 12)).lineLimit(1)
                Text(row.peakBytes > 0 ? "Up to \(Fmt.bytes(row.peakBytes))" : "Little memory").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Text(Past.cpu(row.cpuSeconds)).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
            trailing()
        }
        .frame(height: 30)
    }
}
