# W1 → Spec owner: V8 measured — the limit is exactly 1 MB, and §13.1's duplicate is worse than recorded

**From:** W1 — Resource Intelligence
**To:** Head engineer / owner of the System Integration Spec
**Date:** 2026-08-28
**Re:** §17 **V8**, §13.1 disk budget, §7.1 tier placement
**Status:** Two of V8's three questions answered from live measurement. The third
is untouched.

---

## Why this is late

W1 measured this on 2026-08-22 and did not write it down. The numbers sat in a
terminal session while three documents — this spec's §13.1, §7.1, and W1's own
`2026-08-22-W1-to-spec-owner-storage-budget-and-the-resource-index.md` — continued
to say *"1 MB **by default**"* and *"**unverified on this server**"*.

That is the same failure those documents are about: a measurement existed and
nothing surfaced it. Recording it here so the spec stops carrying an assumption
that has been answered for six days.

## V8, question by question

> **V8** — What is `computer_space_limit` on this server, what is actually
> consuming the dispatch computer's disk, and are CC disk drives available and
> permitted in this modpack?

### 1. `computer_space_limit` — **exactly 1,000,000 bytes. Measured.**

Walked the dispatch computer's filesystem recursively, summing `fs.getSize` and
reading `fs.getFreeSpace("/")`:

```
free            237,583
user files      762,417
                ─────────
                1,000,000
```

The `/rom/*` tree is mod-supplied and read-only; it does not count against the
limit, which the arithmetic confirms by closing exactly on a round number.

**§13.1 change:** *"1 MB by default (**unverified on this server; see V8**)"* →
1 MB, measured 2026-08-28. The parenthesis can go.

**This matters beyond tidiness.** The resource index's Tier 1 budget — 128 KB hard
cap, ~110 sectors before eviction — was sized against an assumed 1 MB. It is now
sized against a measured one.

### 2. What was consuming it — **answered, and it was mostly rubbish**

| File | Bytes | What it was |
|---|---|---|
| `/jobs.dat.bak` | **190,932** | Partial write left behind by the failing `fs.copy` |
| `/startup.lua` | 156,679 | The running server |
| `/central_server.lua` | **150,190** | Stale duplicate — see below |
| `/mine_zones.dat` | 105,485 | Survey history (wanted) |
| `/mine_zones.dat.bak` | 101,565 | Its backup (wanted) |

The largest single file on a full disk was **garbage produced by the disk being
full** — `saveJobs` deleting its backup and then failing to recreate it left a
190 KB partial. The failure was manufacturing its own cause.

Deleting the partial and the stale duplicate reclaimed **341,122 bytes**, taking
free space from 237 KB to ~578 KB. `saveJobs` has worked since, and W3's
`fs.copy` → `fs.move` fix (1.9.44) removes the mechanism.

### 3. CC disk drives — **still unknown**

Not probed. This is the part of V8 that can still change a design decision: §7.1
defers disk drives as the in-world alternative to putting Tier 2 on the bridge,
and that deferral stands until someone tests it.

**V8 should stay open on this question alone**, narrowed to it.

## §13.1's "known defect" is wrong in a way worth correcting

The spec records:

> A machine that was installed and later updated therefore carries **two
> 156,679-byte copies**, about 313 KB.

It does not. Measured:

```
/startup.lua          156,679   ← current build, the one that runs
/central_server.lua   150,190   ← an OLDER build
```

**Two different builds, not two copies of one.** 306,869 bytes total, so the ~31%
figure holds — but "duplicate" implies the copies are interchangeable and one can
be deleted without thought. The reality is a stale program sitting on disk looking
like a redundant copy, which is a different and slightly worse thing: anyone
reasoning about which to keep has to know that `updater.lua` deploys the server
*as* `startup.lua` and that a file does not require itself.

Suggested wording: *"carries two builds of the same program under different names
— the current one as `startup.lua` and a stale one as `central_server.lua`,
together ~307 KB or ~31% of a default disk."*

## What this does not change

- **§7.1's tier placement stands.** Tier 1 in-world, Tier 2 on the bridge. A 1 MB
  measured ceiling is the number the decision already assumed; confirming it
  removes a risk rather than moving the answer.
- **Tier 1's declared budget stands** — 1.1 KB/sector steady state, 2 KB worst
  case, 128 KB hard cap. Now measured against a measured ceiling.
- **The dedicated-indexer rejection stands**, and is strengthened: another
  computer really is another 1,000,000 bytes, not a vaguer "about a megabyte".

## One observation for §13.1's rules

Rule 2 says a subsystem sizes itself against a hard measured cap, never against
free space. The `jobs.dat.bak` finding is the sharpest illustration available:
**190 KB of the shortfall was created by the shortfall**. A subsystem that fails
part-way through a write can leave debris larger than the data it was trying to
store, so a budget has to account for the failure modes of its own writes, not
only for steady-state size.

Not proposing a rule change. Offering it as the concrete example rule 2 currently
lacks.
