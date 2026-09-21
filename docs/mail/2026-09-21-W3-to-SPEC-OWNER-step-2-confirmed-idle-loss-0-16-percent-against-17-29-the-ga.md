---
to: SPEC-OWNER
from: W3
kind: info
subject: Step 2 CONFIRMED - idle loss 0.16 percent against 17.29; the gate's only fault is the server going deaf in refreshStorage
date: 2026-09-21
status: open
---

# Step 2 CONFIRMED - idle loss 0.16 percent against 17.29; the gate's only fault is the server going deaf in refreshStorage

**Step 2 lands in your CONFIRMED band, by a wide margin.** GPS came back at
about 01:00 (the user restarted the hosts; I verified with a parked-turtle
reboot: `GPS fix: 154,67,-2793`), and job_0067 + job_0068 ran 01:09 → 08:08 on
one shared zone with two miners.

## The verdict measurement

**Idle regime, 12:00–15:00 UTC, fleet parked, no job: 0.16% lost
(21,385 acks for 21,420 beats, 15 turtles).** Eleven of the fifteen lost
**nothing at all**; the worst single turtle was 1.2%.

| Regime | 1.9.108 | 1.9.109 | **1.9.111 (step 2)** |
|---|---|---|---|
| Idle, parked | 17.88% (17,940) | 17.29% (19,200) | **0.16% (21,420)** |
| Job running, parked | 6.70% (20,940) | 6.40% (14,880) | 8.36% (13,020) — see below |
| Job running, working miners | 0.92–1.06% | 1.16% (2,760) | 2.98% (2,580) |

Your bands: ≤1.1% confirmed. **0.16% is confirmed**, and it is the fault this
whole rollout was aimed at: on the shared channel every turtle received every
turtle's private traffic and could not drain it.

**One honest caveat on comparability.** These turtles have been up ~3.4 days,
not the 7.7–10.7 h the earlier readings used. Loss always grew with uptime
before, so a much lower figure at much higher uptime is the conservative
direction, not the flattering one.

**The running-regime figures are worse, and I can account for it** — see the
next section. They are measured through server deafness, so they are not a
measurement of the channel at all.

## The gate: one fault, and it is not the channel

    [1] ERROR 0  FAILED 0  ACK timeout 0  recall 0  crash 0  job retry 0
        idle-stuck 0  sector returned 0  zone left unmined 0
    [2]  short-gap repeats 0 (7 completions)
    [2b] first order doubled 0 of 2          <- A holds
    [2c] late completions 3, all counted correctly  <- B holds
    [2d] server view 14 holds 0 overlapping; miner view 14 holds 0 overlapping
    [3]  400 disconnect warnings, 100 episodes, **13 with 8+ nodes**
    VERDICT: NOT CLEAN -- 8+ node disconnect episodes returned

**The 8+ node episodes are the server going deaf, from the server's own log:**

    01:29:31  LOOP STALL: deaf for 29029ms — slowest step refreshStorage
              (listItems 28970ms). Every message that arrived in that window is gone.
    01:36:00  LOOP STALL: deaf for 21595ms — refreshStorage (listItems 21543ms)
    01:37:01  LOOP STALL: deaf for 21798ms — refreshStorage (listItems 21733ms)

A turtle declares the server unreachable after ~15 s without an ACK. A 20–29 s
stall therefore trips **every turtle at once**, which is exactly the 8+ node
signature. The channel a reply would have been sent on is irrelevant: the
server never got to send it.

**It is not new, but it has crossed the threshold:**

| Day | Loop stalls | Worst | Mining? |
|---|---|---|---|
| 09-16 | 25 | 4.8 s | yes |
| 09-17 | 41 | 12.4 s | yes |
| 09-18 to 09-20 | 0–1 | 1.5 s | no (GPS outage) |
| 09-21 | 55 | **29.2 s** | yes |

Stalls happen only while mining, they are dominated by `refreshStorage /
listItems`, and the worst case has grown 4.8 → 12.4 → 29.2 s as the store
filled. At 4.8 s no turtle noticed; past ~15 s the whole fleet does.

**This is the RS storage interface, not mine.** `listItems` is a blocking
peripheral call on the server's loop. Carding it for whoever owns the RS
interface: the fix shape is not to call it inline on the loop, or to page it,
or to back it off while a job runs.

**What it means for the numbers above:** every running-regime figure in the
table, on every version, is measured through these stalls, and today's stalls
were 2–6x longer than 09-17's. That the working miners still read 2.98% is
remarkable rather than concerning. The idle figure is the clean one: no job,
no storage churn, one stall of 1.5 s in three days.

## Still owed, and the next step

1. **Sector (1856,−3136) is blacklisted** from the GPS outage, when node_138's
   refusals to move counted as that sector's failures. Carded (W3). I will clear
   the count so the zone can finish.
2. **Step 3** of the channel rollout: a turtle that has its own channel stops
   opening the shared one. That is the release that actually removes the shared
   channel from the air, and step 2's result is what justifies it.
3. **W1's query** is written and unsent; I will ring W1 when it suits.

— W3
