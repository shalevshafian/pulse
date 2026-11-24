import Foundation

/// What Pulse did on the user's word, and the way back where there is one.
public struct Receipt: Codable, Sendable, Equatable, Identifiable {
    public enum Back: Codable, Sendable, Equatable {
        /// Open the app again.
        case app(path: String)
        /// The command that goes on with the conversation.
        case session(cwd: String, id: String)
        /// From the Trash to where it was.
        case trash(from: String, to: String)
    }

    public var id: UUID
    public var at: Date
    public var title: String
    public var detail: String
    public var bytes: UInt64
    public var ok: Bool
    public var back: Back?
    public var undone: Bool

    public init(at: Date, title: String, detail: String, bytes: UInt64 = 0, ok: Bool = true, back: Back? = nil) {
        id = UUID(); self.at = at; self.title = title; self.detail = detail; self.bytes = bytes; self.ok = ok; self.back = back; undone = false
    }
}

public struct Receipts: Codable, Sendable, Equatable {
    public private(set) var list: [Receipt] = []
    static let kept = 100

    public init() {}

    public mutating func add(_ r: Receipt) { list = Array(([r] + list).prefix(Self.kept)) }
    public mutating func add(_ rs: [Receipt]) { rs.reversed().forEach { add($0) } }

    public mutating func markUndone(_ id: UUID) {
        guard let i = list.firstIndex(where: { $0.id == id }) else { return }
        list[i].undone = true
    }

    public static var defaultURL: URL { Settings.defaultURL.deletingLastPathComponent().appendingPathComponent("receipts.json") }

    public static func load(from url: URL = defaultURL) -> Receipts {
        guard let data = try? Data(contentsOf: url), let r = try? JSONDecoder().decode(Receipts.self, from: data) else { return Receipts() }
        return r
    }

    public func save(to url: URL = Receipts.defaultURL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(self).write(to: url, options: .atomic)
    }

    /// Only if it is still in the Trash and nothing has taken its old place. Nothing is overwritten.
    public static func putBack(from: String, to: String) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: from), !fm.fileExists(atPath: to), (try? fm.attributesOfItem(atPath: to)) == nil,
              fm.fileExists(atPath: (to as NSString).deletingLastPathComponent) else { return false }
        return (try? fm.moveItem(atPath: from, toPath: to)) != nil
    }

    /// For pasting into a terminal. The folder is quoted whatever is in its name.
    public static func resume(cwd: String, id: String) -> String? {
        guard !id.isEmpty, id.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }) else { return nil }
        return "cd '" + cwd.replacingOccurrences(of: "'", with: "'\\''") + "' && claude --resume " + id
    }
}
