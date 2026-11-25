# How Optimize decides

The research behind it, with sources, is in [research/optimizer.md](research/optimizer.md). This page is what the code does.
Every constant here is a starting point to tune, not a measured fact.

## 1. Is memory short?

Used memory is the wrong question. macOS fills memory with files on purpose, and keeps gigabytes of swap at rest.
What the kernel acts on is the compressor: with A the memory that is not wired and C what the compressor occupies,
macOS warns when (A − C) / A falls under 0.50, and stops warning over 0.60 (`xnu/doc/vm/memorystatus_notify.md`).
Pulse reads the same counters every two seconds (`host_statistics64`), and the swap-in and swap-out counters as
minute-long moving averages, the way Linux's pressure stall information does.

| State | Enters | Leaves |
|---|---|---|
| calm | | |
| tight | ratio under 0.65 | over 0.70, and no forecast, for two minutes |
| strained | macOS's warning for ten seconds, or pages back from disk at over 0.2% of active memory a minute | warning gone, ratio over 0.62, little swap-in, for two minutes |
| critical | macOS's critical level | down a level for thirty seconds |

The room on each side keeps it from flickering. Nothing is suggested in calm or tight: closing things then frees
memory nobody is waiting for. Tight gets a forecast instead: the Theil-Sen slope of the compressor over two hours,
the median of the slopes between every two points, so one jump is not a trend.

**Target.** When strained: take the compressor back to 38% of A, two points under the kernel's line. When strained only by
swap, ten minutes of swap-in, between half a gigabyte and eight.

## 2. What each row is worth

For a row with footprint F, of which Z is compressed (read from `top` when the plan opens), and the Mac's compression k = C / held:

- **Back to RAM:** ρ · ((F − Z) + k · Z). Mostly compressed means far less back than counted. This is the number shown.
- **Relief:** ρ · (k · Z + ½ (F − Z)). What eases the compressor; used to reach the target.
- ρ starts at 0.8 per kind and moves towards what earlier closes really gave back, from clean cases only (one kind, half a gigabyte or more, steady memory before).

**The chance it is wanted soon.** Pulse keeps, per app, session folder and simulator, the pauses between uses, counted in awake
time (the clock stands still in sleep). Twelve bins from a minute to three days, each with a return rate smoothed towards a prior
for its kind (Gamma-Poisson, worth four pauses), half life two weeks. p = 1 − exp(−Σ rate × overlap) over the next four hours
(one hour when critical). With no history the prior speaks: an app idle an hour comes back within four hours about six times in ten, a session about four.

**Cost** = taste × p × reopening seconds + 2. Reopening: app 28 s, session 20, simulator 35, emulator 40, build daemon 20,
leftover 65 (nothing starts it again). **Taste** is a half to two, from your choices: ticking a row Pulse left, unticking one it ticked,
opening again what it closed. Beta counts, half life a month. It never lifts a guard and never changes the target.

**Guards**, any one keeps a row out of the suggestion: working; in front now or in the last fifteen minutes; plays sound or keeps the
Mac awake; something connected to its port; Pulse could not check; you opened it again within a day. They are checked again when the button is pressed.

## 3. Which rows

Only rows worth it: relief × hours ahead × (4 s per GB-hour strained, 20 critical) must outweigh the cost. Among them, the set of least
total cost that reaches the target, by dynamic programming over 64 MB units: exact, ties to fewer rows, and the same whatever order rows come in.
A leftover process using 10% of the CPU or more is suggested whatever memory does.

Your rules still decide what is ticked when the plan opens. The suggestion is a mark and one press, "Select the suggested".

## 4. Words

Every sentence is made from the same numbers: "Not seen in use for 9 h. Of 11 pauses this long, 1 ended within 4 h. Gives back about
2.8 GB to RAM. 8.9 GB is counted, most of it compressed. Way back: resume it." Counts, not percentages, while there are few.
"How Pulse chose" on the plan shows all of it.

## 5. Afterwards

Asking is not closing: Pulse waits up to thirty seconds until each row has really gone, and says which did not
("Did not quit. It may be asking to save."). Then the median of three readings of memory in use, ten to sixteen seconds later,
against the median of three before. Other programs move memory too, so this is a fact, not a promise kept.

## 6. Proof

- `OptimizerTests`: the states and their hysteresis, the target, the forecast, the habits, taste bounds, the cover, every guard, the words.
- `OptimizerSimulationTests`: six made-up Macs of thirty rows, three weeks each, 342 moments short of memory. Regrets are rows closed
  and wanted within four hours, per gigabyte given back:

  | rule | regrets per GB |
  |---|---|
  | knows the future | 0.016 |
  | **Pulse** | **0.127** |
  | least recently used | 0.215 |
  | biggest first | 0.297 |
  | Pulse before this | 0.344 |
  | random | 0.763 |

  The learned chance is also better calibrated than the prior alone (Brier 0.187 against 0.252).
  This proves the logic when habits are what the model assumes. It does not prove a real Mac gains.
- Each guard and bound was broken once on purpose, and a test failed each time.

## Not done, on purpose

No automatic closing, no force quit, no purge, no neural network, no time-of-day model, and no experimenting on you.
