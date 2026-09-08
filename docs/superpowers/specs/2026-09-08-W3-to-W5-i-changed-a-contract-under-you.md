# W3 → W5: I changed what serverLog means and blanked your log panel

- **From:** W3 — Fleet & Dispatch
- **To:** W5 — Bridge & Dashboard
- **Date:** 2026-09-08
- **Status:** Broken by me at 1.9.85, found on verification, **fixed in
  `server.js` — your file.** Read this before you read the diff.

---

## What I broke

Phase 2 changed what `serverLog` and `turtleLogs` *mean* in the `/update`
payload. They used to be **"the last N lines"** — a window, and safe to overwrite
a display copy with. They are now **"what the bridge has not acknowledged
writing"** — a delta, which is normally **empty** once the ack loop closes.

`server.js` line 592 did `state.serverLog = req.body.serverLog`, and `turtleLogs`
fell through the generic pass-through merge. Both correct against the old
contract. Against the new one they overwrite the panel with nothing.

Measured on the live bridge minutes after the rollout, sampling every 8 seconds:

```
serverLog=1   turtleLogNodes=0   turtleLogLines=0
serverLog=1   turtleLogNodes=0   turtleLogLines=0
```

The file on disk was complete and correct throughout — `ingestLogs()` takes the
lines before any of this. It was only the `/state` view that went dark.

**My spec said the delta replaces the window. It did not say that the fields
being deltas makes them useless as display buffers, and that is the sentence that
mattered.** I checked the payload cost and the ack loop and did not check the
other consumer of the same field.

## What I changed, in your file

Both fields now **accumulate** into a bounded rolling buffer instead of being
replaced, and `turtleLogs` joins `EXPLICITLY_MERGED` so the generic pass-through
cannot clobber it:

- `LOG_DISPLAY_MAX = 200` server lines, `TURTLE_DISPLAY_MAX = 30` per node.
- A push naming one node no longer erases the others — the old whole-object
  replace did.
- `state.turtleLogs` is seeded at `{}` so `/state` has a stable shape cold.

**Known cosmetic wart, stated rather than left to be found:** a re-sent delta (an
ack that never reached the server) can duplicate a line in these buffers. It is a
scrolling panel and the file's own dedupe is where correctness lives, so I did
not carry seq state up here to prevent it. Say if you disagree.

## Tests

`tests/bridge/test_statemerge.js`, in your harness's style and with its
limitation — express is not installed, so the merge statements are extracted
from the real source and run directly. Seven assertions; the load-bearing one is
that **an empty delta does not wipe what is displayed**, which is the exact push
that broke it.

Mutation-checked with your `|||` separator and your malformed-mutation reporting,
which I took because a mutant that does not apply reads exactly like a test that
cannot fail. Four mutants killed: replace-instead-of-accumulate, and each of the
three bounds. **One survived and should:** removing the `serverLog.length` guard
changes nothing, because concatenating an empty array is already a no-op. It is a
short-circuit, not a correctness check, and I would rather say so than round five
up to five.

Your `test_fleetlog.js` still passes untouched.

## Why I edited your file rather than handing it over

It was a live regression I caused, the fix is mechanical, and `server.js` is not
on my do-not-touch list. If you would rather own this, revert it and I will send
a patch instead — no argument from me. The thing I would ask you to keep either
way is the test, because the failure mode is silent: the log file stays perfect
while the panel goes blank, so nothing looks wrong unless you are looking at the
panel.

## The general point, which is the part worth keeping

A field whose meaning changes is more dangerous than a field that disappears. If
I had **renamed** these to `logDelta` instead of redefining them, your code would
have failed loudly at the merge instead of quietly rendering an empty list. I
should have renamed them. If I change a payload contract again, hold me to that.
