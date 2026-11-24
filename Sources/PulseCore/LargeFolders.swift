import Foundation

/// The biggest folders of the user's Library, shown and nothing more: Pulse does not know what they are.
public struct LargeFolders: Sendable, Equatable {
    public struct Folder: Sendable, Equatable, Identifiable {
        public var path: String
        public var bytes: UInt64
        public var id: String { path }
        public var name: String { (path as NSString).lastPathComponent }
        public var place: String { ((path as NSString).deletingLastPathComponent as NSString).lastPathComponent }
    }

    public var folders: [Folder] = []
    /// Folders macOS would not let Pulse into. Their size is not known, which is not the same as none.
    public var refused = 0
    /// Places that took too long to measure.
    public var unfinished: [String] = []
    public init() {}

    static let minimum: UInt64 = 1 << 30
    static let shown = 8
    static let places = ["Library/Application Support", "Library/Developer", "Library/Caches", "Library/Logs"]
    /// Entering these can raise a permission dialog, or they are the user's own files.
    static let guarded: Set<String> = ["Containers", "Group Containers", "Mobile Documents", "Desktop", "Documents", "Downloads"]

    /// One place at a time. Links are not followed and other volumes are not entered.
    public static func find() -> LargeFolders { find(home: NSHomeDirectory()) }

    static func find(home: String, minimum: UInt64 = minimum,
                     du: ([String]) -> String? = { Shell.output("/usr/bin/du", ["-skx", "--"] + $0, timeout: 120) }) -> LargeFolders {
        var out = LargeFolders()
        var refused = Set<String>()
        // What the list above already offers to clear is not shown twice.
        let offered = Set(Cleanup.places.map { home + "/" + $0.path })
        for place in places {
            let root = home + "/" + place
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: root) else {
                if FileManager.default.fileExists(atPath: root) { refused.insert(root) }
                continue
            }
            let paths = names.filter { !guarded.contains($0) }.map { root + "/" + $0 }.filter { !offered.contains($0) && isRealFolder($0) }
            guard !paths.isEmpty else { continue }
            guard let text = du(paths) else { out.unfinished.append((place as NSString).lastPathComponent); continue }
            let read = parse(text)
            refused.formUnion(read.refused)
            let asked = Set(paths)
            out.folders += read.sizes.filter { asked.contains($0.key) && $0.value >= minimum }.map { Folder(path: $0.key, bytes: $0.value) }
        }
        out.refused = refused.count
        out.folders = Array(out.folders.sorted { $0.bytes > $1.bytes }.prefix(shown))
        return out
    }

    /// "1234\t/path" in kilobytes, and "du: /path: Operation not permitted" on the other stream.
    static func parse(_ text: String) -> (sizes: [String: UInt64], refused: Set<String>) {
        var sizes: [String: UInt64] = [:]
        var refused = Set<String>()
        for line in text.split(separator: "\n") {
            if line.hasPrefix("du: "), let end = line.range(of: ": Operation not permitted", options: .backwards) ?? line.range(of: ": Permission denied", options: .backwards) {
                refused.insert(String(line[line.index(line.startIndex, offsetBy: 4)..<end.lowerBound]))
            } else if let tab = line.firstIndex(of: "\t"), let kb = UInt64(line[..<tab].trimmingCharacters(in: .whitespaces)) {
                sizes[String(line[line.index(after: tab)...])] = kb * 1024
            }
        }
        // A folder refused whole has no size.
        for path in refused { sizes[path] = nil }
        return (sizes, refused)
    }

    /// A folder itself. Asked without opening it, so a link is seen as a link.
    static func isRealFolder(_ path: String) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.type] as? FileAttributeType == .typeDirectory
    }
}
