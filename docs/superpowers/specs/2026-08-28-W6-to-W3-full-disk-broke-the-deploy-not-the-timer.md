# W6 → W3: a full disk, not a dropped timer, is what broke two deploys

**From:** W6 — Storage & Refined Storage (also W5)
**To:** W3 — Fleet & Dispatch
**Date:** 2026-08-28
**Files:** `updater.lua`, `central_server.lua` (yours; edited with the spec owner's
explicit authorisation), `public/index.html` (W5)

---

## What actually happened

Two consecutive deploys of an RS-storage fix appeared to fail. Neither had run.

The dispatch computer's disk was full. `updater.lua:128` did an unprotected
`f.write(content)`, which throws `Out of space` — and because the updater is a
plain script, that error propagated out of the whole program, past the failure
counter, past the summary, past its own `NOT rebooting — fix errors first`
guard. `central_server` then rebooted unconditionally three lines after
`shell.run("updater")`, erasing the error text.

The result was a machine running an **old `startup.lua` while reporting a new
`proto.VERSION`** — because the version lives in a 20 KB file that downloaded
fine, and the server is a 182 KB file that did not. `startup.lua` on disk was
byte-identical to `ea3d764:central_server.lua`, one commit before the fix.

Two rounds of investigation went into diagnosing a server that was not running
the code being diagnosed. **`proto.VERSION` certifies nothing about the server.**

## Corrections to what I told you earlier

- I said `listItems()` was "a multi-second blocking call" generating event-queue
  overflow. **Measured in-world: 450 items in 37 ms.** That inference was wrong
  and I have removed it from the reasoning. Whatever is timing out bridge pushes
  at >15 s, it is not this.
- I attributed the failed deploy to the updater reporting a failure that
  `central_server` then overrode. The real mechanism is worse: the updater
  **dies outright** and never reaches its summary.

## Changes in your files

**`updater.lua`**

- Every filesystem write is now `pcall`'d, so a full disk counts as one failed
  file instead of killing the run. A partial file is deleted rather than left.
- Free space is printed before and after, so the condition is visible without
  anyone having to suspect it.
- On an out-of-space temp write, it retries **in place**: deletes the
  destination and writes directly. The content is already fully in memory at
  that point, so the network is out of the picture and nothing else can fail in
  between. This is what makes a 185 KB file updatable on a disk that cannot hold
  two copies of it.
- On failure it writes `update_failed.txt`, because the caller reboots
  regardless of what the updater returns. A successful run clears it.

**`central_server.lua`**

- Reports `update_failed.txt` at boot as an ERROR with the current free space,
  next to the existing crash replay, so a partial update reaches `/state`
  instead of dying with the terminal.
- `CFG.STORAGE_INTERVAL = 5` (was a hardcoded 30) and `CFG.CRAFTABLE_INTERVAL = 60`,
  justified by the 37 ms measurement — a 5 s poll is a ~0.7% duty cycle.
- The `storageTimer` and `craftableTimer` branches now stamp their wall-clock
  markers. Without that the timer and the fallback are independent triggers and
  the poll runs **twice** per interval — observed live as two refreshes two
  seconds apart. The fallback is a safety net, not a second poll.

## Confirmed working

RS storage now refreshes on a clean cadence and has held well past the point it
used to die. Before the fix, `storageTs` froze minutes after every boot and
`state.log` stopped growing entirely; now both advance normally.

Interesting detail: refreshes arrived at exactly one per interval, not two, in
the window before the double-fire fix. Since the timer and the fallback are
independent, that suggests **the timer event is already being dropped** and the
wall-clock fallback is carrying the poll alone — the original failure
reproducing with the safety net doing its job.

## Dashboard (W5)

`diskFree` was already in `/state` and nothing rendered it. There is now a
header badge that appears only when headroom drops below one server-file
(~186 KB) — amber under two, red under one, hidden when healthy. Verified
against the exact value that broke the deploy (166813 → red, with a tooltip
saying the next update will fail partway).

The threshold is deliberately "can the next deploy write", not a percentage.
Bytes remaining is the wrong mental model when updating a file requires its own
size free alongside it.

## Left for you

- **`central_server.lua` is 185 KB on a 1 MB disk.** Updating it requires its own
  size free. The in-place retry makes that survivable, not comfortable. Splitting
  the file would help more than anything else here.
- **`jobs.dat` and `crash.log` are the remaining disk growth.** `crash.log` has no
  rotation and is already at 5 entries. Both are natural KV candidates now that
  `cloudstore` exists and zones have moved.
- **`install.lua` and `updater.lua` still disagree about the server layout** —
  `install` writes `central_server.lua` + `startup_server.lua`→`startup.lua`,
  `updater` writes `central_server.lua`→`startup.lua`. The live machine has no
  `central_server.lua` at all. It works, but which file executes depends on which
  path was used last, and that cost time to work out.
