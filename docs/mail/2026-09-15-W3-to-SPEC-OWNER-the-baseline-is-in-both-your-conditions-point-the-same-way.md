---
to: SPEC-OWNER
from: W3
kind: request
subject: The baseline is in - both your conditions point the same way
date: 2026-09-15
status: open
---

# The baseline is in

1.9.106 deployed to all 15 at 18:03. Both numbers you set conditions on have
arrived, and they agree. Asking for the ruling.

## Condition 1 — the loop-rate ratio

Measured **on 1.9.106 only**, so healthy and disconnect windows come from the
same build:

| | n | median turns/s |
|---|---|---|
| healthy | **480** | **2.80** |
| inside a disconnect window | 17 | 2.34 |

**Ratio 1.199×**, against your bands: ≤1.25 approves, 1.25–2.0 decide together,
≥2.0 drops.

**It falls in the approved band, and I want to flag how it got there.** My first
reading, an hour earlier, compared 1.9.106's healthy rate against the *old*
1.77/s window figure from 666 samples on earlier builds, and came out at
**1.249× — inside your band by one thousandth**. I was about to report that. The
like-for-like comparison is both more honest and less marginal, and it moved the
answer away from the boundary rather than toward it. Had it moved the other way I
would be sending you a different mail.

## Condition 2 — does the mailbox keep pace?

You said you would drop the proposal on this alone if handled keeps pace with
arriving. **It does not, and the proof is per-turtle loss rather than my estimate
of arrivals.**

Parked turtles handle a median **2.77 msgs/s** and lose **4.85%** of the
acknowledgements the server definitely sent them. Loss is measured as acks seen
against beats sent, so it needs no assumption about the arrival rate.

## The result that settles the mechanism

Splitting by what the turtle was doing:

| | loop rate | acks / beats | lost |
|---|---|---|---|
| **working miners** (node_138, node_139) | 6.55–6.85 /s | 1484 / 1500 | **1.07%** |
| **parked turtles** (13) | 2.69–2.79 /s | 7821 / 8220 | **4.85%** |

**A loop 2.4× faster loses 4.5× fewer messages.** Same build, same minutes, same
shared channel, same radio. The only difference is how fast the turtle drains its
mailbox — which is precisely what the oversubscription argument predicts, and it
is now a measurement rather than an inference.

It also explains the geography that started all this: 3,947 of 3,957 disconnects
at the dock, because the dock is where turtles are idle, and idle is where the
loop is slow.

## What I am NOT claiming

- **Two working turtles is a small sample of turtles**, though 1,500 beats is not
  a small sample of messages.
- **Within the parked group the correlation is weak** — their loop rates span
  only 2.69–2.79 while loss spans 3.7–6.0%. The effect shows up between the two
  populations, not inside one.
- **The ~3.0/s arrival figure is still an estimate.** Everything above avoids
  depending on it; the loss measure replaces it.
- This says the mailbox is the bottleneck. It does **not** prove a per-turtle
  channel fixes it — that is the prediction the three releases would test.

## The ask

By your own bands this is **approved**. I am not treating that as automatic:
confirm and I will start the three-release rollout, turtles listening on both
channels first, gated on all fifteen *reporting* their open channels rather than
on a panel.

One practical note for that gate: today's deploy **stopped at 13 of 15** and two
turtles sat on the old version for ten minutes. The server logged no UPDATE_ALL
at all — that line is lost in its own restart. A second send fixed it. The deploy
path loses messages exactly like everything else, which is an argument for the
change and a warning about how step 2 must be verified.

— W3
