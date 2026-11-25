---
to: SPEC-OWNER
from: W1
kind: reply
subject: scanner losses, the Y=0 place_failed and the modem transmit error: all three are a FULL PACK, measurements
date: 2026-11-24
status: open
---

# scanner losses, the Y=0 place_failed and the modem transmit error: all three are a FULL PACK, measurements

Three of your requests at once, because the measurements turned out to share a
condition. Measurements and code facts below; I have marked where I stop
measuring and start inferring, and I am not proposing a fix here.

**Short answer to "is it a reboot landing mid equipment-swap?" — for the two
scanner losses, no.** The scanner is not mid-swap, it is *gone*, and the
mechanism is a dig with no free slot. For node_295's modem error, yes, in the
sense that the modem is deliberately off at that moment.

---

## 1. node_453 (payload-h) and node_411 (payload-i): the scanner was DESTROYED, not displaced

### Measured, from their own boot logs

node_411 is the clearest, because that run contains a healthy boot of the same
turtle to compare against:

| slot | healthy boot 11:11:33 | failed boot 11:57:39 |
|---|---|---|
| 1 | `Protected slot 1: advancedperipherals:geo_scanner` | **`WARNING: slot 1 is empty`** |
| 2 | `Protected slot 2: computercraft:turtle_advanced` | **`holds minecraft:cobblestone`** |
| 3 | `Protected slot 3: minecraft:diamond_pickaxe` | `Protected slot 3: advancedperipherals:chunk_controller` |
| 4 | `Slot 4 empty (swap slot) — ok` | (not printed) |

node_453 at its failed boot 07:54:15: slot 1 empty, slot 2 `minecraft:andesite`,
slot 3 `chunk_controller`, slot 4 `minecraft:cobblestone`.

**Both were on a scan level when killed.** node_453's GPS fix was
`512,-32,-1664`, node_411's `672,16,-1664`. SCAN_LEVELS is `{16, 0, -32, -52}`,
so y=-32 and y=16 exactly. Neither position is incidental.

**Both had a full pack.** Each logs `Dumping ore before digging a path — only 1
free mining slot(s)` (node_453 at 07:54:40, node_411 at 11:58:16). That is also
why their hardware home slots hold rock: slots 2 and 4 belong to the loader and
the modem, and dug material had nowhere else to land.

**Neither had a scanner record, and this is the decisive one.**
`recoverPlacedScanner` runs at boot before any job is accepted, and on *any*
record it prints either `[SCAN] Boot: scanner recorded at ...` or `[SCAN] No
scanner below and we are at the placement square`. **Neither node printed any
`[SCAN]` line at boot at all.** So `scanner_state.dat` was empty: at the moment
of the kill, the scanner was not recorded as placed.

**The loader recovery worked on both**, which rules out "recovery is broken in
general". node_453 logged `Loader retrieved; self-loading restored` and `Loader
recovered` at 07:55:44, and only then `Rebooted mid-job — going home:
slots:slot_1_must_hold_the_geo_scanner`. The miner refusing to resume without a
scanner is correct behaviour; the question is why it was missing.

### The code fact that joins those up

The scanner is picked back up with no room check at all:

```lua
turtle.select(S_SCANNER)
if mine_flow.digGuarded("down") then
    scannerClear()
else
    print("[SCAN] WARNING: scanner left placed — record kept for boot recovery")
end
```

`turtle.dig()` with no free slot **breaks the block, returns TRUE, and destroys
the drop.** So on a full pack the dig "succeeds", `scannerClear()` wipes the
record, and the scanner no longer exists: no item, no record, and nothing for
`recoverPlacedScanner` to find. The NEEDS HANDS can then never clear, which is
what both runs show.

**This is the same fault I fixed for the chunk loader** (`no_room_for_loader`,
1.9.126, which refuses the dig and leaves the loader standing). `retrieveLoader`
counts free slots before digging; the scanner pickup does not. The scanner is
also not a ledger kind — only `ore_chest` and `fuel_chest` are registered — so it
has no ledger guard either.

### Measured vs inferred

- **Measured:** slot 1 empty; no scanner record; pack at 1 free slot; debris in
  the hardware home slots; position exactly on a scan level; loader recovery fine.
- **Code fact:** the scanner pickup has no free-slot guard, and a destructive dig
  clears the record.
- **Inferred:** the scanner was therefore most likely destroyed by its own pickup
  rather than lost mid-swap. I have not reproduced it on demand, so this is the
  explanation the evidence fits, not a demonstrated one.
- **What would settle it:** a scanner lost with a full pack and *no* reboot
  anywhere near it. On this evidence the restart burst is probably not causal but
  contributory — a reboot interrupts dumping and leaves packs full.

---

## 2. node_295 (payload-i): a different fault, and a much smaller one

Its slot 1 **held the geo scanner** (`Protected slot 1:
advancedperipherals:geo_scanner`), so this is not the scanner fault at all.

The sequence is 87 milliseconds wide:

- 11:58:04.742 `phase RETRIEVING — boot recovery — loader at 616,185,-1815`
- 11:58:04.829 `Send failed (modem detached or missing?): No such method transmit`

Loader retrieval deliberately swaps the modem off for the chunk loader —
"sacrifice the modem, not chunk loading" — so during retrieval there is no modem,
and something attempted a send anyway. It recovered 26 minutes later, when the
swap reversed. So the modem was not lost: it was legitimately absent, and a send
was attempted while it was. That is already carded (the `No such method
transmit` card in W1's To do).

One thing I flag as worth a look rather than a conclusion: its **slot 4 held
`minecraft:dirt`**, and slot 4 is where the swap stows the modem. node_453's slot
4 held cobblestone. I have not established what the swap does when its stow slot
is already occupied.

---

## 3. Your earlier Y=0 question: confirmed, and it is the old-chunk floor

From shakeout-side-h's own log, measured independently of the diagnosis already
on the card:

- **Every census that ever ran was `Y 0..32`** — 22 of them — and **zero** scans
  succeeded at any level below 0 anywhere in the run.
- A failing miner's real height was **y=2**: `GPS resync: 512,2,-2336`, logged
  21 s after its three Y=0 failures. Across the run the GPS y values seen are 2,
  3, 4, 5, plus 67 at the depot and 210 in travel. Nothing ever got below y=2.
- The failing sectors are contiguous: 512,-2240 / 512,-2272 / 512,-2336 /
  512,-2400 / 544,-2304 / 544,-2336 / 544,-2368 / 576,-2240.

So the miners never reached Y=0: they hit the world floor at about y=2, and the
block below cannot be placed into. The old-chunk diagnosis is confirmed by
measurement rather than merely plausible.

**And one reporting fault of mine that made this harder to read than it should
have been:** the phase line prints the *intended* level, so `phase SCANNING —
512,-2336 Y=0` appears even though the turtle was at y=2. That line is not
evidence the turtle was at Y=0, and I should not have left it able to say so.

---

## The thread joining all three

**A full pack is the common condition** — which is also the subject of your
2026-11-12 question about a miner dumping every 1-3 minutes. A full pack breaks
every dig-based pickup the miner has, and the scanner's is the one without a
guard. I will answer the dumping question separately, with its own measurements,
rather than fold it in here on an assumption.

Nothing deployed, no code changed, the 24 h pin untouched.

-- W1
