"""Shakeout Task 4 T2 proof (NOT RUN YET, 2026-11-10: the test server was in use): build the shakeout world on a fresh copy, check
it, and save it as the save point "shakeout-world".

  1. BUILD: sandbox/t2/shakeout/world.py build_world(ctx) on the fresh 2026-10-18 copy the runner starts: forceload, every dock
     cell emptied (the copy's old turtles on docks are removed and named), bays 2-5 floor and pillars from bay 1, the block under
     every new dock copied from bay 1's twin with its NBT, the ATC computer, the GPS towers.
  2. CHECKS, each with its evidence count:
     - no recorded command clones a box with turtles in it (world.clone_violations over INTERVENTIONS);
     - every chunk of BASE_AREAS answers `forceload query` as marked;
     - every one of the 160 dock cells is air; under every one of the 128 new docks an ender chest whose NBT equals its source
       cell's (bay 1's twin, or the nearest bay-1 chest in the same row when the twin has none), lid direction aside
       (world.verify_world: `execute if block` + canonical `data get block`);
     - setblock really applies chest NBT: bay 1's chests are all on the default frequency 0,0,0, which a chest WITHOUT its NBT
       would also show, so one chest is set with Frequency 1,2,3 on a spare cell, read back, and taken away again;
     - every GPS tower is placed and Control.gps_hosts() finds it;
     - a probe computer in each of three far corners of the base: gps.locate gets a fix within 0.01 per axis of the probe's OWN
       computer block (CC measures a down-facing modem's distances from the block it faces: the computer; the towers announce
       their computer blocks, so a tower announcing its modem would show here as an offset); its own PING hears at least 6
       hosts; and the replies of the NEW towers alone trilaterate to the probe's block within 0.01 (so the fix does not lean on
       the old four). The measured fix and residuals are in the report, so a wrong offset is visible;
     - the ATC logs 'ATC online'. That line reaches the bridge through the central server's log relay, so "not online" can
       also mean the central server (or the bridge) is down: look at the server's own lines before blaming the ATC.
  3. The probes are taken away again, then save_point "shakeout-world" (under <run>/savepoints/), which must hold level.dat.

Run (pin the commit under test, 1x):
    python sandbox/t2/scenario.py sandbox/t2/scenarios/shakeout_world.py --pin <sha>
The save point stays in the run folder after the run stops; later runs restore it with Control.restore_save_point or copy it."""
import json
import os
import re
import tempfile

from shakeout import feeder, world  # noqa: E402  (sandbox/t2 is on the path: the runner put it there)

NAME = "shakeout_world"
PROBE_CORNERS = [(129, -2847), (271, -2770), (129, -2770)]     # NW, SE, SW corners of BASE_AREAS
PROBE_REPLY_CH = 64999                                          # no fleet program uses it (fleet 1-5, 1000+id, 65000, GPS 65534)
MIN_HOSTS = 6
FIX_TOLERANCE = 0.01                                            # per axis: gps.locate rounds to 0.01
NBT_PROBE_XZ = (133, -2843)                                     # a spare cell for the frequency read-back chest (NW, outside the bays)
NBT_PROBE_FREQ = (1, 2, 3)

PROBE_LUA = '''
local modem = peripheral.find("modem", function(_, m) return m.isWireless() end)
local r = { t = os.epoch("utc") }
if not modem then
  r.err = "no wireless modem"
else
  local x, y, z = gps.locate(5)
  if x then r.fix = { x, y, z } end
  modem.open(%d)
  modem.transmit(gps.CHANNEL_GPS, %d, "PING")
  local seen, hosts = {}, {}
  local timer = os.startTimer(4)
  while true do
    local e, side, ch, rch, msg, dist = os.pullEvent()
    if e == "modem_message" and ch == %d and type(msg) == "table" and #msg == 3 and dist then
      local k = table.concat(msg, ",")
      if not seen[k] then seen[k] = true; hosts[#hosts + 1] = { pos = msg, d = dist } end
    elseif e == "timer" and side == timer then
      break
    end
  end
  r.hosts = hosts
end
local f = fs.open("gps_probe.json", "w"); f.write(textutils.serialiseJSON(r)); f.close()
''' % (PROBE_REPLY_CH, PROBE_REPLY_CH, PROBE_REPLY_CH)


def probe_spot(c, x, z):
    """The lowest cell from y 68 up where the probe and its modem fit (read-only probes), or None."""
    for y in range(68, 200):
        if world.is_air(c, (x, y, z)) and world.is_air(c, (x, y + 1, z)):
            return (x, y, z)
    return None


def disk_json(c, cid, name):
    try:
        with open(os.path.join(c.disks, str(cid), name)) as f:
            return json.loads(f.read())
    except (OSError, ValueError):
        return {}


def steps(ctx):
    c = ctx.control
    online0 = len(ctx.log_lines("ATC online"))

    # 1. Build. (The RS capacity is read from the saved RS data before and after: housekeeping reads it the same way.)
    rs_world = getattr(ctx._raw, "world", None)
    cap_before = feeder.rs_capacity_of_world(rs_world) if rs_world else None
    report = world.build_world(ctx)
    ctx.note("build report: %s" % str({k: v for k, v in report.items() if k not in ("removed", "under")})[:3000])
    ctx.note("removed from bay cells (%d): %s" % (len(report["removed"]), report["removed"]))

    # 1b. Storage can only fill as a scheduled fault: the creative storage block stands, and the saved RS data shows capacity rose.
    rs = report.get("rs_capacity") or {}
    ctx.expect(bool(rs.get("pos")) and world._passed(ctx._raw, rs["pos"], world.RS_CREATIVE_BLOCK),
               "the creative item storage block stands next to the RS controller (%s)" % (rs,))
    world.restart_after_build(ctx)                          # the RS network only picks the block up when the world loads
    ctx.note("one world restart after the build (setup does the same before placing the fleet)")
    if rs_world:
        ctx._raw.command("save-all flush")
        ctx.wait_game(30)
        cap_after = feeder.rs_capacity_of_world(rs_world)
        ctx.expect(cap_after == float("inf") or (cap_before is not None and cap_after is not None and cap_after > cap_before),
                   "RS item capacity rose after the build and one world restart (before %s, after %s, from <world>/data/refinedstorage_disks.dat)"
                   % (cap_before, cap_after))
    else:
        ctx.note("no world folder on the control: RS capacity read-back skipped")

    # 2a. No clone of turtles.
    cmds = world.commands_of(ctx.interventions)
    bad = world.clone_violations(cmds)
    ctx.expect(cmds and not bad, "no clone left turtles standing (%d recorded console commands checked, %d clone(s), violations %s)"
               % (len(cmds), sum(1 for t in cmds if t.split()[:1] == ["clone"]), bad or "none"))

    # 2b. Forceload.
    chunks = sorted(world.area_chunks(world.BASE_AREAS))
    marked = [ch for ch in chunks if "is marked" in c.command("forceload query %d %d" % (ch[0] * 16, ch[1] * 16))]
    ctx.expect(len(marked) == len(chunks), "every BASE_AREAS chunk is force-loaded (%d of %d; not: %s)"
               % (len(marked), len(chunks), sorted(set(chunks) - set(marked))[:10]))

    # 2c. Docks and under-dock blocks.
    v = world.verify_world(ctx)
    ctx.expect(v["dock_air"] == v["dock_total"] == 160, "every dock cell is air (%d of %d)" % (v["dock_air"], v["dock_total"]))
    ctx.expect(v["under_ok"] == v["under_total"] == 128, "under every new dock an ender chest whose NBT equals its source cell's, lid "
               "direction aside (%d of %d; %d equal with the lid too; %d from the nearest bay-1 chest in the row, the rest from their bay-1 "
               "twin; first differences %s)" % (v["under_ok"], v["under_total"], v["under_exact"], v["under_fallback"],
                                                [b for b in v["bad"] if b.startswith("under")][:5]))
    ctx.note("under-dock: %d set, %d already the right chest, %d chests kept in floor cells %s; frequencies copied: %s" % (
        report["under"]["copied"], report["under"]["same"], len(report["floor"]["chests_kept"]), report["floor"]["chests_kept"],
        report["under"]["frequencies"]))
    ctx.note("left standing in bay cells (not docks; Task 5 identifies them): %s" % (report["left_standing"] or "none"))

    # 2c'. setblock applies chest NBT (else the check above could pass on chests that only show the default frequency).
    spot = probe_spot(ctx._raw, *NBT_PROBE_XZ)
    ctx.expect(spot is not None, "a spare cell for the NBT read-back chest near %s (%s)" % (NBT_PROBE_XZ, spot))
    if spot is not None:
        freq = dict(zip(("left", "middle", "right"), NBT_PROBE_FREQ))
        world.set_block(c, spot, world.CHEST, "{rot:0b,keepPacked:0b,Frequency:{left:%(left)d,middle:%(middle)d,right:%(right)d}}" % freq)
        back = re.sub(r"\s+", "", world.nbt_of(ctx._raw.block_data(spot)) or "")
        got = world.frequency_of(back) or ""
        ok = all(re.search(r"\b%s:%d\b" % kv, got) for kv in freq.items())
        ctx.expect(ok, "a chest set with Frequency %s reads back with it (read back: %s): setblock applies the NBT we copy"
                   % (NBT_PROBE_FREQ, got or back[:160] or "no block data"))
        c.command("setblock %d %d %d minecraft:air" % spot)
        ctx.expect(world.is_air(ctx._raw, spot), "the read-back chest at %s is gone again" % (spot,))

    # 2d. GPS towers placed and found.
    placed = {g["id"] for g in report["gps"]} | {g["id"] for g in report["gps_present"]}
    hosts = set(ctx._raw.gps_hosts())
    ctx.expect(len(placed) == len(world.GPS_TOWERS) and placed <= hosts, "all %d GPS towers stand and gps_hosts() finds them (placed %d, "
               "found %d of them, %d hosts in all, blocked %s)" % (len(world.GPS_TOWERS), len(placed), len(placed & hosts), len(hosts),
                                                                   report["gps_blocked"] or "none"))

    # 2e. Probes in three far corners.
    ctx.wait_game(10)                                           # the hosts boot
    probe_path = os.path.join(tempfile.mkdtemp(prefix="shakeout_gps_probe_"), "startup.lua")
    with open(probe_path, "w", encoding="utf8", newline="\n") as f:
        f.write(PROBE_LUA)
    old_hosts = {tuple(t) for t in world.EXISTING_GPS_HOSTS}
    new_towers = {tuple(t) for t in world.GPS_TOWERS}
    probes = []
    for x, z in PROBE_CORNERS:
        ctx.expect(world.covers(world.BASE_AREAS, x, z, x, z), "probe corner %d,%d lies in BASE_AREAS" % (x, z))
        spot = probe_spot(ctx._raw, x, z)
        ctx.expect(spot is not None, "a free cell for the probe at corner %d,%d (%s)" % (x, z, spot))
        if spot is None:
            continue
        pid = c.spawn_computer(spot[0], spot[1], spot[2], probe_path)
        probes.append((pid, spot))
        got = ctx.wait_until(lambda: disk_json(ctx._raw, pid, "gps_probe.json").get("t"), 120, poll=3)
        r = disk_json(ctx._raw, pid, "gps_probe.json")
        truth = tuple(spot)                                     # the probe's own computer block
        heard = r.get("hosts") or []
        fix = r.get("fix")
        ctx.note("probe #%d at %s: fix %s, %d hosts heard: %s" % (pid, spot, fix, len(heard), heard))
        ctx.expect(bool(got) and not r.get("err"), "probe #%d at %s ran (%s)" % (pid, spot, r.get("err") or "ok"))
        ctx.expect(len(heard) >= MIN_HOSTS, "probe at %s heard %d GPS hosts (need %d)" % (spot, len(heard), MIN_HOSTS))
        off = [round(a - b, 3) for a, b in zip(fix, truth)] if fix else None
        ok_fix = bool(fix) and max(abs(d) for d in off) <= FIX_TOLERANCE
        ctx.expect(ok_fix, "gps.locate at %s gave %s, the probe's computer is at %s (offset %s, tolerance %s per axis)"
                   % (spot, fix, truth, off, FIX_TOLERANCE))
        # every reply that is not one of the old four: a new tower announcing the wrong block is IN this set and shows as an offset
        fixes = [{"pos": tuple(h["pos"]), "d": h["d"]} for h in heard if tuple(h["pos"]) not in old_hosts]
        odd = sorted(f["pos"] for f in fixes if f["pos"] not in new_towers)
        ctx.note("probe at %s: %d new-tower replies, %d of them at a GPS_TOWERS position; announced elsewhere: %s"
                 % (spot, len(fixes), len(fixes) - len(odd), odd or "none"))
        pos, rms = world.trilaterate(fixes) if len(fixes) >= 4 else (None, None)
        noff = [round(a - b, 3) for a, b in zip(pos, truth)] if pos else None
        ok_new = pos is not None and max(abs(d) for d in noff) <= FIX_TOLERANCE
        ctx.expect(ok_new, "the %d NEW towers heard at %s alone trilaterate to %s (offset %s, rms residual %s), the probe is at %s"
                   % (len(fixes), spot, tuple(round(a, 3) for a in pos) if pos else None, noff, rms, truth))
        if len(heard) >= 4:
            ctx.note("all %d hosts at %s: least squares %s, rms %.3f" % ((len(heard), spot) + world.trilaterate(
                [{"pos": tuple(h["pos"]), "d": h["d"]} for h in heard])))

    # 2f. The ATC.
    on = ctx.wait_until(lambda: len(ctx.log_lines("ATC online")) > online0, 180)
    ctx.expect(bool(on), "the ATC computer #%s at %s logged 'ATC online' (%s; its lines come through the central server, so "
               "'nothing' can also mean the server or the bridge is down)" % (
                   report["atc"]["id"], report["atc"]["pos"], (ctx.log_lines("ATC online")[-1:] or ["nothing"])[0][:160]))

    # 3. Probes away, then the save point.
    for pid, (x, y, z) in probes:
        c.shutdown([pid])
        c.command("setblock %d %d %d minecraft:air" % (x, y + 1, z))
        c.command("setblock %d %d %d minecraft:air" % (x, y, z))
    gone = [p for _, p in probes if world.is_air(ctx._raw, p) and world.is_air(ctx._raw, (p[0], p[1] + 1, p[2]))]
    ctx.expect(len(gone) == len(probes), "the probe computers are gone before the save (%d of %d)" % (len(gone), len(probes)))
    dest = world.save_point(ctx, "shakeout-world")
    ctx.expect(os.path.isfile(os.path.join(dest, "level.dat")), "save point 'shakeout-world' written with level.dat (%s)" % dest)
    ctx.note("save point: %s" % dest)
