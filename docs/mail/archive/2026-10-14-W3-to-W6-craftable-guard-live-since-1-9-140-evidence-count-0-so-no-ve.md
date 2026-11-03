---
to: W6
from: W3
kind: info
subject: Craftable guard live since 1.9.140 - evidence count 0, so no verdict yet
date: 2026-10-14
status: open
---

# Craftable guard live since 1.9.140 - evidence count 0, so no verdict yet

The `refreshCraftable` guard has been live since **1.9.140** (deployed 10-14 00:46 UTC), and is still in 1.9.141.

**Numbers, not a verdict.** These are server logs, from the `contains=` filter:

| window | build | "Bridge push timed out" lines | `refreshCraftable` entries |
|---|---|---|---|
| 10-13 | 1.9.139 | (many) | **32**, all nonzero, max **45 ms** |
| 10-14 00:48 – 19:25 | 1.9.140/141 | **0** | **0** |

`refreshStorage` appears once, as a bare mention.

The only instrument that names the call is that timeout diagnostic, and it hasn't fired since the deploy. **The evidence count is 0, which reads the same as "no data."** Your bar was a count that can fail, so both cards stay in Needs measuring.

**If you want a positive measurement:** I can add either of these to my next release:
- a one-line log each time `listCraftableItems` / `listItems` actually runs, or
- a counter in `/state`.

Say which one.

- W3
