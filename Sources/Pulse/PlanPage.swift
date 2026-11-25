import PulseCore
import SwiftUI

/// What Optimize will do, row by row. Nothing happens before the button at the bottom.
struct PlanPage: View {
    @ObservedObject var model: Model
    @ObservedObject var ui: PanelState

    var body: some View {
        let actionable = model.actionable
        let chosen = actionable.filter { ui.selected.contains($0.id) }
        let bytes = chosen.reduce(0) { $0 + ($1.score?.ramBack ?? $1.reclaimBytes) }
        PageHeader(title: "Choose what to close") { ui.back() }
        VerdictTile(model: model, ui: ui)
        if actionable.isEmpty {
            Text("Nothing to close right now.").font(.system(size: 12)).foregroundStyle(.secondary).tile()
            Spacer(minLength: 0)
        } else {
            ScrollView(showsIndicators: false) {
                VStack(spacing: gap) {
                    group("Selected for you", actionable.filter { model.settings.preselects($0) })
                    group("Not selected", actionable.filter { !model.settings.preselects($0) })
                }
            }
            .scrollFade()
            MainButton(title: chosen.isEmpty ? "Nothing selected" : what(chosen), value: chosen.isEmpty ? nil : "about " + Fmt.bytes(bytes), on: !chosen.isEmpty) {
                model.run(chosen, shown: actionable, defaults: model.defaultSelection())
                ui.replace(with: .done)
            }
            .help("What closing these is expected to give back to RAM. Other programs take and give memory at the same time.")
        }
    }
}

/// What the optimizer says, in one title and one or two lines. A press shows how it chose.
struct VerdictTile: View {
    @ObservedObject var model: Model
    @ObservedObject var ui: PanelState

    var body: some View {
        let v = model.verdict
        let suggested = Set(v?.suggested ?? [])
        VStack(alignment: .leading, spacing: 4) {
            Button { ui.go(.decides) } label: {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        if let v, v.state >= .strained { Capsule().fill(Ink.hot).frame(width: 3, height: 12) }
                        Text(v?.title ?? "Reading memory…").font(.system(size: 12, weight: .semibold)).lineLimit(1)
                        Spacer(minLength: 4)
                        Text("How").font(.system(size: 10)).foregroundStyle(.secondary)
                        Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold)).foregroundStyle(.secondary)
                    }
                    if let v { Text(v.detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(3).fixedSize(horizontal: false, vertical: true) }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if !suggested.isEmpty, ui.selected != suggested {
                Button { ui.selected = suggested } label: {
                    Text("Select the \(suggested.count == 1 ? "suggested row" : "\(suggested.count) suggested")").font(.system(size: 10, weight: .semibold)).pill()
                }
                .buttonStyle(PressStyle())
            }
        }
        .tile()
    }
}

extension PlanPage {
    @ViewBuilder private func group(_ title: String, _ list: [Suggestion]) -> some View {
        if !list.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                TileLabel(title)
                VStack(spacing: 0) {
                    ForEach(list) { s in
                        PlanRow(suggestion: s, suggested: model.verdict?.suggested.contains(s.id) == true, isOn: Binding(
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
                    Text("Expected about \(Fmt.bytes(r.promised)) back. Memory in use: \(Fmt.bytes(r.memBefore)) before, \(Fmt.bytes(after)) now.")
                        .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if let st = r.stateAfter {
                        Text(st >= .strained ? "Memory is still short." : st == .tight ? "Memory is tight, but macOS does not warn." : "macOS is not short of memory.")
                            .font(.system(size: 11)).foregroundStyle(st >= .strained ? Ink.hot : .secondary)
                    }
                } else if r?.measuring == true {
                    Text("Measuring memory for a few seconds…").font(.system(size: 11)).foregroundStyle(.secondary)
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

/// How the optimizer chose, with every number it used. Nothing can be done from here.
struct DecidesPage: View {
    @ObservedObject var model: Model
    @ObservedObject var ui: PanelState

    var body: some View {
        let v = model.verdict
        PageHeader(title: "How Pulse chose") { ui.back() }
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: gap) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("Pulse suggests closing only when macOS is short of memory. Then it picks the rows that give back enough and that you are the least likely to want soon. When you used them teaches it, and so do your ticks and what you open again.")
                        .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if let v {
                        Hairline()
                        fact("Memory", state(v.state))
                        fact("Needed back", v.target == 0 ? "nothing" : "about " + Fmt.bytes(v.target))
                        fact("Free and cached", Fmt.bytes(v.availableBytes))
                        if let m = v.forecastMinutes { fact("macOS warns in", "about \(Int(m.rounded())) min") }
                        fact("Read from", v.basis == "learned" ? "the last minute" : "one reading")
                    }
                }
                .tile()
                ForEach(v?.scores ?? [], id: \.id) { s in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(title(s.id)).font(.system(size: 12, weight: .medium)).lineLimit(1)
                            Spacer(minLength: 4)
                            if s.suggested { Text("Suggested").font(.system(size: 9, weight: .semibold)).pill() }
                            Text(s.confidenceWord).font(.system(size: 10)).foregroundStyle(.secondary).help("How sure: from how many of its pauses Pulse has seen")
                        }
                        ForEach(s.reasons, id: \.self) { r in
                            Text(r).font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .tile()
                }
            }
        }
        .scrollFade()
    }

    private func title(_ id: String) -> String { model.snap?.suggestions.first { $0.id == id }?.title ?? id }

    private func state(_ s: MemoryState) -> String {
        switch s {
        case .calm: return "not short"
        case .tight: return "getting tight"
        case .strained: return "short"
        case .critical: return "very short"
        }
    }

    private func fact(_ name: String, _ value: String) -> some View {
        HStack {
            Text(name).font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.system(size: 11)).monospacedDigit()
        }
    }
}
