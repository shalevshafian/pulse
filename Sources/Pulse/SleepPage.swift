import PulseCore
import SwiftUI

/// What asks this Mac to stay awake, and what the last sleep cost. Nothing is ended here: a row
/// leads to its process, where the two presses are.
struct SleepPage: View {
    @ObservedObject var model: Model
    let back: () -> Void
    let open: (String) -> Void

    var body: some View {
        let rows = model.snap?.awake ?? []
        PageHeader(title: "Sleep", count: rows.count, back: back)
        Text("What asks this Mac to stay awake. Pulse stops nothing here; the row opens its process.")
            .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(.horizontal, 4)
        if rows.isEmpty {
            Text(model.snap == nil ? "Checking…" : model.snap?.awake == nil ? "macOS did not answer" : "Nothing keeps this Mac awake")
                .font(.system(size: 12)).foregroundStyle(.secondary).tile()
        } else {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 6) { ForEach(rows) { row($0) } }
            }
            .frame(height: min(CGFloat(rows.count) * 38 - 6, 222))
            .tile()
        }
        if let s = model.lastSleep {
            VStack(alignment: .leading, spacing: 4) {
                TileLabel("Last sleep")
                Text(Self.line(s)).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
            }
            .tile()
        }
        Spacer(minLength: 0)
        Text("While its display is on the Mac stays awake anyway. That is not listed, and neither is a mounted drive.")
            .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(.horizontal, 4)
            .onAppear { model.refreshSleep() }
    }

    static func line(_ s: SleepRecord) -> String {
        var parts = [Fmt.duration(s.seconds)]
        if let lost = s.lost { parts.append(String(format: "lost %.0f%%", lost)) }
        if let n = s.darkWakes { parts.append(n == 0 ? "never woke by itself" : "woke by itself \(Plural.count(n, "time"))") }
        return parts.joined(separator: ", ")
    }

    private func row(_ h: AwakeHolder) -> some View {
        Button { open(h.name) } label: {
            HStack(spacing: 8) {
                Glyph(kind: h.kind == .session ? .lines : h.kind == .app ? .block : h.kind == .runtime ? .cross : .slash)
                VStack(alignment: .leading, spacing: 1) {
                    Text(h.name).font(.system(size: 12)).lineLimit(1)
                    Text(h.reason).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 6)
                if let since = h.since {
                    Text(Fmt.duration(Date().timeIntervalSince(since))).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
            }
            .frame(height: 32)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .help(h.reason)
    }
}

/// One line that leads to the page: whether the Mac will sleep decides whether a drive is let go.
struct AwakeRow: View {
    let holders: [AwakeHolder]?
    let action: () -> Void

    private var text: String {
        guard let h = holders else { return "What keeps this Mac awake" }
        guard let first = h.first else { return "Nothing keeps this Mac awake" }
        return "Awake because of \(first.name)" + (h.count > 1 ? " and \(h.count - 1) more" : "")
    }

    var body: some View {
        Button(action: action) {
            HStack {
                Text(text).font(.system(size: 12)).lineLimit(1)
                Spacer(minLength: 6)
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
            }
            .tile(padding: 9)
        }
        .buttonStyle(PressStyle())
    }
}
