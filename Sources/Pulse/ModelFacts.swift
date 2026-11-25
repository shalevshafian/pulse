import AppKit
import Foundation
import PulseCore

/// What the pages ask of the model beyond the readings themselves.
extension Model {
    /// The list on the first page, and the marks on the tabs.
    var needs: [Need] {
        Needs.build(snap: snap, health: health, plan: settings.planUsage ? plan : [], verdict: verdict,
                    drivesOut: (drives ?? []).filter { d in d.attached && !d.mounted && drivesOut.contains { $0.id == d.id } }.map(\.name),
                    hidden: settings.hidden, settings: settings, now: Date())
    }

    func hide(_ n: Need) {
        let now = Date()
        settings.hidden = settings.hidden.filter { now.timeIntervalSince($0.value) < Needs.rest }
        settings.hidden[n.id] = now
    }

    /// What the rules tick comes first, then the biggest: 10 GB of simulator is not left under the fold.
    var actionable: [Suggestion] {
        (snap?.suggestions ?? []).filter { $0.kind != .advice }.sorted {
            let a = settings.preselects($0), b = settings.preselects($1)
            return a != b ? a : $0.reclaimBytes > $1.reclaimBytes
        }
    }
    var defaults: [Suggestion] { (snap?.suggestions ?? []).filter { settings.preselects($0) } }

    var checkedAgo: String {
        let age = healthAge(now: Date())
        return age == .infinity ? "Not checked yet" : age < 90 ? "Checked just now" : "Checked \(Fmt.duration(age)) ago"
    }

    func session(of c: Consumer) -> ClaudeSession? {
        c.kind == .session ? snap?.sessions.first { $0.pid == c.members.first?.pid } : nil
    }

    func row(ofPid pid: Int32) -> Consumer? {
        snap?.consumers.first { c in c.members.contains { $0.pid == pid } || c.times.contains { $0.pid == pid } }
    }

    /// What closing would interrupt, in a word or two.
    func warning(closing c: Consumer) -> String? {
        if let s = session(of: c) { return s.isWaiting ? "Waits" : s.isIdle && !s.stillWorking ? nil : "Working" }
        if hostsSessions(c) { return "Runs sessions" }
        return snap?.runtimes.first { $0.id == c.runtimeID }?.working == true ? "Working" : nil
    }

    func about(_ c: Consumer) -> String? {
        switch c.kind {
        case .session:
            guard let s = session(of: c) else { return nil }
            return "A Claude Code session in \(s.project). " + (s.waitingText ?? (s.isIdle ? "Idle for \(Fmt.duration(s.idleSeconds(now: Date())))" + (s.stillWorking ? ", but something in it works." : ".") : "Working."))
        case .runtime: return snap?.runtimes.first { $0.id == c.runtimeID }.map { r in
            switch r.kind {
            case .simulator: return "An iOS simulator. Shutting it down keeps its data."
            case .emulator: return "An Android emulator."
            case .buildDaemon: return "Waits for the next build and makes it start faster. It comes back by itself."
            }
        }
        case .app: return WhatIs.sentence(c.name) ?? (c.processCount > 1 ? "An app, with \(c.processCount - 1) helper \(c.processCount == 2 ? "process" : "processes")." : "An app.")
        case .process: return WhatIs.sentence(c.name)
        }
    }

    func facts(_ c: Consumer) -> [(name: String, value: String)] {
        let now = Date()
        var out: [(String, String)] = [
            ("CPU now", String(format: "%.1f%% of this Mac", c.cpuPercent)),
            ("Memory", Fmt.bytes(c.rssBytes) + (system.memTotalBytes > 0 ? String(format: ", %.0f%% of it all", Double(c.rssBytes) / Double(system.memTotalBytes) * 100) : "")),
        ]
        if let p = past.first(where: { $0.kind == c.kind && $0.name == c.name }) {
            out.append(("Last 12 hours", Past.cpu(p.cpuSeconds) + (p.peakBytes > 0 ? ", up to \(Fmt.bytes(p.peakBytes))" : "")))
        }
        if c.processCount > 1 { out.append(("Processes", "\(c.processCount)")) } else if let p = c.members.first?.pid { out.append(("PID", "\(p)")) }
        if let first = c.members.compactMap({ StartTime.date($0.lstart) }).min() { out.append(("Started", Fmt.duration(now.timeIntervalSince(first)) + " ago")) }
        if let h = snap?.awake?.first(where: { $0.kind == c.kind && $0.name == c.name }) {
            out.append(("Keeps the Mac awake", h.since.map { Fmt.duration(now.timeIntervalSince($0)) } ?? "yes"))
        }
        let mine = Set(c.members.map(\.pid)).union(c.times.map(\.pid))
        let open = (ports ?? []).filter { mine.contains($0.pid) }
        if !open.isEmpty {
            out.append(("Listens on", Set(open.map(\.port)).sorted().prefix(4).map(String.init).joined(separator: ", ") + (open.contains(where: \.network) ? ", network" : ", this Mac only")))
        }
        if let s = session(of: c) { out.append(("Folder", (s.cwd as NSString).abbreviatingWithTildeInPath)) }
        if let r = snap?.runtimes.first(where: { $0.id == c.runtimeID }) { out.append(("Up for", Fmt.duration(r.upSeconds))) }
        if let path = c.program ?? c.bundlePath { out.append(("Where", (path as NSString).abbreviatingWithTildeInPath)) }
        return out.map { (name: $0.0, value: $0.1) }
    }

    /// The whole name becomes a word of the rules. A broader word the user wrote stays theirs to remove.
    func protect(_ name: String, _ on: Bool) {
        if on {
            if !settings.isProtected(name) { settings.neverTouch.append(name) }
            return
        }
        settings.neverTouch.removeAll { $0.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(name) == .orderedSame }
        if let word = settings.neverTouch.first(where: { w in name.lowercased().contains(w.trimmingCharacters(in: .whitespaces).lowercased()) && !w.isEmpty }) {
            notice = "Protected by the word \u{201C}\(word)\u{201D} in Rules"
        }
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// The way back from something Pulse did, on the user's press.
    func undo(_ r: Receipt) {
        switch r.back {
        case .app(let path):
            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: NSWorkspace.OpenConfiguration()) { app, _ in
                DispatchQueue.main.async {
                    if app != nil { self.changeReceipts { $0.markUndone(r.id) }; self.learnOpenedAgain(r) } else { self.notice = "Could not open it" }
                }
            }
        case .session(let cwd, let id):
            guard let command = Receipts.resume(cwd: cwd, id: id) else { notice = "No session to resume"; return }
            Self.copy(command)
            learnOpenedAgain(r)
            notice = "Copied. Paste it in a terminal to go on."
        case .trash(let from, let to):
            if Receipts.putBack(from: from, to: to) {
                changeReceipts { $0.markUndone(r.id) }
                notice = "Put back"
            } else {
                notice = "Not put back: no longer in the Trash, or something is in its place"
            }
        case nil: break
        }
    }
}
