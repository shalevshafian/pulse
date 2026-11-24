import PulseCore
import SwiftUI

/// What asks this Mac to stay awake, what the last sleep cost, and keeping it awake on purpose.
/// Nothing of others is ended here: a row leads to its process, where the two presses are.
struct SleepPage: View {
    @ObservedObject var model: Model
    @ObservedObject var ui: PanelState

    var body: some View {
        let rows = model.snap?.awake ?? []
        PageHeader(title: "Sleep", count: rows.count) { ui.back() }
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Keep awake").font(.system(size: 12, weight: .medium))
                Spacer()
                Choice(options: [0, 1, 4, 8], value: Binding(get: { model.awakeHours }, set: { model.keepAwake(hours: $0) })) { $0 == 0 ? "Off" : "\(Int($0)) h" }
            }
            Text(model.awakeUntil.map { "Until \(Fmt.clock($0)), or until Pulse quits. The display may still go dark." } ?? "The Mac stays awake while the display may go dark. It ends by itself.")
                .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .tile()
        ScrollView(showsIndicators: false) {
            VStack(spacing: gap) {
                VStack(alignment: .leading, spacing: 6) {
                    TileLabel("Asks this Mac to stay awake")
                    if rows.isEmpty {
                        Text(model.snap == nil ? "Checking…" : model.snap?.awake == nil ? "macOS did not answer" : "Nothing does").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    ForEach(rows) { row($0) }
                }
                .tile()
                if let s = model.lastSleep {
                    VStack(alignment: .leading, spacing: 4) {
                        TileLabel("Last sleep")
                        Text(Self.line(s)).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                    }
                    .tile()
                }
            }
        }
        .scrollFade()
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
        let target = model.snap?.consumers.first { c in c.times.contains { h.pids.contains($0.pid) } && c.name == h.name } ?? model.snap?.consumers.first { $0.kind == h.kind && $0.name == h.name }
        return Button { (target?.id).map(ui.openRow) } label: {
            HStack(spacing: 8) {
                Glyph(kind: Glyph.of(h.kind))
                VStack(alignment: .leading, spacing: 1) {
                    Text(h.name).font(.system(size: 12)).lineLimit(1)
                    Text(h.reason).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 6)
                if let since = h.since {
                    Text(Fmt.duration(Date().timeIntervalSince(since))).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary).opacity(target == nil ? 0 : 1)
            }
            .frame(height: 32)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle()).disabled(target == nil)
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

    var body: some View { line(text, icon: "chevron.right", action).tile(padding: 9) }
}
