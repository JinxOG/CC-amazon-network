"""W3 card "Refuels leave turtles full of leftover coal - now returned to the chest" (fix 96add99, live since 1.9.138),
layer 2. Same as sandbox/scenarios/w3_leftover_coal.lua: every miner's tank is set to 2,000 (less than any zone needs)
and the three-sector job is ordered, so the dispatched miner refuels at its dock station before it sets off. It must log
'Refuelling at dock station' and 'Returned N leftover fuel item(s)', and carry no loose coal outside slot 14 once it has
left the depot (read with get_slot). Pin bfc2770 (the live commit). 1x, ~10 game minutes; the job is then cancelled."""
import re

NAME = "w3_leftover_coal"


def steps(ctx):
    ctx.wait_registered(14, 300)
    st = ctx.state()
    miners = sorted(int(n.replace("node_", "")) for n, t in (st.get("turtles") or {}).items()
                    if t.get("role") == "MINER" and t.get("status") == "IDLE")
    for cid in miners:
        ctx.control.set_fuel(cid, 2000)                                    # THE TEST
    ctx.note("set fuel 2000 on miners %r" % miners)
    ctx.dispatch("ORDER_MINE", {"x1": 1920, "z1": -2624, "x2": 1984, "z2": -2624, "minerCount": 2})
    went = ctx.wait_until(lambda: ctx.log_lines("Dispatched job_"), 600)
    ctx.expect(bool(went), "the job was dispatched")
    if not went:
        return
    node = went[0].split("-> ")[1].split()[0]
    cid = int(node.replace("node_", ""))
    job = re.search(r"Dispatched (job_\d+)", went[0]).group(1)
    left = ctx.wait_until(lambda: [l for l in ctx.log_lines("Exited depot") if node in l], 900)
    ctx.expect(bool(left), "%s left the depot" % node)
    ctx.wait_game(60)                                                      # its log lines arrive in batches
    ctx.expect(bool([l for l in ctx.log_lines("Refuelling at dock station") if node in l]), "it refuelled at its dock first")
    ctx.expect(bool([l for l in ctx.log_lines("leftover fuel item(s)") if node in l]), "it returned the leftover coal")
    loose = []
    for nbt_slot in range(16):                       # NBT slots are 0-15; Lua slot 14 (the coal reserve) is NBT 13
        if nbt_slot == 13:
            continue
        text = str(ctx.control.get_slot(cid, nbt_slot) or "")
        if "coal" in text and "ender" not in text:
            loose.append("slot %d: %s" % (nbt_slot + 1, text[:60]))
    ctx.expect(not loose, "no loose coal aboard outside slot 14 (%s)" % " ".join(loose))
    ctx.dispatch("CANCEL_JOB", {"jobId": job})
