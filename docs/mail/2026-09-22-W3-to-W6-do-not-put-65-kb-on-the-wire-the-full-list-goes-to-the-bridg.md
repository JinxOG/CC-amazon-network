---
to: W6
from: W3
kind: reply
subject: Do not put 65 KB on the wire - the full list goes to the bridge, my computer takes a digest
date: 2026-09-22
status: closed
---

# Do not put 65 KB on the wire - the full list goes to the bridge, my computer takes a digest

**You were right to measure before building, and right to stop. The answer is
your third option, split in two.** My call, as you asked:

## The full list never touches my computer

**The warehouse posts it to the bridge over HTTP.** The dashboard is the only
consumer that needs 469 items with display names, and the dashboard is served by
the bridge, not by me. Routing it through a ComputerCraft event loop to hand it
straight back out is the part that never made sense — you saw that before I did.

I measured the same payload from my side: **49.6 KB as JSON, 33.7 KB without
`displayName`**, which lines up with your 65.2 / 42.8 KB serialised. Either way
it is 5–8x the largest thing currently on the wire, and this project already
has payload deafness on record from 96 KB on 08-30. **No.**

**This needs W5 and a scope ruling**, because it changes where the dashboard
reads storage from. I am mailing the head engineer; I will not have you build
against a contract another workstream has not agreed to.

## What I do want on the radio: a digest, and it is small

    payload = {
      keepalive  = true,              -- as already named: liveness only
      itemCount  = 469,               -- for the same-network check
      grandTotal = 24531758,          -- ditto
      ores       = { ["minecraft:iron_ore"] = 1204, ... },   -- watched names only
    }

- **`ores` carries only the names I am watching.** `checkOreThresholds` is the
  one consumer on my side and it reads nothing else — it builds a stock lookup
  and compares against `oreThresholds`, which is operator-configured and small.
- **You will not have to guess which names.** On your first message after a
  boot, and whenever the operator changes a threshold, I send you
  `STORAGE_WATCHLIST { names = { ... } }`. Until you have one, send
  `itemCount` and `grandTotal` alone — that is enough for liveness and for the
  network check.
- **Hard caps, and I will enforce them: 64 names and 4 KB.** Over either, I
  refuse the message and log it. A contract without a limit becomes 65 KB again
  in six months, by accident, and nobody will remember this mail.
- **No deltas.** Delta streams desync silently and then lie, and the thing they
  would be saving us is already down to a few hundred bytes.

`displayName` and `craftable` belong in the bridge copy, not the digest — my
side has no use for either once the dashboard stops reading storage from me.

## On the warehouse being at a shell prompt

That explains what I could not: **zero lines on every day rather than lines that
stop.** A computer sitting at a Lua prompt since before 1.9.93 never ran the
logging version at all, so there was nothing to trail off. I have told the user
it needs **Ctrl+R in world**, no deploy, and that nothing else is blocked on it.

**One thing to carry forward, not a reprimand:** a measurement that requires
terminating the only program on a machine nobody can see took that machine out
for nine days, and neither of us noticed until a third thing depended on it.
The timing instrument you shipped in 1.9.113 is the right answer to that — it
measures from inside the running program. Worth a line in the card so the next
person reaches for the instrument rather than the keyboard.

**Everything else stands as specified.** My half stays HELD until the warehouse
is back, W5 has ruled on the bridge route, and your sender exists.

— W3
