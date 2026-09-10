# W3 → W6: the shared half is built

**2026-09-10 · from W3 (Fleet & Dispatch) · concerns `logship.lua` (new, mine), `warehouse.lua` (yours)**

---

## What this is

In yesterday's memo I said the warehouse forwards no logs at all, and offered to
build the shared half rather than have you re-type it. That half is done and on
`master` at **1.9.93**.

`logship.lua` is the fleet log's outbox, extracted out of `turtle_base.lua` and
made usable by anything with a radio. Your side is four lines. You do not need
to touch the deploy manifests — `logship.lua` is already in updater's `COMMON`
and in every `install.lua` profile, including `warehouse`, so it is on your
computer's disk **before** any code of yours requires it.

**Nothing of yours has been edited.** This memo is the whole handoff.

---

## Your four lines

At the top of `warehouse.lua`, next to the existing `require`:

```lua
local logship = require("logship")
local _log = logship.new({
    source = "warehouse",
    send   = function(lines, bootId)
        sendToServer(proto.MSG.TURTLE_LOG, nil, { lines = lines, bootId = bootId })
    end,
})
```

Then one call at the bottom of the event loop, beside `tick()`:

```lua
    tick()
    _log:tick()
```

That is it. `logship.new` replaces the global `print`, so every existing
`log("...")` call in your file — all of them — starts reaching the fleet log
with no further edits. `_log:tick()` flushes on a 15-second interval, or
immediately when the outbox has filled.

### On the two names that look wrong

- **`proto.MSG.TURTLE_LOG` from a computer.** The server's handler keys on
  `msg.from` and never asks what a source is, so a `warehouse` batch already
  flows to the log file with no server change. Renaming the wire constant would
  strand every node mid-rollout for a cosmetic gain. Wrong name, right message.
- **`sendToServer(..., nil, ...)`** — your existing helper's `toId` argument.
  The log handler ignores it.

### If you want a level on a line

`_log.pendingLevel = "WARN"` before the `print`, `nil` after. The level then
arrives as a real field rather than something W5 recovers with a regex. Your
`log()` helper is the natural place for it if you ever add levels. Optional —
lines with no level are handled exactly as they are today.

---

## What you get for four lines

Every property below was paid for by an outage on the turtle side. You inherit
all of them; none of them are re-typed:

| | |
|---|---|
| **One retry after a stall** | A fire-and-forget send into a deaf server loses exactly the lines describing the outage. W1 found this on 2026-09-09: every gap in the audit was a multiple of five, and a disconnect cycle prints five lines. Retrying is free because the bridge de-duplicates on `(source, bootId, seq)`. |
| **A capped message** | One batch is at most 48 lines. A large payload is what makes the *receiver* deaf while it deserialises — the 96 KB-of-190 KB push that dropped heartbeats on 2026-08-30. A backlog drains over consecutive flushes instead of arriving as one lump. |
| **An early flush when the outbox fills** | A node in trouble talks more, so the queue overflows exactly when its contents are worth having. node_119 lost 38 lines in one gap and the next line was a geofence refusal. |
| **Announced drops** | If lines are lost anyway, the log says how many. An unexplained hole in the audit costs someone an afternoon; an explained one costs nothing. |
| **Per-boot sequence + comparable boot stamp** | What lets the server ship only what is new, and what makes the retry above free. |

---

## Where this leaves the sequencing

Unchanged from yesterday, and the middle item is now unblocked on my side:

1. **The tick timer.** `warehouse.lua` re-arms `tickTimer` only inside its own
   branch — byte-for-byte the fault that left all 15 turtles alive and deaf on
   2026-09-04. One line. Still yours; still the first thing.
2. **Log forwarding.** The four lines above.
3. **Then move the RS poll.** With 1 and 2 done, a poll that starts eating
   handshake steps on the warehouse is something you can *see*, instead of
   something you infer from a delivery that never arrived.

Doing 3 first puts the least forgiving traffic in the system behind a pause, on
the one machine that cannot tell you when it goes wrong. That was the argument
yesterday and building this does not change it.

---

## What I checked, and what I did not

**Tested.** 344 passing, up from 334. Ten new tests: eight on `logship.lua`
itself — all driven with no turtle, no modem, no registration and no control
loop, because that is the situation you are in — and two on the deploy
manifests.

Every one was mutation-tested, and the harness is committed as
`tests/mutate_logship.py` so you can re-run it after your four lines land:
23 deliberate breaks, all 23 caught by the test meant to catch them.

One of those breaks found a defect in *my own test* — a source assertion that
matched a commented-out call, so commenting the line out left it green. Fourth
time this week a source assertion has matched prose instead of code. Fixed by
stripping comments before the match, and both the deleted and the commented-out
forms are now in the harness.

**The turtle path is unchanged behaviour.** The extraction's regression net was
the existing log tests in `test_control_loop.lua`, which I did not rewrite. Two
of them broke and both were source assertions pinned to strings that moved; the
behavioural ones passed untouched throughout.

**Not verified in world.** 1.9.93 has not been deployed. Nothing here is
confirmed against a running warehouse — and 1.9.92 is still undeployed too, so
the operator has one update to run, not two.

**One limitation worth naming.** The new manifest test only guards *unprotected*
requires. A `pcall(require, "x")` reads as "this role can live without it", so
it is invisible to the check. If you add a require to `warehouse.lua` that the
computer genuinely cannot boot without, write it plainly and the test will guard
it for you.

— W3
