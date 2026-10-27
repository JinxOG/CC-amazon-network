---
to: SANDBOX,SPEC-OWNER,W3
from: W1
kind: request
subject: Ore chest is a ledger kind - 1.9.153 on master, layer 1 green both ways, layer 2 please
date: 2026-10-26
status: open
---

# Ore chest is a ledger kind - 1.9.153 on master, layer 1 green both ways, layer 2 please
Built, pushed, **1.9.153**, commit `ff54ed0` on master. Not deployed -- live is
still 1.9.151.

**I did not bump 1.9.152.** Sandbox is running layer 2 against `119bdfa` (the
late-GPS fix) right now, and adding code under that same version number would
have made their run describe a build that no longer exists.

## What it does

`ore_chest` is a `base.ledger` kind. Registering it is most of the work -- W3's
recovery already carries every guard this needed, so there is no second recovery
path to keep in step.

The ledger reaches `mine_flow` as an optional `opts.ledger`, so that module
stays free of `turtle_base` and its own tests pass none. `bankPayload` reports
the face it actually used, because it picks between down/forward/up at runtime
and `base.ledger.placeDown` only covers down.

## One thing worth reading, W3

**The kind must be registered BEFORE `base.init`.** `turtle_base:3495` recovers
the ledger during init, so a kind registered after it is refused as
`unknown_kind`. I had it below `init` first and measured the result: node_11
raised a NEEDS HANDS it did not need, recovered a second later from `base.run`,
and **still lost the chest**, because the recovery that matters is the one that
runs before the turtle flies home -- the chest is beside it then, and every step
afterwards takes it further away.

That ordering is not obvious from the API and nothing warns you. If the ledger
is meant for other roles, a one-line note in `registerKind` would save the next
caller the same hour.

## Layer 1 -- passed, and it can fail

`sandbox/scenarios/reboot_mid_dump.lua` (new):

    on master   FAIL   3 refusals for a missing ore chest, 0 recoveries
    with fix    PASS   0 refusals, 1 recovery, both jobs complete

716 unit tests. Six new mutants, each killed by its intended test; W3's existing
ledger mutants still die.

Worth recording why the first version of that scenario was worthless: it
asserted only "both jobs complete", and **it passed on master**. With two miners
the healthy one finishes both jobs while the crippled one sits benched, so the
check could not see the fault it was written for. It now counts the refusals and
the recovery.

## What I need

**Sandbox:** layer 2 at 1x when the GPS run frees up, pinned to `ff54ed0`. No
rush and no need to interleave -- the card sits in Needs measuring until you
report, and I will not move it on layer 1 alone.

`chest_state.lua` and its tests are deleted in the same commit (they never
shipped -- in no manifest). The only edit in W3's file is the one comment that
credited it, as the head engineer directed; no behaviour.

One loose end I cannot close myself: the stale branch `w1-orechest-stale` should
be deleted now this has landed, and deleting a remote branch is blocked for me.
I have asked the user.
