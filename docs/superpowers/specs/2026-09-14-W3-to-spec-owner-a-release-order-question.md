# W3 → spec owner: should the baseline jump the queue?

**Date:** 2026-09-14
**Asks for:** a ruling. I am proceeding in the order you set unless you say otherwise.

## The situation

Your release ruling put the crash handlers next. Since then a new release exists
that did not when you ruled: **1.9.106, the loop-rate baseline** — built today,
permitted under the freeze as §3.1 "measures something the §7 gate needs".

Current queue, both green on master:

| | release | what it is |
|---|---|---|
| next | **1.9.105** | delivery and support send their last log lines; delivery reboots after a crash |
| after | **1.9.106** | turtles report loop turns/sec while healthy |

## Why the order now costs something

The release rule is one fleet update in flight, each cleared by a complete mining
job with no new fault. A job is running about six hours. So the order decides
whether the baseline reaches the fleet in roughly six hours or roughly twelve.

That matters because **1.9.106 is the measurement that decides whether my
mechanism for the gate blocker is right or wrong.** Today's finding — every
private reply rides one shared channel, so each turtle receives fifteen times the
traffic it wants against a loop measured at 1.77 turns/second — rests on a number
sampled only from windows where ACKs were already being lost. Until there is a
healthy sample to compare against, "the loop is too slow" and "the loop sags when
something else goes wrong" fit equally, and they need different fixes. I am not
willing to propose the channel change on the current evidence.

Against that, 1.9.105 is a robustness improvement with **no live fault pending**:
the last recorded crash was 2026-09-06, eight days ago. It makes a future crash
easier to diagnose. It is not answering an open question.

## What I recommend, and how strongly

Swap them: **1.9.106 first, 1.9.105 second.** It buys about six hours on the one
item blocking the gate, and costs nothing except delaying a diagnostic aid for a
fault that is not currently occurring.

I hold this lightly. If you would rather not reshuffle a queue you already ruled
on — or if there is a reason the crash handlers should land before more turtles
are rebooted by another deploy — say so and I will run it as ruled. **Default if
you do not answer: I proceed in your original order**, 1.9.105 next.

## Status of both

- **1.9.105** — 404 tests, 101 mutants, all killed. Signed off by you already.
- **1.9.106** — 409 tests, 108 mutants, all killed. Five behavioural tests plus a
  source check that the baseline is gated on `serverDown`, so a "healthy" sample
  cannot be taken from the exact population it exists to be compared against.

— W3
