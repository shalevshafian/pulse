import XCTest
@testable import PulseCore

/// A made-up Mac, run for three weeks of awake time, on which the optimizer is measured against simpler rules.
/// It proves the logic chooses well when habits are what the model assumes. It does not prove real benefit.
final class OptimizerSimulationTests: XCTestCase {
    struct Rng {
        var s: UInt64
        mutating func next() -> Double {
            s &+= 0x9E37_79B9_7F4A_7C15
            var z = s
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return Double((z ^ (z >> 31)) >> 11) / Double(1 << 53)
        }
        mutating func normal() -> Double { (-2 * log(max(next(), 1e-12))).squareRoot() * cos(2 * .pi * next()) }
        mutating func logUniform(_ lo: Double, _ hi: Double) -> Double { exp(log(lo) + next() * (log(hi) - log(lo))) }
    }

    struct Item {
        var id: String, kind: CandidateKind, bytes: UInt64, median: Double
        var next: Double = 0, last: Double = 0
    }

    struct Tally {
        var events = 0, covered = 0, chosen = 0, regrets = 0
        var bytes: UInt64 = 0
        var regretPerGB: Double { Double(regrets) / max(Double(bytes) / 1_073_741_824, 1e-9) }
    }

    func testBeatsSimplerRulesOnASimulatedMac() {
        var totals: [String: Tally] = [:]
        var brier = (model: 0.0, prior: 0.0, n: 0)
        for seed in 1...6 {
            let r = run(seed: UInt64(seed))
            for (k, t) in r.tallies {
                var a = totals[k] ?? Tally()
                a.events += t.events; a.covered += t.covered; a.chosen += t.chosen; a.regrets += t.regrets; a.bytes += t.bytes
                totals[k] = a
            }
            brier.model += r.brier.model; brier.prior += r.brier.prior; brier.n += r.brier.n
        }
        var lines = ["rule          covered  chosen  regrets  regrets/GB"]
        for k in ["oracle", "pulse", "lru", "biggest", "today", "random"] {
            let t = totals[k]!
            lines.append((k.padding(toLength: 12, withPad: " ", startingAt: 0) as NSString).appending(String(format: " %4d/%-4d %6d %8d %10.3f", t.covered, t.events, t.chosen, t.regrets, t.regretPerGB)))
        }
        lines.append(String(format: "Brier: learned %.4f, prior only %.4f, over %d pauses", brier.model / Double(brier.n), brier.prior / Double(brier.n), brier.n))
        print(lines.joined(separator: "\n"))

        let p = totals["pulse"]!, lru = totals["lru"]!, today = totals["today"]!, big = totals["biggest"]!
        XCTAssertGreaterThanOrEqual(Double(p.covered), 0.9 * Double(p.events), "it must still reach the target")
        XCTAssertLessThanOrEqual(p.regretPerGB, 0.7 * lru.regretPerGB, "30% fewer regrets than least recently used")
        XCTAssertLessThan(p.regretPerGB, today.regretPerGB)
        XCTAssertLessThan(p.regretPerGB, big.regretPerGB)
        XCTAssertLessThan(brier.model, brier.prior, "the learned chance is better calibrated than the prior alone")
    }

    func run(seed: UInt64) -> (tallies: [String: Tally], brier: (model: Double, prior: Double, n: Int)) {
        var rng = Rng(s: seed)
        let kinds: [CandidateKind] = [.app, .app, .app, .session, .session, .simulator, .buildDaemon, .emulator]
        var items = (0..<30).map { i -> Item in
            Item(id: "i\(i)", kind: kinds[Int(rng.next() * Double(kinds.count))], bytes: UInt64(rng.logUniform(0.3, 6) * 1_073_741_824),
                 median: rng.logUniform(600, 3 * 86400))
        }
        func gap(_ m: Double) -> Double { max(120, m * exp(0.8 * rng.normal())) }
        for i in items.indices { items[i].last = -rng.next() * items[i].median; items[i].next = gap(items[i].median) * rng.next() }
        let key = { (it: Item) in "\(it.kind.rawValue):\(it.id)" }
        var memory = OptimizerMemory()
        let step = 300.0, train = 14 * 86400.0, end = 21 * 86400.0, horizon = Optimizer.horizon
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        for i in items.indices { memory.returns.track(key(items[i]), idle: -items[i].last, now: now) }
        var tallies: [String: Tally] = [:]
        var brier = (model: 0.0, prior: 0.0, n: 0)
        var t = 0.0, nextEvent = train
        let vm = VMReading(active: 8 << 30, inactive: 2 << 30, free: 1 << 30, compressor: 12 << 30, stored: 36 << 30, total: 32 << 30)
        while t < end {
            t += step
            memory.returns.clock = t
            for i in items.indices where items[i].next <= t {
                memory.returns.used(key(items[i]), now: now)
                items[i].last = t
                items[i].next = t + gap(items[i].median)
            }
            guard t >= nextEvent else { continue }
            nextEvent += 3 * 3600
            let target = UInt64(rng.logUniform(2, 8) * 1_073_741_824)
            let idle = items.filter { t - $0.last >= 60 }
            let wanted = { (it: Item) in it.next - t < horizon }
            let cands = idle.map { Candidate(id: $0.id, key: key($0), kind: $0.kind, title: $0.id, footprint: $0.bytes, compressed: 0, idleHint: nil) }
            let v = Optimizer.decide(.init(candidates: cands, vm: vm, state: .critical, memory: memory, now: now, target: target))
            let relief = Dictionary(v.scores.map { ($0.id, $0.relief) }, uniquingKeysWith: { a, _ in a })
            for s in v.scores {
                let it = idle.first { $0.id == s.id }!
                let truth = wanted(it) ? 1.0 : 0.0
                let prior = Returns().comeBack(key(it), kind: it.kind, idle: t - it.last, horizon: horizon).p
                brier.model += (s.comeBack - truth) * (s.comeBack - truth); brier.prior += (prior - truth) * (prior - truth); brier.n += 1
            }
            func take(_ order: [Item]) -> [Item] {
                var sum: UInt64 = 0, out: [Item] = []
                for it in order where sum < target { out.append(it); sum += relief[it.id] ?? 0 }
                return out
            }
            let rules: [String: [Item]] = [
                "pulse": idle.filter { v.suggested.contains($0.id) },
                "oracle": take(idle.sorted { $0.next > $1.next }),
                "lru": take(idle.sorted { $0.last < $1.last }),
                "biggest": take(idle.sorted { $0.bytes > $1.bytes }),
                // Today's order: sessions, then runtimes, then apps, each idle an hour or more, the largest first.
                "today": take(idle.filter { t - $0.last >= 3600 }.sorted {
                    let a = $0.kind == .session ? 0 : $0.kind == .app ? 2 : 1, b = $1.kind == .session ? 0 : $1.kind == .app ? 2 : 1
                    return a != b ? a < b : $0.bytes > $1.bytes
                }),
                "random": take(idle.sorted { _, _ in rng.next() < 0.5 }),
            ]
            for (name, chosen) in rules {
                var tally = tallies[name] ?? Tally()
                tally.events += 1
                let got = chosen.reduce(0) { $0 + (relief[$1.id] ?? 0) }
                if got >= target { tally.covered += 1 }
                tally.chosen += chosen.count
                tally.regrets += chosen.filter(wanted).count
                tally.bytes += got
                tallies[name] = tally
            }
        }
        return (tallies, brier)
    }
}
