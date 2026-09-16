---
to: SPEC-OWNER
from: W3
kind: request
subject: Step 2 would blind the in-world admin screen - and the obvious fix rejects live jobs
date: 2026-09-16
status: answered
---

# Step 2 would blind the in-world admin screen

Found while building step 2, before anything shipped. Step 1's job is running
cleanly; **step 2 is held** until you rule on this.

## What step 2 changes

`sendTo` — the only place the server transmits on `CH_PRIVATE` — sends to the
turtle's reported channel instead, falling back to `CH_PRIVATE` when there is
none.

## Who else listens on `CH_PRIVATE`

    admin_ui.lua:934       state.modem.open(proto.CH_PRIVATE)
    android_base.lua:59    { CH_BROADCAST, CH_PRIVATE }
    loader_turtle.lua:50   { ..., CH_PRIVATE, CH_LOCAL }

**Androids and loaders are fine.** Neither runs `turtle_base`, neither reports a
channel, so the fallback keeps serving them on `CH_PRIVATE`. That is the
report-and-fallback design doing its job.

**The admin screen is not fine.** It is an observer: it listens on `CH_PRIVATE`
to watch traffic addressed to *other* nodes. Of the types its `onMsg` handles,
two are server→turtle and go out through `sendTo`:

- **`JOB_ASSIGN`** — how its job page learns a job is ASSIGNED, to whom, its
  destination, its items and its start time.
- **`UPDATE_ALL`** — its update notice.

After step 2 those land on `1000 + id`, which the admin screen does not open. Its
job page stops updating, silently. The web dashboard is unaffected — it reads
`/state`, not the radio. The other types it handles (REGISTER, HEARTBEAT,
STATUS_UPDATE, JOB_COMPLETE, JOB_FAILED) are turtle→server on `CH_SERVER` and are
untouched.

No test would catch this. It is not in any file I own.

## The obvious fix is dangerous — verified, not assumed

"Also send a copy of those on `CH_PRIVATE` for observers" looks cheap, since
they are rare. **It is not safe.** In step 2 a turtle listens on *both* channels,
so it would receive `JOB_ASSIGN` twice. The second copy arrives while it is busy
with that very job:

    -- turtle_base.lua:2668
    elseif msg.type == proto.MSG.JOB_ASSIGN and _self.busy then
        comms.toServer(proto.MSG.JOB_ACK,
            proto.payloadJobAck(msg.payload.jobId, false, "busy"))

and the server acts on the refusal:

    -- jobQueue.acknowledge, not accepted
    logWarn("Job %s rejected by %s: %s")
    jobQueue.reassign(jobId, turtleId, "rejected")

**It takes the job away from the turtle that is doing it.** A double delivery of
`JOB_ASSIGN` would reassign live jobs. So whatever the answer, **nothing may be
mirrored onto `CH_PRIVATE` while turtles listen there** — and that stays true
until step 3.

## Options

**A. Accept it.** If the in-world admin screen is no longer relied on, its job
page going stale is a known, documented cost. Cheapest. I would card it so it is
not a surprise.

**B. The admin screen follows the turtles (recommended).** REGISTER already
carries `privateChannel` since step 1, and the admin screen already receives
every REGISTER on `CH_SERVER`. It can open each reported channel as it sees it —
fifteen channels, well under the modem's 128. Its load is the same as today: it
already receives every turtle's private traffic on the shared channel. No
protocol change, no server change, no double delivery. **But it is not my file** —
it needs its owner, and it has to ship before or with step 2.

**C. A dedicated observer channel.** The server mirrors the rare types
(`JOB_ASSIGN`, `UPDATE_ALL`) onto a new channel only observers open. Safe — never
`CH_PRIVATE` — and near-zero traffic, but it is a protocol change, and it would
need guarding so no turtle ever opens that channel.

## What I need

1. **Is the in-world admin screen still in use?** That decides A against B/C. I
   am asking the operator the same question directly.
2. **Who owns `admin_ui.lua`?** The board has no owner for it (the only related
   card, "admin computer sends no logs", is unassigned and deferred).
3. **If B**, whether its owner makes the change or you want me to, with your
   sign-off on touching a file that is not mine.

Meanwhile I will write step 2 itself — the `sendTo` switch and its tests — and
hold it unmerged. Step 1's job keeps running.

— W3
