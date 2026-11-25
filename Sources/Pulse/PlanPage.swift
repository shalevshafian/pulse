import PulseCore
import SwiftUI

/// What Optimize will do, row by row. Nothing happens before the button at the bottom.
struct PlanPage: View {
    @ObservedObject var model: Model
    @ObservedObject var ui: PanelState

    var body: some View {
        let actionable = model.actionable
        let chosen = actionable.filter { ui.selected.contains($0.id) }
        let bytes = chosen.reduce(0) { $0 + $1.reclaimBytes }
        PageHeader(title: "What Optimize will do") { ui.back() }
        Text(!model.hasClaude ? "Only ticked rows are closed. An app is asked to quit, as if you quit it yourself." : "Only ticked rows are closed. A working session is never closed, and a closed one can be resumed.")
            .font(.system(size: 11)).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 4)
        ForEach((model.snap?.suggestions ?? []).filter { $0.kind == .advice }) { a in
            Label(a.title + ": " + a.detail, systemImage: "exclamationmark.triangle")
                .font(.system(size: 11)).foregroundStyle(Ink.hot)
                .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 4)
        }
        if actionable.isEmpty {
            Text("Nothing to close. Everything is in use.").font(.system(size: 12)).foregroundStyle(.secondary).tile()
            Spacer(minLength: 0)
        } else {
            ScrollView(showsIndicators: false) {
                VStack(spacing: gap) {
                    group("By your rules", actionable.filter { model.settings.preselects($0) })
                    group("Your choice", actionable.filter { !model.settings.preselects($0) })
                }
            }
            .scrollFade()
            MainButton(title: chosen.isEmpty ? "Nothing selected" : what(chosen), value: chosen.isEmpty ? nil : Fmt.bytes(bytes) + " in use", on: !chosen.isEmpty) {
                model.run(chosen)
                ui.replace(with: .done)
            }
            .help("What these hold now, compressed memory included. Closing them gives back at most that.")
        }
    }
}

extension PlanPage {
    @ViewBuilder private func group(_ title: String, _ list: [Suggestion]) -> some View {
        if !list.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                TileLabel(title)
                VStack(spacing: 0) {
                    ForEach(list) { s in
                        PlanRow(suggestion: s, isOn: Binding(
                            get: { ui.selected.contains(s.id) },
                            set: { if $0 { ui.selected.insert(s.id) } else { ui.selected.remove(s.id) } }))
                    }
                }
            }
            .tile()
        }
    }

    /// The result, in words, before it happens.
    private func what(_ chosen: [Suggestion]) -> String {
        let sessions = chosen.filter { $0.kind == .idleSession }.count, rest = chosen.count - sessions
        if sessions == 0 { return rest == 1 ? "Close \(chosen[0].title)" : "Close \(rest) of these" }
        return rest > 0 ? "Close \(sessions + rest) of these" : "Close \(Plural.count(sessions, "session"))"
    }
}

/// What was done, measured, with the way back beside each row.
struct DonePage: View {
    @ObservedObject var model: Model
    @ObservedObject var ui: PanelState

    var body: some View {
        let r = model.result
        let done = model.receipts.list.filter { x in r?.receipts.contains(x.id) ?? false }
        let closed = done.filter { $0.ok }.count
        PageHeader(title: r?.running == true ? "Working…" : "Done", count: nil) { ui.back() }
        VStack(alignment: .leading, spacing: 4) {
            if r?.running == true {
                Text("This can take a few seconds.").font(.system(size: 12)).foregroundStyle(.secondary)
            } else {
                Text("\(closed) of \(done.count) done").font(.system(size: 14, weight: .semibold))
                if r?.cleared == true {
                    Text("\(Fmt.bytes(done.filter(\.ok).reduce(0) { $0 + $1.bytes })) in the Trash. Empty the Trash to free the space.").font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } else if let r, let after = r.memAfter {
                    // Other programs take and give memory at the same time: the difference is a fact, not a promise kept.
                    Text("\(Fmt.bytes(r.memBefore)) in use before, \(Fmt.bytes(after)) now").font(.system(size: 11)).foregroundStyle(.secondary)
                } else {
                    Text("Measuring memory…").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
        }
        .tile()
        if !done.isEmpty {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 8) { ForEach(done) { ReceiptRow(model: model, receipt: $0, dated: false) } }.tile()
            }
            .scrollFade()
        }
        Spacer(minLength: 0)
        if let notice = model.notice { NoticeLine(text: notice) }
        line("History", icon: "chevron.right") { ui.go(.history) }.foregroundStyle(.secondary).padding(.horizontal, 4)
    }
}
