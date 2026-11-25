import PulseCore
import SwiftUI

/// A row for each tool, at the top of the sessions page, and only when ticked in Settings.
struct PlanUsageTile: View {
    @ObservedObject var model: Model

    var body: some View {
        if model.settings.planUsage {
            VStack(alignment: .leading, spacing: 8) {
                TileLabel("Plan limits")
                if model.plan.isEmpty {
                    Text("No recent reading on this Mac").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                ForEach(model.plan) { row($0) }
            }
            .tile()
            // When the page opens, and every five minutes while it stays.
            .task {
                while !Task.isCancelled {
                    model.refreshPlan()
                    try? await Task.sleep(nanoseconds: 300_000_000_000)
                }
            }
        }
    }

    private func row(_ p: PlanUsage) -> some View {
        let main = p.limits[0]
        return VStack(alignment: .leading, spacing: 1) {
            HStack {
                Text("\(p.tool) \(main.name)").font(.system(size: 12))
                Spacer()
                value(main)
            }
            Text(([PlanUsage.resets(main.resetsAt, now: Date())] + p.limits.dropFirst().prefix(1).map { String(format: "%@ %.0f%%", $0.name, $0.percent) }
                  + [Fmt.duration(Date().timeIntervalSince(p.readAt)) + " ago"]).joined(separator: " · "))
                .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
        }
        .help(p.limits.map { String(format: "%@ %.0f%%, ", $0.name, $0.percent) + PlanUsage.resets($0.resetsAt, now: Date()) }.joined(separator: "\n"))
    }

    private func value(_ l: PlanUsage.Limit) -> some View {
        Text(String(format: "%.0f%% used", l.percent)).font(.system(size: 12, weight: .semibold, design: .monospaced))
            .foregroundStyle(l.percent >= 90 ? Ink.hot : Color.primary)
    }
}
