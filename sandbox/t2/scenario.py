"""T2 scenario runner and run report (spec 6.9).

    python sandbox/t2/scenario.py <scenario.py> [--run-id ID] [--pin SHA] [--install SHA] [--tickrate N] [--keep-running]

A scenario is a Python file in sandbox/t2/scenarios/ defining NAME and steps(ctx). The runner starts a fresh run from the
2026-10-18 world copy, optionally pins the fleet to a commit (the real update path), runs the steps, writes
<run>/report.md and report.json, and stops the run. ctx offers the same verb names as the simulator where Minecraft allows
(ctx.control: see control.py; every state-changing call is listed under INTERVENTIONS), plus:

    ctx.dispatch(TYPE, params)          POST /command to the local bridge
    ctx.tickrate(n)                     game ticks per real second (20 = real time)
    ctx.wait_game(seconds)              until that much GAME time has passed
    ctx.wait_real(seconds)              sample tick time for that many REAL seconds
    ctx.wait_until(cond, game_seconds)  poll cond() every few seconds of real time; returns its value or None
    ctx.expect(ok, message)             a CHECK: PASS or FAIL
    ctx.note(text)                      a line in the report
    ctx.state()                         the bridge's /state as a dict
    ctx.log_lines(substr)               bridge log lines containing substr

The report has the simulator report's sections (code, world, speed, CHECKS, INTERVENTIONS, jobs, ore, tool output) and
NOT STAGED in place of NOT MODELLED.
"""
import datetime
import glob
import importlib.util
import json
import os
import re
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(__file__))
import control as ctl  # noqa: E402
import run as runmod  # noqa: E402

REPO = runmod.REPO

NOT_STAGED = [
    "Citadel and Alex's Mobs are left out at speed (the tick-rate mod conflicts with Citadel; Alex's Mobs needs it); at 1x they are present only if a run puts them back (phase 0 report).",
    "Five client-only jars are left out (server/mods-left-out/LEFT_OUT.json). The pack's 8 server-only mods are installed (hash-checked against the pack, docs/superpowers/specs/2026-10-20-t2-server-only-mods.md); five older ones the pack no longer has are not part of the live set.",
    "Needs the control mod (installed on this server): radio loss and latency, chunk unload, turtle move and save/restore, peripheral stall and fail, pause and step. Not available: running Lua on a computer from outside (M7, no clean way exists). Chunk unload releases tickets at Forge level for every mod, but only in the overworld.",
    "At a tick rate above 20 the game clock runs faster than the fleet's real-clock (os.epoch) deadlines: this run shows mechanics, not timeout behaviour.",
    "Exact replay: two runs of the same scenario differ in timing; a timing claim needs at least two runs.",
]

READ_ONLY = {"computers", "read_disk", "list_disk", "block_data", "get_fuel", "get_slot", "role_of", "gps_hosts", "free_spot",
             "command", "rcon", "harvest_radio", "tick_rate"}


class Interventions:
    """Wraps a Control: every method that is not a read is recorded with its arguments and the game time."""

    def __init__(self, ctx, control):
        self._ctx, self._c = ctx, control

    def __getattr__(self, name):
        attr = getattr(self._c, name)
        if not callable(attr) or name in READ_ONLY or name.startswith("_"):
            return attr

        def wrapper(*args, **kwargs):
            self._ctx.interventions.append({"verb": name, "args": [repr(a) for a in args], "kwargs": {k: repr(v) for k, v in kwargs.items()},
                                            "game_seconds": self._ctx.game_seconds()})
            return attr(*args, **kwargs)
        return wrapper


class Ctx:
    def __init__(self, run_id):
        self.run_id = run_id
        self.run = runmod.run_dir(run_id)
        self.interventions = []
        self.checks = []
        self.notes = []
        self.samples = []      # (real seconds, game ticks, mean tick ms, tickrate)
        self.build = []        # (tickrate, pushBuildMs, rsBuildMs) from /state
        self.rate = 20
        self.t0_real = time.time()
        self.g0 = None
        self.control = Interventions(self, ctl.Control(run_id))
        self._raw = self.control._c

    # -- time and speed -----------------------------------------------------------------------------------------
    def gametime(self):
        # RCON can answer oddly (or time out) while the server is catching up after a long tick: try again before giving up
        last = None
        for attempt in range(8):
            try:
                last = self._raw.command("time query gametime")
                m = re.search(r"(\d+)", last)
                if m:
                    return int(m.group(1))
            except (OSError, RuntimeError):
                self._raw._rcon = None
            time.sleep(3)
        raise RuntimeError("no game time from the server; last reply %r" % (last,))

    def game_seconds(self):
        return round((self.gametime() - self.g0) / 20, 1) if self.g0 is not None else 0

    def tickrate(self, n):
        self.rate = n
        self._raw.command("tickrate %d" % n)
        self.notes.append("game time %.0f s: tick rate set to %d (%.1fx)" % (self.game_seconds(), n, n / 20))

    def sample(self):
        self._raw.run_due(self.game_seconds() * 1000)
        tps = self._raw.command("forge tps")
        m = re.search(r"Overall: Mean tick time: ([\d.]+) ms", tps)
        self.samples.append((time.time(), self.gametime(), float(m.group(1)) if m else None, self.rate))
        try:   # the server computer's own timings, published in /state (compared with the simulator's timings table)
            st = json.loads(runmod.bridge_get("/state", 5))
            self.build.append((self.rate, st.get("pushBuildMs"), st.get("rsBuildMs")))
        except Exception:  # noqa: BLE001
            pass

    def wait_until(self, cond, game_seconds, poll=10):
        start = self.gametime()
        while (self.gametime() - start) / 20 < game_seconds:
            v = cond()
            if v:
                return v
            self.sample()
            time.sleep(poll)
        return cond() or None

    def wait_real(self, seconds, poll=10):
        """Sample the tick time every `poll` real seconds for `seconds` real seconds (for speed steps)."""
        end = time.time() + seconds
        while time.time() < end:
            self.sample()
            time.sleep(poll)

    def wait_game(self, seconds, poll=10):
        self.wait_until(lambda: False, seconds, poll)

    # -- the bridge ---------------------------------------------------------------------------------------------
    def dispatch(self, type_, params=None):
        self.notes.append("game time %.0f s: POST /command %s %s" % (self.game_seconds(), type_, json.dumps(params or {})))
        return runmod.bridge_post("/command", {"type": type_, "params": params or {}})

    def state(self):
        return json.loads(runmod.bridge_get("/state"))

    def log_lines(self, substr=""):
        out = []
        for f in sorted(glob.glob(os.path.join(self.run, "bridge", "logs", "*.txt"))):
            with open(f, encoding="utf8", errors="replace") as h:
                out += [l.rstrip("\n") for l in h if substr in l]
        return out

    def expect(self, ok, message):
        self.checks.append({"ok": bool(ok), "message": message})

    def note(self, text):
        self.notes.append(text)

    def wait_registered(self, count=14, seconds=300):
        return self.wait_until(lambda: len(self.state()["turtles"]) >= count, seconds, poll=5)


def load_scenario(path):
    spec = importlib.util.spec_from_file_location("t2_scenario", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def keep_whole(text, limit=80000):
    """A tool's output is kept whole. Only when it is over `limit` characters are the middle lines dropped (the head, where a verdict's sections
    start, and the tail, where the verdict ends, are both kept, with a marker); the old rule kept just the last 6000 characters and cut the
    start of gate_check mid-sentence."""
    if len(text) <= limit:
        return text
    half = limit // 2
    return text[:half] + chr(10) + "[... %d characters left out of the middle ...]" % (len(text) - limit) + chr(10) + text[-half:]


def tools_output(since_iso):
    out = {}
    env = dict(os.environ, BRIDGE_URL="http://127.0.0.1:3000", PYTHONIOENCODING="utf-8")
    for tool in ("gate_check", "ack_loss"):
        try:
            p = subprocess.run([sys.executable, os.path.join(REPO, "tools", tool + ".py"), since_iso], capture_output=True,
                               text=True, encoding="utf-8", errors="replace", env=env, timeout=300)
            out[tool] = {"exit": p.returncode, "output": keep_whole(p.stdout + p.stderr)}
        except Exception as e:  # noqa: BLE001
            out[tool] = {"exit": None, "output": "could not run: %s" % e}
    return out


def job_summary(ctx):
    lines = ctx.log_lines()
    keys = ("Dispatched job", "Zone job_", "done by", "Job complete", "permanently failed", "Mine zone", "survey complete", "mine complete")
    jobs = [l for l in lines if any(k in l for k in keys)]
    done = [l for l in lines if "done by" in l and "Sector" in l or "Survey (" in l and "done by" in l]
    ore = 0
    for l in lines:
        m = re.search(r"Sector \(.*?\) done by \S+ . (\d+) ore mined", l)
        if m:
            ore += int(m.group(1))
    problems = [l for l in lines if re.search(r"\b(ERROR|FATAL)\b|unreachable|NEEDS HANDS|stuck", l)]
    return {"job_lines": jobs, "sector_done_lines": len(done), "ore_from_sector_lines": ore, "problem_lines": problems[:40], "problem_count": len(problems)}


def t2_summary(ctx):
    """What the control mod recorded (files under <run>/t2control, status from the mod); None when it did not log anything."""
    status = ctx._raw.t2_status()
    if not status["radio"].get("written") and not status["events"].get("written") and not status["interventions"].get("written"):
        return None
    radio = ctx._raw.t2_lines("radio")
    events = ctx._raw.t2_lines("events")
    by_channel = {}
    for l in radio:
        key = "channel 1 (to server)" if l["channel"] == 1 else "channel 2 (broadcast)" if l["channel"] == 2 else             "channel 3-5" if l["channel"] in (3, 4, 5) else "private 1000+id" if 1000 <= l["channel"] < 66000 and l["channel"] != 65534 else "other %d" % l["channel"]
        by_channel[key] = by_channel.get(key, 0) + 1
    by_event = {}
    for e in events:
        by_event[e["event"]] = by_event.get(e["event"], 0) + 1
    outcomes = {}
    for l in radio:
        outcomes[l["outcome"]] = outcomes.get(l["outcome"], 0) + 1
    return {"status": status, "radio_lines": len(radio), "radio_by_channel": by_channel, "radio_outcomes": outcomes,
            "event_lines": len(events), "events_by_name": dict(sorted(by_event.items(), key=lambda kv: -kv[1])[:12]),
            "interventions": ctx._raw.t2_lines("interventions")}


def forge_version(run):
    base = os.path.join(run, "libraries", "net", "minecraftforge", "forge")
    try:
        return ", ".join(sorted(os.listdir(base)))
    except OSError:
        return "unknown"


def write_report(ctx, scenario, pin, error, since_iso, tools, started_wall):
    summary = job_summary(ctx)
    seconds = time.time() - ctx.t0_real
    game_total = ctx.game_seconds()
    mean_speed = round(game_total / seconds, 2) if seconds else None
    src = open(os.path.join(ctx.run, "bridge", "BRIDGE_SOURCE.txt")).read().strip().replace("\n", "; ")
    rep = {"scenario": scenario.NAME, "run": ctx.run, "started": started_wall, "pinned_commit": pin, "forge": forge_version(ctx.run), "control_mod": getattr(ctx, "t2", None), "bridge_source": src,
           "world": "worlds/unpacked/2026-10-18_1700 (copied)", "game_seconds": game_total, "real_seconds": round(seconds),
           "mean_speed_x": round(mean_speed / 1, 2) if mean_speed else None, "samples": len(ctx.samples),
           "checks": ctx.checks, "interventions": ctx.interventions, "notes": ctx.notes, "jobs": summary,
           "tools": tools, "error": error, "not_staged": NOT_STAGED,
           "speed_steps": []}
    # speed per tick-rate step, from the samples
    by_rate = {}
    for (t, g, ms, r) in ctx.samples:
        by_rate.setdefault(r, []).append((t, g, ms))
    for r, rows in sorted(by_rate.items()):
        if len(rows) >= 2:
            dt, dg = rows[-1][0] - rows[0][0], rows[-1][1] - rows[0][1]
            mss = [x[2] for x in rows if x[2] is not None]
            rep["speed_steps"].append({"tickrate": r, "speed_x": round(dg / dt / 20, 2) if dt > 0 else None,
                                       "mean_tick_ms": round(sum(mss) / len(mss), 2) if mss else None,
                                       "max_tick_ms": max(mss) if mss else None, "samples": len(rows)})
    def median(xs):
        xs = sorted(x for x in xs if isinstance(x, (int, float)) and x >= 0)
        return xs[len(xs) // 2] if xs else None
    rep["server_build_ms"] = {str(r): {"pushBuildMs_median": median([b[1] for b in ctx.build if b[0] == r]),
                                       "rsBuildMs_median": median([b[2] for b in ctx.build if b[0] == r]),
                                       "samples": sum(1 for b in ctx.build if b[0] == r)} for r in sorted({b[0] for b in ctx.build})}
    with open(os.path.join(ctx.run, "report.json"), "w") as f:
        json.dump(rep, f, indent=1)
    o = ["# T2 run report: %s" % scenario.NAME, "",
         "- Run folder: %s" % ctx.run, "- Started: %s" % started_wall,
         "- Fleet code: %s" % (("pinned to " + pin) if pin else ("copied from " + str(getattr(ctx, "install", None))) if getattr(ctx, "install", None) else "as installed on the computers of the world copy"),
         "- Forge: %s; mods in the server folder: %d" % (forge_version(ctx.run), len(os.listdir(os.path.join(ctx.run, "mods")))),
         "- Bridge: real server.js (%s)" % src, "- World: %s" % rep["world"],
         "- Game time %.0f s (%.2f h) in %d s of real time: **mean speed %sx**" % (game_total, game_total / 3600, seconds, mean_speed),
         "- Samples of tick time: %d" % len(ctx.samples), ""]
    if error:
        o += ["**The scenario stopped with an error:** `%s`" % error, ""]
    o += ["## Speed per tick-rate step", "", "| tick rate | speed | mean tick ms | max tick ms | samples |", "|---|---|---|---|---|"]
    for s in rep["speed_steps"]:
        o.append("| %s | %sx | %s | %s | %s |" % (s["tickrate"], s["speed_x"], s["mean_tick_ms"], s["max_tick_ms"], s["samples"]))
    if rep["server_build_ms"]:
        o += ["", "## Server computer timings (from /state; compare the simulator's timings table)", "", "| tick rate | pushBuildMs median | rsBuildMs median | samples |", "|---|---|---|---|"]
        o += ["| %s | %s | %s | %s |" % (r, v["pushBuildMs_median"], v["rsBuildMs_median"], v["samples"]) for r, v in rep["server_build_ms"].items()]
    o += ["", "## CHECKS", ""]
    o += ["- %s %s" % ("PASS" if c["ok"] else "FAIL", c["message"]) for c in ctx.checks] or ["(none)"]
    o += ["", "## INTERVENTIONS", ""]
    if ctx.interventions:
        o += ["Verbs that changed the world or a computer during the run. A report with interventions is not evidence the fleet works unaided "
              "unless the intervention is the test.", ""]
        o += ["- game %.0f s: %s(%s)" % (i["game_seconds"], i["verb"], ", ".join(i["args"] + ["%s=%s" % kv for kv in i["kwargs"].items()])) for i in ctx.interventions]
    else:
        o.append("None. Nobody reached into the run.")
    o += ["", "## Jobs and ore", "", "- Sector lines logged as done: %d" % summary["sector_done_lines"],
          "- Ore reported by the sector lines: %d" % summary["ore_from_sector_lines"], "- Problem lines: %d" % summary["problem_count"], ""]
    o += ["```"] + [l[:200] for l in summary["job_lines"][:60]] + ["```"]
    if summary["problem_lines"]:
        o += ["", "Problem lines (first 40):", "```"] + [l[:200] for l in summary["problem_lines"]] + ["```"]
    o += ["", "## Notes", ""] + ["- " + n for n in ctx.notes[-80:]]
    t2 = getattr(ctx, "t2", None)
    if t2 and "error" not in t2:
        o += ["", "## Control mod logs (<run>/t2control/)", "",
              "- radio.jsonl: %d lines (written %d, dropped %d); outcomes %s" % (t2["radio_lines"], t2["status"]["radio"]["written"], t2["status"]["radio"]["dropped"], t2["radio_outcomes"]),
              "- radio lines by channel: %s" % t2["radio_by_channel"],
              "- events.jsonl: %d lines (written %d, dropped %d); most frequent events %s" % (t2["event_lines"], t2["status"]["events"]["written"], t2["status"]["events"]["dropped"], t2["events_by_name"]),
              "- The event log shows what was QUEUED to each computer; whether the program consumed it, or a filtered yield ate it, is not visible there.",
              "- interventions.jsonl: %d line(s)" % len(t2["interventions"])]
    elif t2:
        o += ["", "## Control mod logs", "", "could not be read: %s" % t2["error"]]
    for tool, r in tools.items():
        o += ["", "## %s" % tool, "", "exit code %s" % r["exit"], "", "```", r["output"].strip(), "```"]
    o += ["", "## NOT STAGED", "", "Things this run could not exercise. A pass here says nothing about them:", ""]
    o += ["- " + n for n in NOT_STAGED]
    with open(os.path.join(ctx.run, "report.md"), "w", encoding="utf8") as f:
        f.write("\n".join(o) + "\n")
    return rep


def main():
    args = sys.argv[1:]
    if not args:
        print(__doc__)
        sys.exit(2)
    opt = lambda k, d=None: args[args.index(k) + 1] if k in args else d  # noqa: E731
    scenario = load_scenario(args[0])
    run_id = opt("--run-id") or "%s-%s" % (scenario.NAME, time.strftime("%m%d-%H%M%S"))
    pin = opt("--pin")
    t2logs = "--t2logs" in args
    tick = int(opt("--tickrate", 0)) or None
    started = time.strftime("%Y-%m-%d %H:%M:%S")
    since_iso = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S")
    install = opt("--install")
    runmod.start(run_id, install=install)
    ctx = Ctx(run_id)
    ctx.install = install
    error = None
    try:
        ctx.wait_registered()
        ctx.g0 = ctx.gametime()
        ctx.t0_real = time.time()
        if install:
            ctx.note("fleet code copied from commit %s straight onto the computers before boot (not the update path)" % install)
        if pin:
            runmod.pin(run_id, pin)
            ctx.note("fleet pinned to %s through the real update path" % pin)
        if t2logs:
            ctx._raw.radio_log("on")
            ctx._raw.events_log("on")
            ctx.note("control mod: radio log and event log on")
        if tick:
            ctx.tickrate(tick)
        scenario.steps(ctx)
    except Exception as e:  # noqa: BLE001
        error = "%s: %s" % (type(e).__name__, e)
    tools = tools_output(since_iso)
    try:
        ctx.t2 = t2_summary(ctx)
    except Exception as e:  # noqa: BLE001 - the report must still be written
        ctx.t2 = {"error": str(e)}
    write_report(ctx, scenario, pin, error, since_iso, tools, started)
    if "--keep-running" not in args:
        runmod.stop(run_id)
    print("report:", os.path.join(ctx.run, "report.md"))
    if error:
        print("ERROR", error)
        sys.exit(1)


if __name__ == "__main__":
    main()
