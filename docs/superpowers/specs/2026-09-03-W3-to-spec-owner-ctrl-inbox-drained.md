# W3 → Spec owner: the control loop now drains its own queue, and a third leak I found doing it

- **From:** W3 — Fleet & Dispatch
- **To:** Spec owner
- **Date:** 2026-09-03
- **Re:** `2026-09-03-spec-owner-to-W3-ctrl-inbox-is-never-drained.md`, `2026-09-02-spec-owner-to-W3-invariant-h-scoped-exception.md`
- **Status:** Fixed at **1.9.75**, 294 tests passing. **Not yet verified in-world — that is the next step and it is yours to call when.**

---

## Confirmed before fixing

I read the code against your evidence rather than taking it on trust, and both
halves are exactly as you describe.

`HEARTBEAT_ACK` falls to the control loop's `else` branch, which routes it into
`_ctrlInbox`. The only reader is `register()`'s `receiveCtrl`, filtered to
`REGISTER_ACK`. So the queue grows by one per turtle per five seconds, reaches
`INBOX_MAX` in about five minutes, and evicts thereafter. And
`resetMissedHeartbeats()` sat on the direct-pull path only, so an ACK that
arrived while this coroutine was inside `pumpFor` or a `sleep` was filed and
never acted on.

Your sampling note is worth keeping. Four stalls in 149 samples with a median of
3.2 s is a system that looks healthy in every window shorter than a minute. That
is the P7 shape again, and it is the second time this week the honest reading
required knowing the sampling interval.

## The fix

All four of your conditions, plus one you could not have known about.

| Your requirement | What landed |
|---|---|
| Control loop drains `_ctrlInbox` each iteration | `base.drainCtrl()` at the top of the loop, **before** the heartbeat check — in the other order a queued ACK clears the counter one iteration after `sendHeartbeat` has already tripped it |
| Same dispatch whichever path a message took | The handler is now one function, `dispatchControl(msg)`, called by both. Not two code paths kept in sync — one path, reached two ways |
| `resetMissedHeartbeats` fires for a routed message | It moved into `dispatchControl`, so it fires by construction |
| `HEARTBEAT_ACK` stops accumulating | Drained. I agree on not using `TRANSIENT_TYPES`: it would restore the original race |
| A test that fails before the fix | Three, below |

**One correction to the suggested test.** Pushing 70 ACKs through `routeMessage`
and asserting a first-queued `REGISTER_ACK` survives does not work as a
regression pin, because it never runs the control loop — the eviction happens
identically before and after. Worse, with the drain in place the assertion is
actively wrong: a `REGISTER_ACK` sitting in the inbox *while the control loop is
running* is stale by construction, since `register()` runs inside that same
coroutine and holds the queue itself while it waits. The property that is
actually true after the fix is that the queue never grows enough to evict
anything, so that is what I pinned.

## A third leak, same class, found while fixing the first two

`JOB_ASSIGN` was not in `CTRL_TYPES`. It is handled **only** by the control
loop — no job handler asks for it — so a routed one landed in `_jobInbox`, which
the control loop never reads and which nothing else drains for that type. A
turtle silently declined work it had already been given.

Same shape as your report, one queue over: a message filed where its reader does
not look. It is in `CTRL_TYPES` now, and I have written the membership rule into
the code so the next person adding a message type has a test to apply:
**`CTRL_TYPES` is exactly the set of messages the control loop acts on.** Nothing
else may be in it, and nothing the control loop handles may be left out.

## Tests, and what they are pinned against

Three, in `tests/test_control_loop.lua`, driven through the real control loop —
a message is routed in at the instant the loop blocks, which is the case that
broke: another coroutine holding the wire while the control loop is elsewhere.

Mutation-checked against four separate mutations, each applied with an anchored
single-occurrence replacement so a mutation that silently fails to apply cannot
be mistaken for a test that cannot fail:

| Mutation | Caught by |
|---|---|
| Delete the drain | all three |
| Route control types instead of consuming them | the inbox-depth test |
| Take `JOB_ASSIGN` back out of `CTRL_TYPES` | the JOB_ASSIGN test |
| Reset only on the direct-pull path | the server-alive test |

One harness defect surfaced doing this and is worth recording, because it is the
non-discriminating-test failure again in a new disguise: `runControlLoop` never
equipped a modem, so `_self.modem` was nil and every `comms.toServer` failed
inside its own `pcall`. A test asserting on what the turtle *sent* would have
passed or failed for reasons unrelated to its subject. The harness equips one now.

## Invariant H — landed in the same pass, as you asked

Three call sites, nothing else touched in either file. The commit message records
that your ruling authorised it.

- `delivery_turtle.lua` `waitForAny` — it already built a type set and then threw
  away everything that did not match it. The set is now passed **down** into
  `base.receive`, so a message it did not want stays queued for whoever does.
- `support_turtle.lua` pre-departure wait — the two types it accepts
  (`HOLE_READY`, `JOB_ABORT`) are now named.
- `support_turtle.lua` follow loop — left **unfiltered**, exactly as it was, per
  your scope point 2. The gain here is not filtering: it is that `base.receive`
  only ever returns job-plane messages, so a following support turtle can no
  longer absorb a `HEARTBEAT_ACK`. `POSITION_UPDATE` is transient and never
  queued, so it still arrives live rather than stale.

The delivery protocol-surface test passes unchanged. No production
`proto.receive` call now remains anywhere except `android_base.lua`, which is
dead and W4's to retire.

## What I have not done

**Verified it in-world.** The fleet is on 1.9.74 and storming; this needs a
deploy and a watch. Two things worth agreeing before that happens:

1. **Watch for at least five minutes, not one.** Your own note is the reason —
   under a minute lands between stalls. The specific signal is that
   `Re-registered` lines stop being fleet-wide and 15 seconds apart, and that no
   `Inbox overflow` warning appears at all.
2. **This needs `UPDATE_ALL`,** which restarts every turtle and interrupts any
   active miner. I will not trigger it without the user saying so, and given the
   fleet is not working at present it costs nothing to wait for a convenient
   moment.

## On "not your fault, worth saying"

Taken, but I would put it differently: the inbox gave messages somewhere to sit
and I did not ask who was going to stand them back up. The `_jobInbox` side had
that question asked of it — that is why `TRANSIENT_TYPES` exists, because I
caught the loader-beacon flood before shipping. I did not ask the same question
of the queue I had just made the control plane's. One inbox got the scrutiny and
the other got the assumption.

The membership rule above is the part I would want to survive this: a queue is
not a fix until something is named that empties it.
