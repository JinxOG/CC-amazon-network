"""W1 card "Mined material in the coal slot (14) is never banked", layer 2.

THE FAULT, as the user saw it. A screenshot of node_119 on 2026-10-03: a full stack of redstone sitting in slot 14, the
fuel buffer. It never left. The slot was lost for the rest of that turtle's life.

TWO GATES, NOT ONE, and the second was found by writing this file rather than by running it.

  1. dumpToEC's filter exempted the buffer by SLOT (`s ~= S_COAL`). Coal in there is the slot working as intended and
     must stay; anything else is mined material, and a blanket exemption meant it was never banked.
  2. tidyAtDock decides whether it is carrying anything by scanning slots 5-13 -- the mining slots. Slot 14 is not one
     of them. So a miner whose ONLY stranded item was in slot 14 came home, concluded it carried nothing, and left
     again. Fixing the filter alone changes nothing at the dock, because that early return fires first.

Both are fixed; the exemption is now about the CONTENTS, through mine_flow.isFuelItem.

WHY THERE IS NO SIMULATOR LAYER FOR THIS CARD. The simulator cannot stage a turtle's inventory -- it has set_block and
nothing equivalent for slots. The test server can, through the control mod (control.set_slot), so this card's end-to-end
proof lives here and its layer 1 is unit tests plus mutants (4 of 4 killed). That is stated rather than quietly skipped.

WHAT IS STAGED, AND WHAT IT COSTS. Every docked MINER gets a stack of redstone written into slot 14, which REPLACES the
coal normally buffered there. That is a real intervention and worth saying plainly: it removes each miner's fuel buffer,
not its fuel -- the fuel LEVEL is a separate field and is untouched -- and refuelFromEC refills the buffer from the
ender chest on the next refuel. Every miner is staged rather than just one because the server chooses which miner takes
the job by its own ratio, and there is no way to ask it in advance.

Staged while the miners are DOCKED, on purpose. set_slot works through the block entity at the turtle's position, so it
takes a position, clears the slot over several commands and then writes. A turtle in flight moves between those
commands and they would land on the wrong block, or on none.

WHAT IT ASSERTS. The headline is an end state -- slot 14 empty -- and it is checked against a positive on each side:
the stack must be THERE before the job (so an empty slot at the end cannot be a staging that silently did nothing, the
way run w1-skip-c's did), and the miner must have completed a round trip and docked again (so an empty slot cannot be a
job that never ran). Every message carries its evidence.

WHICH PATH CLEARS IT IS NOT ASSERTED, and that is deliberate. soloReturn dumps before leaving the sector, so on a
normal trip the field bank is what takes the redstone and the dock tidy never sees it. Both halves end with the slot
empty, which is what the user reported broken; which one ran is readable in the log lines this prints, and the dock-tidy
half is pinned down by its own mutants (the buffer scan removed, and its sense inverted).

WHY 1x. Above 20 ticks/s the game clock outruns the fleet's os.epoch deadlines, and a deadline firing early could end
the job before the miner gets home -- failing the run for the wrong reason.

WHY IT FAILS ON THE OLD CODE: the filter skips slot 14 outright and the dock tidy never looks at it, so the stack is
still there when the miner docks. That is not a prediction about an unobserved thing -- it is the state the user
photographed.
"""
NAME = "w1_coal_slot"

ZONE = {"x1": 1952, "z1": -2624, "x2": 1952, "z2": -2624, "minerCount": 1}
JUNK = "minecraft:redstone"
NBT_SLOT = 13                 # NBT Items[] is 0-based; Lua turtle slot 14 is NBT slot 13
LUA_SLOT = NBT_SLOT + 1
EMPTY = "Found no elements"   # what block_data says for a slot with nothing in it


def _slot(ctx, cid):
    return (ctx.control.get_slot(cid, NBT_SLOT) or "").strip()


def steps(ctx):
    ctx.wait_registered(14, 300)
    c = ctx.control

    miners = sorted(cid for cid in c.computers() if (c.role_of(cid) or "").upper() == "MINER")
    ctx.expect(len(miners) >= 1, "there is at least one MINER to stage (found %d: %s)" % (len(miners), miners))
    if not miners:
        raise RuntimeError("no miners registered; nothing to stage")

    staged = {}
    for cid in miners:
        before = _slot(ctx, cid)
        c.set_slot(cid, NBT_SLOT, JUNK, 64)
        after = _slot(ctx, cid)
        staged[cid] = after
        ctx.note("node_%d slot %d: %s -> %s" % (cid, LUA_SLOT, before or "(empty)", after or "(empty)"))

    # POSITIVE 1, and the one run w1-skip-c taught me to write. Its staging was
    # silently refused and the whole run then measured a world it had not set
    # up. An end state of "the slot is empty" is worth nothing unless the stack
    # was demonstrably there to begin with.
    landed = [cid for cid in miners if "redstone" in staged[cid]]
    ctx.expect(len(landed) == len(miners),
               "the junk stack is in slot %d of every miner before the job (%d of %d: %s)"
               % (LUA_SLOT, len(landed), len(miners), {k: v[:60] for k, v in staged.items()}))
    if not landed:
        raise RuntimeError("staging put nothing in slot %d of any miner" % LUA_SLOT)

    ctx.dispatch("ORDER_MINE", ZONE)

    # POSITIVE 2 (the anchor): a miner took the job and came back. Without this,
    # a job that never left the dock would leave the slot full and read as a
    # plain failure, and a job that never ran at all would be indistinguishable
    # from a broken fix.
    assigned = ctx.wait_until(lambda: ctx.log_lines("Assigned sector (1952,-2624)"), 1800)
    ctx.expect(bool(assigned), "the server assigned the sector to a miner (%d lines)" % len(assigned or []))

    who = None
    for l in (assigned or []):
        for tok in l.split():
            if tok.startswith("node_") and tok[5:].isdigit():
                who = int(tok[5:])
    ctx.note("the job went to node_%s" % who)

    docked = ctx.wait_until(lambda: [l for l in ctx.log_lines("phase: DOCKED") if "node_%s" % who in l], 2 * 3600)
    ctx.expect(bool(docked), "and that miner finished its trip and docked again (%d lines) -- without this an "
                             "empty slot could just be a job that never ran" % len(docked or []))

    # THE HEADLINE. Slot 14 is empty: the stack was banked rather than kept.
    ctx.wait_game(30)
    end = _slot(ctx, who) if who else ""
    ctx.note("node_%s slot %d after the trip: %s" % (who, LUA_SLOT, end or "(empty)"))
    for line in ctx.log_lines("Dock tidy: banking travel debris"):
        ctx.note("dock tidy: %s" % line.strip())
    ctx.expect(EMPTY in end or "redstone" not in end,
               "slot %d came back without the mined material in it (holds %r) -- the stack was staged and the miner "
               "did a full round trip, so anything still there was kept, which is the fault"
               % (LUA_SLOT, end[:120]))

    # Leave the other miners' buffers empty rather than holding redstone. Noted,
    # not asserted: cosmetic, since every run starts from a fresh world copy.
    for cid in miners:
        if cid != who:
            try:
                c.clear_slot(cid, NBT_SLOT)
                ctx.note("cleared the staged stack from node_%d" % cid)
            except Exception as e:  # noqa: BLE001 - a failed tidy-up must not overwrite the verdict
                ctx.note("could not clear node_%d slot %d: %s" % (cid, LUA_SLOT, e))
