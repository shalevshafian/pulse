import Foundation

/// MCP over stdio, newline-delimited JSON-RPC. Read-only on purpose: an agent can
/// see the machine and the sessions, and cannot close or kill anything.
public final class MCPServer {
    public typealias Provider = () -> Snapshot

    let provider: Provider
    let healthStore: () -> HealthStore

    public init(provider: @escaping Provider = { Snapshot.take(system: SystemSampler().sampleBlocking()) },
                healthStore: @escaping () -> HealthStore = { HealthStore.load() }) {
        self.provider = provider
        self.healthStore = healthStore
    }

    static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"

    static let tools: [(name: String, description: String)] = [
        ("system_usage", "CPU load, memory used and pressure level, swap, free disk and thermal state of this Mac, right now."),
        ("claude_sessions", "Every live Claude Code session on this Mac: name, project folder, idle, busy or waiting for the user (waitingFor says for what), how long idle, and the memory of its whole process tree."),
        ("top_cpu", "What is using the CPU right now: Claude sessions (whole process tree), apps and other processes grouped by name. cpuPercent is the share of the whole machine."),
        ("top_memory", "What is using the most memory right now, grouped the same way as top_cpu."),
        ("dev_runtimes", "Booted iOS simulators, running Android emulators and Gradle or Kotlin build daemons on this Mac: name, UDID or emulator serial, memory, CPU share and how long each has been up. Check here before booting another one."),
        ("optimize_suggestions", "Ranked suggestions for freeing memory (reclaimBytes is what a row holds now, the most that closing it can give back): long-idle Claude sessions (stillWorking marks one whose own processes are running), leftover agent processes, simulators, emulators and build daemons up for over an hour, heavy apps. Read-only; the user applies them from the Pulse menu bar item."),
        ("health_report", "The last health check of this Mac: score out of 100, the open problems (backup, protection, updates, storage, battery, stability, performance, startup items), what could not be read, and folders that can be rebuilt. Reads the stored report and gives its age; it does not run a check."),
    ]

    public func run() {
        while let line = readLine(strippingNewline: true) {
            if let reply = handle(line) {
                FileHandle.standardOutput.write(Data((reply + "\n").utf8))
            }
        }
    }

    /// Returns the reply line, or nil for a notification.
    public func handle(_ line: String) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else {
            return encode(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "Parse error"]])
        }
        guard let id = obj["id"], !(id is NSNull) else { return nil }
        let method = obj["method"] as? String ?? ""
        let params = obj["params"] as? [String: Any] ?? [:]

        switch method {
        case "initialize":
            return result(id, [
                "protocolVersion": params["protocolVersion"] as? String ?? "2025-06-18",
                "capabilities": ["tools": [String: Any]()],
                "serverInfo": ["name": "pulse", "version": Self.version],
                "instructions": "Pulse reports this Mac's load and the Claude sessions running on it. All tools are read-only.",
            ])
        case "ping":
            return result(id, [String: Any]())
        case "tools/list":
            return result(id, ["tools": Self.tools.map {
                ["name": $0.name, "description": $0.description,
                 "inputSchema": ["type": "object", "properties": [String: Any]()],
                 "annotations": ["readOnlyHint": true]] as [String: Any]
            }])
        case "tools/call":
            guard let name = params["name"] as? String, let text = call(name) else {
                return error(id, -32602, "Unknown tool")
            }
            return result(id, ["content": [["type": "text", "text": text]], "isError": false])
        default:
            return error(id, -32601, "Method not found: \(method)")
        }
    }

    func call(_ name: String) -> String? {
        if name == "health_report" { return healthReport() }
        let snap = provider()
        switch name {
        case "system_usage": return json(snap.system)
        case "claude_sessions": return json(snap.sessions)
        case "top_cpu": return json(snap.topCPU)
        case "top_memory": return json(snap.topMemory)
        case "dev_runtimes": return json(snap.runtimes)
        case "optimize_suggestions": return json(snap.suggestions)
        default: return nil
        }
    }

    func healthReport(now: Date = Date()) -> String {
        let store = healthStore()
        guard let report = store.report, let score = store.score else {
            return "{\"error\":\"No health check has run yet. The Pulse menu bar app runs one every six hours.\"}"
        }
        struct Out: Encodable {
            var score: Int, ageMinutes: Int, problems: [HealthCheck], ignored: [String], unknown: [HealthCheck]
            var ok: [HealthCheck], cleanup: [CleanupItem]
        }
        return json(Out(score: score, ageMinutes: Int(now.timeIntervalSince(report.takenAt) / 60), problems: store.problems, ignored: store.ignored,
                        unknown: store.unknowns, ok: report.checks.filter { $0.state == .ok }, cleanup: report.cleanup))
    }

    func json<T: Encodable>(_ value: T) -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        enc.dateEncodingStrategy = .iso8601
        return (try? enc.encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? "null"
    }

    func result(_ id: Any, _ value: Any) -> String { encode(["jsonrpc": "2.0", "id": id, "result": value]) }
    func error(_ id: Any, _ code: Int, _ message: String) -> String {
        encode(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])
    }
    func encode(_ obj: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: obj, options: [.withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}
