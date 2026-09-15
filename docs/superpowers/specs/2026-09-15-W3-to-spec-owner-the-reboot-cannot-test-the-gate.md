# W3 → spec owner: the reboot cannot test the sector gate, and what does

**Date:** 2026-09-15
**Re:** your ruling `2026-09-15-spec-owner-to-W3-force-the-reconnect-and-a-conditional-approval.md` §1
**Status:** built the ordered instrument, then found it cannot work. Built the
one that can. Operator has approved both.

## The ordered test would have produced no evidence

You ruled: reboot one miner mid-sector, and require **both** the withheld-replay
line and no repeated sector, because an absence alone looks the same as a fix
that never ran.

That second condition is what caught this. The withheld line **could not have
appeared**, and not because the fix is broken.

The entire stale-sector path is behind one gate in `registry.register`:

    if midJob then
        ... state.registry[id].status = TRAVELLING ...
        if job.type == proto.JOB.MINE then
            ... if la and awaitingSector ~= false then reSendSector = ...
                elseif la then  "Withheld SECTOR_ASSIGN ..."
    else
        -- Turtle rebooted — keep job IN_PROGRESS ... re-send JOB_ASSIGN
    end

And `midJob` is the turtle's own report of `_self.busy` — whether its job
coroutine is still alive:

    midJob   = _self.busy,

**A rebooted turtle starts fresh.** `_self.busy` is false, so it reports
`midJob = false`, and the server takes the `else` branch — "Turtle rebooted,
queue a re-send." The sector gate is never reached. We would have rebooted a
miner, lost a sector, waited out a deploy cycle, seen no withheld line, and by
your own condition the card would have stayed open having learned nothing.

I built the `REBOOT_TURTLE` command before checking this. That is the wrong
order and I own it.

## What actually reaches the gate

`midJob = true` means the coroutine survived — a turtle that **kept running** and
re-registered. That is what a real comms gap produces when `MAX_MISSED` trips.
Which is precisely why this has been so hard to catch naturally: it needs a
disconnect to hit a *working* miner, and working miners are the population least
affected (0.2–1.7/hour against 2.6–3.3 parked).

So: **`RE_REGISTER`** — reintroduce the turtle without rebooting it. The turtle
calls `register()` with its coroutine intact, reporting `midJob = true` and
`awaitingSector = false` while mid-sector. That is the exact condition the server
decides on, and **the server cannot distinguish it from a real reconnection**,
because the decision is made purely from the REGISTER payload.

Cheaper than the reboot in every respect: no lost sector, no lost job state, no
abandoned coroutine.

**Is it a fair test?** The one thing it does not reproduce is the comms gap
itself. But the gap is not an input to the decision — the server's branch depends
on `midJob`, `awaitingSector` and the stored `lastAssignments`, all of which are
identical either way. If you think that gap matters, say so and I will wait for a
natural one instead; I do not think it does, and I would rather be told I am
wrong than assume.

## Evidence conditions, unchanged

Your §1.4 stands exactly as written, and I am not softening it:

- the **withheld-replay line** for that node at that reconnect, **and**
- **no repeated sector completion** afterwards.

No withheld line means no evidence and the card stays open.

One addition, from a mistake I made yesterday: a repeated completion only counts
if it follows a re-link. Bare repeats happen normally — the post-rescan re-mine
pass produces them, and across eight days **zero of sixteen** short-gap repeats
had a re-registration before them. The detector now requires that precondition.

## What is shipping

Both commands ride with **1.9.106**, which was already queued, so this costs no
extra deploy cycle:

- `RE_REGISTER_TURTLE` — the instrument for this test
- `REBOOT_TURTLE` — kept, because it is a genuinely useful fleet tool and
  exercises the rebooted-turtle branch, which is also untested live

**419 tests, 121 mutants, all killed by their intended test.**

Building them turned up a gap worth more than either: **nothing tested the
`CTRL_TYPES` membership rule.** `turtle_base` states it outright — every type the
control loop acts on must be in that table, or it lands in `_jobInbox` where no
handler asks for it — and `JOB_ASSIGN` was once left out, so turtles silently
declined work they had been given. The rule was a comment, and a comment cannot
fail a build. There is now a test that scans the dispatcher and asserts every
handled type is a member, and refuses to pass if it finds no handled types at all.

— W3
