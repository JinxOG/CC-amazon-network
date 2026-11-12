"""W3, shakeout Task 2 (2026-11-10): PER-BAY DOCK TYPES, layer 2 of the card "the server picks docks by type, and moves
misplaced live miners once". Layer 1 is sandbox/scenarios/w3_bay_types150.lua. One delivery pair, plus ONE MINER DOCKED IN A
SUPPORT-SIDE (north) BAY, on the real game, under the ATC:

  0. STAGING, checked, never assumed (docs: reference T2 staging traps). Bays 2-5 must exist: this world copy has only bay 1
     built, and the shakeout kit (Part 2) builds the others. The north dock used here (support bay 2, first slot: 167,67,-2797)
     and every cell of its departure and return routes must be air, and the block under the dock must not be. If not, the
     run RAISES rather than measuring a miner walking into a wall. The arrivals side is force-loaded (it does not tick here).
  1. The ATC computer is placed by the runner, as in w3_atc_pair.py.
  2. THE MOVE PATH, as the live rollout will meet it: the world copy's dock_assignments.dat predates per-bay types and has its
     miners on worker bay 1 docks, which are DELIVERY docks now. Each such miner must log 'Dock moved: <id> from bay 1 row <r>
     (DELIVERY) to bay <b> row <r> (MINER) -- per-bay types' exactly once, and end standing on that MINER dock.
  3. ONE MINER IS GIVEN THE NORTH DOCK. With the dispatch computer off, its dock_assignments.dat is rewritten from /state with
     the miner on 167,-2797 (by position, the file's own format since this card); the computer is turned back on, the fleet
     re-registers, and the miner is rebooted (REBOOT_TURTLE) so its boot homing drives it to the new dock. It must stand there
     and the server must have it there. The file write is recorded in INTERVENTIONS.
  4. The other miners are held (HOLD_TURTLE), so this one is chosen. One mine job (one sector) and one delivery: the miner's
     departure is ADMITTED by the ATC, it mines, comes home THROUGH THE ATC and docks at its north dock again; the delivery pair
     completes and both dock.
  5. At the end: every turtle on a dock of its own type, the one the server has for it; nobody waited over 30 s at a section
     edge for an answered ATC request; nobody STUCK.

On code before this card step 2 logs nothing and step 3's file is not read (it has no typed lists), so the miner is given a
DELIVERY dock and checks 2, 3 and 5 fail. Pin the commit under test. 1x: the ATC's timers are real-time epoch milliseconds.
Not run yet (2026-11-10): the machine's memory was in use."""
import importlib.util
import os
import re
import tempfile

from shakeout import world

NAME = "w3_bay_types"
_spec = importlib.util.spec_from_file_location("w3_atc_pair", os.path.join(os.path.dirname(os.path.abspath(__file__)), "w3_atc_pair.py"))
_pair = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_pair)

WHITE_Z, RED_Z = -2803, -2801
NORTH_DOCK = (167, -2797)          # support bay 2 (centre x 171), slot dx -4, row A: a MINER dock since per-bay types
NORTH_CENTRE_X = 171


def cell_type(p):
    """The agreed type of the dock cell at p (spec 4.1), or None: worker bay 1 DELIVERY, support bay 1 SUPPORT, the rest MINER."""
    x, y, z = p
    if y != 67 or z not in (-2806, -2810, -2797, -2793):
        return None
    for b in range(5):
        dx = x - (157 + 14 * b)
        if dx != 0 and -4 <= dx <= 4:
            if b > 0:
                return "MINER"
            return "DELIVERY" if z in (-2806, -2810) else "SUPPORT"
    return None


def north_route_cells():
    """Every cell of the north dock's departure and return routes (waypoints.lua: aisle 2 back, return aisle 3 back, the bay's
    centre column to each taxiway), plus the dock itself."""
    x, z = NORTH_DOCK
    aisle, ret = z + 2, z + 3                       # north rows exit AWAY from the taxiway, to larger z
    cells = {(x, z)}
    for az in (aisle, ret):
        for cx in range(min(x, NORTH_CENTRE_X), max(x, NORTH_CENTRE_X) + 1):
            cells.add((cx, az))
    for cz in range(WHITE_Z, ret + 1):
        cells.add((NORTH_CENTRE_X, cz))
    return sorted(cells)


def server_computer(ctx):
    """The RUNNING dispatch computer: the last 'Central server online ... ID: node_NNN' line (see w3_low_disk.py for why not a disk scan)."""
    lines = ctx.log_lines("Central server online")
    if not lines:
        return None
    try:
        return int(lines[-1].rsplit("node_", 1)[1].split()[0])
    except (IndexError, ValueError):
        return None


def turtles(ctx):
    t = ctx.state().get("turtles") or {}
    return dict(t.items()) if isinstance(t, dict) else {e.get("id"): e for e in t}


def on_own_dock(ctx, name, e, pos):
    """(ok, why): standing on a dock cell of its own type, and the server's dock for it is that cell."""
    p = pos.get(name)
    role = (e.get("role") or "").upper()
    want = {"MINER": "MINER", "DELIVERY": "DELIVERY", "SUPPORT": "SUPPORT"}.get(role)
    if want is None:
        return True, "not a docking role"
    if not p:
        return False, "no position"
    ok = cell_type(p) == want and e.get("dockX") == p[0] and e.get("dockZ") == p[2]
    return ok, "%s %s at %s, cell %s, server dock %s,%s" % (name, role, p, cell_type(p), e.get("dockX"), e.get("dockZ"))


def must(ctx, text, want="Test passed"):
    out = ctx.control.command(text)
    if want not in out:
        raise RuntimeError("staging: %r -> %r" % (text, out.strip()[:160]))
    return out


def side_indexes(cells):
    """{(x, z): (side, index)}: each dock's place in its side's list, in waypoints.lua's generation order (bay, then slot dx
    ascending, then row A before B), which is what a dock index meant before per-bay types and what the saver still writes."""
    out = {}
    for side in ("WORKER", "SUPPORT"):
        mine = sorted((c for c in cells if c["side"] == side), key=lambda c: (c["bay"], c["slot"], c["row"]))
        for i, c in enumerate(mine, 1):
            out[(c["x"], c["z"])] = (side, i)
    return out


def dock_file_text(pos_by_name, cells, with_bypos):
    """dock_assignments.dat text for {turtle: (x, z)}: the legacy lists by side index (DELIVERY = worker side, SUPPORT = support side),
    plus byPos when with_bypos -- the way the current saver writes it (waypoints.lua saveDockAssignments; byPos alone is ignored by
    the loader unless the legacy lists say the same). Without byPos it is the file an OLD server wrote."""
    idx = side_indexes(cells)
    lists = {"DELIVERY": [], "SUPPORT": []}
    by_pos = []
    for n, (x, z) in sorted(pos_by_name.items()):
        side, i = idx[(x, z)]
        lists["DELIVERY" if side == "WORKER" else "SUPPORT"].append('[%d] = "%s"' % (i, n))
        by_pos.append('["%d,%d"] = "%s"' % (x, z, n))
    parts = []
    if with_bypos:
        parts.append("byPos = { %s }" % ", ".join(by_pos))
    for k in ("DELIVERY", "SUPPORT"):
        parts.append("%s = { %s }" % (k, ", ".join(lists[k])))
    return "{ %s }" % ", ".join(parts)


def docked_roster(ctx, roster):
    """{name: entry} once EVERY turtle in roster is registered with a dock, else None."""
    ts = turtles(ctx)
    ok = all(n in ts and isinstance(ts[n].get("dockX"), (int, float)) and isinstance(ts[n].get("dockZ"), (int, float)) for n in roster)
    return ts if ok else None


def rewrite_dock_file(ctx, sid, text, why, roster):
    """Server off, its disk's dock_assignments.dat replaced, server on and answering again. Recorded in INTERVENTIONS.
    Returns only when every turtle in roster has registered again with a dock: a file built from a half-registered fleet leaves
    turtles out, and the server hands those fresh docks (run d: node_179 missing from the file, put on 168,-2806)."""
    c = ctx.control
    c.shutdown([sid])
    ctx.wait_game(5)
    with open(os.path.join(c.disks, str(sid), "dock_assignments.dat"), "w", encoding="utf8", newline="\n") as f:
        f.write(text)
    ctx.interventions.append({"verb": "write_disk", "args": [repr(sid), repr("dock_assignments.dat")],
                              "kwargs": {"text": repr(text[:300])}, "game_seconds": ctx.game_seconds()})
    ctx.note("dock_assignments.dat on #%d rewritten (%s): %s" % (sid, why, text[:400]))
    online0 = len(ctx.log_lines("Central server online"))
    c.turn_on([sid])
    ok = ctx.wait_until(lambda: len(ctx.log_lines("Central server online")) > online0, 300)
    ctx.expect(bool(ok), "the dispatch computer came back (%s)" % why)
    back = ctx.wait_until(lambda: docked_roster(ctx, roster), 300)
    ctx.expect(bool(back), "all %d turtles registered again with a dock after the restart (missing: %s)" % (
        len(roster), sorted(set(roster) - set(n for n, e in turtles(ctx).items() if e.get("dockX") is not None))))


def steps(ctx):
    ctx.wait_registered(14, 300)
    c = ctx.control
    pin = getattr(ctx, "pin", None) or "HEAD"
    tmp = tempfile.mkdtemp(prefix="w3bay")

    # 0. Staging, checked.
    out = c.command("forceload add 224 -2816 271 -2769")
    ctx.note("forceload the arrivals side (chunks 14..16, -176..-174): %s" % out.strip()[:120])
    # ...and worker bay 2, where the move path in step 2 sends the world copy's miners (the first MINER docks, 167,-2806 and
    # 167,-2810), with its centre column
    south = [(167, -2806), (167, -2810)] + [(NORTH_CENTRE_X, z) for z in range(-2813, WHITE_Z + 1)]
    def clear(x, z):
        # air, or a turtle standing there (the move path may already have brought a miner to bay 2 during the pin's settle)
        return any("Test passed" in c.command("execute if block %d 67 %d %s" % (x, z, b))
                   for b in ("air", "computercraft:turtle_advanced", "computercraft:turtle_normal"))
    # The world copy has bays 2-5's floor and pillars but not the ender chests under the new docks. The server may send the old miners
    # to ANY free MINER dock, so copy the chest under all of them, from bay 1 (world.py's step 4, on its own; the control wrapper
    # records each setblock as an intervention). The checks below still fail loudly if this did not happen.
    cells = world.dock_cells()
    miner_docks = [d for d in cells if d["type"] == "MINER"]
    under = world.new_under_report()
    world.copy_under_docks(c, cells, miner_docks, under, {})
    ctx.note("under-dock chests for %d MINER docks: copied %d, already right %d, fallback source %d" % (
        len(miner_docks), under["copied"], under["same"], under["fallback"]))
    for (x, z) in north_route_cells() + south:
        if not clear(x, z):
            raise RuntimeError("staging: %d,67,%d on a bay-2 route is not clear -- bays 2-5 are not built in this world "
                               "(run the shakeout kit's bay builder first)" % (x, z))
    if "Test passed" in c.command("execute if block %d 66 %d air" % NORTH_DOCK):
        raise RuntimeError("staging: nothing under the north dock %d,66,%d -- bays 2-5 are not built (shakeout kit, Part 2)" % NORTH_DOCK)
    ctx.note("under the north dock: %s" % c.block_data((NORTH_DOCK[0], 66, NORTH_DOCK[1]))[:200])
    ctx.note("under support bay 1's first dock, for comparison: %s" % c.block_data((153, 66, -2797))[:200])

    # 1. The ATC computer.
    start = os.path.join(tmp, "atc_startup.lua")
    with open(start, "w", encoding="utf8", newline="\n") as f:
        f.write(_pair.show(pin, "atc.lua"))
    files = {name: _pair.show(pin, name) for name in _pair.ATC_FILES}
    files["role.txt"] = "atc"
    online0 = len(ctx.log_lines("ATC online"))
    ax, ay, az = c.free_spot()
    aid = c.spawn_computer(ax, ay, az, start, files=files)
    ctx.note("ATC computer #%d at %d,%d,%d from %s" % (aid, ax, ay, az, pin))
    ctx.expect(bool(ctx.wait_until(lambda: len(ctx.log_lines("ATC online")) > online0, 180)), "the ATC came online")
    ctx.expect(bool(ctx.wait_until(lambda: ctx.log_lines("settled: rebuilt"), 120)), "it settled and rebuilt")
    ctx.wait_until(lambda: len(ctx.log_lines("ATC heard")) >= 10, 180)

    # 2. The move path: a miner the old file has on a worker bay 1 cell (now DELIVERY) is moved once, and ends standing on a MINER
    # dock. The world copy's miners are NOT misplaced (they registered on bay 2 before the server restarted: run b), so this stages
    # one: the dispatch computer is stopped and given an OLD-format file (legacy lists only, no byPos) that puts one miner on a free
    # bay-1 DELIVERY cell; its server then reads the file by side and index and must move that miner.
    roster = sorted(turtles(ctx))
    ts = ctx.wait_until(lambda: docked_roster(ctx, roster), 300) or turtles(ctx)
    miners = sorted(n for n, e in ts.items() if (e.get("role") or "").upper() == "MINER")
    ctx.expect(bool(miners), "the fleet has miners (%s)" % miners)
    if not miners:
        return
    cells = world.dock_cells()
    sid0 = server_computer(ctx)
    ctx.expect(sid0 is not None, "found the dispatch computer (#%s)" % sid0)
    if sid0 is None:
        return
    held = {(e.get("dockX"), e.get("dockZ")) for e in ts.values()}
    free = [d for d in cells if d["bay"] == 1 and d["type"] == "DELIVERY" and (d["x"], d["z"]) not in held]
    if not free:
        raise RuntimeError("staging: no free bay-1 DELIVERY dock to put a miner on")
    stray, spot = miners[-1], free[0]
    assign = {n: (int(e.get("dockX")), int(e.get("dockZ"))) for n, e in ts.items()
              if isinstance(e.get("dockX"), (int, float)) and isinstance(e.get("dockZ"), (int, float))}
    assign[stray] = (spot["x"], spot["z"])
    rewrite_dock_file(ctx, sid0, dock_file_text(assign, cells, False),
                      "OLD format, %s put on bay 1 row %s DELIVERY dock %d,%d" % (stray, spot["row"], spot["x"], spot["z"]), roster)
    moved = ctx.wait_until(lambda: ctx.log_lines("Dock moved: "), 300) or []
    ctx.note("'Dock moved' lines: %s" % moved)
    for m in miners:
        mine = [l for l in moved if ("Dock moved: %s " % m) in l]
        if mine:
            ctx.expect(len(mine) == 1 and "(DELIVERY) to bay" in mine[0] and "(MINER) -- per-bay types" in mine[0],
                       "%s was moved from a DELIVERY dock to a MINER dock exactly once (%s)" % (m, mine))
    ctx.expect(bool(moved), "the old file's misplaced miners were moved (%d 'Dock moved' lines; the world copy's miners sit on worker "
               "bay 1): the move path has something to judge" % len(moved))
    # every miner, not just the ones registered right now: a miner missing from /state must fail this, not pass it by absence
    homed = ctx.wait_until(lambda: (lambda ts, pos: all(m in ts and on_own_dock(ctx, m, ts[m], pos)[0] for m in miners) or None)(
        turtles(ctx), _pair.positions(ctx)), 900)
    ts, pos = turtles(ctx), _pair.positions(ctx)
    ctx.expect(bool(homed), "every miner stands on the MINER dock the server has for it (%s)" % "; ".join(
        on_own_dock(ctx, m, ts[m], pos)[1] if m in ts else "%s not registered" % m for m in miners))

    # 3. One miner to the north dock: rewrite the dispatch computer's dock file with it there, by position.
    who = miners[0]
    holder = [n for n, e in ts.items() if (e.get("dockX"), e.get("dockZ")) == NORTH_DOCK and n != who]
    if holder:
        raise RuntimeError("staging: the north dock %s is already %s's" % (NORTH_DOCK, holder))
    sid = server_computer(ctx)
    ctx.expect(sid is not None, "found the dispatch computer (#%s)" % sid)
    if sid is None:
        return
    assign = {}
    for n, e in sorted(ts.items()):
        x, z = (NORTH_DOCK if n == who else (e.get("dockX"), e.get("dockZ")))
        if isinstance(x, (int, float)) and isinstance(z, (int, float)):
            assign[n] = (int(x), int(z))
    missing = sorted(set(roster) - set(assign))
    if missing:
        raise RuntimeError("staging: the dock file would leave out %s (not registered with a dock)" % missing)
    rewrite_dock_file(ctx, sid, dock_file_text(assign, cells, True), "%s on %s, the current saver's format" % (who, NORTH_DOCK), roster)
    reg = ctx.wait_until(lambda: (lambda e: e if e and (e.get("dockX"), e.get("dockZ")) == NORTH_DOCK else None)(turtles(ctx).get(who)), 300)
    ctx.expect(bool(reg), "the server has %s on the north dock %s after the restart (%s)" % (who, NORTH_DOCK,
               {k: (turtles(ctx).get(who) or {}).get(k) for k in ("dock", "dockX", "dockZ")}))
    booted0 = len([l for l in ctx.log_lines("booting ===") if who in l])
    ctx.dispatch("REBOOT_TURTLE", {"turtleId": who})
    ctx.expect(bool(ctx.wait_until(lambda: len([l for l in ctx.log_lines("booting ===") if who in l]) > booted0, 300)),
               "%s rebooted" % who)
    there = ctx.wait_until(lambda: (lambda p: p if p and (p[0], p[2]) == NORTH_DOCK and p[1] == 67 else None)(_pair.positions(ctx).get(who)), 900)
    ctx.expect(bool(there), "%s drove to its north dock after its reboot (%s)" % (who, _pair.positions(ctx).get(who)))
    if not there:
        return

    # 4. Hold the other miners; one mine job and one delivery.
    for m in miners:
        if m != who:
            ctx.dispatch("HOLD_TURTLE", {"turtleId": m, "reason": "w3_bay_types: only %s mines" % who})
    ctx.wait_game(10)
    sent0 = len(ctx.log_lines("Dispatched job_"))
    docked0 = len(ctx.log_lines("Docked at bay"))
    failed0 = len(ctx.log_lines("Return home failed"))
    waits0 = len(ctx.log_lines("ATC: waiting to enter"))
    # Counted BEFORE the order: the departure admission lands about 0.6 s after the dispatch (run c), before this script
    # would get round to counting.
    adm0 = len(ctx.log_lines("admitted %s:" % who))
    ctx.dispatch("ORDER_MINE", {"x1": 1920, "z1": -2624, "x2": 1920, "z2": -2624, "minerCount": 1})
    dx, dy, dz = c.free_spot()
    if (dx, dy, dz) == (ax, ay, az):
        dz += 6
    ctx.dispatch("ORDER_DELIVERY", {"items": [{"name": "minecraft:cobblestone", "count": 16}], "destination": {"x": dx, "y": dy, "z": dz}})
    went = ctx.wait_until(lambda: (lambda ls: ls if len(ls) >= 2 else None)(ctx.log_lines("Dispatched job_")[sent0:]), 600) or \
        ctx.log_lines("Dispatched job_")[sent0:]
    mine = next((l for l in went if "[MINE]" in l), None)
    deliv = next((l for l in went if "[DELIVER]" in l), None)
    ctx.expect(mine is not None and who in mine, "the mine job went to %s, the north-docked miner (%s)" % (who, mine))
    ctx.expect(deliv is not None, "the delivery was dispatched (%s)" % deliv)
    dm = re.search(r"Dispatched (job_\d+) \[DELIVER\] -> (node_\d+)\s+support job_\d+ -> (node_\d+)", deliv or "")
    if mine:
        admitted = ctx.wait_until(lambda: ctx.log_lines("admitted %s:" % who)[adm0:], 300)
        ctx.expect(bool(admitted), "the ATC admitted %s's departure from the north side (%s)" % (who, admitted[:1] if admitted else "nothing"))
        out = ctx.wait_until(lambda: (lambda p: p if p and not _pair.in_base(p) and not _pair.at_dock(p) and p[1] > 80 else None)(
            _pair.positions(ctx).get(who)), 900)
        ctx.expect(bool(out), "%s left the base (%s)" % (who, out))
        mining = ctx.wait_until(lambda: ctx.log_lines("%s phase: MINING" % who), 3600)
        ctx.expect(bool(mining), "%s started mining its sector (%s)" % (who, mining[:1] if mining else "nothing"))
    if dm:
        djob, dname, sname = dm.group(1), dm.group(2), dm.group(3)
        ctx.expect(bool(ctx.wait_until(lambda: ctx.log_lines("Job complete: %s" % djob), 2400)), "the delivery %s completed" % djob)
        docked = {n: bool(ctx.wait_until(lambda n=n: [l for l in ctx.log_lines("Docked at bay")[docked0:] if n in l], 900)) for n in (dname, sname)}
        ctx.expect(all(docked.values()), "the delivery pair both docked (%s)" % docked)
    if mine:
        # The trip home is driven by a recall, not by the job finishing: this sector held 2013 ores at its first level
        # and node_179 was still mining it 80 minutes in (run c). This test is about docks and the ATC, not a sector.
        adm_out = len(ctx.log_lines("admitted %s:" % who))
        # A miner back from a job logs "<name> phase: DOCKED" (server) -- "Docked at bay" is only the boot-time homing line (run e)
        dock_r = len(ctx.log_lines("%s phase: DOCKED" % who))
        ctx.dispatch("RECALL_ALL", {"reason": "w3_bay_types: bring %s home through the ATC" % who})
        home = ctx.wait_until(lambda: ctx.log_lines("%s phase: DOCKED" % who)[dock_r:], 1800)
        ctx.expect(bool(home), "%s docked again after the recall (%s)" % (who, home[-1:] if home else "nothing"))
        p = _pair.positions(ctx).get(who)
        ctx.expect(bool(p) and (p[0], p[2]) == NORTH_DOCK and p[1] == 67, "%s is back on its north dock %s (%s)" % (who, NORTH_DOCK, p))
        back_in = ctx.log_lines("admitted %s:" % who)[adm_out:]
        ctx.expect(bool(back_in), "it came home through the ATC: %d 'admitted %s:' line(s) after the recall (%s)" % (
            len(back_in), who, back_in[-1:]))

    # 5. The end state.
    ctx.wait_game(60)
    ts, pos = turtles(ctx), _pair.positions(ctx)
    bad = [why for n, e in sorted(ts.items()) for ok, why in [on_own_dock(ctx, n, e, pos)] if not ok]
    ctx.expect(not bad, "every turtle is on a dock of its own type, the one the server has for it (%d not: %s)" % (len(bad), "; ".join(bad)))
    worst = 0
    for l in ctx.log_lines("ATC: waiting to enter")[waits0:]:
        if "no answer from the ATC" in l:
            continue
        s = re.search(r"Still waiting (\d+)s", l)
        worst = max(worst, int(s.group(1)) if s else 0)
    ctx.expect(worst <= 30, "no turtle waited more than 30 s at a section edge for an answered request (worst %d s)" % worst)
    failed = ctx.log_lines("Return home failed")[failed0:]
    ctx.expect(not failed, "nobody's return home failed (%s)" % (failed[:1] or "none"))
    stuck = [l for l in ctx.log_lines("STUCK ") if "node_" in l]
    ctx.expect(not stuck, "no turtle reported STUCK (%d)" % len(stuck))
    for m in miners:
        if m != who:
            ctx.dispatch("RELEASE_TURTLE", {"turtleId": m})
    c.shutdown([aid])
