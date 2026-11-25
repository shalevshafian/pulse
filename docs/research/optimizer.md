# Smart optimizer for Pulse: research report

**Labels.** [S] = source read. [M] = measured on this Mac (64 GB, Darwin 25.4, level 1). [C] = constant I chose, to be tuned offline. UNCONFIRMED = not verified.

**NOT VERIFIED:** nothing here was run under real pressure or on macOS 14. The algorithm is a design with no prototype. xnu source is `main`.

## 1. Key facts

**What the pressure level means.**
- A_nc = active + inactive + free + speculative. A = A_nc + C, where C is the compressor's resident pages. Let r = A_nc/A.
- Warning when r < 0.50, back to normal at r > 0.60. [S: [memorystatus_notify.md](https://github.com/apple-oss-distributions/xnu/blob/main/doc/vm/memorystatus_notify.md)]
- Critical at about r < 0.343, or when the compressor is low on space. Back to warning at r > 0.40. [S: [vm_pageout.c](https://github.com/apple-oss-distributions/xnu/blob/main/osfmk/vm/vm_pageout.c), [divisors](https://github.com/apple-oss-distributions/xnu/blob/main/osfmk/vm/vm_compressor.c)]
- So warning means the compressor holds more than half of non-wired memory.
- `kern.memorystatus_vm_pressure_level` returns 1/2/4.
- `host_statistics64`'s `free_count` already includes speculative pages; do not add them twice. [S: SDK `vm_statistics.h`]

**`kern.memorystatus_level` is not "free".** On macOS it is A_nc/RAM. [S: [vm_page.h](https://github.com/apple-oss-distributions/xnu/blob/main/osfmk/vm/vm_page.h)]

**Closing a resident app does not move the level.** I allocated and released 4 GB twice. [M]
- A_nc, r and the level (88) did not move.
- `memUsedBytes` fell by about 4.1 GB each time.
- The first run also evicted about 2.5 GB of file cache, which did not come back by itself.
- Therefore only releasing *compressed* pages relieves the level directly, and "before/after" must use `memUsedBytes`.

**Footprint is not RAM returned.**
- `phys_footprint` includes compressed memory at uncompressed size. [S: [task.c](https://github.com/apple-oss-distributions/xnu/blob/main/osfmk/kern/task.c)]
- one large local process: footprint 8.9 GB, resident 8.2 GB, CMPRS 7.98 GB. [M] So `footprint − resident` is no proxy for compressed size.
- With this Mac's C/U (2.86/12.0 GB), closing it would return about 2.8 GB, not 8.9 GB (estimate).
- `top -l 1 -stats pid,cmprs` gives CMPRS without root in 0.39 s. [M] `top` is setuid root, so run it only when building a plan.

**Swap used is not a problem; swap rate is.** This Mac holds 3.1 GB of swap at level 1, r = 0.95. [M] The current "Large swap >= 4 GB" advice will fire falsely. Use deltas of `swapins`, `swapouts`, `decompressions`.

**Does closing help without pressure? For memory, essentially no.**
- Green means RAM is used efficiently. [S: [Apple](https://support.apple.com/guide/activity-monitor/check-if-your-mac-needs-more-ram-actmntr34865/mac)]
- Android: "free memory is wasted memory". [S: [Android](https://developer.android.com/topic/performance/memory-management)]
- Exceptions: CPU, heat, energy, a leak, more file cache, or headroom before a known large job.

**macOS kills little itself.** On rising pressure it kills clean opted-in idle daemons, one per second. Out of paging space, it may kill a process holding over half the compressed pages, then shows the Force Quit dialog. [S: [memorystatus_kills.md](https://github.com/apple-oss-distributions/xnu/blob/main/doc/vm/memorystatus_kills.md)] App Nap throttles, and Apple says it does not necessarily save energy. [S: [Apple](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/power_efficiency_guidelines_osx/AppNap.html)]

**Use signals.**
- `NSWorkspace` did-activate/deactivate notifications and `frontmostApplication`, public since 10.6/10.7. [S: SDK]
- `kMDItemLastUsedDate` updates on Launch Services opens [S: SDK]. It says nothing about a long-running app; use it as a cold-start hint only.
- `proc_pid_rusage`: over about 20 s one large local process had about 169 interrupt wakeups/s but only about 0.2 mW from `ri_energy_nj`; `ri_billed_energy` did not move. [M] Wakeups are not energy. V6 behaviour on macOS 14: UNCONFIRMED.
- Audio: CoreAudio process objects (`kAudioProcessPropertyIsRunningOutput`/`Input`); macOS 14.0 availability UNCONFIRMED. `Awake.swift` already reads audio assertions.

**Prior art worth copying.**
- PSI measures stall time over 10/60/300 s, not usage. [S: [kernel](https://docs.kernel.org/accounting/psi.html)] I found no macOS equivalent, so rates are only a proxy.
- lmkd: partial stall 70 ms, swap-low 20%, thrashing limit that decays 10% if a kill did not help. [S: [AOSP](https://source.android.com/docs/core/perf/lmkd)]
- Google far memory: slow-tier promotions <= 0.2% of working set per minute; 120 s = cold. [S: [paper](https://www.cs.purdue.edu/homes/csjgwang/CloudNativeDB/WSCMemoryASPLOS19.pdf)]
- Senpai: step proportional to 1 − PSI/0.1%, so zero once over target. [S: [TMO](https://www.pdl.cmu.edu/PDL-FTP/NVM/tmo_asplos22.pdf)]
- Chrome: 6/4/2 h timers plus revisit caps 5/15/15. [S: [code](https://chromium.googlesource.com/chromium/src/+/refs/heads/main/chrome/browser/performance_manager/policies/memory_saver_mode_policy.cc)] Vetoes: audible, capturing, USB, form edits, recently visible. [S: [code](https://chromium.googlesource.com/chromium/src/+/refs/heads/main/chrome/browser/performance_manager/policies/discard_eligibility_policy.cc)]
- Edge: 15 min default. [S: [Microsoft](https://learn.microsoft.com/en-us/deployedge/microsoft-edge-browser-policies/sleepingtabstimeout)]
- App Standby Buckets: predicted use, else recency; device-off time is not counted towards inactivity. [S: [Android](https://developer.android.com/topic/performance/appstandby)]
- GDSF: Clock + Freq×Cost/Size. [S: [HP](https://eclass-b.uoa.gr/modules/document/file.php/D245/2015/HPL-98-69R1_GDS.pdf)]
- Ski rental break-even: under 2-competitive; randomized e/(e−1). [S, secondary: [Wikipedia](https://en.wikipedia.org/wiki/Ski_rental_problem)]
- TabRanker/Chrome ML, iOS jetsam bands, SysMain: UNCONFIRMED, not used.

## 2. Algorithm

### (a) Pressure state and target

Every 2 s tick, EWMAs of 10/60/300 s (PSI's windows) over swap-in, swap-out, decompression and C. W = active bytes.

| State | Enter | Leave |
|---|---|---|
| calm | default | |
| tight | r < 0.65, or forecast to r = 0.5 < 30 min [C] | r > 0.70 for 120 s |
| strained | level >= 2 for 10 s, or swap-in60 > 0.2% W/min and swap-out60 > 0 | level 1, r > 0.62, swap-in60 < 0.05% W/min, for 120 s |
| critical | level 4 | level <= 2 for 30 s |

The 0.2% is Google's datacentre number borrowed [S], its use here [C]. High decompression alone only supports "tight".

Target in compressor-relief bytes: **T = max(0, C − 0.38·A)** when strained or critical. The kernel needs C < 0.40·A; 2% is margin [C]. If strained only by swap-ins: T = 10 min of swap-in60, clamped to 0.5–8 GB [C]. **Calm: T = 0. Tight: T = 0, forecast shown.**

### (b) Candidate value

k = C/U, where U = `total_uncompressed_pages_in_compressor`. That U includes swapped pages is UNCONFIRMED. Z = CMPRS of the process tree, F = footprint.

- **RAM returned:** f = ρ·((F − Z) + k·Z). This is what the UI promises. Swap returned is a separate line, only once measured.
- **Level relief:** u = ρ·(k·Z + β·(F − Z)), β = 0.5 [C]. Resident pages help only indirectly, so β is the weakest assumption.
- Without CMPRS: promise "up to", use Z = 0, lower confidence.

**Return probability (smoothed discrete hazard).**
- Gaps between uses, 12 log bins from 1 min to 72 h, counted in *awake* time.
- h_b = (d_b + 4·h0_b)/(n_b + 4). d = returns, n = still at risk; open gaps are right-censored ([Kaplan-Meier, NIST](https://www.itl.nist.gov/div898/handbook/apr/section2/apr215.htm)). Half-life 14 days [C].
- **p = 1 − Π(1 − h_b)** from the current idle time to idle + H, partial bins as a power. H = 4 h, or 1 h when critical [C].
- A "use" is: app activated; session idle to busy; daemon or simulator CPU >= 25% of a core, or its window app in front.
- Do not take use from `LoadHistory`: it keeps the top 8 names per bucket, so absence is not idleness.
- Cold prior p(4 h) at idle 1/4/12/24 h [C]: apps .60/.35/.15/.10; sessions .45/.25/.10/.05; runtimes .30/.15/.08/.05.

**Cost in seconds:** K = M·p·(reopen + loss) + 2. Defaults reopen+loss [C]: app 8+20, session 15+5, simulator 25+10, emulator 30+10, Gradle/Kotlin 10+10, leftover 5+60 (no way back). Simulator and emulator restore should be measured first.

**CPU/energy is a separate lane.** An item holding >= 10% of the machine for 10 min while idle qualifies in any state. Never convert watts into gigabytes.

**Vetoes, rechecked at click:**

| Veto | Signal |
|---|---|
| Working, waiting, busy child/build | session status, tree CPU >= 25% |
| In front now, or < 15 min ago [C] | NSWorkspace |
| Hosts sessions | `sessionHosts` |
| Audio or microphone | CoreAudio, `Awake` |
| Keeps the Mac awake | `Awake` holder |
| Connected client on its port | `lsof` ESTABLISHED (Pulse reads only LISTEN today) |
| `neverTouch`, untouchable | existing |
| Evidence unreadable | veto, "could not check" |

**Unsaved work and "being recorded": I found no permission-free signal.** Ask politely, observe `isTerminated` ("terminate" only confirms the request was sent [S: SDK]), report "did not quit". Never force.

### (c) Learning

Per kind and per key, Beta(2,2) decayed over 30 days. Evidence: user ticks an unticked row +1 close; unticks a ticked row +1 keep; "Open again" (`Receipt.undone`) +2 keep; accepted unchanged +0.25 close. Unviewed or ignored rows teach nothing. θ = close share; **M = clamp((1−θ)/θ, 0.5, 2)**. It cannot lift a veto or alter T. A relaunch within H goes to the hazard only, to avoid double counting. No exploration: never experiment on the user.

State: about 40 keys × 24 Float32, under 8 KB plus names.

### (d) Selection

Minimum-cost cover: **minimize ΣK subject to Σu >= T**. Exact DP over 64 MB bins, u rounded down, T <= 16 GB: 40 × 256 steps, expected well under 1 ms (UNCONFIRMED until benchmarked). Ties: fewer items, larger Σf, then id. Infeasible: best subset, "covers X of Y".

Worth-it check: skip an item unless λ·u·H > K, λ in seconds per GB-hour: calm 0, strained 4, critical 20 [C]. With fewer than 5 gaps, use ski-rental break-even: offer only after idle >= (reopen + loss)/(λ·u) hours.

Keep `Settings.preselects`: the score ranks and recommends, but runtimes and apps stay unticked unless the owner changes that ruling.

### (e) Leak and forecast

- 5-minute medians, 24 points, Theil–Sen slope ([29.3% breakdown](https://scikit-learn.org/stable/auto_examples/linear_model/plot_theilsen.html)): 276 pairs per row.
- Leak if: 30+ min, slope >= 0.5 GB/h, gain >= max(1 GB, 6·MAD), >= 80% of pairs rising, no drop > 10% [C].
- Forecast on C: t = (0.5·A − C)/slope. Range from the 25th–75th percentile of pair slopes. Show only if the slow end is < 2 h; else "no forecast".
- Reset after sleep or a sampling gap, as `Growth` does.
- Spikes: modified z = 0.6745·(x − median)/MAD > 3.5 ([NIST](https://itl.nist.gov/div898/handbook/eda/section3/eda35h.htm)). Sustained CPU: CUSUM, k = half the shift, h = 5 ([NIST: 4–5](https://www.itl.nist.gov/div898/handbook/pmc/section3/pmc323.htm)).

### (f) When

- **Now:** strained or critical with a non-empty set, or thermal serious with a CPU-lane item.
- **Later:** tight, or a leak: "At this rate, 40–70 min."
- **Nothing:** "Nothing to do. 31 GB is in use, and macOS is not short of memory. Closing things now would not make it faster." Candidates stay under "Optional".
- **No good option:** "Memory is short, but everything large is in use."

### (g) Confidence and reasons

conf = n/(n+4) × (CMPRS read ? 1 : 0.7) × 0.8 per missing optional signal. High >= 0.7, medium >= 0.4. Store the terms as a struct; text is a pure function of it:

> "Not used for 9 h. After gaps like this you came back within 4 h 1 time in 11. Closing returns about 2.8 GB (8.9 GB counted, mostly compressed). Way back: resume command. Lost: its running shells."

Show counts, not percentages, when n < 10. With no history say "typical, not yet yours".

### (h) Measure and calibrate

Median of 3 `memUsedBytes` before. Wait until targets exit (30 s cap), then median of 3 at +10–16 s. Also record ΔC, Δswap, the level and 60 s prior noise. "Promised 2.8 GB, memory in use fell 2.4 ± 0.3. Pressure: still high."

ρ_kind starts at 0.8: ρ += 0.2·(clamp(actual/promised, 0.2, 1.2) − ρ), only for single-kind batches >= 512 MB with noise < 25% [C]. If the state has not improved after 5 min, say so; do not offer more automatically.

**Current defects:** `Model.run` reads after 2.5 s, too early; a quit request is stored as ok with full footprint bytes even if the app refuses.

## 3. Offline evaluation

1. **Simulator:** seeded candidates (log-normal gaps, day/night, sleeps, leaks, refusals) with the kernel's r rules and compression ratio 1.5–4. Scenarios: 8/16/64 GB, calm with huge "used", old swap at level 1, build burst, 20 idle sessions, slow leak, oscillation near r = 0.5, one irreplaceable large app.
2. **Replay:** a local log of uses. Returns are observable for *unclosed* items, so p can be scored without closing anything.

Baselines: today's rules, LRU, biggest-first, random, GDSF, oracle (knows returns).

Metrics:
- regret = closed, then used within 4 h (also 1/24 h);
- GB *actually* returned per regret; seconds lost; target met;
- calm false-alarm rate (must be 0 on scripted calm traces); state flips per hour;
- Brier score and reliability of p; tick agreement; promise error.

Gates [C]: 30% fewer regrets than LRU at equal f; Brier below prior-only; median promise error < 25%.

Property tests: more idle never raises p when the hazard is non-increasing; a veto always wins; T = 0 gives the empty set; input order is irrelevant; M never exceeds 2×. Mutation-test each veto. Simulator results prove the logic, not real benefit; β, λ and ρ need logged real pressure.

## 4. Pitfalls, and what to leave out

- Scoring by footprint or `memorystatus_level`; calling swap size a fault.
- Summing shared helpers twice across candidates; closing a parent must remove its children from the set.
- Return time broken by sleep, clock changes or Pulse not running: treat as censored.
- Feedback loops: only user-touched rows teach.
- Re-recommending something just reopened: 24 h cooldown [C].
- Claims like "faster" or "saves battery": never made; report only measured bytes, CPU and level.

**Leave out:** neural or LLM scoring, contextual bandits, time-of-day models, per-page cold histograms, force kill, purge, automatic closing.

**Order of value:** 1) correct pressure/target, "nothing to do", drop the swap rule; 2) honest bytes and post-measurement; 3) activation log + hazard; 4) DP; 5) Beta learning. Steps 1–2 fix today's wrong claims; 3–5 need weeks of data.
