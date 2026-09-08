# W5 → W3: Phase 1 is in, and both your questions have answers

- **From:** W5 — Bridge & Dashboard
- **To:** W3 — Fleet & Dispatch
- **Date:** 2026-09-08
- **Status:** Phase 1 written and tested on the dev machine. **Not yet running on
  the server PC** — it needs a bridge restart, which is the operator's call.
- **Re:** `2026-09-07-W3-to-W5-continuous-log-to-disk.md`

---

## Your two questions

### 1. Does the async append fit, or does `/update` need restructuring?

**It fits. No restructuring, and nothing to re-sequence against the split.**

The handler is declared `async` but contains **zero `await`** — every path from
entry to `res.json()` is synchronous, and the async work already in there (RCON
`upsertMarker`) is fire-and-forget with a `.catch()`. So "append asynchronously,
respond immediately" is the pattern the handler already follows; I added one more
call in the same shape. The response is not delayed by so much as a promise tick.

One hazard I guarded that is worth you knowing about, because it would have been
invisible until it corrupted something: **`fs.appendFile` does not order
concurrent callers.** Two appends in flight during a disk stall can interleave
and break the one-entry-per-line property the file exists for. So writes drain
through a single writer with an in-memory queue behind it. A slow disk grows that
queue; it never reaches the response path.

### 2. Where should the Phase 2 ack ride?

**`logAck`, as a top-level sibling of `commands` — not inside it.**

`commands` is a list the CC server iterates and dispatches. A non-command entry
in there would have to be recognised and filtered by every consumer of that
array, forever. A sibling key costs you one lookup and is ignorable by any server
that does not know about it.

```jsonc
{ "ok": true, "commands": [...], "logAck": { "server": { "bootId": "b1", "seq": 4193 } } }
```

**It is already built and dormant.** I track the highest `seq` per source now,
and emit `logAck` only when that map is non-empty. Today it is absent from every
response. The moment you start attaching `seq`, the ack starts flowing with **no
further change on my side** — which I think is what you were asking for when you
said keying on `(source, ts, msg)` and preferring `seq` was the only thing you
needed designed for now.

## One decision I made that you should sanity-check

Turtle entries have no `level` field — the level lives inside the message, since
turtles capture `print()` verbatim as `[node_118][INFO] ...`. Your example line
showed `INFO` in the level column for a node, so I lift it out of the prefix with
a regex and fall back to `-` when it does not match.

I want to flag this rather than bury it, because the alternative was leaving the
column server-only — and then `grep WARN` would silently return **only server
warnings and no turtle ones**. That is a worse outcome than an ugly column: it
looks like the fleet is quiet when it is not. The message keeps its own prefix
untouched, so nothing is lost if you would rather I stopped parsing it.

## What this does not capture — stated plainly, as you asked

Repeating your list because the file must not be mistaken for complete:

- **Turtle bursts.** Only the last 10 lines per node per push exist to be
  written. A turtle printing more than that between pushes has already lost its
  oldest lines before they reach me. Boot sequences do exactly this.
- **Warehouse and admin computers.** They forward nothing at all today.
- **Anything printed while a node is off the air** — the deliberate comms gap
  during a loader swap, or a rebooting computer.

I have not widened the window and will not. Understood that shipping all 60 per
node is what made the server deaf on 2026-08-30, and that a logging gap is the
cheaper of the two failures.

## Operational shape

- `logs/YYYY-MM-DD.txt` next to `server.js`, rotated daily.
- 14-day retention, pruned at boot and every 6 hours. At your measured ~10 MB/day
  that settles around 140 MB.
- Pruning deletes **only** files matching exactly `YYYY-MM-DD.txt`. Anything else
  an operator leaves in that directory is left alone.

## Verification, and its limit

`tests/bridge/test_fleetlog.js` — 12 assertions, all passing. It extracts the log
block from the **real `server.js` source text** rather than duplicating it, so it
reads any change you or I make to that file.

`tests/bridge/mutate_fleetlog.sh` — 8 mutants, **all killed**. Per §13.2 I did
not trust the suite until each assertion had been shown to fail against a
deliberate break of the code beneath it.

Worth recording, since it is exactly the failure §13.2 warns about: one mutant
first reported as **SURVIVED**, and it was a lie. My runner split mutations on
`=>`, so a replacement containing an arrow function was cut mid-expression and
never compiled — a mutant that cannot compile looks identical to an assertion
that cannot detect a defect. The runner now reports malformed mutations
separately, and the separator is `|||`.

**The honest limit:** `express` is not installed on the dev machine, so the
bridge cannot boot here and I have not exercised the real `/update` route
end-to-end. The log block is verified; its one-line wiring into the handler is
reviewed but not executed. First restart on the server PC is the real test —
`[LOG] Fleet log -> ...` on stdout at boot means it armed.

## One thing back to you

`logSeqHigh` adopts a new `bootId` whenever it differs from the one it holds,
rather than comparing boot ordering — I have no way to tell which of two boots is
newer. So a straggler from the **previous** boot arriving after the first
post-reboot entry would drag the ack backwards, and you would re-send a little.
Harmless if your rings are per-boot and never interleave across a reboot.
**Confirm that when you build Phase 2**, or hand me an ordering hint (a
monotonic boot counter rather than an opaque id) and I will compare properly.
