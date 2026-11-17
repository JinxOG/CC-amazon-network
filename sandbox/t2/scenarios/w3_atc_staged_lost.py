"""W3, 2026-11-16: T2 shakeout-side-d (pin 99a7f03), layer 2, ONE pair. A radio loss lost node_216's SUPPORT_STAGED (sent
once); its delivery node_208 waited on at the dispatch hole, node_216 stepped forward into the hole cell where node_208
stood -- inside the base a blocked move waits for ever -- and at 600 s node_208 turned for home through node_216: each
blocked the other's only way out and no departure was let in again. The fix: at staging the support waits for the hole
cell to empty, saying SUPPORT_STAGED again every 5 s, and goes home if its delivery stands it down or never goes.

  1. The ATC is placed (as in w3_atc_pair.py); the arrivals side is force-loaded; once the pair is known every other
     delivery and support is held.
  2. The moment the delivery says "At hole", every radio message on the turtles' local channel is lost for 90 s (the
     control mod's radio loss; only this pair is moving). Its support stages inside that window: its first
     SUPPORT_STAGED is lost, as node_216's was.
  3. PART 2, the same run's second cause (sim w3_side_atc on 17d6b30): a turtle waiting in the base without a word to
     the ATC was taken for dead at 180 s and its section given away under it. A second delivery is ordered; once the
     ATC has let its departure in, every GPS host is shut down for 300 s and the delivery is rebooted where it stands:
     it cannot measure its facing and waits there. A computer that is not a turtle sends the ATC an empty report every
     10 s, as a busy base's turtles would (an ATC that hears nobody counts nobody's silence).
CHECKS (each with its evidence): part 1 -- the support staged inside the loss and said SUPPORT_STAGED again (evidence);
the pair went down together; nobody reported STUCK; the delivery completed. Part 2 -- the rebooted delivery waited over
180 s for a fix (evidence); the ATC never gave away a section it stood in; nobody stayed STUCK; the delivery
completed. At the end the ATC holds nothing and every turtle is on its dock. Pin the commit under test. 1x."""
import datetime
import importlib.util
import os
import re
import tempfile

NAME = "w3_atc_staged_lost"
DEST = {"x": 196, "y": 67, "z": -2761}
LOSS_S = 90
GPS_DOWN_S = 300
CHATTER = r'''
local proto = require("protocol")
local m = peripheral.find("modem")
m.open(9999)
local n = 0
while true do n = n + 1; proto.send(m, proto.CH_ATC, proto.encode(proto.MSG.ATC_REPORT, "node_chatter", "atc", { route = {}, nonce = n })); sleep(10) end
'''
_spec = importlib.util.spec_from_file_location("w3_atc_pair", os.path.join(os.path.dirname(os.path.abspath(__file__)), "w3_atc_pair.py"))
_pair = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_pair)


def now_iso():
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S")


def steps(ctx):
    ctx.wait_registered(14, 300)
    c = ctx.control
    pin = getattr(ctx, "pin", None) or "HEAD"
    tmp = tempfile.mkdtemp(prefix="w3staged")
    ctx.note("forceload the arrivals side: %s" % c.command("forceload add 224 -2816 271 -2769").strip()[:100])
    start = os.path.join(tmp, "atc_startup.lua")
    with open(start, "w", encoding="utf8", newline="\n") as f:
        f.write(_pair.show(pin, "atc.lua"))
    files = {name: _pair.show(pin, name) for name in _pair.ATC_FILES}
    files["role.txt"] = "atc"
    t_atc = now_iso()
    x, y, z = c.free_spot()
    aid = c.spawn_computer(x, y, z, start, files=files)
    ctx.expect(bool(ctx.wait_until(lambda: [l for l in ctx.log_lines("settled: rebuilt") if l[:19] >= t_atc], 240)),
               "the ATC came online and settled")
    ctx.wait_until(lambda: len([l for l in ctx.log_lines("ATC heard") if l[:19] >= t_atc]) >= 10, 180)
    proto_text = _pair.show(pin, "protocol.lua")
    m = re.search(r"CH_LOCAL\s*=\s*(\d+)", proto_text)
    ch_local = int(m.group(1)) if m else None
    ctx.expect(ch_local is not None, "the turtles' local channel is known (%s)" % ch_local)
    ctx.expect("awaitHoleClear" in _pair.show(pin, "turtle_base.lua"), "the pinned commit carries the hole-clear wait (the commit under test)")

    def since(needle, t):
        return [l for l in ctx.log_lines(needle) if l[:19] >= t]

    def by(lines, who):
        return [l for l in lines if ("[%s]" % who) in l or ("%s#" % who) in l]

    def server_done(j, t):
        return [l for l in since("Job complete: %s" % j, t) if "server#" in l and l.rstrip().endswith(j)] if j else []

    t1 = now_iso()
    ctx.dispatch("ORDER_DELIVERY", {"items": [{"name": "minecraft:cobblestone", "count": 16}], "destination": DEST})
    went = ctx.wait_until(lambda: since("Dispatched job_", t1), 300)
    mm = went and re.search(r"Dispatched (job_\d+) \[DELIVER\] -> (node_\d+)\s+support (job_\d+) -> (node_\d+)", went[0])
    ctx.expect(bool(mm), "a delivery and its support were dispatched (%s)" % (went[:1] if went else "nothing"))
    if not mm:
        return
    job1, dname, sjob1, sname = mm.groups()
    held = []
    for name, t in sorted((ctx.state().get("turtles") or {}).items()):
        if t.get("role") in ("DELIVERY", "SUPPORT") and name not in (dname, sname):
            ctx.dispatch("HOLD_TURTLE", {"turtleId": name, "reason": NAME})
            held.append(name)
    ctx.note("pair %s + %s; held the others: %s" % (dname, sname, held))

    at_hole = ctx.wait_until(lambda: by(since("At hole", t1), dname), 1200)
    ctx.expect(bool(at_hole), "%s reached the hole (%s)" % (dname, at_hole[:1] if at_hole else "nothing"))
    if not at_hole:
        return
    t_loss = now_iso()
    # THE FAULT: everything on the turtles' local channel is lost for LOSS_S -- the support's first SUPPORT_STAGED with
    # it (node_216's was sent once, and lost). Every other pair is held, so only this pair talks there. (Run a looked
    # for the delivery's computer by its position to aim the loss at it alone: `t2 computers` gave no turtle there.)
    reply = c.radio_loss(0, LOSS_S * 1000, 1.0, channel=ch_local)
    ctx.note("lost every message on channel %s for %d s: %s" % (ch_local, LOSS_S, reply))

    done1 = ctx.wait_until(lambda: server_done(job1, t1) and server_done(sjob1, t1), 3600)
    staged = by(since("Staged behind hole", t_loss), sname)
    in_loss = [l for l in staged if l[:19] <= (datetime.datetime.strptime(t_loss, "%Y-%m-%dT%H:%M:%S")
                                                 + datetime.timedelta(seconds=LOSS_S)).strftime("%Y-%m-%dT%H:%M:%S")]
    repeated = by(since("SUPPORT_STAGED repeated", t_loss), sname)
    ctx.expect(bool(in_loss) and bool(repeated), "%s staged inside the loss and said SUPPORT_STAGED again: the checks below "
               "have something to judge (%s; %d repeat report(s))" % (sname, in_loss[:1] if in_loss else "staged outside it", len(repeated)))
    joint = by(since("Support staged", t1), dname)
    ctx.expect(bool(joint), "%s and %s went down together (%s)" % (dname, sname, joint[:1] if joint else "nothing"))
    stuck = since("STUCK ", t1)
    ctx.expect(not stuck, "nobody reported STUCK (%s)" % (stuck[0][-150:] if stuck else "none"))
    ctx.expect(bool(done1), "%s and its support's %s completed (the server's lines)" % (job1, sjob1))

    # ── PART 2: rebooted in the base with no GPS ────────────────────────────────────────────────────────────────
    cstart = os.path.join(tmp, "chatter.lua")
    with open(cstart, "w", encoding="utf8", newline=chr(10)) as f:
        f.write(CHATTER)
    cx, cy, cz = c.free_spot()
    if (cx, cy, cz) == (x, y, z):
        cz += 3
    cid = c.spawn_computer(cx, cy, cz, cstart, files={"protocol.lua": proto_text})
    ctx.note("chatter computer #%d: an empty ATC_REPORT every 10 s" % cid)
    t2 = now_iso()
    ctx.dispatch("ORDER_DELIVERY", {"items": [{"name": "minecraft:cobblestone", "count": 16}], "destination": DEST})
    went2 = ctx.wait_until(lambda: since("Dispatched job_", t2), 600)
    m2 = went2 and re.search(r"Dispatched (job_\d+) \[DELIVER\] -> (node_\d+)", went2[0])
    job2, d2 = (m2.group(1), m2.group(2)) if m2 else (None, None)
    ctx.expect(d2 == dname, "the second order went to the same delivery (%s)" % (went2[:1] if went2 else "nothing"))
    admitted = ctx.wait_until(lambda: [l for l in since("admitted %s:" % dname, t2)], 900)
    ctx.expect(bool(admitted), "its departure was let in (%s)" % (admitted[:1] if admitted else "nothing"))
    if not (job2 and admitted):
        return
    ctx.wait_game(3)
    t3 = now_iso()
    did = int(dname.split("_")[1])          # on the test server a turtle's node id is its computer id
    hosts = c.gps_down()
    c.shutdown([did])
    ctx.wait_game(2)
    c.turn_on([did])
    ctx.note("GPS hosts %s down for %d s; rebooted #%d (%s)" % (hosts, GPS_DOWN_S, did, dname))
    ctx.wait_game(GPS_DOWN_S)
    c.gps_up()
    done2 = ctx.wait_until(lambda: server_done(job2, t2), 3600)
    waits = by(since("NOT moving until both are measured", t3), dname)
    meas = by(since("Position and facing measured after", t3), dname)
    tries = int((re.search(r"measured after (\d+) retries", meas[-1]) or [0, 0])[1]) if meas else 0
    ctx.expect(bool(waits) and tries * 10 > 180, "%s rebooted in the base and waited there over 180 s for a fix (%d tries "
               "of 10 s): the check below has something to judge" % (dname, tries))
    lost = [l for l in since("booking dropped, including", t3) if dname in l]
    ctx.expect(not lost, "the ATC never gave away a section %s stood in (%s)" % (dname, lost[0][-150:] if lost else "none"))
    # Rebooted in the hole cell (run c), the delivery waits for its support to give up and go home before it can move:
    # a STUCK it recovers from. One it never recovers from is the failure.
    stuck2 = since("STUCK ", t3)
    moving = since("Moving again after STUCK", t3)
    unrecovered = [l for l in stuck2 if not any(re.search(r"\[(node_\d+)\]", l) and re.search(r"\[(node_\d+)\]", l).group(1) in m
                                                and m[:23] > l[:23] for m in moving)]
    ctx.expect(not unrecovered, "nobody stayed STUCK after the reboot (%d STUCK, %d recovered; %s)"
               % (len(stuck2), len(stuck2) - len(unrecovered), unrecovered[0][-150:] if unrecovered else "none"))
    ctx.expect(bool(done2), "%s completed (the server's line)" % job2)

    for n in held:
        ctx.dispatch("RELEASE_TURTLE", {"turtleId": n})
    ctx.wait_game(120)
    last = (since("section(s) held", t1) or [""])[-1]
    ctx.expect(" 0 section(s) held" in last, "the ATC holds no section at the end (%s)" % last[-120:])
    turtles = ctx.state().get("turtles") or {}
    off = [n for n, t in turtles.items() if t.get("dockX") is not None and not (t.get("x") == t.get("dockX") and t.get("z") == t.get("dockZ"))]
    ctx.expect(turtles and not off, "every registered turtle is on its dock at the end (%d of %d not: %s)" % (len(off), len(turtles), off))
    c.shutdown([aid, cid])
