"""W3 card "A miner rebooted underground, boxed in by rock, never measures its facing and waits forever" (fix b09b972, live
since 1.9.136), layer 2. Same as sandbox/scenarios/w3_boxed_in.lua: an idle miner is moved (turtle move, M4) to y=20
about 100 blocks east of the depot -- far enough that the dig-out is allowed (it never digs near the depot), near enough
that the base's chunk loading keeps it loaded (SANDBOX: move BOX if that spot is not loaded on T2). Stone is put on its
four sides and below; its shaft is opened up to y=100. It is shut down and turned on. It must log 'dug one block out to
measure facing', then 'Facing:', then get home ('Docked at bay'). Pin bfc2770 (the live commit). 1x, ~15 game minutes.
Note: being moved by hand makes the GPS 3 journal check (56ee642 onward) log 'JOURNAL DISAGREES WITH GPS' -- correct."""
NAME = "w3_boxed_in"
BOX = (260, 20, -2800)


def steps(ctx):
    ctx.wait_registered(14, 300)
    st = ctx.state()
    idle = sorted(n for n, t in (st.get("turtles") or {}).items() if t.get("role") == "MINER" and t.get("status") == "IDLE")
    ctx.expect(bool(idle), "an idle miner (%r)" % idle)
    if not idle:
        return
    node = idle[0]
    cid = int(node.replace("node_", ""))
    x, y, z = BOX
    c = ctx.control
    c.command("fill %d %d %d %d %d %d minecraft:stone" % (x - 1, y - 1, z - 1, x + 1, y + 1, z + 1))
    c.command("fill %d %d %d %d %d %d minecraft:air" % (x, y, z, x, 100, z))
    c.turtle_move(cid, x, y, z, "n")                                     # THE TEST: in a stone box at depth
    ctx.wait_game(2)
    dug0 = len([l for l in ctx.log_lines("dug one block out to measure facing") if node in l])
    face0 = len([l for l in ctx.log_lines("] Facing: ") if node in l])
    dock0 = len([l for l in ctx.log_lines("Docked at bay") if node in l])
    c.shutdown([cid])
    ctx.wait_game(2)
    c.turn_on([cid])
    ctx.note("%s (computer #%d) rebooted in a stone box at %d,%d,%d" % (node, cid, x, y, z))
    dug = ctx.wait_until(lambda: len([l for l in ctx.log_lines("dug one block out to measure facing") if node in l]) > dug0, 600)
    ctx.expect(bool(dug), "it dug one block out to measure its facing")
    ctx.expect(bool(ctx.wait_until(lambda: len([l for l in ctx.log_lines("] Facing: ") if node in l]) > face0, 300)), "and measured its facing")
    ctx.expect(bool(ctx.wait_until(lambda: len([l for l in ctx.log_lines("Docked at bay") if node in l]) > dock0, 1800)), "and got home to its dock")
