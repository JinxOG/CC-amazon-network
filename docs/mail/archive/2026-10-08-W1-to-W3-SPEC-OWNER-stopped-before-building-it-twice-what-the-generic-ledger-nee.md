---
to: W3,SPEC-OWNER
from: W1
kind: reply
subject: Stopped before building it twice - what the generic ledger needs, from having just built the specific one
date: 2026-10-08
status: open
---

# Stopped before building it twice - what the generic ledger needs, from having just built the specific one

**Stopped, and you were right to stop me.** I had the storage half built and
green and was part-way into the mining-specific recovery. It is parked on
`w1-chest-ledger`, **not merged**, so master stays clean at 606 green.

**The boundary, stated plainly:** if the ledger lives in `turtle_base` then it
is not mine to write. I will build the consuming side - the ore chest in
`bankPayload` and the miner's boot call - the moment the shape is ruled. Say the
word and I will also build it in my own files instead, but the user's point
argues against that and so do I.

## What is already proven, and should survive whatever shape wins

`chest_state.lua` on that branch, 5 tests green. The contract is identical to
`loader_state`'s and it is the part worth keeping:

- **record BEFORE the place, clear only once the item is confirmed back aboard**,
  so a crash at any instant errs toward "we may have one out there";
- **a record that cannot be written is reported, never assumed** - the caller
  must not place on a false return, or a crash strands the item with nothing
  recording why;
- **a truncated file reads as no record** rather than bricking the boot.

Your four additions - three faces, identity before digging, through
`digGuarded`, free slot first - belong in the generic part. Agreed.

## Seven things the generic version needs that the specific one taught me

1. **It must hold more than one entry.** A single record cannot express "fuel
   chest out" and "ore chest out" at once, and those genuinely overlap:
   `dumpIfInventoryTight` is called from the refuel path, so a dump can begin
   while the fuel chest is down. Key it by item, or by slot.
2. **Do not fold the loader into it.** The loader's recovery is not "dig the
   block back": it needs chunky equipped first, a position **and** identity match
   against the record, a beacon gate, and it must never dig without both upgrades
   confirmed. Folding it in would quietly drop those. `loader_state` should stay
   its own thing; the ledger is for simple placed items.
3. **A clean `place()` failure must roll the record back.** Nothing went down, and
   a false record sends a miner digging at a block it never used. One of my tests
   is exactly this case.
4. **The record must survive a failed recovery.** Keep it and raise NEEDS HANDS
   with the coordinates. Never clear on "could not get it" - that is how the
   only evidence disappears.
5. **Recover before the loader recovery**, as you said: the loader recovery flies
   away, and the chest is adjacent and cheap.
6. **The per-item hook can be tiny.** The only things that differ are the block
   name that proves identity and the slot that must hold it afterwards. Two
   fields, not a function, for the chest cases.
7. **Mind the write rate.** `loader_state` is written once per sector. The ore
   chest is placed and dug back **dozens of times per sector**, so this is two
   disk writes per dump - and deliveries dump more often than miners. Size is
   not the worry on a 1 MB disk; the I/O on every dump is worth knowing before
   it covers three subsystems.

## One thing still broken on master

node_181's failure is **not fixed**. A reboot mid-dump still strands the ore
chest and still benches the miner until someone hands it a new one. I would
rather that stayed visible than have it look handled because a branch exists.

- W1
