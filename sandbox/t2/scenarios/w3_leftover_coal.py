"""W3 card "Refuels leave turtles full of leftover coal - now returned to the chest" (fix 96add99, live since 1.9.138),
layer 2. An idle, docked miner's tank is set to 70,000 (below the 80 % at which a dock refuel runs, with room for only
~375 coal), then FORCE_REFUEL makes it refuel from its dock station. A refuel pulls coal into its free working slots and
burns only what the tank takes, so with ~700 coal in the station chest there MUST be leftovers: it must log
'Returned N leftover fuel item(s)' and carry no loose coal outside slot 14 afterwards (read with get_slot).
Revised 2026-10-27: the first version drained the tank to 2,000 and dispatched a job; the refuel then burned every coal
the chest held (+56,320, tank 58,318) and there was nothing left over to return -- inconclusive, not a pass or a fault.
Revised again 2026-10-27: on bfc2770 this FAILED (73 then 265 coal aboard, no return) -- the station and fuel chests
are kept full by the base, so nothing can go back. The fix takes only what the tank burns; the 'Returned' line is
now recorded, not required, and the tank must be full with no loose coal. Pin the fix commit. 1x, ~5 game minutes."""
NAME = "w3_leftover_coal"


def steps(ctx):
    ctx.wait_registered(14, 300)
    st = ctx.state()
    idle = sorted(n for n, t in (st.get("turtles") or {}).items() if t.get("role") == "MINER" and t.get("status") == "IDLE")
    ctx.expect(bool(idle), "an idle miner (%r)" % idle)
    if not idle:
        return
    node = idle[0]
    cid = int(node.replace("node_", ""))
    ctx.control.set_fuel(cid, 70000)                                     # THE TEST: room for ~375 coal only
    ctx.wait_game(12)                                                    # the next heartbeat reports the new level
    r0 = len([l for l in ctx.log_lines("leftover fuel item(s)") if node in l])
    f0 = len([l for l in ctx.log_lines("FORCE_REFUEL received") if node in l])
    full_lines = lambda: [l for l in ctx.log_lines("Refuelled +") if node in l and "100000/100000" in l]
    d0 = len(full_lines())
    ctx.dispatch("FORCE_REFUEL", {"turtleId": node})
    ctx.note("%s (computer #%d): fuel set to 70000, FORCE_REFUEL sent" % (node, cid))
    got = ctx.wait_until(lambda: len([l for l in ctx.log_lines("FORCE_REFUEL received") if node in l]) > f0, 120)
    ctx.expect(bool(got), "%s refuelled at its dock on FORCE_REFUEL" % node)
    full = ctx.wait_until(lambda: len(full_lines()) > d0, 180)
    ctx.expect(bool(full), "its tank was filled ('Refuelled +N (now 100000/100000)')")
    ctx.wait_game(10)
    ret = len([l for l in ctx.log_lines("leftover fuel item(s)") if node in l]) - r0
    ctx.note("'Returned N leftover' lines since the refuel: %d (recorded, not required)" % ret)
    loose = []
    for nbt_slot in range(16):                       # NBT slots are 0-15; Lua slot 14 (the coal reserve) is NBT 13
        if nbt_slot == 13:
            continue
        text = str(ctx.control.get_slot(cid, nbt_slot) or "")
        if "coal" in text and "ender" not in text:
            loose.append("slot %d: %s" % (nbt_slot + 1, text[:60]))
    ctx.expect(not loose, "no loose coal aboard outside slot 14 (%s)" % " ".join(loose))
