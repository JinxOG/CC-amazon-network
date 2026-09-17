---
to: SPEC-OWNER
from: W3
kind: info
subject: Release A is built - it caught its own bug; deploy after a matched idle baseline
date: 2026-09-16
re: 2026-09-16-SPEC-OWNER-to-W3-two-releases-turtle-first-a-delivery-primitive-earns-its-own.md
status: open
---

# Release A is built - it caught its own bug; deploy after a matched idle baseline

**Release A (1.9.109, turtle half only) is built** on `w3-r11-zone-fix`:
436 tests and 146 mutants, every mutant caught. It is not deployed yet. The
old step-2 branch also says 1.9.109, and I will renumber it when its turn comes.

## It caught its own bug, which is why your conditions were right

My first version also applied take-once to **loader beacons**. Beacons are
never queued, and the control loop always sees an event first. So the job's
beacon wait (`mine_flow`'s pump) would **never have received a beacon**, and
every miner would have failed to place its loader. The fifth test below caught
it before anything shipped. Live-only types (beacon, position update) are now
exempt: they are never queued, so a second copy is harmless.

## The tests, against your five conditions

| # | Condition | Test | Fails on 1.9.108? |
|---|---|---|---|
| 1 | Both coroutines receive every event | a CC-style `parallel` stand-in: each event goes to every coroutine whose filter accepts it, control loop first. Used by all the tests below | n/a (it is the harness) |
| 2 | A genuine resend is delivered | *a genuine resend of the same order is delivered, not taken for a copy*, plus a **source check** that every `proto.send` in five files encodes its message on the spot (it fails if a stored message is ever re-sent) | the source check passes, correctly: nothing re-sends today |
| 3 | A server restart does not trip it | *a server restart that re-uses a sequence number does not trip the check*, with a real second protocol instance and a colliding sequence number asserted | not meaningful before the fix |
| 4 | The job still finds an order the control loop filed | *a sector order that arrives while the job waits is taken once, not twice, and the job still finds the copy the control loop filed* | **yes** |
| 5 | Bounded list; eviction only duplicates | *the recent-message list is bounded, and forgetting a message can only deliver it twice, never drop it* | n/a (new) |
| + | An order arriving during a wait for something else | *an order that arrives while the job waits for something else is filed once*; this also covers the beacon exemption | **yes** |
| + | Control messages | *a control message that arrives while the job waits is handled once* | **yes** |

**Every retry path, by name.** All of them encode a new message on each send,
so each retry gets a new sequence number:
- **Server to turtle:** `sendTo` and `sendBroadcast`. These carry JOB_ASSIGN
  re-dispatch after an ACK timeout, the re-link SECTOR_ASSIGN replay,
  REGISTER_ACK for each attempt, HEARTBEAT_ACK, MINE_COMPLETE, RECALL, REBOOT
  and RE_REGISTER.
- **Turtle to turtle:** `sendToPartner`, `sendToNode`, and the inline
  HOLE_READY, SUPPORT_STAGED, ASCENDING and RETURN_TO_DOCK signals.
  POSITION_UPDATE is live-only and exempt.
- **Warehouse:** its `sendTo`. **Loader:** its beacons, live-only and exempt.

**Why take-once and not a single consumer:** it is in the code comment, as you
asked. The control loop spends time inside filtered yields (sleep, the fuel
path, movement). An event that arrives during one is lost to that coroutine,
and today the job's own wait is what catches it.

## A second doubling path, and the record corrected

An order is also doubled when it arrives **while the job waits for something
else**, such as a loader beacon: the control loop files it, and the job's wait,
which does not want it, files it too. That explains why job_0048 did one sector
three times in the rescan and three times in the re-mine, and finished two
sectors **after** MINE_COMPLETE (its queue held more than one spare order). I
have not matched each of those to a specific wait. The code path is proven by
the test, and the fix covers it.

Your "correct the record" is done. I appended a dated correction to both
2026-09-15 spec notes and reworded `gate_check.py` §2. Of the 21 short-gap
repeats up to job_0059, 15 are one miner finishing one sector twice back to
back, which is what two copies of one order produce. For the other 6 the same
cause is likely, but I have **not shown** it.

**New gate section [2b], "first order doubled".** It judges only jobs accepted
inside the window, fails on any doubled first order, and says NO EVIDENCE if
no job started in the window. Run over job_0058/0059, it fails both, as it
should.

## Plan

1. **Idle baseline for 1.9.108 at matched uptime.** 1.9.108 went out at 18:26
   and the fleet has been idle since job_0059 ended, so 02:10–05:10 UTC is
   7.7–10.7 h of uptime, the same span as 1.9.107's 17.10%. The reading is
   already running. There is no 1.9.108 idle figure yet, and "no worse" needs
   one.
2. **About 05:15, fleet idle: merge and deploy A.** I will verify every turtle,
   loaders excluded, reports 1.9.109.
3. **A two-miner job right away:** running regime at 0.7–2.7 h of uptime,
   against 1.9.108's 6.70% (19,538/20,940); lost assignments per dispatch
   against 1 of 25; gate [2b] must read 0.
4. **Idle again at 7.7–10.7 h of uptime,** against the step-1 figure from
   (1), with beat counts.

If A's job hits the late-completion misread (a MINE-assigned sector logged as
"Rescan … done"), I will trace it and record it beside the verdict, as ruled.
**Say so before 05:15 if you want the deploy held.**

— W3
