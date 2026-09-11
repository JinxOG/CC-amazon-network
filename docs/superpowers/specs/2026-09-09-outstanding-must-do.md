# Outstanding — the must-do list

- **Started:** 2026-09-09
- **Maintained by:** W3 — Fleet & Dispatch
- **Since 2026-09-11:** the cleanup phase (`2026-09-11-cleanup-phase-design.md`)
  sets the order. W3's staged work and the release question are in
  `2026-09-11-W3-to-spec-owner-five-staged-and-a-release-question.md`; the
  ruled release order and the rebuilt branches are in
  `2026-09-11-W3-to-spec-owner-stack-rebuilt-to-your-order.md`.
- **Rule:** an item leaves this list when it is **measured** as done, not when it
  is written. Three things on it were once believed fixed on evidence that could
  not have shown otherwise.

---

## 1. Move the RS storage poll off the dispatch computer — **W6**

**Now evidence-backed rather than tidiness, and the evidence changed the
priority.** It is the measured cause of *every* server stall observed under load.

```
LOOP STALL: deaf for 647ms — slowest step refreshStorage (647ms)
LOOP STALL: deaf for 619ms — slowest step refreshStorage (589ms)
LOOP STALL: deaf for 604ms — slowest step refreshCraftable (588ms)
LOOP STALL: deaf for 617ms — slowest step refreshStorage (617ms)
```

Measured 2026-09-09, 20:36–21:01 UTC, two miners working a six-sector zone each.

**CORRECTED 2026-09-10 - the 267 vs 647 comparison was meaningless.** W6 checked
the spans: `rsPollMs` wraps `rsBridge.listItems()` alone, while the loop's timer
wraps the whole function - the mod call, the rebuild of ~450 items, and a ~44 KB
`serialiseJSON`. I compared an idle figure from the inner span against a loaded
figure from the outer one and reported "2.4x worse under load". Two different
things shared one name; the instrument was honest and the label was not.

The halves also behave differently, which is what the comparison hid: the mod
call **yields** and so inflates when the server is busy, while the rebuild and
serialise are pure Lua and cost the same either way. Only the flat half can be
judged from an idle sample at all.

Split and published as of 1.9.92 (`rsBuildMs`, and stall lines now read
`[listItems Xms + rebuild Yms]`), so the next number quoted here is attributable.

**What survives the correction:** four stalls under load, all four in these two
calls, nothing else on the list. Still item 1, still W6's. What does not survive
is my account of *why* it got worse, which I do not yet know.
Everything arriving in those windows is destroyed — CC hands an event to a
coroutine that is not waiting and drops it.

**What it does NOT explain, so nobody over-claims when it lands:** the
fleet-wide disconnect clusters W1 measured need the server silent for roughly
15 seconds. 647 ms is 20× short. Expect this to remove the occasional
single-turtle disconnect and to remove the largest known yield. Expect it *not*
to close finding 1.

`refreshCraftable` appears in the same list and belongs in the same move.

**Measured 2026-09-10 (W6, from the 1.9.92 split):** 13 `refreshStorage` stalls
under four miners — `listItems` 370–756 ms (median 558), rebuild + serialise
14–107 ms (median **15**). The peripheral call is 96% of the stalled time; the
JSON is not the problem. Worst stall of the whole day: **1,020 ms**.

## 2. The fleet-wide disconnect clusters — **unexplained, owner unassigned**

**2026-09-11, the witness answers half of it: every disconnect is a lost message.**
225 `Server unreachable` lines, all read: **225 of 225** say the turtle kept running
with its radio on and the ACKs did not arrive — zero radio-off, zero declared gap,
zero paused loop. **21 group disconnects** by the §7.2 definition (≥3 turtles in
30 s), 5 of them on 1.9.99 where "radio on" means the transmit returned success.
Server normal throughout (rollups on cadence, `busy_ms_max` ≤ 119 ms, `slow=0`).
Still unknown: which direction is lost. Proposed next measure — the server logs, at
re-registration, how long since it last heard that turtle. Details:
`2026-09-11-W3-to-W1-spec-owner-r1-ran-its-job.md`. **Blocks §7 checks 3 and 4.**

W1 measured 30 clusters of 8+ nodes in 14 hours (`6b4d52a`). Not reproduced in
the 25-minute loaded window on 2026-09-09 — four disconnects, four different
nodes, minutes apart, singles rather than clusters.

**Both instruments have now failed to catch one under real load**, which is a
result rather than a gap:

| Window | Disconnects | Server stalls | Bridge |
|---|---|---|---|
| 25 min, idle-ish | 4 across 4 nodes | 4 (all `refreshStorage`) | `slow=0` |
| Full mining job | **61 across 13 nodes** | 5 | `push_ms_max=3.2, slow=0` |

Sixty-one disconnects against five stalls means **the server was responsive for
substantially all of them**. The bridge measured under a millisecond throughout.
Both candidates are eliminated by measurement, not argument.

The rate rises with fleet activity, and the events self-heal in about two
seconds. **The next look must be from the TURTLE side** — what a turtle observes
in the 15 seconds before it gives up — because the server's side now says
nothing happened.

**Do not close this because the storage poll got fixed.** 647 ms is 20× too
small to produce a fleet-wide cluster.

**2026-09-10, full day:** 291 disconnects in 68 clusters, five of 12–15 nodes.
Two more causes eliminated with evidence: bridge push timeouts land *further*
from the clusters than chance (5 near-hits vs 9.2 expected), and the server's
60 s loop rollup arrives on cadence straight through every fleet-wide dropout.
Per fleet member: SUPPORT 5.6, DELIVERY 4.0, MINER 3.25 — so the miners' modem
swap is not the general cause.

**The turtle-side witness is in** (1.9.95, corrected 1.9.96 and 1.9.98 — see the
fixed-not-measured table). Its first real capture was a miner mid-swap with no
radio at all, which it misreported twice. Wait for a capture on 1.9.98+ before
drawing anything from it.

## 3. Wire the crash handler to flush its dying words — **W1, W4**

A role's crash path prints the fatal error and reboots, with the control loop
that would have flushed it already dead. The most valuable line a turtle ever
writes is the one least likely to arrive. `base.flushLogs()` exists as of
1.9.89; the crash paths in `ore_turtle.lua`, `delivery_turtle.lua` and
`support_turtle.lua` need to call it before rebooting.

**Cleanup phase card 5:** W1 has `ore_turtle.lua`; W3 has delivery and support,
**signed off 2026-09-11**. **W3 half built (1.9.104, `w3-r6-crash-handlers`):**
support flushes before its reboot; delivery, which had no crash handler and
stranded itself at the shell prompt on a control-loop crash, now has support's.
Tests seen red first.

## 4. Sort the log query output by time — **W5** (moved from W3, 2026-09-11)

Bridge code, so code-side W5's per their routing memo.

The file is not chronological: turtles batch every 15 s while the server pushes
every 3 s, so a turtle's lines land after server lines that happened later.
Measured 37 backward steps in one day, up to 4 s. The timestamps are right; the
order is not. `?sort=ts` on the query endpoint, so nobody has to remember.

## 4b. Single-line log losses — **W3, closed 2026-09-11**

**R1's job (jobs 0043–0044, 1.9.99): 1,067 lines, 0 missing, `verdict=clean`.** The
detached-modem gaps and the DUMPING singles both absent. Kept below as the record.

The whole-job audit on 2026-09-09 showed 46 missing of 2,273 (2.02%), down from
19%. **38 of those were one burst**, fixed at 1.9.91. The remaining eight are
single lines, scattered — a different and much smaller mechanism, not yet
identified. Not worth chasing until 1.9.91 has a job's worth of data to measure
against.

**Measured 2026-09-10, jobs 0039–0042 (09:46–18:38): 190 of 9,584 missing
(2.0%), all but a handful on the four miners, and zero "dropped" notices.** Most
of it was not single lines: the large gaps sit right after `Lease released for
the retrieval ascent` and `Fence armed`. A modem swap leaves the turtle's handle
in place, detached; the outbox took the batch, the send raised, the batch was
gone. **Fixed at 1.9.98 (`fd29d34`)** — a failed send keeps its batch, a declared
comms gap holds the outbox. **Still open:** single-line gaps right after
`phase DUMPING`, four on each of the two miners examined.

## 4c. Chunk-loader retrieval position mismatches — **W1, informational**

Two `loader_position_mismatch` retries during the 2026-09-09 job. Both recovered
on their own and the job succeeded, so this is not a fault — but the retry path
added weeks ago is still being exercised in normal operation, which is worth
knowing before anyone treats it as dead code.

## 5. Warehouse and admin computers forward no logs at all — **unowned**

Phase 3 of the log work. If a delivery fault lives in the warehouse's logic it
is invisible.

**Warehouse half shipped by W6 at 1.9.97** (`78c4a76`, through `logship`). **Not
verified:** `?node=warehouse` is empty for 2026-09-10 and 09-11, which cannot
distinguish an un-updated warehouse from a broken forwarder — the warehouse has
never reported a version. Admin half not started.

## 6. Reconcile the systemd unit with reality — **W5 / operator**

`deploy/cc-dashboard.service` is a templated unit that has never been installed;
the running service is a hand-written one from 3 June with no hardening. The
repo file now carries a warning, but the two have not been reconciled. Needs the
installed unit's full text and a decision on whether to adopt the hardening.

## 7. The server's live-zone backup was never deleted — **W3 fix, W6's card**

`saveMiningZones` moved `active_zones.dat` aside and never dropped the `.bak`,
so live zones cost the 1 MB disk twice (~183 KB each). Found by W6. **Fixed at
1.9.99 (`459a2bf`).** Disk fell 544 KB → 308 KB free across jobs 0039–0042 and
stayed there idle. **Open (W6's question):** `jobs.dat.bak` at 326 KB on
2026-09-09, after `saveJobs` began dropping it — older code running, or a save
failing between the two moves. A file listing off the server computer settles it.

## 8. The low-disk warning comes too late — **W3**

It fires below 120 KB. A 236 KB drop in one job said nothing.

**Built, staged (1.9.102, `w3-r4-disk-warning`):** WARN below 350 KB, ERROR
below 300 KB — the §7 run's floor — checked every minute as well as after job
saves. Also removed the old text's advice that the zone files were
"expendable": live zones are on disk only.

## 9. A stale sector order is replayed after a reconnect — **W3 (server), W1 (miner)**

From W6's node_139 diagnosis: the server replays a miner's last `SECTOR_ASSIGN`
on re-link even mid-sector, so the miner later re-enters the sector it just
finished. 6 replays, 4 repeated sectors in jobs 0039–0042.

**Built, staged (1.9.103, `w3-r5-stale-sector`):** the reconnect carries
`awaitingSector`; the server replays only when it is not false, and logs every
withheld replay. `reSendSector` is gated, not removed — the cleanup phase counts
it as flaw 1's footprint. W1's miner-side half is separate.

## 10. The install check cannot see a guarded require — **W3**

W6 loads `logship` on the warehouse with `pcall(require, …)`, which the manifest
test ignores by design. Add an allowance for guarded-and-reported requires.

**Done — on `master` (`7c6a934`, test only):** a guarded require
whose file says "<module> unavailable" / "not installed" is required wherever the
file ships; per-role exemptions carry their reason. Removing `cloudstore` from
the server's list now fails the suite — the gap this list used to record.

## 11. Dashboard updates get lost — **W3** (cleanup phase card 7)

~83–123 bridge pushes a day time out while the bridge answers in 1–3 ms; one
hard force-clear on 2026-09-10. Not correlated with the disconnect clusters.
Suspected: a peripheral call in the turn AFTER a push discards the queued reply.
**Witness built, staged (1.9.101, `w3-r3-push-witness`, release R3)** — every timeout
line now says what ran in its window. A lost reply may also be a lost dashboard
command (asked of W5).

## 12. Wave 1 removals — **W3 rows built, staged**

`stress_test.lua` out of the updater; `test_turtle.lua` to `tests/inworld/`
(1.9.100, `w3-r2-wave1`, release R2). This release changes `updater.lua` itself, so it
is also the first live run of the 1.9.94 self-restart.

---

## Recently closed — kept because each was closed wrongly once

| Item | Closed on | Why it is really closed now |
|---|---|---|
| Log lines lost during outages | 1.9.89 | audit `verdict=clean`, 360/360 sequenced under load |
| Phase-lock storm | 1.9.87 | 0 fleet-wide episodes in 25 min — **but see item 2** |
| Equipment swap after the CC:Tweaked upgrade | verified 2026-09-09 | both miners ran `SWAP_TO_PICKAXE` and `RETRIEVING` repeatedly |
| Bridge as a stall suspect | 2026-09-09 | `log_share` under 10% of a sub-millisecond push |
| A complete mining job | 2026-09-09 | 17,087 ore, 6/6 sectors, both miners docked and refuelled, loaders retrieved, zero failures |

## Fixed but NOT yet measured — the list's own rule applies

| Item | Fixed at | What would close it |
|---|---|---|
| Burst log loss (38 lines in one gap) | 1.9.91 | **Measured 2026-09-11:** jobs 0043–0044 on 1.9.99, 1,067 lines, **0 missing**, `verdict=clean` — no gaps of any size. Closing with the next row |
| Updater restarts when its own file list changes | 1.9.94 | a live update that changes `updater.lua` itself, with every node landing |
| Detached-modem log loss | 1.9.98 | **Measured clean 2026-09-11** (same job, 9 modem swaps on node_139 alone, 0 missing). Card moved to Done |
| Witness verdict from the send result | 1.9.98 | a live capture whose verdict matches the turtle's phase |
| Live-zone backup dropped | 1.9.99 | a file listing off the server computer with no `active_zones.dat.bak` |

Written down separately rather than in the closed table, because three entries
above were once closed on evidence that could not have shown otherwise. A fix is
a hypothesis until a measurement agrees with it.
