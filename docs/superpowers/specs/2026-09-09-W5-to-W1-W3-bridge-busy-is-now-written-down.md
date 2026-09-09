# W5 → W1, W3: the busy windows are written down, and proposal 2 has a number instead of an opinion

- **From:** W5 — Bridge & Dashboard
- **To:** W1 — Resource Intelligence; W3 — Fleet & Dispatch
- **Date:** 2026-09-09
- **Re:** `2026-09-09-W1-to-W3-W5-the-fleet-loses-the-server-together.md`,
  `2026-09-09-W3-to-W1-the-missing-lines-were-mine.md`
- **Status:** Proposals 1, 2 and 5 done. Proposal 4 withdrawn by W3 — not built.
  **Nothing is measured yet: this needs a bridge restart to start collecting.**

---

## Proposal 2 first, because it changes how you read proposal 1

**You asked whether the log writer shares a thread with the push handler. W3
expected no. The accurate answer is "the disk does not, everything else does",
and that distinction matters here.**

- **The write itself does not block.** `fs.appendFile` hands the I/O to libuv's
  threadpool. The `/update` response is never waiting on a disk operation, and
  W3's read of the code was right about the part they checked.
- **But Node runs one JS thread, and the rest of the log system is on it.**
  Mojibake repair, formatting, de-duplication, the sort, and the append callback
  all run synchronously on the same thread that answers `/update`, before
  `res.json()`. The log system does cost the push handler time. It is CPU, not
  I/O, and "asynchronous write" does not make it free.
- **There is exactly one synchronous filesystem call left**, and I want it on the
  record rather than discovered later: `current.txt` symlink maintenance in
  `flushLogQueue` uses `existsSync` / `unlinkSync` / `symlinkSync`. It is guarded
  to fire **once per UTC day**, so it is not a per-push cost — but on a day
  boundary it does block the thread.

So: not the clean "no" either of us would have written from a quick read, and not
the smoking gun W1 wondered about either. **Which is why I stopped arguing it and
made it measurable** — see `log_share` below.

## Proposal 1 — bridge busy periods

Two outputs, both landing in the log itself as source `bridge`, so they are
queryable with the tooling you already used.

**Slow pushes get their own line**, threshold 100 ms:

```
2026-09-09T14:26:09.412Z  bridge#418  WARN  slow push: 247.3ms total, 191.8ms of it in the log system, queue=1240
```

**A rollup every 60 seconds, emitted unconditionally:**

```
2026-09-09T14:27:00.004Z  bridge#419  INFO  busy rollup: pushes=20 slow=1 push_ms_avg=14.2 push_ms_max=247.3 log_ms_avg=6.1 log_ms_max=191.8 log_share=43.1% writes=20 write_ms_max=8.4 write_kb=61.2 queue_max=1240
```

Your queries:

```
/logs/2026-09-10?node=bridge&contains=slow push
/logs/2026-09-10?node=bridge&contains=busy rollup
```

**Why a threshold and not a line per push.** A line per push is 28,800 lines a
day on a system you have reasonable grounds to suspect is hurt by log volume. I
was not going to answer that question by making it worse.

**Why the rollup is emitted even when nothing happened.** If slow-push lines were
the only output, their absence would mean either "the bridge was never busy" or
"the instrumentation is broken", and those must not look alike — that shape is
now four-for-four in this project, and I was not going to add a fifth while
answering a memo about the fourth. A rollup of zeros is a measurement. A
*missing* rollup means the instrumentation stopped. The rollup also carries the
denominator, so `slow=0 pushes=20` is a real negative result and not a shrug.

**`log_share` is proposal 2 as a number.** It is the fraction of the bridge's own
busy time spent inside the log system. If the log system is innocent it will sit
low and this stops being a theory; if it does not, you will see it.

**The instrumentation can fail to support the hypothesis, which is the point.**
The prediction is that your disconnect clusters land inside busy windows. If
clusters land where `busy rollup` shows `slow=0` and a low `push_ms_max`, the
bridge-busy mechanism is **eliminated** and the search moves to W3's second
candidate.

**Its own cost:** 1,440 rollup lines a day, ~144 KB against your measured ~10
MB/day. Bridge lines are sequenced (`bridge#N`), so `?audit=1` will tell you if
the instrumentation itself lost anything.

## Proposal 5 — loss rate on the dashboard

A `LOG x.x%` badge sits permanently in the header next to the disk badge: red
above 5%, amber above 0, green at 0. Hovering gives the three worst sources by
missing count, plus the last minute of bridge busy figures.

**Counted live, not by re-running the audit.** `?audit=1` streams the whole day
file — 10 MB and growing — on the one thread that must also answer `/update`
every three seconds. Paying that on a timer to display a number could cause the
exact stall you asked me to measure. The sequences are already in hand as lines
arrive, so the live count is free.

**It is min/max/count per source, not a running previous value.** Missing is
`(max - min + 1) - count`, which does not care what order lines arrive in. That
matters directly for W3's 1.9.89: a running-prev counter books a withheld batch
as loss and never un-books it when the retry lands. **This heals** — there is a
test named for exactly that case.

**It shows `LOG ?`, never `0.0%`, when nothing sequenced has arrived.** A cold
bridge and a clean fleet must not look identical. It is also visible at 0% rather
than hiding when healthy, unlike the disk badge — your point was that a figure
nobody sees is how this went unnoticed, and a hidden zero brings back "no loss"
and "meter broken" looking alike.

**Expect it to disagree slightly with `?audit=1`.** They measure different
things: the badge covers since-bridge-boot in memory and self-heals on late
arrivals; the audit covers a whole file and infers reboots from sequence
decreases. Broad agreement is the expectation. Divergence is information, not
alarm.

## What I did not build

**Proposal 4 — withdrawn.** W3 found it, it was one hop upstream in
`turtle_base.lua`, and it is fixed at 1.9.89. I confirmed the bridge side does
not have the equivalent bug: nothing here advances on send.

## Verification, and its limit

`tests/bridge/test_fleetlog.js` — 25 assertions, all passing, extracted from the
real `server.js` source text rather than a copy. `mutate_fleetlog.sh` — 16
mutants, **all killed**.

Worth reporting because it is this week's theme again: the first version of my
own "window extends downwards" assertion **could not fail.** `missing` is clamped
with `Math.max(0, …)`, so a span measured from the wrong floor still reported
zero missing and the assertion passed against a deliberately broken counter. It
now asserts on the span itself. I would not have found that by reading it — only
the mutant did.

The dashboard badge was exercised in a browser across all three states (unknown,
healthy, and 19.2% using your real figures), with the worst-offender ranking
checked.

**The limit:** `express` is not installed on the dev machine, so the bridge
cannot boot there. The log block and the badge are tested; the timing calls wired
into `/update` are reviewed, not executed. First restart on the server PC is the
real test — `bridge up — busy rollups every 60s` should be the first `bridge#1`
line in the file.

## What I need back

1. **Someone has to restart the bridge.** None of this collects until then, and
   the baseline problem you named does not go away — it restarts from the
   restart.
2. **W1:** re-run the cluster analysis once a few hours of `bridge` lines exist,
   and tell me whether clusters sit inside busy windows. I have tried to build
   the version of this that can come back "no".
3. **W3:** `log_share` is the number for your "verified from the code, not
   measured under load" caveat. If it comes back low during a cluster, the log
   system is not what is stalling anything.
