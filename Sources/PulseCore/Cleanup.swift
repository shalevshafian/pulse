import Darwin
import Foundation

/// Something that comes back by itself when it is needed: a build cache or a download cache.
public struct CleanupItem: Codable, Sendable, Identifiable, Equatable {
    public var id: String { path }
    public var title: String
    public var detail: String
    public var path: String
    public var bytes: UInt64
    /// Set while something that uses it is running. Such a row cannot be ticked.
    public var blockedBy: String?
}

public enum Cleanup {
    static let minimum: UInt64 = 100 << 20
    static let staleDays = 14.0

    /// The only fixed places ever offered. Everything else has to carry cargo's own cache tag.
    static let places: [(path: String, title: String, detail: String, users: [String])] = [
        ("Library/Developer/Xcode/DerivedData", "Xcode builds", "Rebuilt on the next build", ["Xcode", "xcodebuild", "swift-build", "XCBBuildService"]),
        (".gradle/caches", "Gradle cache", "Downloaded again on the next build", ["java", "gradle"]),
        (".npm/_cacache", "npm cache", "Downloaded again on the next install", ["npm"]),
        ("Library/Caches/pnpm", "pnpm cache", "Downloaded again on the next install", ["pnpm"]),
        ("Library/Caches/pip", "pip cache", "Downloaded again on the next install", ["pip", "pip3"]),
        ("Library/Caches/node-gyp", "node-gyp cache", "Downloaded again on the next build", ["node-gyp"]),
        ("Library/Caches/Homebrew", "Homebrew cache", "Downloaded again on the next install", ["brew"]),
        (".gradle/wrapper", "Gradle versions", "Downloaded again on the next build", ["java", "gradle"]),
        ("Library/Caches/ms-playwright", "Playwright browsers", "Downloaded again by its own install", ["playwright"]),
        ("Library/Caches/org.swift.swiftpm", "Swift package cache", "Downloaded again on the next build", ["Xcode", "xcodebuild", "swift-build", "swift-package", "swift-test", "swift-run"]),
        (".cargo/registry/cache", "Downloaded cargo crates", "Downloaded again on the next build", ["cargo", "rustc"]),
    ]

    /// Where people keep code, by name in any case. Nothing outside these is looked at for old
    /// builds: the folders macOS guards (Desktop, Documents, Downloads) are left alone.
    static let codeNames: Set<String> = ["code", "developer", "dev", "projects", "src", "repos", "git", "github", "workspace", "work"]

    static func codeFolders(home: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: home)) ?? []).sorted()
            .filter { codeNames.contains($0.lowercased()) }.map { home + "/" + $0 }.filter(isPlainDirectory)
    }

    public static func find(home: String, table: ProcTable, settings: Settings, now: Date) -> [CleanupItem] {
        var out: [CleanupItem] = []
        for p in places {
            let path = home + "/" + p.path
            guard isPlainDirectory(path), !settings.isProtected(p.title, path) else { continue }
            let bytes = size(path)
            guard bytes >= minimum else { continue }
            out.append(CleanupItem(title: p.title, detail: p.detail, path: path, bytes: bytes, blockedBy: user(of: path, programs: p.users, table: table)))
        }
        for path in codeFolders(home: home).flatMap({ cargoTargets(under: $0) }) where !settings.isProtected(path) {
            guard let touched = lastTouched(path), now.timeIntervalSince(touched) >= staleDays * 86400 else { continue }
            let bytes = size(path)
            guard bytes >= minimum else { continue }
            let project = ((path as NSString).deletingLastPathComponent as NSString).lastPathComponent
            out.append(CleanupItem(title: "Old build: \(project)", detail: "Untouched for \(Int(now.timeIntervalSince(touched) / 86400)) days",
                                   path: path, bytes: bytes, blockedBy: user(of: path, programs: [], table: table)))
        }
        return out.sorted { $0.bytes > $1.bytes }
    }

    /// Moves one item to the Trash, after checking again that it is still allowed. Never deletes.
    public static func trash(_ item: CleanupItem, home: String = NSHomeDirectory(), table: ProcTable = .live(), settings: Settings,
                             now: Date = Date(), move: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }) -> Bool {
        guard !settings.isProtected(item.title, item.path), isPlainDirectory(item.path) else { return false }
        if let place = places.first(where: { home + "/" + $0.path == item.path }) {
            guard user(of: item.path, programs: place.users, table: table) == nil else { return false }
        } else {
            guard codeFolders(home: home).contains(where: { item.path.hasPrefix($0 + "/") }), isCargoTarget(item.path), user(of: item.path, programs: [], table: table) == nil,
                  let touched = lastTouched(item.path), now.timeIntervalSince(touched) >= staleDays * 86400 else { return false }
        }
        do { try move(URL(fileURLWithPath: item.path)) } catch { return false }
        return true
    }

    /// The name of a running program that uses the folder, or nil.
    static func user(of path: String, programs: [String], table: ProcTable) -> String? {
        for p in table.all {
            let name = (p.program as NSString).lastPathComponent
            if programs.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) { return name }
            if p.command.contains(path) || p.program.hasPrefix(path) { return name }
        }
        return nil
    }

    /// A real folder, not a link to one somewhere else.
    static func isPlainDirectory(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue,
              let real = realpath(path, nil) else { return false }
        defer { free(real) }
        return String(cString: real) == path
    }

    /// Cargo tags its build folders, so a folder that only happens to be called "target" is never taken.
    static func isCargoTarget(_ path: String) -> Bool {
        guard let tag = FileManager.default.contents(atPath: path + "/CACHEDIR.TAG") else { return false }
        let text = String(decoding: tag, as: UTF8.self)
        return text.hasPrefix("Signature: 8a477f597d28d172789f06886806bc55") && text.contains("created by cargo")
    }

    static func cargoTargets(under root: String, depth: Int = 3) -> [String] {
        guard depth > 0 else { return [] }
        var out: [String] = []
        for name in (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? [] where name != "node_modules" && name != ".git" {
            let path = root + "/" + name
            guard isPlainDirectory(path) else { continue }
            if isCargoTarget(path) { out.append(path) } else { out += cargoTargets(under: path, depth: depth - 1) }
        }
        return out
    }

    /// The newest change in the folder and one level under it: cargo touches those on every build.
    static func lastTouched(_ path: String) -> Date? {
        let fm = FileManager.default
        func m(_ p: String) -> Date? { (try? fm.attributesOfItem(atPath: p))?[.modificationDate] as? Date }
        var newest = m(path)
        for a in (try? fm.contentsOfDirectory(atPath: path)) ?? [] {
            let one = path + "/" + a
            for p in [one] + ((try? fm.contentsOfDirectory(atPath: one)) ?? []).map({ one + "/" + $0 }) {
                if let d = m(p), d > (newest ?? .distantPast) { newest = d }
            }
        }
        return newest
    }

    static func size(_ path: String) -> UInt64 {
        let first = Shell.run("/usr/bin/du", ["-skx", path]).split(whereSeparator: \.isWhitespace).first ?? "0"
        return (UInt64(first) ?? 0) * 1024
    }
}
