# W1 → Spec owner: the disk budget is undeclared, and the assumption behind it just failed

**From:** W1 — Resource Intelligence
**To:** Head engineer / owner of the System Integration Spec
**Date:** 2026-08-22
**Subject:** §7.4 storage constraint, §4.1 in-world computers, §13 ownership
**Status:** Raising a conflict, not proposing a divergence (per §1)
**Observed at:** server and full fleet on 1.9.34

---

## The ask

Two decisions, both above W1's pay grade:

1. **Where does Tier 2 of the resource index physically live?** The ore-index
   design assumes it gets 512–640 KB on the dispatch computer. That computer is
   currently full.
2. **Should the spec declare a per-computer disk budget as a first-class
   constraint**, the way it declares invariants and ownership?

W1 is not asking to change §7 (the two-tier index) or the packing format. Those
survive intact. The question is *where the bytes go* and *who is allowed to
assume they are available.*

## What happened

While diagnosing an unrelated dispatch deadlock, W1 found this repeating in the
server log:

```
saveJobs failed: /startup.lua:433: Out of space
```

The dispatch computer's disk is full. Job state has not been persisted for at
least the length of the visible log window. The mechanism, the reboot hazard it
creates, and the one-word fix are in
`2026-08-22-W1-to-W3-savejobs-destroys-its-own-backup-on-a-full-disk.md` and are
W3's to action. **This document is only about what it means for the spec.**

## The assumption that failed

The ore-coordinate design states:

> CC:Tweaked's default `computer_space_limit` is 1 MB, shared with the server's own
> programs, `zones.dat` and its backup — so the index gets a configured fraction,
> call it 512–640 KB.

That sentence is doing a great deal of load-bearing work, and it was written
without measuring the machine. The measurement now exists and the fraction
available is **zero**, before a single byte of index has been written.

§7.1 has the same gap in a milder form:

> Rejected: coordinates for every block type. A sector scan covers ~109,000
> blocks; this is roughly **100× over the CC disk budget**.

The conclusion is right. But *"the CC disk budget"* is referenced as though it
were a known quantity, and it is nowhere defined in the spec. Every subsystem
that persists anything is currently free to assume its own number.

**An honest caveat, stated up front.** The disk may be full for a mundane reason —
`install.lua` and `updater.lua` write `central_server.lua` to two different names,
so a machine installed and later updated carries two 153 KB copies of the same
file. If that is all it is, the 512–640 KB estimate may well survive intact. W1
has not been able to see the live filesystem to confirm either way. **The
architectural question stands regardless of the answer**, because the budget was
never declared and the failure was never surfaced — those are true whether or not
this particular disk turns out to be easy to clear.

## Why this is architectural and not just a full disk

Three things, in increasing order of consequence.

**1. The budget is undeclared.** §13 assigns one owner per file. Nothing assigns
owners to *bytes*. `central_server.lua` alone is 156,679 bytes — roughly 15% of a
default 1 MB disk for the program text before it stores anything. W1's index, W3's
`zones.dat`, and `jobs.dat` are all drawing on the same unmeasured pool.

**2. The §4.1 reasoning concentrates storage in-world.** The planner was put on
its own CC computer for good reasons — a PC-side process load-bearing for autonomy
is fragile, and `central_server.lua` "does not get more responsibilities." W1
agrees with both. But the same reasoning routes *every* growing dataset onto CC
computers with fixed 1 MB disks, and the spec never checks whether the sum fits.
The planner is a new computer that will hold `protocol.lua` + `waypoints.lua` +
`updater.lua` + its own program before it stores a single BOM. It inherits this
constraint on day one.

**3. §4's failure table has no row for this.** The Storage layer is
`warehouse.lua` + Refined Storage, and its failure mode is *"deliveries stall;
nothing is lost."* That row is about **items**. There is no layer, no owner and no
failure mode for **system data on disk** — which is exactly why this ran for hours
in a `pcall` with a log line and nobody knew. The two defects found today are
unrelated in mechanism and identical in shape: **the system was degraded and had
no way to say so.**

## Where Tier 2 could live

| Option | Fits the spec? | Cost |
|---|---|---|
| **A. Dispatch computer** (as designed) | §13 already says `central_server.lua` is "at scale limits — new logic goes elsewhere by default" | Contradicts §13's own note; disk is full today |
| **B. Dedicated indexer computer** | Follows the §4.1 planner precedent exactly | Another computer, another modem hop, another 1 MB ceiling to budget |
| **C. CC disk drives** | Native CC capacity; each drive is a separate mount | Unverified in this modpack — needs a probe |
| **D. The Node bridge** | **Conflicts with §13**: "Bridge & dashboard — W5 — Never load-bearing" | Requires ruling on what "load-bearing" means |
| **E. Tier 1 census only, defer Tier 2** | Fully compliant; §7.1 already separates the tiers | No coordinate index yet |

**Option D deserves an explicit ruling rather than silent rejection.** §7.3 states
that index entries are **"hints, never truth"**, that `turtle.dig()` returning
false detects a miss for free, and that every visit re-uploads an authoritative
scan. If that is genuinely true, then losing the bridge degrades the system to
*"no hints — survey as we go"*, which is exactly today's behaviour. That is a
materially weaker dependency than the planner would have had, and it is the case
§4.1 was actually arguing against.

So the question for the spec owner is: **does "never load-bearing" mean "no
availability dependency" or "no correctness dependency"?** Under the second
reading, D is permitted and cheap. Under the first, it is not. W1 will build to
whichever, but the two readings produce different systems and the spec currently
supports either.

## What W1 recommends

**Near term — Option E.** Tier 1 census is ~50 entries per sector, cheap by an
order of magnitude, and it is the tier that answers *"where in the world is
spruce"* and *"how much is actually there"* — the questions the planner needs
first. It can ship into whatever headroom exists after the disk is cleared.
Tier 2 waits for the ruling. This unblocks Stage 2 without betting on an
unresolved budget.

**Structurally — B or C**, decided by whether disk drives work here.

**Regardless of both — the index must declare its own ceiling and enforce it.**
The design already specifies LRU eviction under a configured byte budget. That
budget must be a hard, measured cap that the index refuses to exceed, not a share
of whatever happens to be free. A subsystem that sizes itself against free space
will always eventually consume someone else's.

## Proposed spec changes

**Add to §17 (Open verification items):**

> **V8** — What is `computer_space_limit` on this server, what is actually
> consuming the dispatch computer's disk, and are CC disk drives available and
> permitted in this modpack? **Blocks:** where Tier 2 of the resource index lives,
> and the planner's own storage budget.

**Add a per-computer disk budget table** alongside §13's ownership table. Same
principle, different resource: every computer gets a declared ceiling, and every
subsystem that persists data declares its steady-state and worst-case bytes
against it. `central_server.lua`'s 153 KB of program text should appear in that
table as a fixed cost, not a surprise.

**Add an invariant** in the style of A–J:

> **K — Persistence failure must be visible.** Any subsystem that writes to disk
> surfaces a health signal reachable from `/state`. A `pcall` around a write is
> required, and is not sufficient on its own: a silent `logWarn` in a 100-line
> ring buffer is not a signal.

That last one is the piece W1 feels most strongly about. Both defects found today
were survivable individually. What made them expensive was that each ran for hours
with the system reporting itself healthy.

## What this does not change

- **The two-tier split (§7.1) is right** and this strengthens it: the tiers have
  very different budget profiles, and separating them is what makes E possible.
- **The watchlist is still load-bearing**, for the reason already documented —
  ~19 KB/sector for all ore types versus ~2–4 KB for a narrow watchlist.
- **The packing format is not the problem.** 4 bytes per ore is already 15× better
  than the naive representation. No amount of further packing rescues a design
  that has no declared budget to pack into.
- **§7.4 holds.** Coordinates staying out of `state.persistentZones`, out of the
  `/state` payload and out of server RAM in bulk is correct and this changes none
  of it.
