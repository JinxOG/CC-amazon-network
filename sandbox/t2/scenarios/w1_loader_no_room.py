"""W1 card "A loader dig with no free slot destroys the loader", LAYER 2 -- making the guard actually FIRE.

WHAT IS AND IS NOT ALREADY PROVEN. The fix (4005f4b, 1.9.126) refuses the retrieval dig when nothing is free and returns
`no_room_for_loader`, leaving the loader STANDING instead of destroyed. The live record says the FAULT is gone: across the 13
days in retention there were about 132 completed sectors -- one loader retrieval each -- with zero `loader_lost_after_dig`.

But there were also zero `no_room_for_loader`, which means THE GUARD HAS NEVER FIRED IN THE WORLD. The pre-approach dump kept
room in all 132, so what is proven live is the absence of the fault, not the behaviour of the refusal. That path rests on a unit
test and two mutants. This run is the attempt to exercise it for real, which is the honest reason the card's layer 2 said NOT
RUN and should not have been left there.

HOW THE PACK IS MADE UNBANKABLE, and why the obvious way no longer works. The field fault was node_139 carrying raw thorium
that had been recorded as protected hardware, so the dump kept it and freed nothing. That route is CLOSED by current code: the
init scan now prints "Slot N holds X -- not hardware, so it will be banked, not protected" and deliberately does not record a
non-hardware item, because recording one filled all four miners with deepslate on 2026-10-03. Reproducing the original
staging would therefore test a bug that has already been fixed somewhere else.

So the pack is filled with a GENUINE hardware name, `enderstorage:ender_chest`. `equipment.isHardwareItem` returns true for
it, `shouldDump` keeps anything whose name is in protectedItemNames, and the ore chest's name is there because the miner
carries one in slot 16. The dump therefore banks nothing, every mining slot stays occupied, and the retrieval dig meets a full
pack -- which is exactly the state the guard exists for.

THE STAGING IS ARTIFICIAL AND THE CODE PATH IS REAL. No miner would carry nine ender chests. What this run exercises is
`freeSlots == 0` at the instant of the dig, reached by a route the fleet can genuinely reach (an unbankable pack), and the
refusal, the surviving loader and the absence of a destroyed one are all real behaviour. Said plainly rather than dressed up as
a field reproduction.

AND IT MAY NOT GET THERE, which is why the anchors below matter more than usual. A miner with a full pack may refuse the job,
bank at the dock, or fail somewhere earlier for reasons that are not this card. Every assertion about the guard is gated on a
positive anchor -- the miner must have placed a loader and reached retrieval -- so a run that falls over early reports
INCONCLUSIVE instead of passing. A pass here must mean the guard fired, not that nothing happened.

1x. The pack is staged while the miner is DOCKED, where its position is stable: set_slot needs several commands and a turtle in
flight moves between them, which is the trap that kept the slot-14 card's second gate on its unit test.
"""
NAME = "w1_loader_no_room"

ZONE = {"x1": 1920, "z1": -2624, "x2": 1920, "z2": -2624, "minerCount": 1}

# Lua slots 5..13 are the mining payload; NBT Items[].Slot is 0-BASED, so Lua n is NBT n-1 (measured on the slot-14 card:
# NBT 0 geo scanner = Lua 1, NBT 14/15 the two ender chests = Lua 15/16). Filling the payload is enough: the hardware slots
# are already occupied, so with these nine full there is nothing free anywhere.
MINE_LUA_FIRST, MINE_LUA_LAST = 5, 13
FILL_ITEM = "enderstorage:ender_chest"

REFUSED = "no_room_for_loader"
LOST = "loader_lost_after_dig"
PLACED = "phase: PLACING_LOADER"
RETRIEVING = "RETRIEVING"


def steps(ctx):
    ctx.wait_registered(14, 300)
    c = ctx.control

    # Pick a docked miner and remember which, so every later check is about that node and not any miner's unrelated trouble.
    miners = sorted(int(n.replace("node_", "")) for n, t in (ctx.state().get("turtles") or {}).items()
                    if isinstance(t, dict) and (t.get("role") or "").upper() == "MINER" and n.replace("node_", "").isdigit())
    ctx.expect(bool(miners), "found miners to stage (%s)" % miners)
    if not miners:
        return
    cid = miners[0]
    node = "node_%d" % cid
    ctx.note("staging %s; miners present: %s" % (node, miners))

    # ---- STAGE, AND VERIFY IT TOOK. An unverified staging is how run w1-skip-c measured nothing at all. ----
    staged = 0
    for lua in range(MINE_LUA_FIRST, MINE_LUA_LAST + 1):
        try:
            got = c.set_slot(cid, lua - 1, FILL_ITEM, 1)
        except Exception as e:  # noqa: BLE001 - a refused write is a finding, not a crash
            ctx.note("slot %d (NBT %d) refused: %s" % (lua, lua - 1, e))
            continue
        if FILL_ITEM.split(":")[-1] in str(got):
            staged += 1
        else:
            ctx.note("slot %d (NBT %d) read back as %s" % (lua, lua - 1, got))
    ctx.note("payload slots staged: %d of %d" % (staged, MINE_LUA_LAST - MINE_LUA_FIRST + 1))
    ctx.expect(staged == MINE_LUA_LAST - MINE_LUA_FIRST + 1,
               "every mining slot of %s holds an unbankable hardware item before the job (%d of %d, read back from the "
               "world) -- with the pack not actually full the guard cannot fire and this run would prove nothing"
               % (node, staged, MINE_LUA_LAST - MINE_LUA_FIRST + 1))
    if staged == 0:
        return

    base = {k: len(ctx.log_lines(k)) for k in (REFUSED, LOST, PLACED, RETRIEVING)}
    before_ids = {int(l.get("computer")) for l in c.chunk_loaders()}
    ctx.dispatch("ORDER_MINE", ZONE)

    # ---- ANCHOR: it must get as far as having a loader in the world to retrieve. ----
    placed = ctx.wait_until(lambda: len(ctx.log_lines(PLACED)) > base[PLACED], 2 * 3600)
    ctx.expect(bool(placed),
               "a miner placed its chunk loader (%d new PLACING_LOADER lines) -- without a loader standing there is no "
               "retrieval dig and nothing below is about this card"
               % (len(ctx.log_lines(PLACED)) - base[PLACED]))
    if not placed:
        ctx.note("INCONCLUSIVE: never placed a loader, so the guard was never reached")
        return

    reached = ctx.wait_until(lambda: len(ctx.log_lines(RETRIEVING)) > base[RETRIEVING]
                             or len(ctx.log_lines(REFUSED)) > base[REFUSED], 2 * 3600)
    ctx.note("new RETRIEVING lines: %d; new refusals: %d"
             % (len(ctx.log_lines(RETRIEVING)) - base[RETRIEVING], len(ctx.log_lines(REFUSED)) - base[REFUSED]))
    ctx.expect(bool(reached),
               "and reached the retrieval, where the guard lives (RETRIEVING or a refusal appeared)")
    if not reached:
        ctx.note("INCONCLUSIVE: never reached loader retrieval, so the guard was never reached")
        return

    ctx.wait_game(240)
    refusals = ctx.log_lines(REFUSED)[base[REFUSED]:]
    losses = ctx.log_lines(LOST)[base[LOST]:]
    for l in refusals[:4]:
        ctx.note("refusal: %s" % l.strip()[-140:])
    for l in losses[:4]:
        ctx.note("LOSS: %s" % l.strip()[-140:])

    # ---- THE CARD: no loader destroyed. This holds whether or not the guard fired. ----
    ctx.expect(not losses,
               "no loader was destroyed by the dig (%d '%s' lines) -- this is the fault the card is about, and the live "
               "record already shows it absent across about 132 retrievals" % (len(losses), LOST))

    # ---- AND THE PART ONLY THIS RUN CAN SHOW: the refusal actually fired, by name. ----
    ctx.expect(bool(refusals),
               "the guard REFUSED the dig by name (%d '%s' lines) -- the live record has zero of these, so this path has "
               "never run in the world and rests on a unit test and two mutants; a run that gets here without it means the "
               "pack was not full at the instant of the dig" % (len(refusals), REFUSED))

    # ---- AND THE LOADER IS STILL STANDING, which is the whole point of refusing. ----
    #
    # Asked of the WORLD, not of the log. My first draft counted lines containing "Loader beacon", and there is no such
    # positive line -- the only beacon strings in the fleet are about a beacon being LOST, so that check would have read 0
    # and failed for a reason that has nothing to do with the card. `chunk list` is the right instrument and the same one
    # the lane probe uses: it reports the loader turtles whose computers are loaded, by id.
    after_ids = {int(l.get("computer")) for l in c.chunk_loaders()}
    survived = sorted(after_ids - before_ids)
    ctx.note("loader ids before the job: %s" % sorted(before_ids))
    ctx.note("loader ids after the refusal: %s" % sorted(after_ids))
    ctx.expect(len(after_ids) >= len(before_ids),
               "no chunk loader disappeared from the world across the job (%d listed before, %d after; new: %s) -- "
               "'standing but unretrieved' is the state this card trades for 'destroyed', so a loader surviving a refusal "
               "is the thing worth proving, and a destroyed one would be gone from this list for good"
               % (len(before_ids), len(after_ids), survived or "none"))
