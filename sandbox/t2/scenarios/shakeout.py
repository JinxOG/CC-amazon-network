"""Shakeout stress test, the run driver (plan Tasks 5 and 8; spec docs/superpowers/specs/2026-11-09-shakeout-stress-test-design.md).
T2 ONLY. NOT RUN YET: the 24-hour run waits for the user to confirm Windows Update is held off (plan, Task 8).

    python sandbox/t2/scenario.py sandbox/t2/scenarios/shakeout.py --pin <sha> [--tickrate N] [--t2logs]

    SHAKEOUT_SEED       the schedule's seed (default 1)
    SHAKEOUT_HOURS      real hours of faults (default 24: "24 real hours, no matter what")
    SHAKEOUT_POLL_S     seconds between scheduler calls (default 15)
    SHAKEOUT_SCHEDULE   run this schedule.json instead of making one (a replay of an earlier run's schedule)

setup(ctx), which the proof scenarios share (shakeout_fleet_proof.py, shakeout_faults_once.py):
  1. ROLE_KIT is checked against what the world copy's own turtles carry (fleet.read_role_kit on fleet.KIT_SOURCES, before
     anything is removed); the loader donor is the loader the source miner carries (its item's ComputerId);
  2. the donors are registered turtles of each role (they got the pin), chosen before the world is rebuilt;
  3. world.build_world (Task 4) and verify_world;
  4. fleet.retire_strays: the copy's fleet turtles outside the docks go (a 161st turtle would find no MINER dock);
  5. fleet.place_fleet: 160 fresh turtles with fresh loaders, dock_assignments.dat seeded while the dispatch computer is off;
  6. PLACEMENT CHECKS (each with its evidence count): every placed node registers; the server's dock for each is the cell it
     stands in, and it stands there; no 'Assigned dock', 'Dock moved' or 'No free docks' line names a placed node;
  7. save_point "shakeout-fleet" (a void run restarts from it without rebuilding).
Then the schedule is made (or loaded), written to <run>/schedule.json BEFORE the first fault, and run_loop fires it by wall
clock for SHAKEOUT_HOURS, with the Task-6 feeder and housekeeping when sandbox/t2/shakeout/feeder.py exists. run_loop ends,
whatever happened, with schedule.teardown and a check that no filler file is left on any disk.
"""
import importlib
import json
import os
import re
import time

from shakeout import fleet, schedule, world  # noqa: E402  (sandbox/t2 is on the path: the runner put it there)

NAME = "shakeout"
PLACEMENT_LINES = ("Assigned dock:", "Dock moved: ", "No free docks for ")


def env_int(name, default):
    return int(os.environ.get(name) or default)


def turtles(ctx):
    t = ctx.state().get("turtles") or {}
    return dict(t.items()) if isinstance(t, dict) else {e.get("id"): e for e in t}


def loader_donor(ctx, miner):
    """The loader the source miner carries (its item's ComputerId), when its disk is there; else fleet.LOADER_SOURCE."""
    c = ctx.control
    kit = fleet.ROLE_KIT["MINER"]
    try:
        _, _, tag = fleet.parse_stack(c.get_slot(miner, kit["loader_slot"]))
        cid = int(dict(world.parse_snbt(tag)[1])["ComputerId"][1].rstrip("bBsSlL"))
        if os.path.isdir(os.path.join(c.disks, str(cid))):
            return cid
    except Exception:  # noqa: BLE001 - not readable: the default, and the note says so
        pass
    ctx.note("loader donor: could not read #%s's loader item; using #%d" % (miner, fleet.LOADER_SOURCE))
    return fleet.LOADER_SOURCE


def placement_checks(ctx, placed):
    """The T2 proof's placement checks (see the module doc). The placed nodes' ids are new, so every log line naming one is
    from after the placement."""
    ts = turtles(ctx)
    reg = [n for n in placed if n in ts]
    ctx.expect(len(reg) == len(placed), "every placed turtle registered (%d of %d)" % (len(reg), len(placed)))
    on_dock, standing, bad = 0, 0, []
    for n in reg:
        cell, e = placed[n], ts[n]
        if (e.get("dockX"), e.get("dockZ")) == (cell["x"], cell["z"]):
            on_dock += 1
        else:
            bad.append("%s server dock %s,%s, cell %d,%d" % (n, e.get("dockX"), e.get("dockZ"), cell["x"], cell["z"]))
        p = e.get("position") or e
        if isinstance(p, dict) and (p.get("x"), p.get("y"), p.get("z")) == (cell["x"], cell["y"], cell["z"]):
            standing += 1
    ctx.expect(on_dock == len(placed), "the server's dock for each placed turtle is the cell it was placed in (%d of %d)%s"
               % (on_dock, len(placed), (": " + "; ".join(bad[:10])) if bad else ""))
    ctx.expect(standing == len(placed), "each placed turtle reports itself standing in that cell (%d of %d)" % (standing, len(placed)))
    names = set(placed)
    for key in PLACEMENT_LINES:
        lines = ctx.log_lines(key)
        new = [l for l in lines if names & set(re.findall(r"node_\d+", l))]
        ctx.expect(not new, "no '%s' line names a placed turtle (%d such lines of %d '%s' lines in the run)%s"
                   % (key.strip(), len(new), len(lines), key.strip(), (": " + new[0][:200]) if new else ""))
    registered = [l for l in ctx.log_lines("Registered node_") if names & set(re.findall(r"node_\d+", l))]
    ctx.note("placement evidence: %d 'Registered' lines naming placed nodes, %d placed nodes in /state" % (len(registered), len(reg)))


def setup(ctx):
    """Builds the shakeout world and fleet (module doc, steps 1-7). Returns {node_id: dock cell}."""
    c = ctx.control
    ctx.wait_registered(14, 300)

    # 1. the kit, from the world copy's own turtles, while they still stand on their docks
    comps = c.computers()
    sources = {r: i for r, i in fleet.KIT_SOURCES.items() if i in comps}
    ctx.expect(len(sources) == len(fleet.KIT_SOURCES), "the kit's source turtles are loaded (%s of %s)" % (sorted(sources.values()),
               sorted(fleet.KIT_SOURCES.values())))
    if sources:
        read = fleet.read_role_kit(ctx, sources)
        diffs = fleet.kit_differences({r: fleet.ROLE_KIT[r] for r in sources}, read)
        compared = sum(len(set(fleet.ROLE_KIT[r]["items"]) | set(read[r]["items"])) + 1 for r in sources)
        ctx.expect(not diffs, "ROLE_KIT is what the world's turtles carry (%d roles, %d upgrades and slots compared)%s"
                   % (len(sources), compared, (": " + "; ".join(diffs)) if diffs else ""))
        ctx.note("kit fuel as read: %s (ROLE_KIT: %s)" % ({r: read[r]["fuel"] for r in read}, {r: fleet.ROLE_KIT[r]["fuel"] for r in read}))
    ldonor = loader_donor(ctx, fleet.KIT_SOURCES["MINER"])

    # 2. donors: registered turtles (the pin reached them), chosen before the rebuild removes their blocks
    donors = fleet.find_donors(ctx)
    ctx.expect(sorted(donors) == sorted(fleet.DOCK_TYPES), "a registered donor for each role (%s), loader donor #%s" % (donors, ldonor))

    # 3. the world
    built = world.build_world(ctx)
    ctx.note("build_world removed %s; left standing %s" % (json.dumps(built["removed"], default=str)[:600],
                                                         json.dumps(built["left_standing"], default=str)[:600]))
    v = world.verify_world(ctx)
    ctx.expect(v["dock_air"] == v["dock_total"] and v["under_ok"] == v["under_total"],
               "the world is built: dock cells air %d of %d, under-dock chests %d of %d" % (v["dock_air"], v["dock_total"],
                                                                                         v["under_ok"], v["under_total"]))

    # 3b. one world restart before any turtle is placed: the RS network only picks up the creative storage block on a load
    world.restart_after_build(ctx)
    ctx.wait_registered(14, 600)

    # 4-5. strays out, the fleet in
    sid = fleet.server_computer(ctx)
    keep = [i for i in (sid,) if i is not None]
    fleet.retire_strays(ctx, keep=keep)
    online0 = len(ctx.log_lines("Central server online"))
    placed = fleet.place_fleet(ctx, donors=donors, server_id=sid, loader_donor=ldonor)
    ctx.expect(bool(ctx.wait_until(lambda: len(ctx.log_lines("Central server online")) > online0, 600)),
               "the dispatch computer came back after the seeding")

    # 6. every turtle registers on the dock it stands on
    ctx.wait_until(lambda: all(n in turtles(ctx) for n in placed), 1800, poll=15)
    placement_checks(ctx, placed)

    # 7. a checkpoint
    dest = world.save_point(ctx, "shakeout-fleet")
    ctx.expect(os.path.exists(os.path.join(dest, "level.dat")), "save point written (%s)" % dest)
    return placed


def _feeder(ctx):
    try:
        mod = importlib.import_module("shakeout.feeder")
    except ImportError:
        ctx.note("no shakeout.feeder module (Task 6): the fleet gets no orders from the driver")
        return None, None
    return mod.Feeder(ctx), getattr(mod, "housekeep", None)


def run_loop(ctx, sched, seconds, poll=None):
    """Fires the schedule by wall clock for `seconds` real seconds; the feeder and housekeeping ride along when they exist.
    Always ends with schedule.teardown and the no-filler-left check, whatever stopped the loop."""
    poll = poll or env_int("SHAKEOUT_POLL_S", 15)
    feed, housekeep = _feeder(ctx)
    ctx.shakeout_entries = sched          # housekeeping tags a storage reading taken inside a scheduled storage fault as expected
    t0 = time.time()
    errors = 0
    try:
        while True:
            wall = int((time.time() - t0) * 1000)
            if wall >= seconds * 1000:
                break
            schedule.run_due(ctx, sched, wall)
            for fn in ([feed.tick] if feed else []) + ([lambda now: housekeep(ctx, now)] if housekeep else []):
                try:
                    fn(time.time())
                except Exception as ex:  # noqa: BLE001 - a feeder error is a note, not the end of a 24-hour run
                    errors += 1
                    if errors <= 20:
                        ctx.note("wall %d s: feeder/housekeeping error %s: %s" % (wall // 1000, type(ex).__name__, ex))
            try:
                ctx.sample()
            except Exception:  # noqa: BLE001 - the server may be down for a scheduled fault
                pass
            time.sleep(poll)
    finally:
        out = schedule.teardown(ctx, sched)
        st = schedule.state_of(ctx)
        phases = {}
        for s in st["status"].values():
            phases[s["phase"]] = phases.get(s["phase"], 0) + 1
        ctx.expect(not out["fillers_left"], "no filler file left on any disk at the end (%d removed at teardown, %d left: %s)"
                   % (len(out["fillers_removed"]), len(out["fillers_left"]), out["fillers_left"]))
        ctx.note("schedule: %d entries; phases %s; ended at teardown %s; end errors %s; never fired %d"
                 % (len(sched), phases, out["ended"], out["end_errors"], len(out["never_fired"])))
    return out


def steps(ctx):
    placed = setup(ctx)
    seed, hours = env_int("SHAKEOUT_SEED", 1), float(os.environ.get("SHAKEOUT_HOURS") or 24)
    given = os.environ.get("SHAKEOUT_SCHEDULE")
    sched = schedule.load_schedule(given) if given else schedule.make_schedule(seed, hours, schedule.DEFAULT_RATES)
    path = schedule.write_schedule(os.path.join(ctx.run, "schedule.json"), sched, seed=seed, hours=hours,
                                   rates=schedule.DEFAULT_RATES, minimums=schedule.MIN_COUNTS, fleet=len(placed),
                                   source=given or "make_schedule")
    ctx.note("schedule.json written before the first fault: %s (%d entries, seed %d, %.1f h, %.0f%% within 10 min of the one "
             "before)" % (path, len(sched), seed, hours, 100 * schedule.recovery_share(sched)))
    run_loop(ctx, sched, hours * 3600)
