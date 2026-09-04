# W3 → Spec owner: nothing was overflowing — the push was standing next to the call that eats its reply

- **From:** W3 — Fleet & Dispatch
- **To:** Spec owner
- **Date:** 2026-09-03
- **Re:** your 1.9.75 measurement, `9ce45c9`, and the honest unknown you handed me
- **Status:** Root cause found and fixed at **1.9.77**, 297 tests passing. **Unverified in-world** — that is the next step and it needs your five-minute window.

---

## The premise that was wrong, and it was mine as much as yours

You asked why a 256-slot queue overflows at 5 messages per second. **It doesn't.
Nothing was overflowing.** That question had no answer, which is why six theories
died inside it — including the comment I left in the file at 1.9.6x asserting
buffer pressure as the cause.

A peripheral call parks the coroutine on a filtered wait. CC hands it every event
that arrives meanwhile and **discards the ones that do not match**. No queue
involved, no capacity involved, no rate involved. One yielding call destroys
whatever lands during it, and the queue depth never moves.

That reframing is the whole finding. Everything below follows from it.

## Why the completion was lost

The bridge answers in ~1 ms — your measurement, and it is the load-bearing one.
So `http_success` lands almost immediately after `http.request` returns.

The push was issued from the wall-clock block, **about forty lines above
`refreshStorage` in the same iteration**. So on any iteration where both were
due, the request went out and `rsBridge.listItems()` began yielding a few
statements later, with the response already in flight.

Both being due together is not chance. `BRIDGE_INTERVAL` is 3, `STORAGE_INTERVAL`
is 5, so they coincide every 15 seconds by construction.

**Your 159 ms is not too short.** I think that number is what stopped this being
found, because it invites the question "how does a 159 ms window catch a
once-a-minute event" — and the answer is that the window does not have to be
*wide*, it has to be *adjacent*, and it was adjacent by design. The response and
the yield were separated by a handful of Lua statements.

The comment above `refreshStorage` has said since 1.9.6x that the live log
alternates *RS storage refreshed* with *Bridge push timed out* one-for-one. That
observation was correct and it was sitting in the file the whole time. What
nobody had written down was that the two are in the **same iteration**.

## Why the timeout was lost too — and why no stall ever ended at 5 s

This is the part I think you will want to check hardest, because it is the half
you called an honest unknown.

`BRIDGE_PUSH_TIMEOUT` was **5**. `STORAGE_INTERVAL` is **5**.

The timeout timer is armed in the same iteration as the push. That iteration
stamps `lastStorageWC`. So the next poll was scheduled for exactly
`push + 5 s` — **the instant the timeout timer fired.** The timeout event was
born inside the next poll's yield window, every single time.

The two "independently dropped events" were never independent. They were the same
peripheral call eating the same push twice, five seconds apart. That is a phase
lock, and it is why every stall you measured ran the force-clear window end to
end — 33.2, 31.6, 31.3, 29.4, 29.6, 25.9 — instead of any of them ending at five
seconds. A genuinely random double drop would have produced a mix.

## The fix

Three changes, all in `central_server.lua`, none of them touching `refreshStorage`.

| Change | Why |
|---|---|
| The push moves to the **bottom of the loop**, below everything that can yield | From `http.request` to `os.pullEventRaw` there is now no yielding call left. Two `os.*Timer` calls do not yield |
| It is now the **only** push site | The `bridgeTimer` branch pushed *without* stamping `lastBridgePushWC`, so it and the wall-clock check ran as two independent triggers — the same double-run the `storageTimer` handler already carries a comment about having fixed for the RS poll. It was still live for the bridge |
| `BRIDGE_PUSH_TIMEOUT` 5 → **4** | Breaks the phase lock. Not equal to `STORAGE_INTERVAL` and not a multiple of it, still well under the fleet's 15 s patience |

The force-clear warning now reports the last RS poll duration and how many
milliseconds before the push it ran, **so you can falsify this from the log
rather than take it on trust.** If force-clears keep happening while the poll is
nowhere near the push, I am wrong and that line says so.

## What I did not do, and why

**I did not touch `refreshStorage`.** Moving the RS poll off the dispatch
computer is still the structural fix and still W6's — this only stops the poll
standing next to the one call that cannot survive it. Any other yielding call
that lands adjacent to a push will do the same thing again, and the loop still
has several: modem transmits, and the KV writes in the cloud path.

So treat this as removing the specific adjacency that was firing, not as making
the loop yield-safe. It is not yield-safe and cannot be made so while a
multi-hundred-millisecond peripheral poll shares the event loop with an async
HTTP push.

## On `9ce45c9`

Read and kept, and your reasoning is right: the value **is** the stall duration
rather than a worst case, because it is the only recovery when both events die.
Worth saying that with the phase lock broken, the 4 s timeout should now do the
recovering and the force-clear should go back to being what its name says. **If
you still see force-clears at 10 s after this deploys, that is the signal my
diagnosis is incomplete** — it would mean something else is eating the timeout as
well.

## Your correction, accepted — and it cost me nothing to be wrong there

You are right that the three frozen-file sites were not the differentiator, and
the per-node numbers settle it: miners with the inbox re-register *more* than
support without it. I landed them at 1.9.75 anyway on your standing exception,
and I would still land them — a direct `proto.receive` is a latent defect — but
I will not describe them as storm-related again.

Worth noting what the numbers do rule out: if the inbox migration made no
difference to re-registration rate, then the turtle side was not the limiting
factor by 1.9.74. Your "the causality has flipped" reading is the one the data
supports.

## Methodology note, taken

Five minutes minimum, report the episodes not the median. I have written it into
the verification ask below rather than treating it as advice.

## What I need from you

1. **Deploy 1.9.77 and watch for five minutes.** The signals, in order of what
   they would tell us:
   - No `Bridge push stuck` force-clears at all → both halves fixed.
   - `Bridge push timed out (>4s)` appearing instead → the completion is still
     being lost sometimes, but the timeout now recovers it in 4 s rather than 10.
     That is a partial win and tells us there is a second adjacency.
   - Force-clears continuing → I am wrong; the log line now carries the RS timing
     to say how wrong.
2. **The deploy needs `UPDATE_ALL`,** which restarts every turtle. The operator's
   call, not mine.

## The thing I would want kept

Six theories died against "why does a 256-slot queue overflow at 5 msg/sec."
The question was unanswerable because the queue was never the mechanism, and the
comment in my own file asserting that it was is what kept it alive.

**A measurement that makes a question unanswerable is evidence the question is
wrong, not evidence the measurement is.**
