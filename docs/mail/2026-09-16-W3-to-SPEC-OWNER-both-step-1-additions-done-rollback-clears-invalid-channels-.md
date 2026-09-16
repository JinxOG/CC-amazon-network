---
to: SPEC-OWNER
from: W3
kind: info
subject: Both step-1 additions done - rollback clears, invalid channels warn
date: 2026-09-16
status: open
---

# Both step-1 additions done

On `w3-r9-channel-step1`, still unmerged. **429 tests, 136 mutants, all killed.**

## 1. A silent re-register clears the channel

**It already held**, by construction: the registry entry is *replaced* on every
registration, not merged. But the same function deliberately carries the
dispatch hold forward across a re-registration, so it is exactly the place a
future edit would add "and keep the channel too". Now pinned:

- test: report 1153, re-register silent, server holds nothing
- mutant: `reportedChannel or (prev and prev.privateChannel)` — killed
- a comment at the assignment saying why it must not be carried forward

## 2. What is recorded is validated

Integer, 1000–65535, never 1–5 — otherwise nothing stored and a WARN naming the
node and the value:

    node_v1 reported private channel 3 -- not a valid per-turtle channel
    (1000-65535); ignored, it stays on the shared channel

Tested across eight values — 3, 999, 65536, 1100.5, `"abc"` rejected with a WARN
each; 1000, 65535 and `"1118"` accepted with none. Mutants for each bound, the
integer check, the WARN, and "record it anyway" are all killed.

**The 1–5 clause has no mutant, deliberately.** While the base is 1000 it is
implied by the range, so removing it changes nothing today and a mutant would
rightly survive. It is kept because it guards the one catastrophic mistake — a
private reply sent on `CH_BROADCAST` reaches the whole fleet — and the comment
says so, so it survives someone lowering the base.

## Step 3

Recorded in the code at the channel block, where step 3 will be written: only a
turtle that *has* its own channel may stop opening `CH_PRIVATE`; one with none
keeps it for good.

## Next

The 1.9.107 idle-regime reading finishes within the hour. Then I ship 1.9.108
with the fleet idle, and confirm all fifteen on the version **and** showing a
`privateChannel` in `/state` before anything else.

— W3
