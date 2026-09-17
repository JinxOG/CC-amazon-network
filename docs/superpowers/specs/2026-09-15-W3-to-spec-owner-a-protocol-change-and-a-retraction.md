# W3 → spec owner: a protocol change to rule on, and a number to retract

**Date:** 2026-09-15
**Asks for:** two rulings and one correction on the record.

I published four memos yesterday about the disconnect blocker. Re-reading them, I
buried the one thing that actually needs your decision inside a memo addressed to
everybody, and I let a wrong number stand in a place you read. Both fixed here.

---

## 1. RETRACTION: the "15 stale replays across 11 jobs" figure is wrong

It was on the stale-sector card. **Do not use it.** It counted repeated sector
completions, which are not the same thing as stale replays.

A stale replay only reaches a **reconnecting** miner — the server resends the
last `SECTOR_ASSIGN` on re-link, it waits in the inbox, and is popped after the
next `SECTOR_DONE`. A re-registration is the mechanism's precondition.

Checked across eight days: of **16** short-gap repeated completions, **zero** had
a re-registration within about one sector's work before the first completion.
job_0051's repeat was **746 minutes** from any re-link, and node_139 logged zero
disconnects for the whole job. So bare repeats have some other, ordinary cause.

**How I got it wrong, because the method matters more than the number.** I
"validated" the detector by confirming it fired on jobs 0039–0042, which W6
traced as containing replays. That proves nothing: firing *somewhere inside* a
job that contains the bug is not firing *on* the bug. It is the same error this
project keeps making — a check that cannot distinguish its pass state from its
no-data state.

What survives: six repeats across jobs 0040/0041/0043/0044/0048 have a re-link
40–58 minutes before the first completion, consistent with the mechanism. Those
are candidates, not confirmations.

**Consequence for 1.9.104:** it is deployed and unvalidated, and *no clean run
can validate it*. Closing it needs a miner that re-registers mid-sector with no
repeat following — and working miners are the population least affected by
disconnects. Waiting may take a long time. **Ruling wanted:** is it acceptable to
force one — deliberately interrupt a miner mid-sector — or should this sit open
until it happens naturally?

---

## 2. DECISION WANTED: a per-turtle private channel

This is the candidate fix for the gate blocker and it is a **protocol change**,
so it is yours to rule on rather than mine to ship.

**The finding.** Every private reply the server sends — every `HEARTBEAT_ACK` —
goes out on the single shared `CH_PRIVATE`. Each turtle opens it and keeps only
what matches its own id, so **every turtle receives all fifteen turtles' private
traffic and discards fourteen fifteenths of it**: 3.0 inbound messages per second
per turtle as a floor. The control loop handles one event per iteration.

Direction is settled, 19 of 19: the server's `lastSeen` advanced at wallclock
rate through every window a turtle spent declaring the server gone, with
re-registration excluded in all 19. **The server hears every beat; the reply is
what is lost.**

**The proposal.** Make `CH_PRIVATE` a base plus the turtle's index. Inbound drops
about fifteenfold. Keep the `msg.to` filter as a backstop. It also fixes scaling:
the shared design degrades quadratically with fleet size, which is why this was
invisible at five turtles and bites at fifteen — and why it will bite harder if
the scaling-to-150 work ever unfreezes.

**It cannot ship in one release.** The server must not transmit on the new
channel before every turtle listens on it, or the fleet goes deaf — the same
shape as the OTA trap that cost us the 1.9.94 outage:

1. Turtles open **both** channels. Server unchanged. Deploy, confirm all fifteen.
2. Server switches `sendTo`. Deploy.
3. Later, turtles stop opening the shared one.

That is three releases and, at one job per release, the better part of a day.

**What I am NOT asking you to approve yet.** The evidence has a hole I own: the
loop-rate figure behind "the turtle cannot keep up" is sampled *only* from
windows where ACKs were already being lost, because that is the only place the
witness reports it. If the loop normally runs fast and merely sags in those
windows, the channel arithmetic is a red herring and this change is wasted work.

**1.9.106 closes that hole** — it makes turtles report their loop rate while
healthy. It is built, green (409 tests, 108 mutants), and queued.

So the ruling I want is conditional: **if the healthy baseline comes back near
the disconnect-window figure, do you want the three-release channel change?** If
it comes back much higher, I will drop the proposal myself and say so.

---

## 3. Still open from yesterday

The release-order question (`2026-09-14-W3-to-spec-owner-a-release-order-question.md`).
1.9.105 has since deployed, so the queue is now just **1.9.106** and the question
is moot — it goes next either way. No answer needed.

— W3

---

**Correction, 2026-09-17 (W3).** The claim above that bare short-gap repeats are
normal, and come from "the post-rescan re-mine pass", is withdrawn. Up to 1.9.108
a miner could hold **two copies of one sector order**: both turtle loops (control
and job) received each radio message, and both filed it. The miner's first order
was always doubled (its first sector reported done twice in 21 of 22 jobs,
job_0037 to job_0059), and an order that arrived while the job was waiting for
something else was doubled too. Of the 21 short-gap repeats in the log up to
job_0059, **15 are one miner finishing one sector twice back to back**, which is
what two copies of one order produce. That the other 6 have the same cause is
likely but **not shown**. Fixed in 1.9.109 (release A, not yet deployed when this was written); `tools/gate_check.py`
section [2b] now counts doubled first orders and fails the gate on any.
See `docs/mail/2026-09-16-W3-to-SPEC-OWNER-found-the-double-issue-every-miner-holds-a-spare-copy-of-its.md`.
