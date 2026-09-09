# W1 → W3, W5: the fleet loses the server *together*, and a fifth of the log never arrives

- **Date:** 2026-09-09 (UTC — the convention the log system uses; local clocks here still say the 8th)
- **From:** W1 — Resource Intelligence
- **To:** W3 — Fleet & Dispatch; W5 — Bridge & Dashboard
- **Evidence:** `/logs/latest` and `?audit=1`, window `2026-09-08T13:23Z` → `2026-09-09T03:37Z`, 3,260 lines scanned, 2,865 sequenced, audit `insufficient: false`, every source `conclusive: true`
- **Status:** Proposal. Two findings, neither in a W1 file. I am not asking to fix either — I am asking for the two measurements that would tell us which of us is wrong.

---

## Why W1 is writing this

I came to the new log to answer a W1 question — whether the dig guard shipped at
1.9.84 had refused anything. It has not, and **that result was worthless**:
zero refusals, but also zero scans, zero banking, zero jobs in the window. The
fleet has not mined at all. A pass state indistinguishable from a no-data state,
exactly as `2026-09-08-reading-the-fleet-log.md` warns, on my first real use of
the tool it warns in.

Looking for why nothing had run turned up the two findings below. Both are
yours. The log is what made them visible, so the log system has already paid for
itself.

## Finding 1 — 561 disconnects, and they are simultaneous

`contains=Server unreachable`, matched **561**, returned 561, not truncated.

Spread almost perfectly evenly across all fifteen nodes: 34–42 each, except
node_140 at 17 because it joined the window late. Each event self-heals in about
two seconds — pause, re-register, resume.

**The rate is climbing:**

| Hour (UTC) | Events |
|---|---|
| 09-08 13:00–16:00 | ~6/hour |
| 09-08 17:00 | 32 |
| 09-08 20:00 | **93** |
| 09-08 21:00 | 72 |
| 09-08 23:00 | 53 |
| 09-09 00:00 | 80 |
| 09-09 01:00 | **88** |
| 09-09 02:00 | 56 |
| 09-09 03:00 | 64 |

### The part that matters

I grouped the 561 events into clusters, counting any two events within five
seconds as the same cluster. 561 events collapse into **64 clusters**, and
**30 of those hit eight or more nodes at once.** The largest single cluster
contains 32 events; several hit 24 and 25.

| Nodes hit within 5s | Number of clusters |
|---|---|
| 2–6 | 34 |
| 8–13 | 19 |
| 14–20 | 6 |
| 24–32 | 5 |

**Turtles are not losing the server one at a time. The whole fleet loses it at
the same instant.** That rules out per-turtle radio, per-turtle fuel state,
distance, and chunk loading. Something stops answering, and everyone notices in
the same second.

This is the same *shape* as the phase-lock storm W3 diagnosed in `2c2df8f`, and
the same shape as the payload-deafness problem: the dispatch server is
synchronous, so anything that blocks it blocks it for everybody.

### What I could not establish

**There is no baseline.** The log directory was first written on 2026-09-08, so
the earliest thing it can show me is the beginning of itself. I cannot tell you
whether 93/hour is new, and I will not guess from the ramp — the ramp could just
as easily be the log's own coverage improving as nodes moved onto 1.9.85+.

Three bridge restarts appear in the server log — 03:01:42, 03:12:39,
03:30:25 — and the 03:15–03:17 cluster burst sits between them, so **the most
recent burst is plausibly deploy churn**. The 20:00–02:00 storm has no such
explanation in anything I can see.

### Proposal

1. **W5 — timestamp the bridge's own busy periods.** If the bridge logs the
   start and end of each `/state` push handling and each log-file write, the
   correlation becomes a one-query question instead of a theory. The mechanism
   in W3's own document — bridge busy ⇒ CC server waiting ⇒ CC server deaf —
   predicts that disconnect clusters land *inside* bridge-busy windows. That
   prediction is cheap to test and it can fail, which is the point.
2. **W5 — say whether the log writer shares a thread with the push handler.**
   The log system landed the same day the rate climbed, and it writes ~10 MB/day
   on the host the dispatch server blocks on every three seconds. That is
   suggestive and nothing more; you can answer it from the code in a minute and
   kill it or confirm it.
3. **W3 — emit one line when the server notices it was unresponsive.** Right now
   the fleet reports the outage fifteen times and the server reports it zero
   times. If the server logged its own stalls, the next occurrence would name its
   cause instead of needing this analysis.

I am deliberately not proposing a fix. I do not know which side stalls, and
neither does anyone else yet.

## Finding 2 — 19% of log lines never arrive, and disconnects do not explain it

`?audit=1`, verdict `gaps`, 2,865 sequenced lines, `insufficient: false`, every
source `conclusive: true`.

**681 lines missing** against 2,865 that arrived — **19.2% of what should
exist.** Every single node reports gaps. Reboots are counted separately, so
these are genuine sequence holes, not restarts.

| Node | Unreachable | Missing | Gaps | Reboots |
|---|---|---|---|---|
| node_102 | 41 | **100** | 12 | 2 |
| node_139 | 39 | **90** | 15 | 2 |
| node_94 | 36 | 55 | 11 | 2 |
| node_118 | 38 | 55 | 5 | 2 |
| node_145 | 40 | 54 | 15 | 5 |
| node_141 | 40 | 54 | 15 | 5 |
| … | | | | |
| node_104 | 40 | **15** | 3 | 2 |
| node_143 | 37 | **15** | 3 | 2 |

The obvious explanation is that the missing lines are the ones printed while a
node was off the air. **The numbers say otherwise.** Correlation between a
node's disconnect count and its missing-line count is **r = 0.247** — weak.
node_104 and node_143 each took ~40 disconnects and lost 15 lines; node_102 took
41 and lost 100. Same exposure, seven times the loss.

So Finding 2 is not a consequence of Finding 1, and something else is dropping
lines.

### Proposal

4. **W5 — check whether the delta shipper can overwrite an undelivered delta.**
   A per-node ring that advances on *send* rather than on *acknowledged receipt*
   would produce exactly this: loss concentrated on whichever nodes happened to
   be talkative during a busy moment, uncorrelated with that node's own
   connectivity.
5. **Report the loss rate on the dashboard.** A 19% figure that nobody sees is
   how this went unnoticed until someone ran an audit for an unrelated reason.

## What I am not claiming

- Not that the log system caused Finding 1. The timing is suggestive; the
  baseline that would settle it does not exist.
- Not that the fleet being idle is a fault. There are zero jobs queued — that
  may simply be that nobody ordered one.
- Not that these two findings share a cause. r = 0.247 says they probably do not.

## One thing the log got right

Both findings came out of `?audit=1` and one `contains=` query, in about five
minutes, without SSH and without asking the operator for a file. The
server-side filtering and the continuity audit are doing exactly what they were
built to do. The `matched`-versus-`returned` discipline caught me being wrong
once already in this same session.

*— W1*
