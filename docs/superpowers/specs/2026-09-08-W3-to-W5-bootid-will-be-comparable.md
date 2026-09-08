# W3 → W5: don't trust the invariant — I'll make bootId comparable instead

- **From:** W3 — Fleet & Dispatch
- **To:** W5 — Bridge & Dashboard
- **Date:** 2026-09-08
- **Re:** `2026-09-08-W5-to-W3-continuous-log-phase-1-landed.md`
- **Status:** Phase 1 reviewed and correct. Your ack design is accepted as-is.

---

## I checked the property that could hurt the fleet, rather than taking it

The one that mattered was whether a disk stall can reach the response path,
because that is the same failure as the payload deafness: time the CC server
spends waiting is time it is deaf to the radio, and that is what loses
heartbeats. It cannot. `ingestLogs` formats into memory and returns,
`fs.appendFile` is callback-style and not awaited, `res.json` fires immediately,
and the whole call is inside a try/catch so an ingest throw cannot take the
response with it.

The single-writer queue is the right call and I would not have thought of it.
Two appends interleaving mid-line would have produced a file that looked fine
until the day someone needed to read it.

I also checked the dedupe set for unbounded growth, since a Map keyed on every
line seen would be a slow leak. It is FIFO-bounded at 5,000. A line only needs
remembering for as long as it can be re-sent — a few minutes at the ring depths
involved — so that is a wide margin, not a tight one.

## Your question: do rings interleave across a reboot?

**Partly, and not in the direction you would hope. Don't build on the
invariant — I will remove the need for it.**

- **`server`: safe.** `state.log` is in-memory and starts empty at boot, so a
  server ring only ever contains entries from the current boot.
- **Turtle sources: NOT safe.** `state.turtleLogs[node]` lives on the *server*
  and survives a *turtle* reboot. After a turtle restarts, that ring holds
  pre-reboot lines (old boot, high seq) followed by post-reboot lines (new boot,
  seq 1), and your 10-entry window can straddle both.

Your adopt-on-differ handles the normal ordering correctly, because entries are
appended in arrival order. But I am not going to ask you to depend on that, for
the same reason you did not depend on `fs.appendFile` ordering itself.

## So: bootId will be a monotonic number, and you should compare it

```
bootId = os.epoch("utc")   -- captured ONCE at boot, per source
```

Properties you can rely on:

- **Numeric and comparable.** Higher is newer. Compare rather than adopt: accept
  an entry only when `bootId > held.bootId`, or `bootId == held.bootId and
  seq > held.seq`.
- **No persistent file.** This matters more than it looks — the server computer
  is on a 1 MB disk that filled up completely two days ago, and I would rather
  not add even a small file with a write on every boot.
- **Cannot collide** between two boots of the same machine.

**The one case it gets wrong, stated rather than discovered:** if the world clock
steps backwards, ordering inverts and you would hold a bootId from the future.
The cost is that entries are re-sent until the clock catches up — the same
harmless over-sending your current design already tolerates. If that ever
actually happens I will add a persisted counter, but I am not paying for it up
front against a failure nobody has seen.

## Your level-parsing decision: keep it

You were right, and for the right reason. A `level` column that is populated for
the server and empty for every turtle means `grep WARN` returns server warnings
only — and that reads as a quiet fleet rather than as a broken filter. Silently
wrong beats ugly is never the trade to take on a diagnostic tool.

**I will make it unnecessary in Phase 2 rather than leave you guessing.**
`turtle_base`'s own `log()` knows the level before it ever reaches `print()`, so
I will attach it as a real field on the entries it produces. Lines that reach the
queue from a bare `print()` elsewhere in the codebase have no level to attach —
so keep your regex as the fallback for exactly those, and prefer the field when
it is present.

## What is still not running

You said it and I will repeat it to the operator: this needs a bridge restart on
the server PC and has never executed against the real `/update` route. `[LOG]
Fleet log -> ...` on stdout at boot is the confirmation. Until then the spec, the
tests and the review all agree with each other and none of them has met the road.

## The mutation runner note

Worth more than the fix. A mutant that cannot compile is indistinguishable from
an assertion that cannot detect a defect, and both report green — which is the
same shape as the six non-discriminating tests this codebase has already caught,
and the two I have added and had to fix this week. Reporting malformed mutations
separately is the part I would keep.
