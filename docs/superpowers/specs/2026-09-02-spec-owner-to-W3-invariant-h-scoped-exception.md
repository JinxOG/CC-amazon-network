# Spec owner → W3: scoped exception to Invariant H, granted

- **From:** Spec owner
- **To:** W3 — Fleet & Dispatch
- **Date:** 2026-09-02
- **Re:** `2026-09-02-W3-to-spec-owner-frozen-files-carry-the-storm-bug.md`
- **Status:** **Granted, scoped.** Ruling, not permission to use judgement.

---

## Ruling

**Granted.** Migrate the three `proto.receive` sites — one in
`delivery_turtle.lua`, two in `support_turtle.lua` — to `base.receive`. Nothing
else in either file changes.

## Why Invariant H does not protect this

H exists to stop delivery being *improved into instability*: behaviour changes to
a working subsystem, made because someone thought they could do better. That is
the failure it was written against, and it is a real one.

**This is not that.** It is a mechanical substitution of a primitive, with no
control flow moved and no new state. And the thing being removed is not a design
choice — it is the exact defect that took the fleet down for 11.8 hours, still
live in the code path used by **11 of 15 workers**.

> **A freeze preserves working behaviour. It does not preserve a known defect.**

That sentence is the rule, and it is narrower than "frozen means not changed
casually." Apply it only where the defect is already identified, already
understood, and the fix is mechanical.

## The asymmetry that decides it

Leaving them costs a known message-loss path in delivery and support, **which will
now be diagnosed against a fleet everyone believes is fixed.** That is the P7
shape the spec exists to prevent, and this week is the case study: six wrong
theories chased because a degraded system reported itself healthy.

Fixing them costs a three-line change to a primitive with eight tests behind it,
including the storm scenario.

## Scope — binding

1. **Three call sites only.** No other edit to either file, in the same commit or
   a follow-up justified by "while I was in there."
2. **Behaviour identical.** Where a site did not filter by type, keep it
   unfiltered — and read the `base.receive` drain-first trap first: an unfiltered
   receive pops whatever is queued, so a caller that discards non-matches
   destroys them exactly as `proto.receive` did. If a site needs a type, name it.
3. **Regression pin.** The existing delivery protocol-surface test must still
   pass unchanged. If it does not, stop and raise it.
4. **The commit message says this ruling authorised it**, so the next reader of
   `git log` does not find an unexplained edit to a frozen file.
5. **H is otherwise unchanged.** Delivery and support stay frozen. This does not
   generalise, and a future exception needs its own ruling.

Your offer to prepare the diff without applying it was the right instinct. It is
not needed here — the change is small enough that the description and the diff
are the same thing — but ask again for anything larger.

## On your precedent question

You were right to raise it and right that the two cases differ. `returnToDock`
was shared code you own, removing a false success; this is inside the frozen
files themselves. Treating them as the same would have made H mean whatever the
editor thought reasonable.

**Asking is why you get the exception.** An engineer who edits frozen files on
their own judgement gets the invariant tightened; one who stops and asks gets it
scoped and moved forward. That is the incentive I want.

## `android_base.lua` — retire it

Confirmed dead. Androids are gone from the modpack, the `ANDROID` class is
retired, and the fleet target is `WORKER` + `LOADER`.

**Do not migrate its two calls.** Retire the file deliberately: remove it from
`install.lua` and `updater.lua` so no profile can deploy it, and leave the file
in git history rather than deleting it outright, in case the Turtlematic builder
work wants the API reference. That is a W4 concern to action, not yours — you
have flagged it, which was the job.
