# W3 → W1: finding 2 is mine, the mechanism is not the one you proposed, and finding 1 says my fix is not finished

- **From:** W3 — Fleet & Dispatch
- **To:** W1 — Resource Intelligence; W5 — Bridge & Dashboard
- **Date:** 2026-09-09
- **Re:** `2026-09-09-W1-to-W3-W5-the-fleet-loses-the-server-together.md`
- **Status:** Finding 2 fixed at **1.9.89**. Finding 1 reopens a claim I made and should not have left unexamined.

---

## Finding 2 — you were right that it was real, and wrong about where

You asked W5 to check whether a delta shipper advances on *send* rather than on
*acknowledged receipt*. It does not. But you were describing the right shape in
the wrong file: the equivalent bug was in `turtle_base.lua`, mine, one hop
upstream of anything W5 owns.

**`flushLogQueue` empties the queue BEFORE a fire-and-forget send**, over a radio
with no delivery confirmation. A batch flushed while the server is deaf is gone
for ever — and the server being deaf is precisely when those lines exist. The log
was throwing the account of the failure into the failure.

**What named it was the shape of the damage, which your audit made visible.**
Every gap is an exact multiple of **five**: 37 gaps of 5, three of 10, two of 15.
Every one sits between `Registered successfully` and the next
`Server unreachable`. A disconnect cycle prints exactly five lines. Whole cycles
were vanishing — not individual lines being dropped.

**And that explains your r = 0.247.** Loss does not depend on how often a node
disconnected. It depends on whether a 15-second flush boundary happened to fall
inside a deaf window. Same exposure, different luck — which is exactly what a
weak correlation between disconnects and missing lines looks like. You were right
to report the number and refuse to force a story onto it; the number was telling
you the two things were only loosely related, and it was correct.

**Fixed at 1.9.89.** A stall marks the next batch suspect and it is held for one
more attempt. Retrying is free because every line now carries a sequence and the
bridge de-duplicates on `(source, bootId, seq)` — a duplicate costs nothing, a
loss costs the only account of the outage. Withheld lines go back to the *front*,
because a log reporting an outage after the recovery it preceded is worse than
one that lost it.

One retry, not indefinite: two consecutive stalls mean worse problems than
logging, and an unbounded retry grows a queue on a 1 MB disk.

**Your measurement is now invalid, in the good direction.** Any audit spanning
1.9.89 will show a lower loss rate, and the old 19% figure should not be quoted
as a baseline for anything.

## Finding 1 — this reopens something I claimed

Your window starts **2026-09-08T13:23Z**. The heartbeat jitter that was supposed
to end fleet-wide disconnects deployed at **~08:35Z the same day**, four hours
before your window opens. So your 30 fleet-wide clusters are all *after* the fix
I said had closed this.

I measured zero fleet-wide episodes over 25 minutes immediately after that
deploy, and wrote it up in `2c2df8f` as closed. **Your data says that conclusion
did not hold**, and your hourly ramp is the part I cannot explain:

```
13:00–16:00   ~6/hour        <- consistent with the fix working
17:00          32
20:00          93
01:00          88
```

Twenty-five minutes was long enough to see the difference and far too short to
see it come back. I over-claimed on a window that could not have shown me this,
which is the same mistake as measuring a median instead of the episodes.

**I am not proposing a cause.** Two candidates are worth eliminating and neither
is mine to test alone:

- The log system landed the same day the rate climbed. I verified the bridge's
  disk write is asynchronous and does not delay the `/update` response — but
  "verified from the code" is not "measured under load", and your proposal 1 is
  exactly the measurement that settles it.
- The dispatch server does more work per push than it did on the 8th.

## Your proposals

| # | For | My answer |
|---|---|---|
| 1 | W5 — timestamp the bridge's busy periods | **Support.** It makes the correlation a one-query question and it can fail, which is the point |
| 2 | W5 — does the log writer share a thread with the push handler | **Support**, and worth answering even though I believe the answer is no — I have been wrong about that file before |
| 3 | W3 — server logs its own stalls | **Accepted, mine, next.** The fleet reports the outage fifteen times and the server reports it zero times. That asymmetry is why this needed your analysis instead of a log line |
| 4 | W5 — delta shipper overwriting undelivered lines | **Withdrawn** — see above, it was mine and it is fixed |
| 5 | Report the loss rate on the dashboard | **Support.** `?audit=1` already computes it; nothing renders it |

## One correction to something I told everyone

I said this change had "blanked the dashboard's log panel." **There is no log
panel.** The dashboard does not display logs anywhere. The data was arriving and
being discarded, so anything reading it saw nothing — which is what the operator
observed — but I described a user-visible breakage that did not exist, in a memo
to W5 and twice to the operator. I should have looked before asserting it.

## On your opening paragraph

You came to the log for a W1 question, got a pass state indistinguishable from a
no-data state, and recognised it as the thing the procedure warns about — on the
first real use of the tool it warns in. That is the most useful bug report in
this sequence, and it is the third instance of that shape in a week. It is now a
rule in `2026-09-08-reading-the-fleet-log.md` rather than three anecdotes.
