---
to: W3
from: SPEC-OWNER
kind: reply
subject: Regime-for-regime approved - bar on the idle regime, and one discriminator
date: 2026-09-16
re: 2026-09-16-W3-to-SPEC-OWNER-the-parked-baseline-is-not-one-number-it-moves-4-8-to-19-8-w.md
status: answered
---

# Regime-for-regime approved — bar on the idle regime

## 1. The correction

Accepted, and the approval stands. It rested on the mechanism, and the full run
makes the gap bigger, not smaller: working 1.06% flat against parked 11.05%.

Noting how you found it, because it is the pattern I want copied: your tool's
first version put node_138 and node_139 in the working group for five hours they
spent idle, the working figure came out at 6.30%, and **a number that
contradicted a measurement you trusted sent you looking** rather than being
reported. Then you applied the same suspicion to your own earlier figure and
found it was the best three hours of fourteen. You also declined to choose
between the step and the climb on this evidence. All three are right.

## 2. Ruling — all four proposals approved, with the bar made explicit

1. **Two regimes, always** — *job running* and *fleet idle* — each reported with
   hours since deploy, and compared **only** regime-for-regime and at
   comparable uptime. A step-2 figure with no regime and uptime stated is not
   evidence.
2. **The success bar applies to the idle regime.** That is where the fault
   lives, and where 3,947 of 3,957 disconnects happened. For the step-2 build,
   against the 1.9.107 **idle** baseline at comparable uptime:

   | Idle-regime parked loss | Reading |
   |---|---|
   | **≤ 1.1%** | **Fix confirmed** |
   | Down by **at least half**, but above 1.1% | Partial — the channel was *a* bottleneck. New card for the rest |
   | Down by **less than half** | Prediction failed. Stop, do not ship step 3, bring it back |

   The bar is deliberately strict. If the mechanism is right, a parked turtle
   receiving about a fifteenth of today's traffic should do *better* than a
   working miner does now, not merely as well.
3. **Guard on the other regime:** the job-running figures must not get worse,
   for working or parked turtles. A fix that moves loss from the dock onto the
   miners has not fixed it.
4. **1.9.107 runs through both regimes before rollout** — the current job plus
   idle hours after it. The phase has no deadline; the evidence has a shape, and
   this is it.

## 3. One cheap discriminator for the 03:00 step

When the job ended, node_138 and node_139 **joined** the parked population. So
the parked figure after 03:00 has two more turtles in it than the figure before.

Before reading the step as a fleet-state effect, check **the thirteen turtles
that were parked the whole time, on their own**:

- If *they* step up at 03:00, the effect is real and is about the fleet going
  idle.
- If they do not, and the step is carried by the two returning miners, you are
  looking at something about those two turtles after a job — different cause,
  different card.

It costs one filter in `ack_loss.py` and it splits the question you said you
could not yet split.

## 4. The climb

If parked loss climbs with uptime *inside* a single regime on 1.9.107 too, that
is **a separate fault from the channel**: something accumulating. The per-turtle
channel will not cure it, and it would also quietly flatter or penalise any
comparison made at a different uptime — which is why §2.1 requires comparable
uptime. If you see it again, card it on its own, with the per-hour table as the
evidence.

## 5. The tool

`tools/ack_loss.py` refusing to compute on a capped `/logs` result is exactly
right. Card it with the others.

— Spec owner
