"""Shakeout fault scheduler (plan Task 5; spec section 5): a seeded schedule of everything that can go wrong, written to the
run folder before the run starts, fired on T2 by wall clock, and replayable in the simulator under the same names.

    from shakeout import schedule
    s = schedule.make_schedule(seed, 24, schedule.DEFAULT_RATES)    # [{id, t_ms, fault, args, quiet_ms}], sorted by t_ms
    schedule.write_schedule(os.path.join(ctx.run, "schedule.json"), s, seed=seed, hours=24, rates=schedule.DEFAULT_RATES)
    while ...: schedule.run_due(ctx, s, wall_ms)                       # fires what is due; survives its own server dying
    schedule.teardown(ctx, s)                                          # ends every open window; no filler file is left

THE SCHEDULE. t_ms is milliseconds after the schedule starts: REAL milliseconds on T2 (wall clock, so the 24 hours are 24 real
hours whatever the speed), simulated milliseconds in the simulator (sandbox/scenarios/shakeout_replay.lua). Durations in args
(dur_ms, down_ms) are in the same base. quiet_ms is how long from t_ms the fleet is EXPECTED to go silent (a bridge down, a
restart) -- what watch_run --schedule excuses (Task 6); 0 for a fault the fleet keeps talking through. Targets of one-turtle
faults are selectors, not computer ids, so the same entry means the same dock's turtle in both layers: {"role", "index"
(taken modulo the role's turtles, ordered by dock x then z), "prefer": "working"} (a turtle off its dock when there is one).

THE RULES BAKED IN (each a test in sandbox/tests/test_shakeout_schedule.py):
  - every fault with a rate > 0 fires max(MIN_COUNTS, round(rate * hours / 24)) times: at least 3 each, the 5-in-a-row restart
    burst at least once;
  - RECOVERY_SHARE (15%) of the faults are placed 1-9 minutes after another one, so at least 10% start within 10 minutes of
    the one before: a crash during recovery (spec 2.3 / 5);
  - one disk_full window holds a server_crash (Review Focus 3, made certain to happen);
  - nothing starts inside a restart burst's quiet window; bridge faults never overlap each other, nor do disk fills.

THE T2 VERBS (APPLY): every fault name maps to the control verb the spec's table names; where there is none it is built from
existing primitives, never a new mod feature:
  server_crash      the DISPATCH COMPUTER off for down_ms, then on (Control.shutdown / turn_on) -- the simulator's meaning;
                    the Minecraft process is world_restart's and restart_burst5's business
  world_restart     kind clean: Control.world_restart (save, stop, start); kind crash: Control.server_crash +
                    restart_after_crash (killed, no save). The run's tick rate is put back afterwards. gps_delay_ms (GPS
                    hosts back late) is the simulator's; on T2 the hosts come back with the world
  restart_burst5    five times: Control.server_crash, then restart_after_crash -- up, then straight down again
  atc_crash         the ATC computer (role atc) off for down_ms, then on
  warehouse_crash   the warehouse computer (role WAREHOUSE) off for down_ms, then on
  radio_loss        Control.radio_loss (control mod), dur in game ms (real dur x speed)
  radio_latency     Control.radio_latency, the delay in game ms (real ms x speed) for the same reason
  gps_down          Control.gps_down on one, several or all hosts (Control.gps_hosts), then turn_on; overlapping windows
                    keep a host off until the last one ends
  chunk_unload      Control.chunk_unload(area=...) round a working turtle (its chunk +- radius_chunks), game-ms dur; never
                    a turtle whose area would touch a base chunk (world.BASE_AREAS): that would unload the base itself
  rs_stall          Control.rs_stall;  rs_offline  Control.rs_offline (storage gone: the spec's "storage full for a while")
  tps_drop          Control.tick_rate to speed x tps / 20 for dur_ms, then the run's own rate again
  bridge_down       the T2 bridge process stopped (taskkill on pids.json's bridge pid) for dur_ms, then started again
  bridge_slow       the bridge restarted on port 3001 behind a delaying HTTP proxy on 3000 (the one address the computers'
                    HTTP rules allow), for dur_ms; then the proxy stopped and the bridge back on 3000
  disk_full         a filler file written into the dispatch computer's disk folder, leaving leave_bytes of /state diskFree,
                    then a world_restart, because CC measures a disk only when it creates the computer (w3_low_disk.py);
                    after the restart diskFree must READ at most leave_bytes + DISK_MARGIN, or the filler is removed and
                    the begin fails (a fill can go unseen: w3_low_disk.py); no usable diskFree, no filler at all. At the
                    window's end the filler is REMOVED FIRST (a host file delete, no game needed), the disk measured again
                    with another restart and diskFree read back (end_observed). teardown sweeps every disk for a filler
  turtle_reboot     one turtle off and on (off_ms apart); the simulator can pick the action (at_action), T2 cannot
  remove_item       Control.clear_slot of one turtle's loader or ender chest (Lua slot in args; NBT slot = Lua slot - 1)
  put_back_turned   Control.turtle_move to where it stands with another facing
  low_fuel          Control.set_fuel;  full_inventory  Control.set_slot of every empty slot

THE RUNNER (Review Focus 2). run_due keeps its place by wall clock: an entry fires once wall_ms reaches its t_ms; one due while
the runner was blocked (a restart takes minutes) fires late and records late_ms. A begin that fails (rcon down, say) is retried
for RETRY_MS, then recorded as failed; a fault that takes the server down and does not get it back sets need_relaunch, and
every later call (and teardown, first) tries restart_after_crash -- but only when pids.json says the server process is NOT
alive: when that cannot be told, nothing is relaunched (a second server on one folder) and it is logged once.
A BEGIN THAT FAILS PART-WAY LEAVES NOTHING BEHIND (review 1): a hold (a computer kept off) is taken only once the verb has
worked, and per entry, so a failed try cannot leak one or release another window's; bridge_slow puts the real bridge back on
3000 at once when any step fails; a disk fill that fails to write leaves no partial file; and when a begin is finally given
up, the fault's end runs once on what the begin had done, as a compensating undo.
EVERY BEGIN OBSERVES ITS EFFECT: detail["observed"] = {..., "ok"} is one cheap read made right after the verb (the computer
reads off, the GPS hosts off, the tick rate reads back, the control mod replied ok, nothing answers on 3000, a ping through
the proxy takes the delay, the slot is empty, the fuel reads back, the facing reads back, no slot is empty, the server answers
after a restart). It is recorded, not acted on (except disk_full's): shakeout_faults_once.py's check requires it.
Every call goes to the raw Control (the INTERVENTIONS wrapper asks the server for the game time first, which fails while it is
down) and is recorded as an intervention here, with the game time estimated from the last sample. Begins (with their detail),
ends, retries, failures and undos go to <run>/shakeout/faults.jsonl, each line with its actual wall time (wall_ms: ms since the
schedule started; an end line also carries began_ms), which is what a watchdog should measure quiet windows from.
"""
import http.client
import http.server
import json
import math
import os
import random
import re
import subprocess
import sys
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
T2 = os.path.dirname(HERE)
if T2 not in sys.path:
    sys.path.insert(0, T2)
import run as runmod  # noqa: E402
import scenario as scn  # noqa: E402
from shakeout import fleet, world  # noqa: E402

MIN = 60000
HOUR = 3600000

# The simulator's fault names (sandbox/faults/faults.lua), then the six the shakeout adds. one_of_each fires them in this order.
FAULTS = ["server_crash", "world_restart", "radio_loss", "radio_latency", "gps_down", "chunk_unload", "rs_stall", "rs_offline",
          "tps_drop", "bridge_down", "bridge_slow", "disk_full", "turtle_reboot", "remove_item",
          "atc_crash", "warehouse_crash", "restart_burst5", "put_back_turned", "low_fuel", "full_inventory"]

# How many of each in 24 hours (the builder's call, spec section 9): 126 a day, one every 11 minutes on average.
DEFAULT_RATES = {
    "server_crash": 8, "world_restart": 4, "radio_loss": 10, "radio_latency": 8, "gps_down": 8, "chunk_unload": 8,
    "rs_stall": 5, "rs_offline": 4, "tps_drop": 5, "bridge_down": 4, "bridge_slow": 3, "disk_full": 3, "turtle_reboot": 24,
    "remove_item": 4, "atc_crash": 5, "warehouse_crash": 4, "restart_burst5": 1, "put_back_turned": 6, "low_fuel": 6,
    "full_inventory": 6,
}
MIN_COUNTS = dict({f: 3 for f in FAULTS}, restart_burst5=1)

RECOVERY_WINDOW_MS = 10 * MIN       # "within 10 minutes after the previous one" (the test's measure of a crash in recovery)
RECOVERY_SHARE = 0.15               # placed 1-9 minutes after another fault: comfortably over the 10% the test asks for
RESTART_QUIET_MS = 10 * MIN         # one game-server restart and the fleet registering again
BRIDGE_START_MS = 5 * MIN           # a bridge start (216 s was observed on 2026-11-10, see run.py)
START_MARGIN_MS = 15 * MIN          # the fleet settles before the first fault
END_MARGIN_MS = 45 * MIN            # the last window closes, and recovery is seen, before the run ends
RETRY_MS = 10 * MIN                 # a begin that keeps failing is retried this long, then recorded as failed
DISK_CAPACITY = 1000000             # CC's default computer disk (computer_space_limit); used only when /state has no diskFree
FILLER_PREFIX = "shakeout_filler_"
BRIDGE_PORT, SLOW_BRIDGE_PORT = 3000, 3001
EXCLUSIVE = (("bridge_down", "bridge_slow"), ("disk_full",))   # windows of one group never overlap
FORMAT = "shakeout-schedule/1"

# ---------------------------------------------------------------------------------------------------------------------------
# The schedule
# ---------------------------------------------------------------------------------------------------------------------------


class _Rng:
    """Only random.Random.random() is used, whose sequence for a seed has been the same in every Python 3: the same seed
    gives the same schedule on any machine."""

    def __init__(self, seed):
        self.r = random.Random(seed)

    def u(self, a, b):
        return a + (b - a) * self.r.random()

    def i(self, a, b):
        return min(b, a + int(self.r.random() * (b - a + 1)))

    def pick(self, seq):
        return seq[min(len(seq) - 1, int(self.r.random() * len(seq)))]

    def shuffle(self, seq):
        for k in range(len(seq) - 1, 0, -1):
            j = min(k, int(self.r.random() * (k + 1)))
            seq[k], seq[j] = seq[j], seq[k]


def _target(rng, roles=("MINER", "MINER", "MINER", "DELIVERY", "SUPPORT"), prefer="working"):
    return {"role": rng.pick(roles), "index": rng.i(0, 999), "prefer": prefer}


def _args(fault, rng):
    """The arguments of one fault (durations in ms of the schedule's time base)."""
    if fault in ("server_crash", "atc_crash", "warehouse_crash"):
        return {"down_ms": int(rng.u(1, 10) * MIN)}
    if fault == "world_restart":
        return {"kind": rng.pick(("clean", "crash")), "gps_delay_ms": rng.pick((0, 0, 60000))}
    if fault == "restart_burst5":
        return {"count": 5}
    if fault == "radio_loss":
        return {"dur_ms": int(rng.u(1, 10) * MIN), "rate": rng.pick((0.05, 0.2, 0.5, 1.0))}
    if fault == "radio_latency":
        return {"dur_ms": int(rng.u(1, 10) * MIN), "ms": rng.pick((250, 1000, 3000))}
    if fault == "gps_down":
        return {"dur_ms": int(rng.u(2, 20) * MIN), "count": rng.pick((1, 3, "all")), "pick": rng.i(0, 99)}
    if fault == "chunk_unload":
        return {"dur_ms": int(rng.u(1, 5) * MIN), "target": _target(rng), "radius_chunks": 1}
    if fault == "rs_stall":
        return {"dur_ms": int(rng.u(2, 10) * MIN), "seconds": rng.pick((1, 2, 2.5))}
    if fault == "rs_offline":
        return {"dur_ms": int(rng.u(2, 15) * MIN)}
    if fault == "tps_drop":
        return {"dur_ms": int(rng.u(1, 5) * MIN), "tps": rng.pick((5, 10))}
    if fault == "bridge_down":
        return {"dur_ms": int(rng.u(2, 15) * MIN)}
    if fault == "bridge_slow":
        return {"dur_ms": int(rng.u(5, 20) * MIN), "ms": rng.pick((500, 1500, 3000))}
    if fault == "disk_full":
        return {"dur_ms": int(rng.u(10, 30) * MIN), "leave_bytes": rng.pick((2048, 50000, 250000))}
    if fault == "turtle_reboot":
        return {"target": _target(rng), "off_ms": rng.i(500, 5000), "at_action": rng.pick(("dig", "forward", "refuel", "drop"))}
    if fault == "remove_item":
        if rng.u(0, 1) < 0.7:
            slot, what = rng.pick(((2, "loader"), (15, "fuel_chest"), (16, "ore_chest")))
            return {"target": _target(rng, roles=("MINER",), prefer=None), "slot": slot, "what": what}
        slot, what = rng.pick(((15, "fuel_chest"), (16, "delivery_chest")))
        return {"target": _target(rng, roles=("DELIVERY",), prefer=None), "slot": slot, "what": what}
    if fault == "put_back_turned":
        return {"target": _target(rng), "turn": rng.i(1, 3)}
    if fault == "low_fuel":
        return {"target": _target(rng), "fuel": rng.pick((0, 50, 200, 1000))}
    if fault == "full_inventory":
        return {"target": _target(rng), "item": "minecraft:cobblestone"}
    raise ValueError("no arguments known for fault %r" % fault)


def window_ms(e):
    """How long a fault's window lasts (its dur_ms or down_ms; 0 for a one-shot)."""
    a = e.get("args") or {}
    return int(a.get("dur_ms") or a.get("down_ms") or 0)


def quiet_of(fault, args):
    if fault == "world_restart":
        return RESTART_QUIET_MS
    if fault == "restart_burst5":
        return int(args.get("count", 5)) * RESTART_QUIET_MS
    if fault in ("bridge_down", "bridge_slow"):
        return int(args["dur_ms"]) + BRIDGE_START_MS
    if fault == "disk_full":
        return int(args["dur_ms"]) + RESTART_QUIET_MS
    if fault == "server_crash":
        return int(args["down_ms"]) + 3 * MIN
    return 0


def recovery_share(entries):
    """The share of faults that start within RECOVERY_WINDOW_MS after the one before."""
    times = sorted(e["t_ms"] for e in entries)
    if not times:
        return 0.0
    return sum(1 for a, b in zip(times, times[1:]) if b - a <= RECOVERY_WINDOW_MS) / float(len(times))


def _group(fault):
    return next((g for g in EXCLUSIVE if fault in g), None)


def _fits(e, placed, lo, hi):
    t, end = e["t_ms"], e["t_ms"] + max(window_ms(e), 1)
    if not lo <= t <= hi:
        return False
    for o in placed:
        if o["fault"] == "restart_burst5" and o["t_ms"] <= t < o["t_ms"] + o["quiet_ms"]:
            return False
        if e["fault"] == "restart_burst5" and (t <= o["t_ms"] < t + e["quiet_ms"] or o["t_ms"] <= t < o["t_ms"] + max(window_ms(o), 1)):
            return False
        g = _group(e["fault"])
        if g and o["fault"] in g and t < o["t_ms"] + window_ms(o) and o["t_ms"] < end:
            return False
    return True


def make_schedule(seed, hours, rates=None, minimums=None):
    """The seeded schedule: [{id, t_ms, fault, args, quiet_ms}] sorted by t_ms (see the module doc for the rules). The same
    seed, hours and rates give the same list. `rates` must name EVERY fault of FAULTS (a forgotten name would silently drop a
    fault from the run): a rate of 0 leaves that fault out on purpose; minimums apply to the rest."""
    rates = DEFAULT_RATES if rates is None else rates
    minimums = MIN_COUNTS if minimums is None else minimums
    unknown = sorted(set(rates) - set(FAULTS))
    if unknown:
        raise ValueError("unknown fault names in rates: %s" % unknown)
    missing = [f for f in FAULTS if f not in rates]
    if missing:
        raise ValueError("rates name no rate for %s: give 0 to leave a fault out on purpose" % missing)
    lo, hi = START_MARGIN_MS, int(hours * HOUR) - END_MARGIN_MS
    if hi <= lo:
        raise ValueError("%s hours leave no room for faults" % hours)
    rng = _Rng(seed)
    names = []
    for f in FAULTS:
        r = rates.get(f, 0)
        if r and r > 0:
            names += [f] * max(int(minimums.get(f, 0)), int(round(r * hours / 24.0)))
    rng.shuffle(names)
    bursts = [f for f in names if f == "restart_burst5"]
    rest = [f for f in names if f != "restart_burst5"]
    n_chain = int(math.ceil(RECOVERY_SHARE * len(names)))
    chained, free = rest[:n_chain], rest[n_chain:]

    def new(f):
        args = _args(f, rng)
        return {"t_ms": 0, "fault": f, "args": args, "quiet_ms": quiet_of(f, args)}

    placed = []
    # exclusive and burst faults first, while there is room for them, then the rest; uniform over the run
    for f in bursts + [f for f in free if _group(f)] + [f for f in free if not _group(f)]:
        e = new(f)
        for _ in range(500):
            e["t_ms"] = int(rng.u(lo, hi))
            if _fits(e, placed, lo, hi):
                break
        else:
            raise RuntimeError("no room for %s in %s hours" % (f, hours))
        placed.append(e)
    anchors = set()
    for f in chained:
        e = new(f)
        for _ in range(500):
            a = rng.pick([o for o in placed if o["fault"] != "restart_burst5"])
            e["t_ms"] = a["t_ms"] + int(rng.u(1, 9) * MIN)
            if _fits(e, placed, lo, hi):
                anchors.add(id(a))
                e["_chained"] = True
                break
        else:
            raise RuntimeError("no room to chain %s after another fault" % f)
        placed.append(e)

    # One disk_full window holds a server_crash (Review Focus 3): move a free crash nobody is chained to into the first one.
    fills = sorted((e for e in placed if e["fault"] == "disk_full"), key=lambda e: e["t_ms"])
    crashes = [e for e in placed if e["fault"] == "server_crash"]
    if fills and crashes and not any(d["t_ms"] < c["t_ms"] < d["t_ms"] + window_ms(d) for d in fills for c in crashes):
        movable = [c for c in crashes if not c.get("_chained") and id(c) not in anchors]
        for c in movable:
            for d in fills:
                old = c["t_ms"]
                c["t_ms"] = d["t_ms"] + int(window_ms(d) * rng.u(0.3, 0.7))
                if _fits(c, [o for o in placed if o is not c], lo, hi):
                    break
                c["t_ms"] = old
            else:
                continue
            break
        if not any(d["t_ms"] < c["t_ms"] < d["t_ms"] + window_ms(d) for d in fills for c in crashes):
            raise RuntimeError("no server_crash could be put inside a disk_full window (Review Focus 3); %d crashes, %d fills"
                               % (len(crashes), len(fills)))
    for e in placed:
        e.pop("_chained", None)
    placed.sort(key=lambda e: (e["t_ms"], FAULTS.index(e["fault"])))
    out = [dict(id="f%03d" % (i + 1), **e) for i, e in enumerate(placed)]
    if names and recovery_share(out) < 0.10:
        raise RuntimeError("only %.1f%% of faults land in recovery" % (100 * recovery_share(out)))
    return out


SHORT = {"down_ms": 2 * MIN, "dur_ms": 3 * MIN}


def one_of_each(seed=1, start_ms=5 * MIN, gap_ms=5 * MIN):
    """The T2 proof's schedule: every fault once, in FAULTS order, each with short windows and starting only after the one
    before has closed and its quiet time has passed (plus gap_ms)."""
    rng = _Rng(seed)
    out, t = [], start_ms
    for i, f in enumerate(FAULTS):
        args = _args(f, rng)
        for k, v in SHORT.items():
            if k in args:
                args[k] = v
        e = {"id": "f%03d" % (i + 1), "t_ms": t, "fault": f, "args": args, "quiet_ms": quiet_of(f, args)}
        out.append(e)
        t += window_ms(e) + e["quiet_ms"] + gap_ms
    return out


def write_schedule(path, schedule, **meta):
    """schedule.json: {format, time_base, the meta given (seed, hours, rates ...), entries}."""
    doc = {"format": FORMAT, "time_base": "t_ms and durations: real ms on T2, simulated ms in the simulator"}
    doc.update(meta)
    doc["entries"] = schedule
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    with open(path, "w", encoding="utf8", newline="\n") as f:
        json.dump(doc, f, indent=1, sort_keys=True)
    return path


def load_schedule(path):
    with open(path, encoding="utf8") as f:
        doc = json.load(f)
    return doc["entries"] if isinstance(doc, dict) else doc


# ---------------------------------------------------------------------------------------------------------------------------
# Running it on T2
# ---------------------------------------------------------------------------------------------------------------------------

READS = set(scn.READ_ONLY) - {"tick_rate"}      # scenario.py counts tick_rate as a read; a tps drop is a change


def _game_estimate(ctx):
    """The game time now, from the last tick sample (the server may be down, so it is not asked)."""
    s = getattr(ctx, "samples", None)
    if s:
        t, g, _, rate = s[-1]
        g0 = getattr(ctx, "g0", None) or g
        return round((g - g0) / 20.0 + (time.time() - t) * (rate or 20) / 20.0, 1)
    return 0


class _Recorder:
    """The raw Control, with every changing call recorded as an INTERVENTION (fault id included) without asking the server."""

    def __init__(self, ctx, raw, fault_id):
        self._ctx, self._raw, self._id = ctx, raw, fault_id

    def __getattr__(self, name):
        attr = getattr(self._raw, name)
        if not callable(attr) or name.startswith("_") or name in READS:
            return attr

        def call(*args, **kwargs):
            if name != "command" or scn.world_changing_command(args[0] if args else ""):
                self._ctx.interventions.append({"verb": name, "args": [repr(a) for a in args],
                                                "kwargs": {k: repr(v) for k, v in kwargs.items()},
                                                "game_seconds": _game_estimate(self._ctx), "fault": self._id})
            return attr(*args, **kwargs)
        return call


def _intervention(ctx, fault_id, verb, *args, **kwargs):
    ctx.interventions.append({"verb": verb, "args": [repr(a) for a in args], "kwargs": {k: repr(v) for k, v in kwargs.items()},
                              "game_seconds": _game_estimate(ctx), "fault": fault_id})


def state_of(ctx):
    st = getattr(ctx, "shakeout_sched", None)
    if st is None:
        st = {"status": {}, "holds": {}, "partial": {}, "need_relaunch": False, "proxy": None, "fillers": {}}
        ctx.shakeout_sched = st
    return st


def _log(ctx, wall_ms, e, phase, **detail):
    d = os.path.join(ctx.run, "shakeout")
    os.makedirs(d, exist_ok=True)
    rec = dict({"wall_ms": wall_ms, "time": time.strftime("%Y-%m-%dT%H:%M:%S"), "id": e["id"] if e else None,
                "fault": e["fault"] if e else None, "phase": phase}, **detail)
    with open(os.path.join(d, "faults.jsonl"), "a", encoding="utf8") as f:
        f.write(json.dumps(rec, default=repr) + "\n")


def _game_ms(ctx, real_ms):
    return int(round(real_ms * getattr(ctx, "rate", 20) / 20.0))


def _hold(st, key, eid):
    """Entry `eid` keeps `key` (a computer id) off. Per entry, not a counter: an entry that never took a hold cannot release
    another entry's (the leak of review 1: a failed shutdown took a hold, a retry a second, the end released one)."""
    st["holds"].setdefault(key, set()).add(eid)


def _release(st, key, eid):
    """Entry `eid` lets `key` go; True when no entry holds it any more (then it may come back on)."""
    held = st["holds"].get(key)
    if held is not None:
        held.discard(eid)
        if held:
            return False
        st["holds"].pop(key, None)
    return True


def _fleet(ctx):
    return getattr(ctx, "shakeout_fleet", None) or {}


def _server_id(ctx):
    sid = _fleet(ctx).get("server") or fleet.server_computer(ctx)
    if sid is None:
        raise RuntimeError("no dispatch computer known")
    return sid


def _role_computer(c, role):
    comps = c.computers()
    ids = [i for i in sorted(comps) if (c.role_of(i) or "").strip().upper() == role.upper()]
    if not ids:
        raise RuntimeError("no loaded computer with role %s" % role)
    on = [i for i in ids if comps[i]["on"]]
    return (on or ids)[0]


def _cid(node):
    return int(node.replace("node_", ""))


def _pick_turtle(c, ctx, sel, accept=None):
    """The computer id a selector names (see the module doc). `accept(cid, pos)` narrows the turtles that may be picked."""
    role = sel["role"].upper()
    placed = _fleet(ctx).get("placed") or {}
    nodes = sorted((n for n, cell in placed.items() if cell["type"] == role), key=lambda n: (placed[n]["x"], placed[n]["z"]))
    if not nodes:
        raise RuntimeError("no %s turtle in the placed fleet" % role)
    comps = c.computers() if (accept or sel.get("prefer") == "working") else {}
    if accept:
        nodes = [n for n in nodes if _cid(n) in comps and accept(_cid(n), tuple(comps[_cid(n)]["pos"]))]
        if not nodes:
            raise RuntimeError("no %s turtle this fault may be aimed at right now" % role)
    pool = nodes
    if sel.get("prefer") == "working":
        working = [n for n in nodes if _cid(n) in comps and
                   tuple(comps[_cid(n)]["pos"]) != (placed[n]["x"], placed[n]["y"], placed[n]["z"])]
        pool = working or nodes
    return _cid(pool[int(sel.get("index", 0)) % len(pool)])


def _pos(c, cid):
    comps = c.computers()
    if cid not in comps:
        raise RuntimeError("computer #%d is not loaded" % cid)
    return tuple(comps[cid]["pos"])


def _partial(st, e):
    """The detail of this begin attempt, kept as it goes: what the compensating undo needs if the begin fails part-way."""
    d = {}
    st["partial"][e["id"]] = d
    return d


def _observe(d, fn):
    """d["observed"] = fn(): one cheap read showing the fault took effect ({..., "ok": bool}); a read that fails is ok False."""
    try:
        d["observed"] = fn()
    except Exception as ex:  # noqa: BLE001 - an observation is evidence, never a reason to stop
        d["observed"] = {"ok": False, "error": "%s: %s" % (type(ex).__name__, ex)}
    return d


def _on(c, cid):
    return (c.computers().get(cid) or {}).get("on")


def _reply_ok(reply):
    if isinstance(reply, list):
        return bool(reply) and all(_reply_ok(r) for r in reply)
    return isinstance(reply, dict) and not reply.get("error") and reply.get("ok", True) is not False


# -- the verbs ---------------------------------------------------------------------------------------------------------------

def _after_restart(ctx, c):
    rate = getattr(ctx, "rate", 20)
    if rate != 20:
        c.tick_rate(rate)


def _server_answers(c):
    reply = c.command("time query gametime")
    return {"reply": reply.strip()[:80], "ok": any(ch.isdigit() for ch in reply)}


def _crash_computer(find):
    def begin(ctx, c, st, e):
        d = _partial(st, e)
        cid = d["computer"] = find(ctx, c)
        c.shutdown([cid])
        _hold(st, cid, e["id"])                        # only once it is off
        return _observe(d, lambda: {"on": _on(c, cid), "ok": _on(c, cid) is False})

    def end(ctx, c, st, e, detail):
        cid = detail.get("computer")
        if cid is not None and _release(st, cid, e["id"]):
            c.turn_on([cid])
    return begin, end


def _world_restart(ctx, c, st, e):
    d = _partial(st, e)
    if e["args"].get("kind") == "crash":
        c.server_crash()
        c.restart_after_crash()
    else:
        c.world_restart()
    _after_restart(ctx, c)
    return _observe(d, lambda: _server_answers(c))


def _burst(ctx, c, st, e):
    d = _partial(st, e)
    for i in range(int(e["args"].get("count", 5))):
        c.server_crash()
        c.restart_after_crash()            # returns once the server says Done: then it is killed again at once
        d["restarts"] = i + 1
    _after_restart(ctx, c)
    return _observe(d, lambda: dict(_server_answers(c), restarts=d["restarts"]))


def _gps_begin(ctx, c, st, e):
    d = _partial(st, e)
    hosts = sorted(c.gps_hosts())
    if not hosts:
        raise RuntimeError("no GPS hosts found")
    n = len(hosts) if e["args"].get("count") == "all" else min(len(hosts), int(e["args"].get("count", 1)))
    start = int(e["args"].get("pick", 0)) % len(hosts)
    chosen = d["hosts"] = sorted(hosts[(start + j) % len(hosts)] for j in range(n))
    c.gps_down(hosts=chosen)
    for h in chosen:
        _hold(st, h, e["id"])                          # only once they are off

    def seen():
        comps = c.computers()
        still = [h for h in chosen if (comps.get(h) or {}).get("on")]
        return {"still_on": still, "ok": not still}
    return _observe(d, seen)


def _gps_end(ctx, c, st, e, detail):
    back = [h for h in detail.get("hosts", []) if _release(st, h, e["id"])]
    if back:
        c.turn_on(back)


def _tick_seen(c, want):
    """The tick rate read back: a number in the reply EXACTLY equal to the rate set (a substring test let 2 match "20")."""
    reply = c.command("tickrate")
    nums = [float(x) for x in re.findall(r"\d+(?:\.\d+)?", reply)]
    return {"want": want, "reply": reply.strip()[:80], "numbers": nums, "ok": float(want) in nums}


def _tps_begin(ctx, c, st, e):
    d = _partial(st, e)
    want = d["rate"] = max(1, int(round(getattr(ctx, "rate", 20) * float(e["args"]["tps"]) / 20.0)))
    c.tick_rate(want)
    return _observe(d, lambda: _tick_seen(c, want))


def _tps_end(ctx, c, st, e, detail):
    c.tick_rate(getattr(ctx, "rate", 20))


BASE_CHUNKS = world.area_chunks(world.BASE_AREAS)


def unload_area(pos, r):
    cx, cz = pos[0] >> 4, pos[2] >> 4
    return ((cx - r) * 16, (cz - r) * 16, (cx + r + 1) * 16 - 1, (cz + r + 1) * 16 - 1)


def _chunk_unload(ctx, c, st, e):
    """Under a working turtle -- never where the area would touch a base chunk (world.BASE_AREAS): a docked turtle's chunk +-1
    covers the dispatch computer at x 136, and unloading the base is not this fault."""
    d = _partial(st, e)
    r = int(e["args"].get("radius_chunks", 1))
    clear = lambda cid, pos: not (world.area_chunks([unload_area(pos, r)]) & BASE_CHUNKS)   # noqa: E731
    cid = d["computer"] = _pick_turtle(c, ctx, e["args"]["target"], accept=clear)
    area = d["area"] = unload_area(_pos(c, cid), r)
    reply = c.chunk_unload(0, area=area, dur=_game_ms(ctx, e["args"]["dur_ms"]))
    return _observe(d, lambda: {"reply": reply, "ok": _reply_ok(reply)})


def _turtle_reboot(ctx, c, st, e):
    d = _partial(st, e)
    cid = d["computer"] = _pick_turtle(c, ctx, e["args"]["target"])
    c.shutdown([cid])
    off = _on(c, cid)
    time.sleep(int(e["args"].get("off_ms", 0)) / 1000.0)
    c.turn_on([cid])
    d["observed"] = {"on_while_off": off, "ok": off is False}
    return d


def _remove_item(ctx, c, st, e):
    d = _partial(st, e)
    cid = d["computer"] = _pick_turtle(c, ctx, e["args"]["target"])
    slot = int(e["args"]["slot"]) - 1
    c.clear_slot(cid, slot)
    return _observe(d, lambda: {"slot_empty": "Found no elements" in c.block_data(_pos(c, cid), "Items[{Slot:%db}]" % slot),
                                "ok": "Found no elements" in c.block_data(_pos(c, cid), "Items[{Slot:%db}]" % slot)})


FACINGS = ("north", "east", "south", "west")


def _facing(c, cid, pos):
    x, y, z = pos
    return next((i for i, f in enumerate(FACINGS) for kind in world.TURTLE_KINDS
                 if "Test passed" in c.command("execute if block %d %d %d %s[facing=%s]" % (x, y, z, kind, f))), None)


def _put_back_turned(ctx, c, st, e):
    d = _partial(st, e)
    cid = d["computer"] = _pick_turtle(c, ctx, e["args"]["target"])
    pos = _pos(c, cid)
    now = _facing(c, cid, pos)
    if now is None:
        raise RuntimeError("cannot read which way #%d faces" % cid)
    new = (now + int(e["args"].get("turn", 1))) % 4
    c.turtle_move(cid, pos[0], pos[1], pos[2], facing=FACINGS[new][0])
    d.update({"from": FACINGS[now], "to": FACINGS[new]})
    return _observe(d, lambda: {"facing": FACINGS[_facing(c, cid, _pos(c, cid))], "ok": _facing(c, cid, _pos(c, cid)) == new})


def _low_fuel(ctx, c, st, e):
    d = _partial(st, e)
    cid = d["computer"] = _pick_turtle(c, ctx, e["args"]["target"])
    c.set_fuel(cid, int(e["args"]["fuel"]))
    return _observe(d, lambda: (lambda f: {"fuel": f, "ok": f == int(e["args"]["fuel"])})(c.get_fuel(cid)))


def _full_inventory(ctx, c, st, e):
    d = _partial(st, e)
    cid = d["computer"] = _pick_turtle(c, ctx, e["args"]["target"])
    pos = _pos(c, cid)
    empty = lambda: [s for s in range(16) if "Found no elements" in c.block_data(pos, "Items[{Slot:%db}]" % s)]   # noqa: E731
    d["filled"] = empty()
    for slot in d["filled"]:
        c.set_slot(cid, slot, e["args"].get("item", "minecraft:cobblestone"), 64)
    return _observe(d, lambda: (lambda left: {"empty_after": left, "ok": not left})(empty()))


# -- disk_full ---------------------------------------------------------------------------------------------------------------

DISK_MARGIN = 8000          # bytes: what w3_low_disk.py allows between the target and the diskFree it then reads
DISK_WAIT_S = 600           # real seconds for the dispatch computer to come back after the remeasuring restart
DISK_SETTLE_S = 30          # then this long, so the next bridge push carries the new figure (w3_low_disk waits 20 game s)
DISK_POLL_S = 3


def _disk_free(ctx):
    """/state diskFree as a whole number of bytes, or None when the bridge has no usable figure."""
    try:
        v = (ctx.state() or {}).get("diskFree")
    except Exception:  # noqa: BLE001 - the bridge may be down
        return None
    return int(v) if isinstance(v, (int, float)) and not isinstance(v, bool) and v >= 0 else None


def _online_count(ctx):
    try:
        return len(ctx.log_lines("Central server online"))
    except Exception:  # noqa: BLE001
        return None


def _fresh_disk_free(ctx, online_before):
    """diskFree as the dispatch computer measures it after the restart: once it has logged 'Central server online' again
    (when the log can be read), and DISK_SETTLE_S later."""
    deadline = time.time() + DISK_WAIT_S
    while online_before is not None and time.time() < deadline:
        n = _online_count(ctx)
        if n is not None and n > online_before:
            break
        time.sleep(DISK_POLL_S)
    time.sleep(DISK_SETTLE_S)
    return _disk_free(ctx)


def _remeasure(ctx, c, st, e):
    """A world restart, so CC measures the dispatch computer's disk again. Returns whether it worked; a failure is logged and
    handed to need_relaunch, and never stands between a filler and its removal."""
    try:
        c.world_restart()
        _after_restart(ctx, c)
        return True
    except (Exception, SystemExit) as ex:  # noqa: BLE001
        st["need_relaunch"] = True
        _log(ctx, st.get("_wall", 0), e, "remeasure-failed", error="%s: %s" % (type(ex).__name__, ex))
        return False


def filler_path(c, sid, fault_id):
    return os.path.join(c.disks, str(sid), "%s%s.bin" % (FILLER_PREFIX, fault_id))


def _write_filler(path, size):
    with open(path, "wb") as f:
        left = size
        while left > 0:
            n = min(left, 1 << 20)
            f.write(b"\0" * n)
            left -= n


def _drop_filler(ctx, st, e, path):
    if path and os.path.exists(path):
        os.remove(path)
        _intervention(ctx, e["id"], "delete_disk", os.path.basename(path))
    st["fillers"].pop(path, None)


def _disk_begin(ctx, c, st, e):
    """Fill, restart, and SEE it: diskFree after the restart must be at most leave_bytes + DISK_MARGIN (w3_low_disk.py found a
    fill can go unseen). If it is not -- or diskFree was not usable to size the fill -- the filler is removed again (and the
    disk measured once more) and the begin fails: an unseen fill is not a fault that fired."""
    d = _partial(st, e)
    leave = int(e["args"].get("leave_bytes", 0))
    sid = d["server"] = _server_id(ctx)
    free = d["free_before"] = _disk_free(ctx)
    if free is None or free <= leave + DISK_MARGIN:
        d["clean"] = True
        raise RuntimeError("diskFree %r cannot size a fill leaving %d bytes" % (free, leave))
    path = d["path"] = filler_path(c, sid, e["id"])
    size = d["bytes"] = free - leave
    st["fillers"][path] = e["id"]
    try:
        _write_filler(path, size)
    except BaseException:
        if os.path.exists(path):
            os.remove(path)                # never a half-written filler left behind
        st["fillers"].pop(path, None)
        d["clean"] = True
        raise
    _intervention(ctx, e["id"], "write_disk", sid, os.path.basename(path), bytes=size, free_before=free)
    n0 = _online_count(ctx)
    restarted = _remeasure(ctx, c, st, e)
    seen = _fresh_disk_free(ctx, n0) if restarted else None
    d["observed"] = {"diskFree": seen, "want_at_most": leave + DISK_MARGIN, "restarted": restarted,
                     "ok": seen is not None and seen <= leave + DISK_MARGIN}
    if not d["observed"]["ok"]:
        _drop_filler(ctx, st, e, path)
        if restarted:
            _remeasure(ctx, c, st, e)      # the filler may have been counted after all: measure the emptied disk
        d["clean"] = True
        raise RuntimeError("the fill was not seen: diskFree %r after the restart, want at most %d" % (seen, leave + DISK_MARGIN))
    return d


def _disk_end(ctx, c, st, e, detail):
    _drop_filler(ctx, st, e, detail.get("path"))    # first, and without the game: a failure here keeps the window open
    if detail.get("clean"):
        return                                     # a failed begin already put the disk back
    n0 = _online_count(ctx)
    back = _fresh_disk_free(ctx, n0) if _remeasure(ctx, c, st, e) else None
    want = int(e["args"].get("leave_bytes", 0)) + DISK_MARGIN
    detail["end_observed"] = {"diskFree": back, "want_more_than": want, "ok": back is not None and back > want}


# -- the bridge --------------------------------------------------------------------------------------------------------------

def _read_pids(ctx):
    with open(runmod.pids_path(ctx.run)) as f:
        return json.load(f)


def _bridge_ping(port, timeout=10):
    """Milliseconds a GET /ping on 127.0.0.1:port took, or None when nothing answers."""
    t0 = time.time()
    try:
        conn = http.client.HTTPConnection("127.0.0.1", port, timeout=timeout)
        conn.request("GET", "/ping")
        conn.getresponse().read()
        conn.close()
    except (OSError, http.client.HTTPException):
        return None
    return (time.time() - t0) * 1000.0


def _bridge_alive(ctx):
    """Whether the recorded bridge PROCESS is alive (pids.json, then the process table); None when that cannot be told."""
    try:
        pid = _read_pids(ctx).get("bridge")
        return bool(pid) and runmod.alive(pid)
    except Exception:  # noqa: BLE001
        return None


def _bridge_stop(ctx, e):
    pids = _read_pids(ctx)
    pid = pids.get("bridge")
    if pid:
        subprocess.run(["taskkill", "/F", "/PID", str(pid)], capture_output=True)
    _intervention(ctx, e["id"] if e else None, "bridge_stop", pid)


def _bridge_start(ctx, e, port):
    host, rport, pw = open(os.path.join(ctx.run, "rcon.txt")).read().split()
    runmod.port_free(port, 120)
    pid = runmod.start_bridge(ctx.run, rport, pw, port=port, append=True)
    pids = _read_pids(ctx)
    pids["bridge"] = pid
    with open(runmod.pids_path(ctx.run), "w") as f:
        json.dump(pids, f)
    _intervention(ctx, e["id"] if e else None, "bridge_start", port, pid)
    t0 = time.time()
    while time.time() - t0 < 300:
        if _bridge_ping(port, 3) is not None:
            return pid
        time.sleep(2)
    raise RuntimeError("the bridge on port %d did not answer /ping in 300 s" % port)


def _proxy_start(ctx, e, listen, target, ms):
    d = os.path.join(ctx.run, "shakeout")
    os.makedirs(d, exist_ok=True)
    out = open(os.path.join(d, "proxy.out"), "ab")
    p = subprocess.Popen([sys.executable, "-I", os.path.abspath(__file__), "proxy", str(listen), str(target), str(ms)],
                         stdout=out, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL, creationflags=runmod.DETACHED)
    with open(os.path.join(d, "proxy.pid"), "w") as f:
        f.write(str(p.pid))
    _intervention(ctx, e["id"], "proxy_start", listen, target, ms, p.pid)
    return p.pid


def _proxy_stop(ctx, e, pid):
    if pid:
        subprocess.run(["taskkill", "/F", "/PID", str(pid)], capture_output=True)
    path = os.path.join(ctx.run, "shakeout", "proxy.pid")
    if os.path.exists(path):
        os.remove(path)
    _intervention(ctx, e["id"] if e else None, "proxy_stop", pid)


def _bridge_restore(ctx, e, st):
    """The real bridge on 3000, whatever state a bridge fault left. Idempotent: the end of bridge_down and bridge_slow, their
    compensating undo, and teardown all use it.
      - any proxy is stopped;
      - a bridge we moved to 3001 (st["bridge_port"]) is stopped and one started on 3000: that move is the fault's own;
      - otherwise a bridge on 3000 is NEVER stopped because a ping went unanswered. A bridge can be merely slow (pushes of
        143 s were measured when the host starves it), and killing it would be an intervention nobody scheduled. It is
        started again only when its PROCESS is dead (pids.json pid); alive, or unknown, it is left alone and that is logged."""
    if st.get("proxy"):
        _proxy_stop(ctx, e, st["proxy"])
        st["proxy"] = None
    if st.get("bridge_port", BRIDGE_PORT) != BRIDGE_PORT:
        _bridge_stop(ctx, e)
        _bridge_start(ctx, e, BRIDGE_PORT)
        st["bridge_port"] = BRIDGE_PORT
        return
    if _bridge_ping(BRIDGE_PORT) is not None:
        return
    alive = _bridge_alive(ctx)
    if alive is not False:
        _log(ctx, st.get("_wall", 0), e, "bridge-slow-left-alone",
             error="3000 did not answer /ping but the bridge process is %s: not restarted" % ("alive" if alive else "unknown"))
        return
    _bridge_start(ctx, e, BRIDGE_PORT)


def _bridge_down(ctx, c, st, e):
    d = _partial(st, e)
    _bridge_stop(ctx, e)
    return _observe(d, lambda: (lambda ms: {"ping_ms": ms, "ok": ms is None})(_bridge_ping(BRIDGE_PORT, 3)))


def _bridge_up(ctx, c, st, e, detail):
    _bridge_restore(ctx, e, st)


def _slow_begin(ctx, c, st, e):
    d = _partial(st, e)
    ms = int(e["args"]["ms"])
    try:
        _bridge_stop(ctx, e)
        _bridge_start(ctx, e, SLOW_BRIDGE_PORT)
        st["bridge_port"] = SLOW_BRIDGE_PORT
        st["proxy"] = _proxy_start(ctx, e, BRIDGE_PORT, SLOW_BRIDGE_PORT, ms)
        d["proxy"] = st["proxy"]
    except (Exception, SystemExit):
        try:
            _bridge_restore(ctx, e, st)    # never leave the fleet without a bridge on 3000 because the slow one failed
        finally:
            d["clean"] = True
        raise
    return _observe(d, lambda: (lambda took: {"ping_ms": took, "want_at_least": 0.9 * ms,
                                              "ok": took is not None and took >= 0.9 * ms})(_bridge_ping(BRIDGE_PORT, 3 + ms / 1000.0)))


def _slow_end(ctx, c, st, e, detail):
    _bridge_restore(ctx, e, st)


class DelayProxy(http.server.ThreadingHTTPServer):
    """127.0.0.1:<listen> -> 127.0.0.1:<target>, every request held back `delay_ms` first. Plain HTTP (the computers' push and
    the scenario's /state and /command); one request per connection."""
    daemon_threads = True

    def __init__(self, listen, target, delay_ms):
        self.target, self.delay_ms = target, delay_ms
        super().__init__(("127.0.0.1", listen), _ProxyHandler)


class _ProxyHandler(http.server.BaseHTTPRequestHandler):
    def _forward(self):
        time.sleep(self.server.delay_ms / 1000.0)
        body = self.rfile.read(int(self.headers.get("Content-Length") or 0))
        conn = http.client.HTTPConnection("127.0.0.1", self.server.target, timeout=60)
        headers = {k: v for k, v in self.headers.items() if k.lower() not in ("host", "connection")}
        try:
            conn.request(self.command, self.path, body=body or None, headers=headers)
            r = conn.getresponse()
            data = r.read()
        except OSError as ex:
            self.send_error(502, "bridge unreachable: %s" % ex)
            return
        self.send_response(r.status)
        for k, v in r.getheaders():
            if k.lower() not in ("transfer-encoding", "connection", "content-length"):
                self.send_header(k, v)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(data)

    do_GET = do_POST = do_PUT = do_DELETE = _forward

    def log_message(self, fmt, *args):
        pass


def start_proxy_thread(listen, target, delay_ms):
    """The proxy in this process (tests)."""
    srv = DelayProxy(listen, target, delay_ms)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return srv


# -- the table ---------------------------------------------------------------------------------------------------------------

class Fault:
    """begin(ctx, control, state, entry) -> detail dict (with "observed": {..., "ok"}, one cheap read showing it took effect);
    end(ctx, control, state, entry, detail) at t_ms + window, or None for a one-shot (or a control-mod verb that ends by
    itself). Every begin keeps its partial detail as it goes (_partial) and takes a hold only once its verb has worked.
    blocking: it takes the game server down, so a failure sets need_relaunch. retry: a failed begin is tried again for
    RETRY_MS (never for blocking faults, nor disk_full: each try costs restarts). When a begin finally fails, end runs once on
    the partial detail as a compensating undo."""

    def __init__(self, begin, end=None, blocking=False, retry=True, sim=""):
        self.begin, self.end, self.blocking, self.retry, self.sim = begin, end, blocking, retry and not blocking, sim


def _mod_verb(name, *keys):
    def begin(ctx, c, st, e):
        d = _partial(st, e)
        a = e["args"]
        vals = [_game_ms(ctx, a["dur_ms"])] + [(_game_ms(ctx, a[k]) if k == "ms" else a[k]) for k in keys]
        reply = getattr(c, name)(0, *vals)
        return _observe(d, lambda: {"reply": reply, "ok": _reply_ok(reply)})
    return begin


_server_crash = _crash_computer(lambda ctx, c: _server_id(ctx))
_atc_crash = _crash_computer(lambda ctx, c: _role_computer(c, "atc"))
_warehouse_crash = _crash_computer(lambda ctx, c: _role_computer(c, "WAREHOUSE"))

APPLY = {
    "server_crash": Fault(*_server_crash, sim="sim:server_crash(t, down_ms)"),
    "world_restart": Fault(_world_restart, blocking=True, sim="sim:world_restart(t, {gps_delay})"),
    "radio_loss": Fault(_mod_verb("radio_loss", "rate"), sim="sim:radio_loss(t, dur, rate)"),
    "radio_latency": Fault(_mod_verb("radio_latency", "ms"), sim="sim:radio_latency(t, dur, ms)"),
    "gps_down": Fault(_gps_begin, _gps_end, sim="sim:gps_down(t, dur, {hosts})"),
    "chunk_unload": Fault(_chunk_unload, sim="sim:chunk_unload(t, area); loading:clear_forced() at the end"),
    "rs_stall": Fault(_mod_verb("rs_stall", "seconds"), sim="sim:rs_stall(t, dur, seconds)"),
    "rs_offline": Fault(_mod_verb("rs_offline"), sim="sim:rs_offline(t, dur)"),
    "tps_drop": Fault(_tps_begin, _tps_end, sim="sim:tps_drop(t, dur, tps)"),
    "bridge_down": Fault(_bridge_down, _bridge_up, sim="sim:bridge_down(t, dur)"),
    "bridge_slow": Fault(_slow_begin, _slow_end, sim="sim:bridge_slow(t, dur, ms)"),
    "disk_full": Fault(_disk_begin, _disk_end, retry=False, sim="sim:disk_full(t, server, leave_bytes), and back at the end"),
    "turtle_reboot": Fault(_turtle_reboot, sim="sim:turtle_reboot(t, node, {at_action})"),
    "remove_item": Fault(_remove_item, sim="sim:remove_item(t, node, slot)"),
    "atc_crash": Fault(*_atc_crash, sim="sim:atc_crash(t, down_ms)"),
    "warehouse_crash": Fault(*_warehouse_crash, sim="sim:shutdown(warehouse), sim:start(warehouse)"),
    "restart_burst5": Fault(_burst, blocking=True, sim="sim:world_restart x count"),
    "put_back_turned": Fault(_put_back_turned, sim="sim:teleport(node, where it stands, new facing)"),
    "low_fuel": Fault(_low_fuel, sim="sim:set_fuel(node, fuel)"),
    "full_inventory": Fault(_full_inventory, sim="sim:set_slot(node, every empty slot, item, 64)"),
}


def _server_alive(ctx):
    """True / False from pids.json and the process table; None when that cannot be told (pids.json unreadable)."""
    try:
        return runmod.alive(ctx._raw._pids()["server"])
    except Exception:  # noqa: BLE001
        return None


def _relaunch(ctx, st, wall_ms, acted):
    """Starts the game server again after a restart fault left it down -- only when pids.json says its process is NOT alive.
    Unknown (pids.json unreadable) is not a reason: a relaunch then could start a second server on the run folder, so it is
    logged once and the flag stays set."""
    alive = _server_alive(ctx)
    if alive is True:
        st["need_relaunch"] = False
        return
    if alive is None:
        if not st.get("relaunch_unknown_logged"):
            st["relaunch_unknown_logged"] = True
            _log(ctx, wall_ms, None, "relaunch-unknown", error="pids.json unreadable: not relaunching a server that may be alive")
            acted.append((None, "relaunch-unknown"))
        return
    c = _Recorder(ctx, getattr(ctx, "_raw", ctx.control), "relaunch")
    try:
        c.restart_after_crash()
        _after_restart(ctx, c)
        st["need_relaunch"] = False
        _log(ctx, wall_ms, None, "relaunched")
        acted.append((None, "relaunched"))
    except (Exception, SystemExit) as ex:  # noqa: BLE001 - the next call tries again
        _log(ctx, wall_ms, None, "relaunch-failed", error="%s: %s" % (type(ex).__name__, ex))


def _undo(ctx, st, e, f, c, wall_ms, acted):
    """A begin that finally failed: its end, once, on what the begin had done (its partial detail)."""
    if f.end is None:
        return
    try:
        f.end(ctx, c, st, e, st["partial"].get(e["id"]) or {})
        _log(ctx, wall_ms, e, "undo", detail=st["partial"].get(e["id"]))
        acted.append((e["id"], "undo"))
    except (Exception, SystemExit) as ex:  # noqa: BLE001
        _log(ctx, wall_ms, e, "undo-failed", error="%s: %s" % (type(ex).__name__, ex))
        acted.append((e["id"], "undo-failed"))


def _begin(ctx, st, e, wall_ms, acted):
    s = st["status"][e["id"]]
    f = APPLY.get(e["fault"])
    if f is None:
        s["phase"] = "failed"
        _log(ctx, wall_ms, e, "fail", error="unknown fault %r" % e["fault"])
        acted.append((e["id"], "fail"))
        return
    s["attempts"] = s.get("attempts", 0) + 1
    c = _Recorder(ctx, getattr(ctx, "_raw", ctx.control), e["id"])
    st["_wall"] = wall_ms
    try:
        detail = f.begin(ctx, c, st, e) or {}
    except (Exception, SystemExit) as ex:  # noqa: BLE001 - nothing a fault does may stop the runner
        err = "%s: %s" % (type(ex).__name__, ex)
        if f.blocking:
            st["need_relaunch"] = True
        if f.retry and wall_ms - e["t_ms"] < RETRY_MS:
            _log(ctx, wall_ms, e, "retry", error=err, attempt=s["attempts"], detail=st["partial"].get(e["id"]))
            acted.append((e["id"], "retry"))
        else:
            s["phase"] = "failed"
            s["error"] = err
            _log(ctx, wall_ms, e, "fail", error=err, detail=st["partial"].get(e["id"]))
            acted.append((e["id"], "fail"))
            _undo(ctx, st, e, f, c, wall_ms, acted)
        return
    s.update(phase="active" if f.end else "done", began_ms=wall_ms, late_ms=wall_ms - e["t_ms"],
             ends_ms=max(wall_ms, e["t_ms"] + window_ms(e)), detail=detail)
    _log(ctx, wall_ms, e, "begin", late_ms=s["late_ms"], detail=detail)
    acted.append((e["id"], "begin"))


def _end(ctx, st, e, wall_ms, acted):
    s = st["status"][e["id"]]
    c = _Recorder(ctx, getattr(ctx, "_raw", ctx.control), e["id"])
    st["_wall"] = wall_ms
    try:
        APPLY[e["fault"]].end(ctx, c, st, e, s.get("detail") or {})
    except (Exception, SystemExit) as ex:  # noqa: BLE001 - stays open, retried on the next call and at teardown
        _log(ctx, wall_ms, e, "end-retry", error="%s: %s" % (type(ex).__name__, ex))
        acted.append((e["id"], "end-retry"))
        return
    s["phase"] = "done"
    s["ended_ms"] = wall_ms
    _log(ctx, wall_ms, e, "end", began_ms=s.get("began_ms"), detail=s.get("detail"))
    acted.append((e["id"], "end"))


def run_due(ctx, schedule, wall_ms):
    """Fires what is due at wall_ms (ms since the schedule started): window ends first, then begins, in time order. Returns
    [(entry id, phase)] for what it did. Never raises because a fault went wrong."""
    st = state_of(ctx)
    acted = []
    if st["need_relaunch"]:
        _relaunch(ctx, st, wall_ms, acted)
    todo = []
    for e in schedule:
        s = st["status"].setdefault(e["id"], {"phase": "pending", "attempts": 0})
        if s["phase"] == "pending" and e["t_ms"] <= wall_ms:
            todo.append((e["t_ms"], 1, e))
        elif s["phase"] == "active" and s["ends_ms"] <= wall_ms:
            todo.append((s["ends_ms"], 0, e))
    for _, kind, e in sorted(todo, key=lambda x: (x[0], x[1])):
        (_begin if kind else _end)(ctx, st, e, wall_ms, acted)
    return acted


def teardown(ctx, schedule):
    """The end of a run (also after an error): every filler on every disk removed FIRST; then the game server relaunched if a
    restart fault left it down (need_relaunch), so the ends below can reach it; then every open window closed (the computers
    it switched off back on, GPS up, the bridge back on 3000, the tick rate back). Returns {"fillers_removed", "fillers_left"
    (a check must see this empty), "ended", "end_errors", "never_fired", "relaunch"}."""
    st = state_of(ctx)
    raw = getattr(ctx, "_raw", ctx.control)
    out = {"fillers_removed": [], "fillers_left": [], "ended": [], "end_errors": [], "never_fired": [], "relaunch": None}
    paths = set(st["fillers"])
    try:
        for d in os.listdir(raw.disks):
            folder = os.path.join(raw.disks, d)
            if os.path.isdir(folder):
                paths |= {os.path.join(folder, f) for f in os.listdir(folder) if f.startswith(FILLER_PREFIX)}
    except OSError as ex:
        out["end_errors"].append("could not list the disks: %s" % ex)
    for p in sorted(paths):
        if not os.path.exists(p):
            continue
        try:
            os.remove(p)
            out["fillers_removed"].append(p)
            st["fillers"].pop(p, None)
        except OSError as ex:
            out["fillers_left"].append(p)
            out["end_errors"].append("filler %s: %s" % (p, ex))
    wall = int(st.get("_wall", 0))
    if st["need_relaunch"]:
        acted = []
        _relaunch(ctx, st, wall, acted)
        out["relaunch"] = acted or "still needed"
    for e in schedule:
        s = st["status"].get(e["id"])
        if s is None or s["phase"] == "pending":
            out["never_fired"].append(e["id"])
        elif s["phase"] == "active":
            acted = []
            _end(ctx, st, e, wall, acted)
            (out["ended"] if (e["id"], "end") in acted else out["end_errors"]).append(e["id"])
    if st.get("proxy"):
        _proxy_stop(ctx, None, st["proxy"])
        st["proxy"] = None
    _log(ctx, wall, None, "teardown", **{k: v for k, v in out.items()})
    return out


if __name__ == "__main__" and len(sys.argv) >= 5 and sys.argv[1] == "proxy":
    DelayProxy(int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4])).serve_forever()
