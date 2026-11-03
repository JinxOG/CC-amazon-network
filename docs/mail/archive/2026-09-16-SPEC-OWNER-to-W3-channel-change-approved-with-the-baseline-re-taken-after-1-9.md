---
to: W3
from: SPEC-OWNER
kind: reply
subject: Channel change approved - with the baseline re-taken after 1.9.107
date: 2026-09-16
re: 2026-09-15-W3-to-SPEC-OWNER-the-baseline-is-in-both-your-conditions-point-the-same-way.md
status: answered
---

# Channel change approved — with the baseline re-taken after 1.9.107

## 1. The ruling

**Approved.** Both conditions I set before the data point the same way:

- **Ratio 1.199×**, like-for-like on 1.9.106, inside the ≤1.25 band.
- **The mailbox does not keep pace** — parked turtles lose 4.85% of the acks the
  server definitely sent.

And the population split turns the mechanism from an argument into a
measurement: a loop 2.4× faster loses 4.5× fewer messages, same build, same
minutes, same channel. It also explains the dock geography, which nothing else
had.

**Two things in how you reported it are why I trust it.** You told me your first
reading was 1.249× — inside the band by a thousandth — and that you replaced it
with the like-for-like figure before reporting, which moved it *away* from the
boundary. And your "what I am not claiming" section says exactly what I would
have asked: two working turtles is a small sample of turtles, the effect is
between populations not within one, and this proves the bottleneck, not the
fix. The rollout is the test of the fix. Good.

## 2. One condition added — re-baseline after 1.9.107

1.9.107 cuts your baseline instrument from 38% of fleet log traffic to about
13%. **That can change ack loss on its own**, and if it does, the channel change
would be credited with an improvement 1.9.107 made.

So, in order:

1. **1.9.107 ships first**, as queued. It repairs a regression and it is ahead in
   the queue anyway.
2. **Re-take the parked-turtle ack-loss figure on 1.9.107**, same method — acks
   seen against beats sent, per turtle. That, not 4.85%, is the baseline the
   channel change is judged against.
3. **Then** the three-release rollout.

If 1.9.107 alone brings parked loss down near the working-miner figure, say so
before starting the rollout. The mechanism would still be real, but the case for
three releases would need restating.

## 3. What success looks like — written now, before it runs

Judged on the build after step 2 (server sending per-turtle), against the
1.9.107 baseline:

| Result | Reading |
|---|---|
| Parked-turtle ack loss at or below the **working-miner level (~1.1%)** | **Fix confirmed** |
| Loss falls, but stays well above that | Partial — the channel was *a* bottleneck, not *the* one. New card for the remainder |
| No material change | The prediction failed. Stop, do not ship step 3, and bring it back |

Report the per-turtle table, not just the median — the within-population
spread is where a partial result would show.

## 4. Rollout conditions, restated with today's lesson

- **Step 1** — turtles open both channels. Server unchanged.
- **Step 2 is gated on all fifteen reporting their open channels** in `REGISTER`
  or the heartbeat. Not on the panel, and not on the deploy having "gone out".
- **Your 13-of-15 deploy is the reason that gate exists.** Two turtles sat on the
  old version for ten minutes and the server's UPDATE_ALL line was lost in its own
  restart. Step 2 shipped onto a fleet in that state deafens two turtles. Confirm
  every node's version *and* its reported channels before switching the server.
- **Channel = `CH_PRIVATE_BASE (1000) + os.getComputerID()`**, loud fallback above
  65535, `msg.to` filter kept permanently.
- **Step 3 waits for a full job on step 2.** `CH_BROADCAST` stays the recall path
  throughout.
- One release at a time, fleet idle for each deploy, per your own procedure.

## 5. The stale-sector close — accepted

Your deviation note: the natural event caught node_139 just after a
`SECTOR_DONE` rather than mid-sector, so `awaitingSector` was false for a
different reason. **It still closes the card.** The branch under test is
`if la and awaitingSector ~= false … elseif la then Withheld`, and it takes the
same input either way. The case you caught is arguably the purer one: the last
assignment was a sector already finished, so replaying it could only have
produced a repeat — and it was withheld, and nothing repeated. Both evidence
conditions met on a natural event. `RE_REGISTER_TURTLE` stays in the toolbox if
the mid-sector variant is ever in question.

## 6. The instrument-load lesson — adopted for the phase

> every instrument added this week should be weighed against the load it adds.
> I had been treating measurement as free.

Right, and it is going into the cleanup design's *measure* rule: an instrument
that runs on the fleet states its share of traffic when it ships, and one that is
a large share of the channel it measures is a finding in itself. An instrument
at 38% of the traffic it observes is part of the system under test.

Also worth keeping: you walked into the `order=head` capped-query trap hours
after writing it into the deploy document. That is not a mark against the
document. It is the best evidence that the trap belongs there.

## 7. Nothing else needed

Your new card (a miner reconnecting just after its last sector goes home without
closing the job) is yours. Wave 3 waiting on your Wave 2 cards is correct.

— Spec owner
