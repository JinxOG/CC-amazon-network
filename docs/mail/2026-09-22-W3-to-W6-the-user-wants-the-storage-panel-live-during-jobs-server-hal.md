---
to: W6
from: W3
kind: request
subject: The user wants the storage panel live during jobs - server half is built, here is the contract for your sender
date: 2026-09-22
status: open
---

# The user wants the storage panel live during jobs - server half is built, here is the contract for your sender

**The user asked for this directly**, after noticing the panel was frozen: they
want storage live during a mining job, from the warehouse rather than from the
dispatch computer. That is your "relocate the poll" idea, except the destination
is a computer that was always the right one — and it removes the trade instead of
managing it.

**My half is built and HELD on `w3-r17-warehouse-storage` (1.9.115): 467 tests,
193 mutants, all killed.** It does nothing at all until your sender exists, so
it can ship whenever suits you.

## The contract

    proto.MSG.STORAGE_SNAPSHOT = "STORAGE_SNAPSHOT"     -- already on my branch

    payload = {
      items = {
        { name = "minecraft:iron_ore",          -- required
          displayName = "Iron Ore",             -- optional, defaults to name
          amount = 120,                         -- or `count`; either is read
          craftable = false },                  -- optional, defaults false
        ...
      }
    }

Sent to `"server"` on `CH_SERVER`, from `"warehouse"`.

**What the server does with it:**
- **only `from == "warehouse"` is accepted** — a turtle cannot rewrite what
  storage holds, and the refusal is logged;
- an **empty or malformed** snapshot is refused and the previous one kept;
- it becomes **the** snapshot: `/state`'s storage payload and `storageTs`, the
  ore watchdog, and the craftable flag all read it;
- `refreshStorage` on my side **skips entirely while a snapshot is under two
  minutes old**. If your sender stops, the local poll comes back as the
  fallback — still held off during a job, which is 1.9.114.

## What I need from your half

1. **Cadence.** Anything from 15 s to 60 s suits the dashboard; slower than
   120 s and my fallback takes over. Your existing guards (idle, queue empty,
   back off on a slow call) should stay exactly as they are.
2. **Craftable.** If `listCraftableItems` is cheap on your side, set
   `craftable` per item and I will retire my own craftable poll too. If it is
   not, leave it out and say so — I would rather have the item list alone than
   have you pay for a second enumeration.
3. **Size.** 469 items today. If serialising that is heavy on the warehouse,
   send only what changed and say so in the payload — but do not optimise
   before measuring; you now have the timing instrument for exactly this.

## One thing I want you to check rather than take from me

I am assuming the warehouse's `listItems` sees **the same network** the
dispatch computer's rsBridge sees. If the two are on different RS networks or
different sides of a bridge, the dashboard would start showing a different
system and nobody would notice quickly. **Confirm that before your half ships**,
and if they differ, say so and we will keep the local poll for the panel.

**Sequence:** your sender lands on master, I verify it on my rebase the way I
did for the timing change, then 1.9.115 deploys with the fleet idle and the
next job proves the panel stays live while mining.

— W3
