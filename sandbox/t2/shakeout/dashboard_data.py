"""The shakeout dashboard's data files, made from the runs' own report (report.build_report), never typed by hand.

    python -I sandbox/t2/shakeout/dashboard_data.py <live-run-id> <out-dir> [compare-run-id ...]

Writes three JSON files into <out-dir>:
  summary.json  one row for the live run: how far it is, and every pass-bar count;
  hourly.json   one row per hour of the live run: deliveries, mining sectors, faults, stuck turtles, timer-cleared waits
                (null where the report marks the hour TRUNCATED);
  compare.json  one row per run (the compare runs, then the live run): the same headline counts side by side.
Each file is {"rows": [...], "meta": [...]}: meta names the run folders and the time the numbers were read.
"""
import glob
import json
import os
import re
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
from shakeout import report  # noqa: E402

RUNS = "G:/TurtleOS-Sandbox/testserver/runs"
HOUR = report.HOUR


KILL_RX = re.compile(r"^\[(\d\d\w{3}\d{4} \d\d:\d\d).*Terminating computer #(\d+)")


def host_kills(run_dir):
    """Computers CC killed for running too long (memory reference-big-sims-kill-t2-turtles): one per computer per minute,
    since CC logs a kill on more than one line and the game log rotates (latest.log, debug.log)."""
    seen = set()
    for p in glob.glob(os.path.join(run_dir, "logs", "latest.log")):
        with open(p, encoding="utf8", errors="replace") as f:
            for line in f:
                m = KILL_RX.match(line)
                if m:
                    seen.add((m.group(2), m.group(1)))
    return len(seen)


def pin_of(run_dir):
    try:
        for line in open(os.path.join(run_dir, "report.md"), encoding="utf8"):
            if "pinned to" in line:
                return line.split("pinned to")[1].strip()[:8]
    except OSError:
        pass
    try:
        m = re.search(r"\b[0-9a-f]{40}\b", open(os.path.join(run_dir, "PINNED.txt"), encoding="utf8").read())
        return m.group(0)[:8] if m else ""
    except OSError:
        return ""


def headline(rep, run_id, run_dir, planned_hours=None, faults_planned=None):
    jobs = rep["jobs"]
    c = rep["counts"]
    return {
        "run": run_id,
        "pin": pin_of(run_dir),
        "hours": round(rep["end_ms"] / float(HOUR), 2),
        "planned_hours": planned_hours,
        "turtles": rep["evidence"]["turtles"],
        "deliveries": sum(1 for j in jobs if j["type"] == "DELIVER"),
        "support_jobs": sum(1 for j in jobs if j["type"] == "SUPPORT_FOLLOW"),
        "mine_sectors": sum(1 for j in jobs if j["type"] == "MINE sector done"),
        "mine_zones": sum(1 for j in jobs if j["type"] == "MINE"),
        # windows past the run's end are faults still to come (the schedule plans all of them up front)
        "faults_fired": sum(1 for w in rep["windows"] if w["begin"] <= rep["end_ms"]),
        "faults_planned": faults_planned,
        "lost": c["lost"],
        "decommissioned": c["decommissioned"],
        "not_recovered": len(rep["not_recovered"]),
        "jams": len(rep["jams"]),
        "uncleared_jams": sum(1 for j in rep["jams"] if j["clear"] is None),
        "timer_waits": len(rep["timer_clears"]),
        "host_kills": host_kills(run_dir),
        "ok": c["ok"],
        "stuck_recovered": c["stuck_recovered"],
    }


def main():
    live, out = sys.argv[1], sys.argv[2]
    compare = sys.argv[3:]
    os.makedirs(out, exist_ok=True)
    read_at = time.strftime("%Y-%m-%d %H:%M UTC", time.gmtime())
    live_dir = os.path.join(RUNS, live)
    rep = report.build_report(live_dir)
    try:
        sched = json.load(open(os.path.join(live_dir, "schedule.json")))
        planned_h, planned_f = sched.get("hours"), len(sched.get("entries") or [])
    except (OSError, ValueError):
        planned_h, planned_f = None, None
    summary = headline(rep, live, live_dir, planned_h, planned_f)
    summary["read_at"] = read_at
    timer_by_hour = {}
    for t in rep["timer_clears"]:
        timer_by_hour[int(t["t"] // HOUR)] = timer_by_hour.get(int(t["t"] // HOUR), 0) + 1

    def num(v):
        return None if v == report.TRUNCATED else v

    hourly = [{"hour": h["hour"] + 1, "deliveries": None if h["truncated"] else sum(
        1 for j in rep["jobs"] if j["type"] == "DELIVER" and h["hour"] * HOUR <= j["t"] < (h["hour"] + 1) * HOUR),
        "sectors": num(h["sectors"]), "faults": num(h["faults_fired"]), "stuck": num(h["stuck_onsets"]),
        "timer_waits": None if h["truncated"] else timer_by_hour.get(h["hour"], 0)} for h in rep["hours"]]
    rows = []
    for rid in compare:
        d = os.path.join(RUNS, rid)
        r = report.build_report(d)
        rows.append(headline(r, rid, d))
    rows.append(dict(headline(rep, live, live_dir, planned_h, planned_f)))
    meta = [{"label": "Run folder", "value": live_dir}, {"label": "Read", "value": read_at},
            {"label": "Made by", "value": "sandbox/t2/shakeout/dashboard_data.py over report.build_report"}]
    for name, data in (("summary", [summary]), ("hourly", hourly), ("compare", rows)):
        with open(os.path.join(out, name + ".json"), "w", encoding="utf8") as f:
            json.dump({"rows": data, "meta": meta}, f)
    print("wrote %s: %.2f h, %d deliveries, %d sectors, %d timer waits, %d compare rows"
          % (out, summary["hours"], summary["deliveries"], summary["mine_sectors"], summary["timer_waits"], len(rows)))


if __name__ == "__main__":
    sys.stdout.reconfigure(encoding="utf-8")
    main()
