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
     stands in, and it stands there; no SERVER 'Assigned dock ... to', 'Dock moved' or 'No free docks' line names a placed node
     (PLACEMENT_RX: the node the server's line is about, never the line's source -- each turtle logs its own 'Assigned dock');
  7. save_point "shakeout-fleet" (a void run restarts from it without rebuilding).
Then the schedule is made (or loaded), written to <run>/schedule.json BEFORE the first fault, and run_loop fires it by wall
clock for SHAKEOUT_HOURS, with the Task-6 feeder and housekeeping when sandbox/t2/shakeout/feeder.py exists. run_loop ends,
whatever happened, with schedule.teardown and a check that no filler file is left on any disk; then the end-of-run turtle probe
(shakeout/final.json). The Task-7 report (shakeout/report.md) is written by after_stop, which scenario.py calls once the game
server is stopped. run_loop also records a compact /state snapshot a minute (shakeout/state.jsonl, report.record_state), which
is what the report judges the turtles on.

THE SPEED RAMP (plan Task 8 Step 2) is ramp_on_fleet, run by scenarios/shakeout_ramp.py: setup, then ramp.ramp with the feeder
ticking at every sample, so each speed is held with the 160 turtles working.
"""
import importlib
import json
import os
import re
import time

from shakeout import fleet, schedule, world  # noqa: E402  (sandbox/t2 is on the path: the runner put it there)
from shakeout import report as shreport  # noqa: E402

NAME = "shakeout"
PLACEMENT_LINES = ("Assigned dock:", "Dock moved: ", "No free docks for ")
# THE SERVER'S lines only, and the node they NAME (final review): every turtle logs its own "Assigned dock: bay 1 row A
# (153,67,-2806)" on every register, prefixed with its own node id, so a search for any node_N in the line failed 160 of 160 on
# a correct placement. These are central_server.lua registry.register's texts; the group is the node the line is about.
PLACEMENT_RX = {
    "Assigned dock:": re.compile(r"Assigned dock: bay \d+ row \w+ to (node_\d+)"),
    "Dock moved: ": re.compile(r"Dock moved: (node_\d+) from "),
    "No free docks for ": re.compile(r"No free docks for (node_\d+)"),
}


def placement_hits(lines, key, names):
    """The server's `key` lines that name one of `names` (the PLACEMENT_RX group, never the line's source node)."""
    rx = PLACEMENT_RX[key]
    return [l for l in lines if any(m in names for m in rx.findall(l))]


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
        new = placement_hits(lines, key, names)
        ctx.expect(not new, "no '%s' line names a placed turtle (%d such lines of %d '%s' lines in the run)%s"
                   % (key.strip(), len(new), len(lines), key.strip(), (": " + new[0][:200]) if new else ""))
    registered = [l for l in ctx.log_lines("Registered node_") if names & set(re.findall(r"node_\d+", l))]
    ctx.note("placement evidence: %d 'Registered' lines naming placed nodes, %d placed nodes in /state" % (len(registered), len(reg)))


def restart_and_wait_online(ctx, seconds=600):
    """world.restart_after_build, then a wait until the dispatch computer has logged 'Central server online' once MORE than
    before the restart (counted before it). Returns whether it did; the check says so with its evidence."""
    n0 = len(ctx.log_lines("Central server online"))
    world.restart_after_build(ctx)
    ok = bool(ctx.wait_until(lambda: len(ctx.log_lines("Central server online")) > n0, seconds))
    ctx.expect(ok, "the dispatch computer came back after setup's world restart ('Central server online' lines: %d before, %d now)"
               % (n0, len(ctx.log_lines("Central server online"))))
    return ok


def setup(ctx, only=None):
    """Builds the shakeout world and fleet (module doc, steps 1-7). Returns {node_id: dock cell}. `only` (a predicate on a dock
    cell) places part of the fleet: the 1x side test's bay 1 (fleet.place_fleet)."""
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
    restart_and_wait_online(ctx)
    ctx.wait_registered(14, 600)

    # 4-5. strays out, the fleet in. online0 is taken only once the restart's own 'Central server online' is in: taken before
    # it, the wait below would pass on the restart's line instead of the seeding's (final review).
    sid = fleet.server_computer(ctx)
    keep = [i for i in (sid,) if i is not None]
    fleet.retire_strays(ctx, keep=keep)
    online0 = len(ctx.log_lines("Central server online"))
    placed = fleet.place_fleet(ctx, donors=donors, server_id=sid, loader_donor=ldonor, only=only)
    ctx.expect(bool(ctx.wait_until(lambda: len(ctx.log_lines("Central server online")) > online0, 600)),
               "the dispatch computer came back after the seeding")

    # 6. every turtle registers on the dock it stands on
    ctx.wait_until(lambda: all(n in turtles(ctx) for n in placed), 1800, poll=15)
    placement_checks(ctx, placed)

    # 7. a checkpoint
    dest = world.save_point(ctx, "shakeout-fleet")
    ctx.expect(os.path.exists(os.path.join(dest, "level.dat")), "save point written (%s)" % dest)

    # 8. the dispatch computer still WORKING once the copy has settled, before anything is measured
    ready = dispatch_settled(ctx)
    ctx.expect(ready["ok"], "the dispatch computer is still pushing %d s after the save point (%s)" % (READY_SETTLE_S, ready))
    if not ready["ok"]:
        raise RuntimeError("the dispatch computer stopped pushing after the save point: nothing after it would measure the "
                           "fleet (%s)" % ready)
    return placed


READY_SETTLE_S = 90      # the save point's copy keeps the disk busy after it returns (shakeout-faults-d: the wedge came 14 s on)
READY_FRESH_S = 30       # a push this recent counts as pushing
READY_S = 300
READY_POLL_S = 5


def dispatch_settled(ctx):
    """READY_SETTLE_S after the save point, a push no older than READY_FRESH_S must come within READY_S. shakeout-faults-d: the
    copy stalled the disk, CC terminated the dispatch computer inside a storage-block write 10 s after its last push, the
    termination itself failed (InterruptedException in ComputerExecutor.shutdown), and it sat 'on' and silent for 17 minutes
    while the schedule ran on it."""
    time.sleep(READY_SETTLE_S)
    t0 = time.time()
    at = None
    while True:
        try:
            at = (ctx.state() or {}).get("updatedAt")
        except Exception:  # noqa: BLE001 - an unreadable state is not a push
            at = None
        now_ms = time.time() * 1000
        if isinstance(at, (int, float)) and at >= now_ms - READY_FRESH_S * 1000:
            return {"updatedAt": at, "age_s": round((now_ms - at) / 1000.0, 1), "ok": True}
        if time.time() - t0 >= READY_S:
            return {"updatedAt": at, "age_s": None if not isinstance(at, (int, float)) else round((now_ms - at) / 1000.0, 1),
                    "waited_s": READY_S, "ok": False}
        time.sleep(READY_POLL_S)


def _feeder(ctx, **kw):
    try:
        mod = importlib.import_module("shakeout.feeder")
    except ImportError:
        ctx.note("no shakeout.feeder module (Task 6): the fleet gets no orders from the driver")
        return None, None
    return mod.Feeder(ctx, **kw), getattr(mod, "housekeep", None)


NOTE_CAP = 20      # notes per error source (scheduler, feeder, housekeeping, state recorder) outside scheduled outages


class _Errors:
    """The driver's error notes, ONE CAP PER SOURCE (final review): the state recorder failing through every bridge outage used
    to use up a cap shared with the feeder, hiding a later real feeder bug. And an error made while a scheduled outage is on
    (schedule.in_quiet) is expected: it is counted, never noted one by one, and does not count toward the cap."""

    def __init__(self, ctx, sched):
        self.ctx, self.sched, self.n, self.quiet = ctx, sched, {}, {}

    def __call__(self, source, wall, ex):
        try:
            quiet = schedule.in_quiet(self.ctx, self.sched, wall)
        except Exception:  # noqa: BLE001
            quiet = False
        book = self.quiet if quiet else self.n
        book[source] = book.get(source, 0) + 1
        if not quiet and book[source] <= NOTE_CAP:
            self.ctx.note("wall %d s: %s error %s: %s%s" % (wall // 1000, source, type(ex).__name__, ex,
                                                           " (the last %s note; the rest are counted)" % source
                                                           if book[source] == NOTE_CAP else ""))

    def summary(self):
        srcs = sorted(set(self.n) | set(self.quiet))
        return ", ".join("%s %d (+%d during scheduled outages)" % (s, self.n.get(s, 0), self.quiet.get(s, 0)) for s in srcs) or "none"


def run_loop(ctx, sched, seconds, poll=None, feeder=None):
    """Fires the schedule by wall clock for `seconds` real seconds; the feeder and housekeeping ride along when they exist.
    Always ends with schedule.teardown, the no-filler-left check and the end-of-run probe, whatever stopped the loop. NOTHING
    stops the loop but the clock ("24 h no matter what"): an error from the scheduler itself (a log the full drive will not take,
    say), the feeder, housekeeping or the state recorder is noted (per source, capped: _Errors) and the run goes on. The shakeout
    report is NOT written here: after_stop writes it once the game server is stopped. `feeder`: the Feeder's keyword arguments
    (min_jobs, sites ...) for a fleet smaller than the 160."""
    poll = poll or env_int("SHAKEOUT_POLL_S", 15)
    feed, housekeep = _feeder(ctx, **(feeder or {}))
    ctx.shakeout_entries = sched          # housekeeping tags a storage reading taken inside a scheduled storage fault as expected
    t0 = time.time()
    err = _Errors(ctx, sched)
    try:
        while True:
            wall = int((time.time() - t0) * 1000)
            if wall >= seconds * 1000:
                break
            try:
                schedule.run_due(ctx, sched, wall)
            except Exception as ex:  # noqa: BLE001 - run_due catches every fault's errors; this is anything else
                err("scheduler", wall, ex)
            for source, fn in ([("feeder", feed.tick)] if feed else []) + (
                    [("housekeeping", lambda now: housekeep(ctx, now))] if housekeep else []):
                try:
                    fn(time.time())
                except Exception as ex:  # noqa: BLE001 - a feeder error is a note, not the end of a 24-hour run
                    err(source, wall, ex)
            try:
                ctx.sample()
            except Exception:  # noqa: BLE001 - the server may be down for a scheduled fault
                pass
            try:   # the /state snapshots the report reads (Task 7); a bridge that does not answer is written as a gap
                shreport.record_state(ctx, wall, t0 * 1000)
            except Exception as ex:  # noqa: BLE001
                err("state recorder", wall, ex)
            time.sleep(poll)
    finally:
        ctx.note("driver errors by source: %s" % err.summary())
        out = schedule.teardown(ctx, sched)
        st = schedule.state_of(ctx)
        phases = {}
        for s in st["status"].values():
            phases[s["phase"]] = phases.get(s["phase"], 0) + 1
        ctx.expect(not out["fillers_left"], "no filler file left on any disk at the end (%d removed at teardown, %d left: %s)"
                   % (len(out["fillers_removed"]), len(out["fillers_left"]), out["fillers_left"]))
        ctx.note("schedule: %d entries; phases %s; ended at teardown %s; end errors %s; never fired %d"
                 % (len(sched), phases, out["ended"], out["end_errors"], len(out["never_fired"])))
        try:   # needs the game server: here, while it is up
            ctx.note("final probe: %d turtles probed" % len(shreport.probe_final(ctx)))
        except Exception as ex:  # noqa: BLE001
            ctx.note("final probe failed: %s: %s" % (type(ex).__name__, ex))
        ctx.shakeout_report_due = True
    return out


def after_stop(ctx):
    """scenario.py calls this once the game server is stopped: the shakeout report reads a whole day's log files, which is no
    job for the moment the server still holds its memory (final review). Returns the report's path, or why there is none."""
    if not getattr(ctx, "shakeout_report_due", False):
        return "no shakeout report: run_loop never ran"
    try:
        return "shakeout report: %s" % shreport.write_report(ctx.run)
    except Exception as ex:  # noqa: BLE001 - it can be written again from the run folder
        return "shakeout report failed: %s: %s (python sandbox/t2/shakeout/report.py %s)" % (type(ex).__name__, ex, ctx.run)


def ramp_on_fleet(ctx, steps=(1, 2, 3, 4), hold_min=None):
    """The speed ramp (plan Task 8 Step 2) ON THE PLACED FLEET WITH THE FEEDER RUNNING (final review I7): ramp.ramp alone held
    each speed on whatever the world was doing, which on the saved shakeout-world is an idle server, and an idle server holds
    4x. setup(ctx) places the 160 turtles (ctx.shakeout_fleet), then every tick sample of every hold also calls Feeder.tick
    (and housekeeping), so the whole fleet is working while its tick time is measured. Returns the chosen speed; RampFailed
    propagates (stop and tell the user)."""
    from shakeout import ramp as shramp
    if not getattr(ctx, "shakeout_fleet", None):
        setup(ctx)
    feed, housekeep = _feeder(ctx)
    t0 = time.time()
    err = _Errors(ctx, [])

    def on_poll():
        wall = int((time.time() - t0) * 1000)
        for source, fn in ([("feeder", feed.tick)] if feed else []) + (
                [("housekeeping", lambda now: housekeep(ctx, now))] if housekeep else []):
            try:
                fn(time.time())
            except Exception as ex:  # noqa: BLE001
                err(source, wall, ex)
    hold = hold_min if hold_min is not None else env_int("SHAKEOUT_RAMP_HOLD_MIN", 20)
    try:
        return shramp.ramp(ctx, steps=steps, hold_min=hold, on_poll=on_poll)
    finally:
        ctx.note("ramp driver errors by source: %s" % err.summary())


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
