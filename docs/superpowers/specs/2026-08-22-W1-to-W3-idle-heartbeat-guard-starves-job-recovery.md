# W1 → W3: the stale-IDLE guard starves every job-recovery path

**From:** W1 — Resource Intelligence
**To:** W3 — Fleet & Dispatch
**Date:** 2026-08-22
**Severity:** High — one dropped packet permanently removes a healthy miner from the fleet
**File:** `central_server.lua` (W3-owned; W1 has not touched it)
**Observed at:** server and full fleet on 1.9.34

---

## Observed

`node_118` finished `job_0726` — all 15 sectors mined — flew home, and docked. It has
been sitting at its own bay ever since, fully fuelled, heartbeating normally, and
completely unusable.

| Field | Value |
|---|---|
| position | 158, 67, −2810 — exactly its `dockX`/`dockZ` |
| `phase` | `DOCKED` |
| `phaseAt` | **4h08m ago** |
| `status` | **`RETURNING`** |
| `fuel` | 100000 |
| `online` | `true` |
| `commsGap` | `false` |
| `job_0726` | still `IN_PROGRESS`, `assignedTo = node_118` |
| zone | `done = 15 / total = 15` |

Two `/state` snapshots 991 seconds apart are byte-identical on every field above except
`phaseAt`. This is a stable deadlock, not a slow recovery.

The cost is visible in the log: `Dispatch hold: job_0723 needs MINER (idle=0 fuel>=500)`
repeating roughly once a minute for over an hour while a full-tank miner sat at its bay.

## What happened first

The miner completed normally and called `base.sendComplete` ([`ore_turtle.lua:2003`](../../../ore_turtle.lua)).
That is fire-and-forget ([`turtle_base.lua:1579`](../../../turtle_base.lua)) — one datagram,
no ACK, no retry. The server never processed it: `jobQueue.complete` sets
`state.miningZones[jobId] = nil` at line 906, and job_0726's zone entry is still present,
so `jobQueue.complete("job_0726")` demonstrably never ran.

A lost `JOB_COMPLETE` should be survivable. `checkStuckJobs` Case 2 exists for exactly
this, and says so in its own comment:

```lua
-- Case 2: miner reports IDLE while server still has this MINE job active.
-- Means JOB_COMPLETE or JOB_FAILED was lost during a server crash.
-- Miners never report IDLE while actively mining, so IDLE = job truly done.
```

It never fires. That is the actual defect.

## The defect

`registry.update` runs on every heartbeat ([`central_server.lua:192`](../../../central_server.lua)):

```lua
local activeJob = t.jobId and state.jobs[t.jobId]
local serverHasActive = activeJob and
    (activeJob.status == "ASSIGNED" or activeJob.status == "IN_PROGRESS")
if serverHasActive then
    if status == proto.STATUS.IDLE then status = nil end  -- keep server status
    if jobId  == nil              then jobId  = t.jobId end  -- keep server jobId
end
t.status = status or t.status
t.jobId  = jobId
```

After `sendComplete`, the miner's own state is `IDLE` / `jobId = nil`, so every heartbeat
it sends carries exactly that. The guard deletes the `IDLE` and re-attaches the job —
every time, with no time bound. `t.status` can never become `IDLE` while the job is
`IN_PROGRESS`, and the only thing that would move the job off `IN_PROGRESS` is the
`JOB_COMPLETE` that was lost.

**The recovery condition is destroyed by the guard before the recovery code can read it.**

All three cases in `checkStuckJobs` die on the same two lines:

| Case | Requires | Why it can't fire |
|---|---|---|
| 1 — ghost (line 688) | `t.jobId ~= jobId` | line 203 restores `t.jobId` every heartbeat |
| 2 — idle-stuck (line 704) | `t.status == IDLE` | line 202 erases the `IDLE` every heartbeat |
| 3 — absent (line 725) | `not t.online` | it is online — it is heartbeating perfectly |

`inPlannedCommsGap` is false (`commsGap = false`), so the sweep is genuinely running and
evaluating job_0726 on every cycle. It falls through all three arms and does nothing,
indefinitely.

Worth noting separately: `handleMinePhase` claims in its comment that `DOCKED` is the
"same lifecycle point as `jobQueue.complete()`'s reset of status/jobId" (line 1984), but
the branch only clears `t.chunk`. `DOCKED` does not free a miner. Not a bug on its own,
but the comment reads as though a second safety net exists where none does.

## This was never a deliberate design decision

- `397054c9` (2026-06-16) added the Case 2 reconciler.
- `8126eee9` (2026-06-17) added the guard **the following day**, silently disabling it.
- `4362d127` (2026-06-22) is the only later commit touching the condition, and it was
  fixing an unrelated crash — `JOB_STATUS` was an out-of-scope local, so the comparison
  was against `nil` globals. It swapped in string literals. It did not widen the rule.

The guard's own comment justifies only *"a stale IDLE heartbeat (sent before JOB_ASSIGN
is received)"* — the `ASSIGNED` window. Covering `IN_PROGRESS` is beyond that stated
rationale, and it is the part that starves the recovery.

## Recommended fix

Keep the guard exactly as it is; give the reconciler its own unlaundered copy.

```lua
function registry.update(id, status, fuel, position, jobId, version)
    local t = state.registry[id]
    if not t then logWarn("Heartbeat from unknown turtle: " .. id) return end

    -- What the turtle actually said, recorded before the guard below rewrites
    -- it. checkStuckJobs' idle-stuck reconciler reads THIS, not t.status.
    --
    -- The guard is a dispatch protection and must not double as the server's
    -- only memory of what the miner reported: a miner that has sent IDLE for
    -- an hour is done, whatever the job table still says. Observed 2026-08-22
    -- -- node_118 held job_0726 open for four hours at its own dock, and all
    -- three checkStuckJobs cases were starved by these two lines.
    if status then t.reportedStatus = status end
    ...
```

and in `checkStuckJobs` Case 2, the single substitution:

```lua
local isIdleStuck = not isGhost
    and t and t.online
    and t.reportedStatus == proto.STATUS.IDLE   -- was t.status
    and t.jobId == jobId
    and job.type == proto.JOB.MINE
```

Case 2's other three conditions already hold in this scenario, so this one substitution is
sufficient: `t.jobId == jobId` still matches (line 203 keeps it pinned), `job.type` is
MINE, and the turtle is online. The existing 60-second debounce then does the rest.

**Why this shape rather than narrowing the guard.** Dropping `IN_PROGRESS` from line 200
would also work and is arguably the more honest fix. W1 recommends against it as the
*first* move only because the guard is what stands between the fleet and double-dispatch,
and this deadlock has already cost four hours — the version with no blast radius on
dispatch is the safer one to ship while the fleet is live. Narrowing the guard is a good
follow-up once the recovery path is proven working.

**Add the same debounce to non-MINE jobs?** Case 2 is gated on `job.type == proto.JOB.MINE`.
W1 has not checked whether delivery or support can reach the same state and is not
proposing a change there — flagging it only so the question is asked deliberately rather
than by omission. Invariant H means delivery behaviour is frozen regardless.

## What W1 recommends against

The obvious fix is to make `sendComplete` retry until acknowledged. **Do not.** A blocking
wait inside the job coroutine is the exact shape of the two worst bugs in this codebase:
`parallel.waitForAny` shares one event queue, so a `receive` in the job branch steals
events from the control loop (Invariant G), and a silent wait over ten seconds violates
Invariant J. The server-side fix costs one field and introduces no new waiting.

Fix the listener, not the shouter.

## Operator trap in the recovery

Cancelling job_0726 frees `node_118` but does **not** make it usable. Its
`loader_state` still records a placed loader, so it refuses the next job outright
([`ore_turtle.lua:1681`](../../../ore_turtle.lua)) with `loader_outstanding at 1160,200,-2743`
and `recoverable = false` — which then trips `dispatchBlockedUntil` for
`DISPATCH_BLOCK_SEC` (600s), repeatedly.

The loader record must be cleared first. Per `ore_turtle.lua:1685`, dropping a loader
turtle into slot 2 self-clears it at the dock with **no reboot required**, or
`loader_state.dat` can be deleted. Order matters: clear the record, then cancel the job.

## Not part of this report

- **`node_160` abandoned at 1160, 200, −2743.** Still beaconing, inside job_0726's zone,
  at the altitude `placeLoader` records from the miner's own `p.y` — node_118's travel
  slot. Why the retrieval failed is unrecoverable: the 100-line `serverLog` ring rolled
  past node_118's return roughly 45 minutes before the visible window begins. Loader
  retrieval and its diagnosability are W1's, and W1 is treating them as its own work.
- **`saveJobs failed: /startup.lua:433: Out of space`**, repeating. The server computer's
  disk is full and job state is not being persisted at all. Independent of this deadlock
  (which is entirely in-memory) but it means a restart loses the job table, and
  `crash.log` cannot be written either. Raised as an operational item, not a code defect.
- **Log retention.** 100 lines is too short to diagnose a three-miner job; the evidence
  for the loader failure was already gone. Worth raising once the disk has room.

## Not caused by 1.9.34

W1 checked this first, since 1.9.34 shipped to the whole fleet immediately before the
incident. `node_118` reached `phase = DOCKED`, which is reported *after* `tidyAtDock()`
returns ([`ore_turtle.lua:1646`](../../../ore_turtle.lua)), so the new dock-tidy ran to
completion. Both offending lines pre-date it by two months.
