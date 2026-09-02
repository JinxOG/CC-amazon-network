# W3 → Spec owner: the frozen files still carry the bug the inbox just fixed

**From:** W3 — Fleet & Dispatch
**To:** Spec owner
**Date:** 2026-09-02
**Re:** `2026-09-02-spec-owner-to-W3-registration-storm-handoff.md`, Invariant H
**Status:** Inbox landed at **1.9.72**, restart verified. **A ruling is needed, not permission.**

---

## Done

`base.receive` exists. `turtle_base.lua` has zero `proto.receive` calls.
`register()`, `queryTurtle`, the `SUPPORT_STAGED` wait and the
wait-for-any-of-set all use the inbox, and the control loop routes what it does
not act on rather than dropping it. A full server restart has been observed with
the fleet rejoining unaided.

Because the fix is in shared worker code, **delivery and support turtles are
already protected on the registration path** — that is where the outage lived,
and it is closed for all three worker types.

## The question

`delivery_turtle.lua` and `support_turtle.lua` still call `proto.receive`
directly — one site in delivery, two in support. Those are the same
discard-what-you-did-not-ask-for calls that caused the outage, and they run
**mid-job**, where a lost message is a stalled delivery rather than a retry.

Invariant H freezes both files. I am not going to edit them on my own judgement,
because I have already made this call once and I would rather it be consistent
than convenient.

**The precedent I set, and why it may not extend.** On 2026-08-25 I fixed the
false-dock bug in `returnToDock`, which delivery and support both use. I ruled
Invariant H did not shield it, on the grounds that the code lives in
`turtle_base.lua` (mine), the caller already read the return value, and the change
removed a false success rather than altering control flow. I still think that was
right.

**This is different in the way that matters.** The remaining sites are *inside*
the frozen files. Fixing them means editing files Invariant H names directly, not
a shared primitive they happen to call. "Frozen means not changed casually, not
left broken deliberately" was a fair reading for the first case; applying it here
would let me edit any frozen file whenever I judged the reason good enough, which
is the thing the invariant exists to prevent.

## Three options, with what each costs

| Option | Cost |
|---|---|
| **Leave them.** Accept a known message-loss path in delivery and support | Mid-job losses stay possible. They were survivable before the inbox existed and are no worse now — but they are now the only ones left, and will be diagnosed against a fleet everyone believes is fixed |
| **Grant a scoped exception** — these three call sites only, no other behaviour change | Small, mechanical, testable. Requires you to say so |
| **Unfreeze delivery** | Much larger question, and not one this needs |

My recommendation is the middle one, and I want to be honest that I am not
neutral: I would rather finish the class. The argument against my own preference
is that delivery has been stable for weeks and the invariant exists precisely to
stop people improving it into instability.

## What makes this decidable rather than a judgement call

The change is mechanical. Each site becomes `base.receive(timeout)` or
`base.receive(timeout, wantType)`. No control flow moves, no new state, and the
primitive is already covered by eight tests including the storm scenario itself.

If it helps, I can prepare the diff without applying it, so the decision is made
against the actual change rather than a description of one.

## Unrelated, and also yours

`android_base.lua` has the same two calls. Androids have been removed from the
modpack and the `ANDROID` class is retired, so this is almost certainly dead code
— flagging it only so it is retired deliberately rather than left to be found
later by someone who assumes it is live.
