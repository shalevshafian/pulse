import Foundation

/// A program of this user that other programs can connect to.
public struct OpenPort: Codable, Sendable, Equatable, Identifiable {
    public var port: Int
    public var program: String
    public var pid: Int32
    /// Bound to every address: other machines on the network can reach it, unless the firewall stops them.
    public var network: Bool
    public var id: String { "\(pid):\(port)" }
}

public enum Ports {
    /// Nil when `lsof` did not answer. Programs of other users are not in it.
    public static func read() -> [OpenPort]? {
        Shell.output("/usr/sbin/lsof", ["-nP", "-iTCP", "-sTCP:LISTEN", "-Fpcn"], timeout: 8).map { parse($0) }
    }

    /// `-F` prints a letter and a value per line: p pid, c command, f descriptor, n address.
    static func parse(_ text: String) -> [OpenPort] {
        var rows: [String: OpenPort] = [:]
        var pid: Int32 = 0, name = ""
        for line in text.split(separator: "\n") {
            let value = String(line.dropFirst())
            switch line.first {
            case "p": pid = Int32(value) ?? 0; name = ""
            case "c": name = value.replacingOccurrences(of: "\\x20", with: " ")
            case "n":
                guard pid > 0, let cut = value.lastIndex(of: ":"), let port = Int(value[value.index(after: cut)...]) else { continue }
                let host = value[..<cut]
                let local = host == "127.0.0.1" || host == "[::1]" || host.hasPrefix("127.") || host == "localhost"
                var row = rows["\(pid):\(port)"] ?? OpenPort(port: port, program: name, pid: pid, network: false)
                if !local { row.network = true }
                rows[row.id] = row
            default: continue
            }
        }
        return rows.values.sorted { ($0.port, $0.pid) < ($1.port, $1.pid) }
    }
}
