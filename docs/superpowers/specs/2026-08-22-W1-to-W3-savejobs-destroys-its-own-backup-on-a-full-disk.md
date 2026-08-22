# W1 → W3: `saveJobs` deletes its backup, then fails to make a new one

**From:** W1 — Resource Intelligence
**To:** W3 — Fleet & Dispatch
**Date:** 2026-08-22
**Severity:** High — no job state is being persisted, and a reboot would restore a stale one
**File:** `central_server.lua` (W3-owned; W1 has not touched it)
**Observed at:** server and full fleet on 1.9.34

---

## Observed

Repeating in the server log, once per save attempt:

```
saveJobs failed: /startup.lua:433: Out of space
```

The dispatch computer's disk is full. Every `saveJobs` call has been failing for
at least as long as the visible log window.

**`/startup.lua:433` is real code in this file.** `updater.lua:48` deploys
`central_server.lua` **as** `startup.lua` for the SERVER role, so the line number
maps directly. (`install.lua:39` writes it under its own name instead — see the
second defect below.) Line 433 is `fs.copy`.

## The defect

```lua
local f = fs.open("jobs.tmp", "w")            -- 425  succeeds
f.write(data); f.close()                      -- 427-428
if fs.exists(JOB_SAVE_FILE) then              -- 431
    if fs.exists(JOB_SAVE_FILE .. ".bak") then fs.delete(...) end   -- 432  backup DELETED
    fs.copy(JOB_SAVE_FILE, JOB_SAVE_FILE .. ".bak")                 -- 433  FAILS
    fs.delete(JOB_SAVE_FILE)                                        -- 434  never runs
end
fs.move("jobs.tmp", JOB_SAVE_FILE)                                  -- 437  never runs
```

The order is the problem. The backup is **deleted at 432**, and the replacement
copy **fails at 433** because `fs.copy` needs room for a second full copy of the
file. Nothing after 433 executes.

State after every failed save:

| File | State |
|---|---|
| `jobs.dat.bak` | **gone** — deleted at 432, never recreated |
| `jobs.dat` | stale — frozen at whenever the disk filled |
| `jobs.tmp` | orphaned, holding the data that should have been saved |

The comment above line 431 says the backup exists so *"a crash between delete and
move can't destroy both copies simultaneously."* On a full disk the sequence does
precisely what the backup was written to prevent. **The safety net is destroyed by
the exact failure it was designed to survive.**

## Why nothing has visibly broken yet

`saveJobs` is `pcall`-wrapped and only calls `logWarn` (line 438). Job creation,
dispatch and multi-miner operation are all in-memory and never touch the disk, so
jobs 0723/0724/0725 completed normally today with persistence dead the whole time.

This is the dangerous part of the shape: **the system is running with no
durability and no signal that says so** beyond one repeated log line.

## The reboot hazard

Do not restart this server until the disk is dealt with.

`loadJobs` restores any saved job carrying `assignedTo` as **`IN_PROGRESS`**
(line 464), and `jobs.dat` is stale. A restart would resurrect jobs that finished
hours ago, marked in progress, pinned to turtles that are now idle — reproducing
the deadlock in the companion report several times over.

It also restores `state.jobCounter` from the same stale file (line 457). The
counter is currently past `job_0726`; a rollback would reissue IDs that already
exist, and mining zone keys are derived from job IDs.

`loadJobs` falls back to `.bak` only when `jobs.dat` is *missing* (line 446) —
and `.bak` no longer exists, so there is no second copy to fall back to.

## Recommended fix

**One word: `fs.copy` → `fs.move` on line 433.**

```lua
if fs.exists(JOB_SAVE_FILE) then
    if fs.exists(JOB_SAVE_FILE .. ".bak") then fs.delete(JOB_SAVE_FILE .. ".bak") end
    -- move, not copy: a rename needs no additional space, so a nearly-full disk
    -- cannot leave us with neither a live file nor a backup. Observed 2026-08-22
    -- -- fs.copy failed here on a full disk AFTER line 432 had already deleted
    -- the only backup, and every save since left jobs.dat stale with no .bak.
    fs.move(JOB_SAVE_FILE, JOB_SAVE_FILE .. ".bak")
end
fs.move("jobs.tmp", JOB_SAVE_FILE)
```

`fs.delete(JOB_SAVE_FILE)` at 434 becomes redundant — the move consumes it.

This is strictly safer than the current sequence, not merely cheaper. The window
where only `.bak` exists is already handled by `loadJobs`'s fallback at line 446,
which the present code can never actually reach.

Two additions worth making in the same pass:

- **Check free space before writing** and log `disk full — job state not saved`
  rather than surfacing a line number from `fs`. Right now the message tells an
  operator nothing about what to do.
- **Surface it in `/state`.** A persistence failure is currently invisible unless
  someone reads the log ring at the right moment. W1 found this only while
  investigating an unrelated deadlock. One boolean would have made it obvious.

## Second defect: the server may hold two copies of itself

`central_server.lua` is **156,679 bytes**. Two installers write it to two
different names:

| Installer | Destination |
|---|---|
| `install.lua:39` | `central_server.lua` |
| `updater.lua:48` | `startup.lua` |

A machine that was installed and *later* updated therefore carries **both** — 306 KB
of identical code on a disk whose default `computer_space_limit` is 1 MB. Neither
installer removes the other's copy.

W1 cannot confirm this is the case on the live machine, only that nothing prevents it.
It is the first thing worth looking at.

## What W1 could not determine

What is actually consuming the disk. Accounted for: code ~194 KB for the SERVER
file set (~356 KB if duplicated), zone data ~17 KB measured across three zones
from `/state`, `jobs.dat` small (only PENDING/ASSIGNED/IN_PROGRESS are persisted,
per line 411), `crash.log` bounded by `CRASH_LOG_MAX_LINES` and trimmed at boot.
That does not add up to a full 1 MB disk, so something else is holding several
hundred KB.

There is no remote way to see it. The server console (`handleConsoleEnter`,
line 2135) implements `help`, `mine`, `job`, `stress`, `fueltest`, `recall`,
`update`, `jobs` — nothing for the filesystem. **A `disk` console command listing
file sizes and `fs.getFreeSpace` would have turned this into a five-second
answer**, and is probably worth adding regardless of what is found this time.

## Not part of this report

- **The stale-IDLE guard deadlock** — separate defect, same day, see
  `2026-08-22-W1-to-W3-idle-heartbeat-guard-starves-job-recovery.md`. The two are
  independent; they share only the property of failing silently.
- **The resource index storage budget.** §7.4 of the integration spec assumes the
  index gets a configured fraction of this disk, and the ore-index design sizes
  that at 512–640 KB. That assumption is falsified by a disk that is full before
  the index exists. Raised with the spec owner as an architectural question, not
  with W3 — it is not a dispatch defect.
