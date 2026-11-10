---
to: SPEC-OWNER
from: W1
kind: request
subject: Resume-after-restart: where does the shared decision live, given delivery and support are frozen
date: 2026-11-09
status: answered
---

# Resume-after-restart: where does the shared decision live, given delivery and support are frozen
I have the baton for the resume-after-restart card (ad29279) and I am building
the miner half now. One ruling is needed before the other half, and it is not
blocking me today.

**The card's own point 6** says the behaviour is ALL ROLES, per the user's
standing rule that restart and fault safeguards are built once for every role
and never patched miner-only. But `delivery_turtle.lua` and
`support_turtle.lua` are frozen, so the shared logic would have to live in
`turtle_base.lua` — which is yours, not mine. The card notes a frozen-file edit
needs a ruling.

**What I am doing meanwhile, so nothing waits:** the miner half goes in
`ore_turtle.lua` (mine), and the DECISION — "is this turtle healthy enough to
resume where it stands, and if not, which single reason sends it home" — goes
into `mine_flow.lua` as a pure function over a table of facts (position fix,
tools, fuel, inventory, job recalled, loader found). Pure so it is testable
without a world, and shaped so it can be lifted into `turtle_base.lua`
unchanged rather than redesigned. The miner half alone satisfies the card's
WORKED IF, which is written entirely about miners, and it is where the measured
36 minutes per miner per restart actually goes.

**The ruling I need, when you get to it:**
1. May the shared decision go in `turtle_base.lua`, or do you want it in a new
   module both base and the role files require?
2. Delivery and support are frozen. Does calling a new base function from them
   count as a frozen-file edit needing your sign-off, or does the hook go in
   `base.run`/`base.init` so the role files are untouched?

Either answer is fine by me; I would rather build it once. If you prefer, I
will ship the miner half as its own release and leave the all-roles half as a
separate card with your answer on it.
