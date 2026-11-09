"""W3, the card "Miners rebooted during DUMPING journal the wrong facing" (fix 1bd4ee3), layer 2, ONE pair (a miner and
its loader). Same story as sandbox/scenarios/w3_dump_reboot_facing.lua on the real game.

Live 11-03 13:02: three of five miners rebooted while DUMPING logged JOURNAL FACING DIFFERS by 90/180 degrees, nobody had
touched them. Underground the block ahead is rock; detectFacing turns right until a step is free, and the boot check
compared the journal's facing from before those turns with the facing after them.

Here: the moment the miner reports DUMPING it is switched off, stone is set in front of it and to its right (only where
there is air, so nothing is dug up), and it is switched on: it must turn twice to measure. Its boot check must say the
journal agrees, and its "Facing:" line must differ from the facing it had (the evidence that it turned). The stones are
taken away after. Pin the commit under test. 1x."""
import re

NAME = "w3_dump_reboot_facing"
FACINGS = ("north", "east", "south", "west")
AHEAD = {"north": (0, -1), "east": (1, 0), "south": (0, 1), "west": (-1, 0)}


def block_facing(c, x, y, z):
    for f in FACINGS:
        if "Test passed" in c.command("execute if block %d %d %d #computercraft:turtle[facing=%s]" % (x, y, z, f)) or \
           "Test passed" in c.command("execute if block %d %d %d computercraft:turtle_advanced[facing=%s]" % (x, y, z, f)) or \
           "Test passed" in c.command("execute if block %d %d %d computercraft:turtle_normal[facing=%s]" % (x, y, z, f)):
            return f
    return None


def steps(ctx):
    ctx.wait_registered(14, 300)
    c = ctx.control
    sent0 = len(ctx.log_lines("Dispatched job_"))
    ctx.dispatch("ORDER_MINE", {"x1": 1920, "z1": -2624, "x2": 1984, "z2": -2624, "minerCount": 1})
    went = ctx.wait_until(lambda: ctx.log_lines("Dispatched job_")[sent0:], 600)
    ctx.expect(bool(went), "the mining job was dispatched (%s)" % (went[:1] if went else "nothing"))
    if not went:
        return
    miner = re.search(r"-> (node_\d+)", went[0]).group(1)
    cid = int(miner.split("_")[1])
    d0 = len(ctx.log_lines("%s phase: DUMPING" % miner))
    dumping = ctx.wait_until(lambda: ctx.log_lines("%s phase: DUMPING" % miner)[d0:], 5400)
    ctx.expect(bool(dumping), "%s reported DUMPING (%s)" % (miner, dumping[:1] if dumping else "nothing"))
    if not dumping:
        return

    # THE TEST: off, rock ahead and to the right, on.
    c.shutdown([cid])
    ctx.wait_game(3)
    pos = None
    for _ in range(5):
        try:
            pos = c._pos(cid)
            break
        except KeyError:
            ctx.wait_game(2)
    if pos is None:
        # switched off it may drop out of the computer list: the last /state position is just as good
        t = (ctx.state().get("turtles") or {}).get(miner) or {}
        pos = (t.get("x"), t.get("y"), t.get("z"))
    x, y, z = [int(v) for v in pos]
    before = block_facing(c, x, y, z)
    ctx.note("%s (#%d) off at %d,%d,%d facing %s" % (miner, cid, x, y, z, before))
    ctx.expect(before is not None, "read %s's facing from the world before the reboot (%s)" % (miner, before))
    if before is None:
        c.turn_on([cid])
        return
    right = FACINGS[(FACINGS.index(before) + 1) % 4]
    placed = []
    for f in (before, right):
        dx, dz = AHEAD[f]
        bx, bz = x + dx, z + dz
        if "Test passed" in c.command("execute if block %d %d %d air" % (bx, y, bz)):
            c.command("setblock %d %d %d minecraft:stone" % (bx, y, bz))
            placed.append((bx, y, bz))
    ctx.note("stone set at %s (only where there was air)" % placed)
    # Lines after the switch-on, by their own timestamp: the log files are not in arrival order, so counting lines
    # missed the miner's boot lines in run -a (they were there: "Facing: north", "Journal: agrees ... facing south").
    import datetime
    t_on = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S")
    c.turn_on([cid])

    def since(needle):
        return [l for l in ctx.log_lines(needle) if miner in l and l[:19] >= t_on]
    ctx.wait_until(lambda: since("Journal: agrees") or since("JOURNAL FACING DIFFERS") or since("Journal: nothing"), 300)
    ctx.wait_game(10)
    facing_line = since("] Facing: ")
    measured = None
    if facing_line:
        m = re.search(r"Facing: (\w+)", facing_line[0])
        measured = m.group(1) if m else None
    differs = since("JOURNAL FACING DIFFERS")
    agrees = since("Journal: agrees")
    ctx.expect(measured is not None and measured != before, "%s had to turn to measure: facing %s before, 'Facing: %s' at "
               "boot (the check below has something to judge)" % (miner, before, measured))
    ctx.expect(not differs, "no JOURNAL FACING DIFFERS (%s)" % (differs[:1] or "none"))
    ctx.expect(bool(agrees), "the boot check says the journal agrees (%s)" % (agrees[:1] or "nothing"))
    for (bx, by, bz) in placed:
        c.command("setblock %d %d %d air" % (bx, by, bz))
    ctx.dispatch("RECALL_ALL", {"reason": "w3_dump_reboot_facing"})
    home = ctx.wait_until(lambda: [l for l in ctx.log_lines("Docked at bay") if miner in l], 1800)
    ctx.note("%s back home after the test: %s" % (miner, bool(home)))
