import Foundation

/// One line of "what is using the machine": a Claude session with its whole tree,
/// an app bundle, or every process sharing an executable name (node, rustc, ...).
public struct Consumer: Codable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable { case session, app, process, runtime }
    public var kind: Kind
    public var name: String
    public var rssBytes: UInt64
    /// Share of the whole machine, 0...100, so the rows add up to the CPU figure.
    public var cpuPercent: Double
    public var processCount: Int
    /// The processes to signal when the user closes this row: every process of the
    /// group, or only the root of a session. Each with its start time, against pid reuse.
    public var members: [ProcRef] = []
    public var bundlePath: String? = nil
    /// Set for a simulator, emulator or build daemon: closing goes through its own shutdown.
    public var runtimeID: String? = nil
    public var id: String { runtimeID ?? "\(kind.rawValue):\(name)" }
}

public struct ProcRef: Codable, Sendable, Equatable {
    public var pid: Int32
    public var lstart: String
}

public enum Consumers {
    public static func build(
        table: ProcTable, sessions: [ClaudeSession], runtimes: [DevRuntime] = [],
        cores: Int = ProcessInfo.processInfo.activeProcessorCount
    ) -> [Consumer] {
        let n = Double(max(cores, 1))
        var out: [Consumer] = []
        var taken = Set<Int32>()
        for r in runtimes {
            taken.formUnion(r.members.map(\.pid))
            out.append(Consumer(
                kind: .runtime, name: r.name, rssBytes: r.rssBytes, cpuPercent: r.cpuPercent,
                processCount: r.processCount, members: [r.root], runtimeID: r.id))
        }
        for s in sessions {
            let tree = table.tree(of: s.pid).filter { !taken.contains($0.pid) }
            taken.formUnion(tree.map(\.pid))
            out.append(Consumer(
                kind: .session, name: s.name.isEmpty ? s.project : s.name, rssBytes: s.rssBytes,
                cpuPercent: s.cpu / n, processCount: tree.count,
                members: [ProcRef(pid: s.pid, lstart: table.byPid[s.pid]?.lstart ?? "")]))
        }
        var groups: [String: Consumer] = [:]
        for p in table.all where !taken.contains(p.pid) {
            let kind: Consumer.Kind
            let name: String
            var bundlePath: String?
            if let bundle = AppGroups.bundlePath(of: p.program) {
                bundlePath = bundle
                kind = .app
                name = (bundle as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: "")
            } else {
                kind = .process
                name = (p.program as NSString).lastPathComponent
            }
            let key = "\(kind.rawValue):\(name)"
            var c = groups[key] ?? Consumer(kind: kind, name: name, rssBytes: 0, cpuPercent: 0, processCount: 0, bundlePath: bundlePath)
            c.members.append(ProcRef(pid: p.pid, lstart: p.lstart))
            c.rssBytes += p.rssBytes
            c.cpuPercent += p.cpu / n
            c.processCount += 1
            groups[key] = c
        }
        return out + groups.values
    }

    public static func topCPU(_ all: [Consumer], _ count: Int) -> [Consumer] {
        Array(all.sorted { $0.cpuPercent > $1.cpuPercent }.prefix(count))
    }

    public static func topMemory(_ all: [Consumer], _ count: Int) -> [Consumer] {
        Array(all.sorted { $0.rssBytes > $1.rssBytes }.prefix(count))
    }
}
