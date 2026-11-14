"""Shakeout report (plan Task 7; spec sections 2 and 7): what happened to every turtle in a run, read from the run folder's own files.

    from shakeout import report
    report.write_report(run_dir)                              # -> <run>/shakeout/report.md (+ report.json beside it)
    report.write_report(run_dir, expected=EXPECTED_ISSUES)    # open board cards, matched by log pattern, reported apart
    report.classify(turtle_timeline, schedule)                # -> ok | stuck_recovered | decommissioned | lost | expected_hands

    python sandbox/t2/shakeout/report.py <run_dir> [--out DIR]     (a T2 run folder, or a simulator run folder: see below)

WHAT IT READS (Review Focus 5: files on disk, never only through the bridge; a gap it cannot fill is TRUNCATED, never zero):
  <run>/bridge/logs/*.txt     the fleet log the bridge writes (every turtle, server, warehouse and ATC line), sorted by time
                              here because arrival order is not time order;
  <run>/schedule.json         the seed and the planned faults (schedule.py);
  <run>/shakeout/faults.jsonl what actually fired, with wall_ms (ms since the schedule started): start / begin / retry / fail /
                              undo / end-retry / end lines (schedule.py's module doc);
  <run>/shakeout/state.jsonl  /state snapshots, compact (record_state below, called by scenarios/shakeout.py run_loop every
                              SNAPSHOT_EVERY_S, 21-34 KB each with 160 turtles: ~31-49 MB a day): positions, status and phase,
                              docks, lastSeen, NEEDS HANDS, disk, the job queue.
                              The first line is a header with the schedule's start (t0_epoch_ms), the clock everything is put on;
  <run>/shakeout/housekeeping.log  HOUSEKEEPING lines (feeder.py): storage-headroom-low is a FINDING;
  <run>/shakeout/final.json   probe_final: whether each turtle off its dock at the end is still a turtle block where it last said
                              it was (lost = decommissioned and not there).
  A SIMULATOR run folder (sandbox/sim: logs/*.txt, state.json, report.json, no bridge) is read by an adapter: the same log
  format, but only ONE /state (the final one), so positions between come from log lines that state a turtle's own position
  (GPS fix, Pos:, Homing from), new phases from the server's "node_N phase:" / accepted / dispatched lines, and heartbeats
  only from the final lastSeen. The report says so in its evidence section.

THE RULES (spec section 2, the spec owner's table):
  stuck           off its dock and making no progress (position unchanged and no new status/phase) for more than STUCK_MS
                  (10 real minutes), counted OUTSIDE every fault window that touches the turtle and outside every stretch the
                  files do not cover (a /state gap: a turtle could have moved and come back unseen). A fault window is from its
                  actual begin (the "start" line) to the later of its end line and start + quiet_ms (quiet_ms holds the duration
                  already); a one-shot fault (turtle_reboot, low_fuel ...)
                  is a window of no length. A fleet-wide fault touches everyone; a one-turtle fault its computer; chunk_unload
                  its computer and whoever stood in its area.
  recovered       a stuck turtle that later moves, changes phase or parks on its dock. ONE stretch of no progress is ONE
                  finding however many faults hit it (Review Focus 4), and its recovery time is measured from the LAST fault
                  that touched it by the time it was stuck (begun by its onset, not over more than TOUCH_GRACE_MS before it
                  stopped); from the moment it stopped when none did. Faults that begin later, mid-episode, are listed apart.
  gone            no heartbeat (lastSeen, or a log line of its own) for more than GONE_MS (30 real minutes), counted the same
                  way. Gone at the end is decommissioned; gone and back by itself is a recovered finding.
  decommissioned  stuck at the end of the run; or NEEDS HANDS raised and never cleared; or gone at the end.
  lost            decommissioned and not a turtle at its last reported position (final.json); unknown is said, not guessed.
  expected hands  a turtle a remove_item fault took an item from, that asked for hands after it (NEEDS HANDS) and never got
                  them: counted apart from decommissioned (spec 5). One that never asked is decommissioned.
  JAM             at least JAM_COUNT (3) turtles stuck at once inside world.BASE_AREAS; cleared when fewer than 3 remain.
  drift (judged)  server disk used, Lua memory on any computer, the job queue, recovery time: FAIL when it grows steadily, i.e.
                  hourly medians rise with Kendall tau >= TAU_FAIL AND the last 6 h median is over the first 6 h median by more
                  than the metric's tolerance. Jitter round a level, or one step, passes. Fewer than MIN_DRIFT_HOURS hours of
                  samples, or a run with no separate first and last 6 h, is TRUNCATED. Samples inside a fleet-wide fault window
                  are left out. Ordinary rates (jams, stuck, jobs) are reported per hour, not judged.
"""
import argparse
import calendar
import glob
import json
import math
import os
import re
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
T2 = os.path.dirname(HERE)
if T2 not in sys.path:
    sys.path.insert(0, T2)
from shakeout import feeder, world  # noqa: E402

MIN = 60000
HOUR = 60 * MIN
TRUNCATED = "TRUNCATED"
STUCK_MS = 10 * MIN
GONE_MS = 30 * MIN
JAM_COUNT = 3
TOUCH_GRACE_MS = 10 * MIN       # a fault that ended this long before a turtle stopped still counts as having touched it
LOG_GAP_MS = 5 * MIN            # a stretch this long with no fleet log line at all is a gap (160 turtles talk every few s)
SNAP_GAP_MS = 5 * MIN           # ditto for /state snapshots (one every SNAPSHOT_EVERY_S)
SNAPSHOT_EVERY_S = 60
DISK_CAPACITY = 1000000         # CC's default computer disk, used only when a snapshot has diskFree and no disk.bytes
HALF_MS = 6 * HOUR              # "the first 6 hours against the last 6 hours"
TAU_FAIL = 0.6
MIN_DRIFT_HOURS = 8
DRIFT_TOLERANCE = {             # (absolute, share of the first-6-h level): growth under the larger of the two passes
    "disk_used": (10000, 0.05),
    "lua_memory": (64 * 1024, 0.10),
    "queue": (5, 0.25),
    "recovery_ms": (60000, 0.25),
}
ONE_TURTLE_FAULTS = ("turtle_reboot", "remove_item", "put_back_turned", "low_fuel", "full_inventory")
# Faults with a duration that END BY THEMSELVES (a control-mod verb given its duration; schedule.APPLY has no end verb for them),
# so faults.jsonl never has an end line: the window is start + dur_ms. Until 2026-11-14 such a window ran to the run's end, and
# in shakeout-side-a the first radio burst (minute 40 of 180) excused every turtle's stuck time for the rest of the run.
SELF_ENDING = ("radio_loss", "radio_latency", "rs_stall", "rs_offline", "chunk_unload")
VERDICTS = ("ok", "stuck_recovered", "decommissioned", "lost", "expected_hands")
SECTIONS = ["Pass bar", "Stuck or failed turtles", "Jams", "Jobs completed by type", "Faults fired by type",
            "Decommissioned turtles and why", "Expected hands", "First 6 h against last 6 h", "Housekeeping",
            "EXPECTED (board cards open at run time)", "Draft board cards", "Evidence and gaps"]

# The board cards still open at run time, by log pattern: a finding whose reason or quoted lines match one is reported under
# EXPECTED with that card, apart from the new findings. {"card": the card's title, "pattern": a regex}. Filled from the board
# when a run is reported (plan Task 8); empty here, so nothing is excused by default.
EXPECTED_ISSUES = []

# The jam detector's control run (Task 7 step 4): the run where the jam check MUST fail, and what this code reported on it. A jam
# count of 0 is only evidence next to a detector that fired on this run.
JAM_CONTROL = {"run": "G:/TurtleOS-Sandbox/run/20261103-181857-w3_atc_base150-1",
               "what": "W3's 150-turtle simulator boot rush on code without the ATC (rev 4fb6b50)",
               "jams": 1, "uncleared": 1, "stuck_turtles": 126}     # measured 2026-11-10 (task-7-report.md); the spec's bar: >= 1, >= 100

# ---------------------------------------------------------------------------------------------------------------------------
# Reading files
# ---------------------------------------------------------------------------------------------------------------------------

LINE_RX = re.compile(r"^(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d)(\.\d+)?Z\s+(\S+?)#(\d+)\s+(\S+)\s+(.*)$")
NODE_RX = re.compile(r"\bnode_\d+\b")


def _iso_ms(stamp, frac):
    ms = calendar.timegm(time.strptime(stamp, "%Y-%m-%dT%H:%M:%S")) * 1000
    return ms + (int(round(float(frac) * 1000)) if frac else 0)


def parse_log_line(line):
    m = LINE_RX.match(line.rstrip("\r\n"))
    if not m:
        return None
    return {"t": _iso_ms(m.group(1), m.group(2)), "src": m.group(3), "seq": int(m.group(4)), "level": m.group(5),
            "msg": m.group(6), "raw": line.rstrip("\r\n")}


def read_log_files(paths):
    """(lines sorted by time then sequence, unparsed count)."""
    out, bad = [], 0
    for p in sorted(paths):
        with open(p, encoding="utf8", errors="replace") as f:
            for line in f:
                if not line.strip():
                    continue
                r = parse_log_line(line)
                if r is None:
                    bad += 1
                else:
                    out.append(r)
    out.sort(key=lambda r: (r["t"], r["seq"]))
    return out, bad


def _read_jsonl(path):
    out = []
    if not os.path.exists(path):
        return None
    with open(path, encoding="utf8", errors="replace") as f:
        for line in f:
            line = line.strip()
            if line:
                try:
                    out.append(json.loads(line))
                except ValueError:
                    pass
    return out


# ---------------------------------------------------------------------------------------------------------------------------
# /state snapshots: written during the run, read by the report
# ---------------------------------------------------------------------------------------------------------------------------

TURTLE_KEYS = ("x", "y", "z", "status", "phase", "dockX", "dockZ", "lastSeen", "online", "needsHands", "role")


def compact_state(st):
    """The parts of /state the report uses, one a minute for 24 hours: 21-34 KB each with 160 turtles (measured in review), so
    ~31-49 MB a day."""
    fresh, why = feeder.state_is_fresh(st)
    ts = st.get("turtles") or {}
    if isinstance(ts, list):
        ts = {e.get("id"): e for e in ts if isinstance(e, dict)}
    turtles = {tid: {k: e.get(k) for k in TURTLE_KEYS if e.get(k) is not None} for tid, e in ts.items() if isinstance(e, dict)}
    jobs = [j for j in feeder._as_list(st.get("jobs")) if isinstance(j, dict)]
    disk = st.get("disk") if isinstance(st.get("disk"), dict) else {}
    return {"fresh": fresh, "why": why, "serverTime": st.get("serverTime"), "updatedAt": st.get("updatedAt"),
            "disk_bytes": disk.get("bytes"), "disk_free": st.get("diskFree", disk.get("free")),
            "pending": sum(1 for j in jobs if j.get("status") == "PENDING"),
            "jobs": [[j.get("id"), j.get("type"), j.get("status"), j.get("zoneKey"), j.get("assignedTo")] for j in jobs
                     if j.get("status") in feeder.ACTIVE],
            "turtles": turtles}


def record_state(ctx, wall_ms, t0_epoch_ms, every_s=SNAPSHOT_EVERY_S, get=None):
    """Appends one compact /state snapshot to <run>/shakeout/state.jsonl, at most every `every_s`. A bridge that does not answer is
    written as {"fresh": false, "why"}: the report shows the gap as TRUNCATED. Returns the record, or None when not due."""
    st = getattr(ctx, "shakeout_report", None)
    if st is None:
        st = ctx.shakeout_report = {"last": None}
    if st["last"] is not None and wall_ms - st["last"] < every_s * 1000:
        return None
    st["last"] = wall_ms
    d = os.path.join(ctx.run, "shakeout")
    os.makedirs(d, exist_ok=True)
    path = os.path.join(d, "state.jsonl")
    try:
        rec = compact_state(get() if get else ctx.state())     # scenario.Ctx.state(): the bridge's /state
    except Exception as ex:  # noqa: BLE001 - the bridge may be down for a scheduled fault
        rec = {"fresh": False, "why": "no /state: %s: %s" % (type(ex).__name__, str(ex)[:120])}
    rec["wall_ms"], rec["epoch_ms"] = int(wall_ms), int(time.time() * 1000)
    new = not os.path.exists(path)
    with open(path, "a", encoding="utf8") as f:
        if new:
            f.write(json.dumps({"header": {"t0_epoch_ms": int(t0_epoch_ms), "every_s": every_s}}) + "\n")
        f.write(json.dumps(rec, separators=(",", ":")) + "\n")
    return rec


def probe_final(ctx):
    """<run>/shakeout/final.json: for each turtle off its dock in the last fresh snapshot, whether a turtle block stands where it
    last said it was (`execute if block`): present true, false (lost if it is decommissioned), or null when that chunk is not
    loaded or the server does not answer (said as unknown in the report, never guessed)."""
    snaps = _read_jsonl(os.path.join(ctx.run, "shakeout", "state.jsonl")) or []
    last = next((s for s in reversed(snaps) if s.get("fresh") and s.get("turtles")), None)
    out = {}
    raw = getattr(ctx, "_raw", None) or ctx.control
    for tid, e in sorted(((last or {}).get("turtles") or {}).items()):
        if None in (e.get("x"), e.get("y"), e.get("z")) or (e.get("x"), e.get("z")) == (e.get("dockX"), e.get("dockZ")):
            continue
        present, reply = False, ""
        for kind in world.TURTLE_KINDS:
            try:
                reply = raw.command("execute if block %d %d %d %s" % (e["x"], e["y"], e["z"], kind)) or ""
            except Exception as ex:  # noqa: BLE001
                reply, present = "%s: %s" % (type(ex).__name__, ex), None
                break
            if "Test passed" in reply:
                present = True
                break
            if "not loaded" in reply.lower():
                present = None
        out[tid] = {"present": present, "pos": [e["x"], e["y"], e["z"]], "reply": reply[:160]}
    with open(os.path.join(ctx.run, "shakeout", "final.json"), "w", encoding="utf8") as f:
        json.dump(out, f, indent=1, sort_keys=True)
    return out


# ---------------------------------------------------------------------------------------------------------------------------
# Intervals and fault windows
# ---------------------------------------------------------------------------------------------------------------------------


def _merge(iv):
    out = []
    for a, b in sorted((a, b) for a, b in iv if b > a):
        if out and a <= out[-1][1]:
            out[-1][1] = max(out[-1][1], b)
        else:
            out.append([a, b])
    return out


def _covered(a, b, iv):
    return sum(max(0, min(b, e) - max(a, s)) for s, e in iv)


def _outside(a, b, iv):
    return max(0, b - a) - _covered(a, b, iv)


def _cross(a, need, iv):
    """The first time t >= a at which [a, t] holds `need` ms outside the merged intervals iv."""
    t, left = a, need
    for s, e in iv:
        if e <= t:
            continue
        if s > t:
            if s - t >= left:
                return t + left
            left -= s - t
        t = max(t, e)
    return t + left


def _quiet(e):
    return int(e.get("quiet_ms") or 0)


def _window_ms(e):
    a = e.get("args") or {}
    return int(a.get("dur_ms") or a.get("down_ms") or 0) if isinstance(a, dict) else 0


def windows_from(schedule, fault_lines=None, end_ms=None):
    """Fault windows {id, fault, begin, end, targets (None: everyone, or a set of node ids), area, planned}. `schedule` is either
    windows already (each with "begin") or schedule.json entries. Without fault_lines the windows are the PLANNED ones (t_ms to
    t_ms + max(dur, quiet_ms), a one-turtle fault aimed at nobody known); with them, measured: the "start" line to the later of
    the "end" line (start + dur_ms for a SELF_ENDING fault, which never logs one; the run's end for any other that never
    ended; its begin line for a one-shot) and start + quiet_ms (quiet_ms is
    measured from the start and already holds the duration). A fault that never began is no window."""
    if schedule and all("begin" in w for w in schedule):
        return sorted([dict(w, targets=set(w["targets"]) if w.get("targets") is not None else None) for w in schedule],
                      key=lambda w: w["begin"])
    out = []
    by_id = {}
    for r in fault_lines or []:
        by_id.setdefault(r.get("id"), []).append(r)
    for e in schedule or []:
        f = e.get("fault")
        if fault_lines is None:
            b = int(e["t_ms"])
            targets = set() if f in ONE_TURTLE_FAULTS or f == "chunk_unload" else None
            out.append({"id": e.get("id"), "fault": f, "begin": b, "end": b + max(_window_ms(e), _quiet(e)), "targets": targets,
                        "area": None, "planned": True})
            continue
        ls = sorted(by_id.get(e.get("id"), []), key=lambda r: r.get("wall_ms", 0))
        begin = next((r for r in ls if r.get("phase") == "begin"), None)
        if begin is None:
            continue
        start = next((r for r in ls if r.get("phase") == "start"), begin)
        end = next((r for r in ls if r.get("phase") == "end"), None)
        if end is not None:
            stop = int(end["wall_ms"])
        elif f in SELF_ENDING:
            stop = int(start["wall_ms"]) + _window_ms(e)
        elif _window_ms(e) > 0:
            stop = int(end_ms if end_ms is not None else begin["wall_ms"])
        else:
            stop = int(begin["wall_ms"])
        detail = begin.get("detail") or {}
        targets, area = None, None
        if f in ONE_TURTLE_FAULTS or f == "chunk_unload":
            cid = detail.get("computer") if isinstance(detail, dict) else None
            targets = {"node_%s" % cid} if cid is not None else set()
            if f == "chunk_unload" and isinstance(detail, dict) and detail.get("area"):
                area = list(detail["area"])
        # quiet_ms counts from the fault's start and already holds its duration (schedule.py): the window is the later of the end
        # line and start + quiet_ms, never the end line PLUS quiet_ms (that counted the duration twice: 40-45% of a day excused)
        out.append({"id": e.get("id"), "fault": f, "begin": int(start["wall_ms"]),
                    "end": max(stop, int(start["wall_ms"]) + _quiet(e)), "targets": targets,
                    "area": area, "planned": False})
    return sorted(out, key=lambda w: w["begin"])


def _in_area(pos, area):
    return pos is not None and area is not None and area[0] <= pos[0] <= area[2] and area[1] <= pos[2] <= area[3]


def _touches(w, tid, pos):
    if w.get("targets") is None:
        return True
    return tid in w["targets"] or _in_area(pos, w.get("area"))


def in_base(pos):
    return pos is not None and any(x1 <= pos[0] <= x2 and z1 <= pos[2] <= z2 for x1, z1, x2, z2 in world.BASE_AREAS)


# ---------------------------------------------------------------------------------------------------------------------------
# One turtle
# ---------------------------------------------------------------------------------------------------------------------------


def analyse(timeline, windows, end_ms=None):
    """Everything classify() decides, with its evidence. timeline: {"id", "samples": [{"t", "pos": [x,y,z] or None, "phase" (a
    status/phase string) or None, "on_dock": bool or None (None carries the last known), "seen": a heartbeat time or None,
    "needs_hands" (present: the current value, None = cleared; absent: unchanged)}], "heard": [its own log line times],
    "heard_complete": whether heartbeats between samples are known (False: only the silence at the end is judged), "gaps":
    [[a, b]] the files do not cover, "end", "present": final.json's verdict}. Times are ms on one clock (the run's)."""
    windows = windows_from(windows) if windows and "begin" not in windows[0] else (windows or [])
    tid = timeline.get("id")
    samples = sorted(timeline.get("samples") or [], key=lambda s: s["t"])
    end = end_ms if end_ms is not None else timeline.get("end", samples[-1]["t"] if samples else 0)

    def pos_at(t):
        p = None
        for s in samples:
            if s.get("pos") is not None:
                if s["t"] > t and p is not None:
                    break
                p = tuple(s["pos"])
        return p

    mine = [w for w in windows if _touches(w, tid, pos_at(w["begin"]))]
    excl = _merge([(w["begin"], w["end"]) for w in mine] + [tuple(g) for g in timeline.get("gaps") or []])

    # stretches off the dock with no progress
    stretches = []
    last_pos = last_phase = None
    on = None
    since = spos = None
    nh, nh_raised, nh_first = None, None, None
    for s in samples:
        pos = tuple(s["pos"]) if s.get("pos") is not None else None
        ph = s.get("phase")
        progress = (pos is not None and last_pos is not None and pos != last_pos) or \
                   (ph is not None and last_phase is not None and ph != last_phase)
        if s.get("on_dock") is not None:
            on = bool(s["on_dock"])
        if "needs_hands" in s:
            if s["needs_hands"] and not nh:
                nh_raised = s["t"]
                nh_first = nh_first if nh_first is not None else s["t"]
            nh = s["needs_hands"]
        if on:
            if since is not None:
                stretches.append((since, s["t"], spos, False))
            since = None
        elif since is None:
            since, spos = s["t"], pos or last_pos
        elif progress:
            stretches.append((since, s["t"], spos, False))
            since, spos = s["t"], pos or last_pos
        if pos is not None:
            last_pos = pos
            if since is not None and spos is None:
                spos = pos
        if ph is not None:
            last_phase = ph
    if since is not None:
        stretches.append((since, end, spos, True))

    def touching(a, b):
        return [w for w in mine if w["begin"] <= b and w["end"] >= a - TOUCH_GRACE_MS]

    episodes = []
    for a, b, p, is_open in stretches:
        onset = _cross(a, STUCK_MS, excl)
        if onset >= b:
            continue
        hit = touching(a, b)
        # Review Focus 4: recovery from the LAST fault that touched it -- among those that began by the time it was stuck. A
        # fault that begins later, mid-episode, is listed apart: counting it would shorten every long episode to the time since
        # whatever unrelated fault fired last (72 fleet-wide a day).
        cause = [w for w in hit if w["begin"] <= onset]
        later = [w for w in hit if w["begin"] > onset]
        frm = max(w["begin"] for w in cause) if cause else a
        episodes.append({"since": a, "onset": onset, "until": None if is_open else b, "pos": list(p) if p else None,
                         "open": is_open, "faults": [w["id"] for w in cause], "later_faults": [w["id"] for w in later],
                         "recovery_from": frm, "recovery_ms": None if is_open else b - frm})

    # heartbeats
    heard = sorted({s["seen"] for s in samples if s.get("seen") is not None} | set(timeline.get("heard") or []))
    heard = [h for h in heard if h <= end]
    silences, gone = [], {"silent_ms": None, "since": heard[-1] if heard else None}
    if heard:
        pairs = list(zip(heard, heard[1:])) if timeline.get("heard_complete", True) else []
        for a, b in pairs:
            out = _outside(a, b, excl)
            if out > GONE_MS:
                hit = touching(a, b)
                silences.append({"since": a, "until": b, "silent_ms": out, "faults": [w["id"] for w in hit]})
        gone["silent_ms"] = _outside(heard[-1], end, excl)

    reasons = []
    if any(e["open"] for e in episodes):
        e = episodes[-1]
        reasons.append("stuck at the end of the run: no progress off its dock since run %s at %s" % (_hm(e["since"]), e["pos"]))
    if gone["silent_ms"] is not None and gone["silent_ms"] > GONE_MS:
        reasons.append("gone: no heartbeat for %d min outside any fault (last heard run %s)" % (gone["silent_ms"] // MIN,
                                                                                              _hm(gone["since"])))
    if nh:
        reasons.append("NEEDS HANDS never cleared: %s (raised run %s)" % (nh, _hm(nh_raised)))
    removals = [w for w in mine if w["fault"] == "remove_item"]
    asked = nh_raised is not None and any(nh_raised >= w["begin"] for w in removals)
    decom = bool(reasons)
    if decom and timeline.get("present") is False:
        verdict = "lost"
    elif decom and removals and asked:
        verdict = "expected_hands"
    elif decom:
        verdict = "decommissioned"
        if removals and not asked:
            reasons.append("an item was taken (%s) and it never asked for hands" % ", ".join(w["id"] for w in removals))
    elif episodes or silences:
        verdict = "stuck_recovered"
    else:
        verdict = "ok"
    return {"id": tid, "verdict": verdict, "episodes": episodes, "silences": silences, "gone": gone, "needs_hands": nh,
            "needs_hands_raised": nh_raised, "reasons": reasons, "touching": [w["id"] for w in mine],
            "excluded_ms": _covered(samples[0]["t"] if samples else 0, end, excl), "present": timeline.get("present"),
            "samples": len(samples)}


def classify(turtle_timeline, schedule, end_ms=None):
    """One of "ok", "stuck_recovered", "decommissioned", "lost", "expected_hands" (the module doc's rules). `schedule` is fault
    windows (windows_from) or schedule.json entries (taken as planned windows)."""
    return analyse(turtle_timeline, windows_from(schedule) if schedule else [], end_ms)["verdict"]


def _hm(ms):
    if ms is None:
        return "?"
    ms = int(ms)
    sign = "-" if ms < 0 else ""
    ms = abs(ms)
    return "%s%d:%02d" % (sign, ms // HOUR, (ms % HOUR) // MIN)


# ---------------------------------------------------------------------------------------------------------------------------
# The fleet: jams and counts
# ---------------------------------------------------------------------------------------------------------------------------


def find_jams(analyses, end_ms):
    """JAM: at least JAM_COUNT turtles stuck at once inside world.BASE_AREAS; cleared when fewer remain. Returns (jams, evidence:
    the number of stuck episodes inside the base)."""
    ev = []
    n = 0
    for a in analyses.values():
        for e in a["episodes"]:
            if in_base(e["pos"]):
                n += 1
                ev.append((e["onset"], 1, a["id"]))
                if e["until"] is not None:
                    ev.append((e["until"], -1, a["id"]))
    ev.sort(key=lambda x: (x[0], x[1]))
    jams, cur, now = [], None, set()
    for t, d, tid in ev:
        if d > 0:
            now.add(tid)
        else:
            now.discard(tid)
        if cur is None and len(now) >= JAM_COUNT:
            cur = {"start": t, "clear": None, "peak": len(now), "members": set(now)}
        elif cur is not None:
            cur["peak"] = max(cur["peak"], len(now))
            cur["members"] |= now
            if len(now) < JAM_COUNT:
                cur["clear"] = t
                jams.append(cur)
                cur = None
    if cur is not None:
        jams.append(cur)
    for j in jams:
        j["members"] = sorted(j["members"], key=_node_key)
        j["duration_ms"] = (j["clear"] if j["clear"] is not None else end_ms) - j["start"]
    return jams, n


def _node_key(tid):
    m = re.search(r"(\d+)$", tid or "")
    return (int(m.group(1)) if m else 0, tid or "")


def is_loader(tid, tl):
    """A miner's chunk loader: it hovers over the sector, by design, for as long as its miner digs (76 min in shakeout-side-a),
    so the off-dock-no-progress rule would call every one stuck. Loaders are listed, not judged; their miner is."""
    return str(tid).startswith("loader_") or (tl or {}).get("role") == "LOADER"


def findings(timelines, windows, end_ms):
    """Every turtle analysed: {"all": {id: analysis}, "turtles": [the ones not ok], "counts": {verdict: n}, "jams", "jam_evidence",
    "stuck_ever"}."""
    windows = windows_from(windows) if windows else []
    al = {tid: analyse(tl, windows, end_ms) for tid, tl in timelines.items() if not is_loader(tid, tl)}
    loaders = sorted((tid for tid, tl in timelines.items() if is_loader(tid, tl)), key=_node_key)
    counts = {v: 0 for v in VERDICTS}
    for a in al.values():
        counts[a["verdict"]] += 1
    jams, n = find_jams(al, end_ms)
    return {"all": al, "loaders": loaders,
            "turtles": [al[t] for t in sorted(al, key=_node_key) if al[t]["verdict"] != "ok"], "counts": counts,
            "jams": jams, "jam_evidence": n, "stuck_ever": sum(1 for a in al.values() if a["episodes"])}


# ---------------------------------------------------------------------------------------------------------------------------
# Drift
# ---------------------------------------------------------------------------------------------------------------------------


def _median(v):
    v = sorted(v)
    n = len(v)
    return None if not n else (v[n // 2] if n % 2 else (v[n // 2 - 1] + v[n // 2]) / 2.0)


def _kendall(pts):
    n = len(pts)
    if n < 2:
        return 0.0
    s = 0
    for i in range(n):
        for j in range(i + 1, n):
            dx, dy = pts[j][0] - pts[i][0], pts[j][1] - pts[i][1]
            s += ((dx > 0) - (dx < 0)) * ((dy > 0) - (dy < 0))
    return s / (n * (n - 1) / 2.0)


def judge_drift(series, end_ms, metric):
    """{"verdict": PASS | FAIL | TRUNCATED, "evidence": samples, ...}: see the module doc."""
    tol_abs, tol_rel = DRIFT_TOLERANCE[metric]
    out = {"metric": metric, "evidence": len(series)}
    if not series:
        return dict(out, verdict=TRUNCATED, why="no samples of %s in the run folder" % metric)
    if end_ms < 2 * HALF_MS:
        return dict(out, verdict=TRUNCATED, why="a run of %.1f h has no separate first and last 6 h" % (end_ms / float(HOUR)))
    first = [v for t, v in series if t < HALF_MS]
    last = [v for t, v in series if t >= end_ms - HALF_MS]
    hours = {}
    for t, v in series:
        hours.setdefault(int(t // HOUR), []).append(v)
    pts = sorted((h, _median(v)) for h, v in hours.items())
    out.update(hours=len(pts), first_n=len(first), last_n=len(last))
    if len(first) < 3 or len(last) < 3 or len(pts) < MIN_DRIFT_HOURS:
        return dict(out, verdict=TRUNCATED, why="too few samples: %d in the first 6 h, %d in the last, %d hours with any (need 3, 3, "
                    "%d)" % (len(first), len(last), len(pts), MIN_DRIFT_HOURS))
    m1, m2 = _median(first), _median(last)
    tau = _kendall(pts)
    tol = max(tol_abs, tol_rel * abs(m1))
    rise = m2 - m1
    fail = tau >= TAU_FAIL and rise > tol
    return dict(out, verdict="FAIL" if fail else "PASS", first_median=m1, last_median=m2, rise=rise, tolerance=tol,
                tau=round(tau, 3),
                why="%s: first 6 h median %s, last 6 h median %s (rise %s, tolerance %s), hourly trend tau %.2f (fails at >= %.2f "
                    "with the rise over tolerance)" % ("grows steadily" if fail else "no steady growth", _num(m1), _num(m2),
                                                       _num(rise), _num(tol), tau, TAU_FAIL))


def _num(v):
    return "%d" % v if isinstance(v, (int, float)) and abs(v - round(v)) < 1e-9 else ("%.1f" % v if v is not None else "?")


# ---------------------------------------------------------------------------------------------------------------------------
# A run folder
# ---------------------------------------------------------------------------------------------------------------------------

OWN_POS_RX = [re.compile(r"GPS fix: (-?\d+),(-?\d+),(-?\d+)"), re.compile(r"Pos:(-?\d+),(-?\d+),(-?\d+)"),
              re.compile(r"Homing to dock from (-?\d+),(-?\d+),(-?\d+)")]
DOCK_RX = re.compile(r"Assigned dock: bay \d+ row \w+ \((-?\d+),(-?\d+),(-?\d+)\)")
PHASE_RX = re.compile(r"^(node_\d+) phase: (.+)$")
ACCEPT_RX = re.compile(r"^Job (job_\d+) accepted by (node_\d+)")
DISPATCH_RX = re.compile(r"^Dispatched (job_\d+) \[\w+\] -> (node_\d+)")
HANDS_RX = re.compile(r"NEEDS HANDS: (node_\d+) \S+ (.*)$")
HANDS_CLEAR_RX = re.compile(r"^(node_\d+) passed its own hardware check")
JOB_TYPE_RX = re.compile(r"\b(job_\d+) \[([A-Z_]+)\]")
JOB_DONE_RX = re.compile(r"^Job complete: (job_\d+)")
ZONE_DONE_RX = re.compile(r"^Zone (job_\d+) rescan clean .*MINE_COMPLETE")
JOB_FAIL_RX = re.compile(r"^(?:Job permanently failed: (job_\d+)|Job (job_\d+) retry \d+/\d+)")
SECTOR_DONE_RX = re.compile(r"^Sector \(-?\d+,-?\d+\) done by node_\d+")
FAIL_RX = re.compile(r"fail|STUCK|stuck|NEEDS HANDS|Gave up|blocked|blocking|retry|ERROR|refused|lost|cannot|no fix|timeout",
                     re.I)
HK_RX = re.compile(r"^(\S+) HOUSEKEEPING (\S+?):?(\s.*)?$")


def _t0_from_faults(fault_lines):
    vals = []
    for r in fault_lines or []:
        try:
            vals.append(time.mktime(time.strptime(r["time"], "%Y-%m-%dT%H:%M:%S")) * 1000 - int(r["wall_ms"]))
        except (KeyError, ValueError, TypeError):
            pass
    return int(_median(vals)) if vals else None


def load_run(run_dir):
    """The run folder read into one shape (T2 or simulator); every time on the run's clock (ms since the schedule started, or the
    simulation start). notes: what could not be read, each a TRUNCATED line in the report."""
    R = {"dir": run_dir, "notes": [], "snapshots": [], "stale": 0, "entries": [], "fault_lines": None, "hk": None, "final": {},
         "seed": None, "schedule_path": None, "sim_faults": None}
    t2 = os.path.isdir(os.path.join(run_dir, "bridge", "logs")) or os.path.isdir(os.path.join(run_dir, "shakeout"))
    sim = not t2 and os.path.exists(os.path.join(run_dir, "state.json")) and os.path.isdir(os.path.join(run_dir, "logs"))
    if not (t2 or sim):
        raise ValueError("%s is neither a T2 run folder (bridge/logs, shakeout/) nor a simulator one (logs/, state.json)" % run_dir)
    R["kind"] = "t2" if t2 else "sim"
    lines, bad = read_log_files(glob.glob(os.path.join(run_dir, "bridge" if t2 else "", "logs", "*.txt")))
    R["unparsed"] = bad
    if not lines:
        R["notes"].append("no fleet log line in the run folder's %s: every count from the log is TRUNCATED" %
                          ("bridge/logs" if t2 else "logs"))
    sp = os.path.join(run_dir, "schedule.json")
    if os.path.exists(sp):
        with open(sp, encoding="utf8") as f:
            doc = json.load(f)
        R["entries"] = doc.get("entries", []) if isinstance(doc, dict) else doc
        R["seed"] = doc.get("seed") if isinstance(doc, dict) else None
        R["schedule_path"] = sp
    elif t2:
        R["notes"].append("no schedule.json: no fault is known, so none is excused, and cards carry no seed")
    if t2:
        R["fault_lines"] = _read_jsonl(os.path.join(run_dir, "shakeout", "faults.jsonl"))
        if R["fault_lines"] is None:
            R["notes"].append("no shakeout/faults.jsonl: what fired is unknown (TRUNCATED); planned windows are used")
        hk = os.path.join(run_dir, "shakeout", "housekeeping.log")
        if os.path.exists(hk):
            with open(hk, encoding="utf8", errors="replace") as f:
                R["hk"] = [l.rstrip("\n") for l in f if l.strip()]
        snaps = _read_jsonl(os.path.join(run_dir, "shakeout", "state.jsonl"))
        header = next((s["header"] for s in (snaps or []) if "header" in s), {})
        t0 = header.get("t0_epoch_ms") or _t0_from_faults(R["fault_lines"])
        if t0 is None:
            t0 = lines[0]["t"] if lines else 0
            R["notes"].append("the schedule's start is not recorded: the first log line is used as the start")
        if snaps is None:
            R["notes"].append("no shakeout/state.jsonl: no /state snapshot, so no turtle can be judged (TRUNCATED)")
        for s in snaps or []:
            if "header" in s:
                continue
            if not s.get("fresh"):
                R["stale"] += 1
                continue
            s = dict(s)
            s["t"] = int((s.get("updatedAt") or s.get("epoch_ms") or (t0 + s.get("wall_ms", 0))) - t0)
            R["snapshots"].append(s)
        fp = os.path.join(run_dir, "shakeout", "final.json")
        if os.path.exists(fp):
            with open(fp, encoding="utf8") as f:
                R["final"] = json.load(f)
        ends = [s["t"] for s in R["snapshots"]] + [int(r.get("wall_ms", 0)) for r in R["fault_lines"] or []] + \
               [l["t"] - t0 for l in lines[-1:]]
        R["end"] = max(ends) if ends else 0
    else:
        with open(os.path.join(run_dir, "state.json"), encoding="utf8") as f:
            st = json.load(f)
        rj = {}
        if os.path.exists(os.path.join(run_dir, "report.json")):
            with open(os.path.join(run_dir, "report.json"), encoding="utf8") as f:
                rj = json.load(f)
        hours = rj.get("simulated_hours")
        st_t = st.get("serverTime") or st.get("updatedAt")
        t0 = int(round(st_t - hours * HOUR)) if (st_t and hours) else (lines[0]["t"] if lines else 0)
        snap = compact_state(st)
        snap["t"] = int((st.get("updatedAt") or st_t) - t0)
        R["snapshots"] = [snap]
        R["end"] = int(st_t - t0) if st_t else (lines[-1]["t"] - t0 if lines else 0)
        R["sim_faults"] = rj.get("faults") or []
        R["seed"] = rj.get("seed")
        R["notes"].append("SIMULATOR run folder: one /state only (the final one). Positions between come from log lines that state "
                          "a turtle's own position, new phases from the server's phase/accepted/dispatched lines, heartbeats from "
                          "the final lastSeen only (a silence before the end is not judged): TRUNCATED between those")
    R["t0"] = t0
    for l in lines:
        l["rt"] = l["t"] - t0
    R["lines"] = lines
    return R


def _sim_windows(faults):
    out = []
    for i, f in enumerate(faults or []):
        nums = [int(v) for v in re.findall(r"=(\d+)", str(f.get("args", "")))]
        b = int(f.get("t_ms") or 0)
        node = re.findall(r"node_\d+", str(f.get("args", "")))
        out.append({"id": "sim%02d" % (i + 1), "fault": f.get("name"), "begin": b, "end": b + (max(nums) if nums else 0),
                    "targets": set(node) if node else None, "area": None, "planned": False})
    return out


def run_windows(R):
    if R["kind"] == "sim":
        return _sim_windows(R["sim_faults"])
    return windows_from(R["entries"], R["fault_lines"], R["end"])


def _gaps(times, end, limit):
    times = sorted(times)
    if not times:
        return [[0, end]] if end > 0 else []
    out = []
    if times[0] > limit:
        out.append([0, times[0]])
    for a, b in zip(times, times[1:]):
        if b - a > limit:
            out.append([a, b])
    if end - times[-1] > limit:
        out.append([times[-1], end])
    return out


def _on_dock(e):
    if e.get("x") is None or e.get("dockX") is None:
        return False
    return (e.get("x"), e.get("z")) == (e.get("dockX"), e.get("dockZ"))


def _snap_sample(s, e, t0):
    pos = [e["x"], e["y"], e["z"]] if None not in (e.get("x"), e.get("y"), e.get("z")) else None
    return {"t": s["t"], "pos": pos, "phase": "%s/%s" % (e.get("status") or "", e.get("phase") or ""), "on_dock": _on_dock(e),
            "seen": (e["lastSeen"] - t0) if isinstance(e.get("lastSeen"), (int, float)) else None,
            "needs_hands": e.get("needsHands")}


def timelines(R):
    """{node id: timeline} for every turtle the run folder names."""
    t0, end = R["t0"], R["end"]
    out = {}
    own = {}
    for l in R["lines"]:
        if l["src"].startswith("node_"):
            own.setdefault(l["src"], []).append(l)
    if R["kind"] == "t2":
        gaps = _gaps([s["t"] for s in R["snapshots"]], end, SNAP_GAP_MS)
        for s in R["snapshots"]:
            for tid, e in (s.get("turtles") or {}).items():
                tl = out.setdefault(tid, {"id": tid, "samples": [], "heard": [l["rt"] for l in own.get(tid, [])],
                                          "heard_complete": True, "gaps": gaps, "end": end,
                                          "present": (R["final"].get(tid) or {}).get("present"), "role": e.get("role")})
                tl["samples"].append(_snap_sample(s, e, t0))
        return out
    # the simulator adapter
    final = R["snapshots"][0]
    ids = set(final.get("turtles") or {}) | set(own)
    events = {}
    for l in R["lines"]:
        msg = l["msg"]
        if l["src"] == "server":
            for rx, kind in ((PHASE_RX, "phase"), (ACCEPT_RX, "accept"), (DISPATCH_RX, "dispatch")):
                m = rx.match(msg)
                if m:
                    tid = m.group(1) if kind == "phase" else m.group(2)
                    events.setdefault(tid, []).append({"t": l["rt"], "pos": None, "on_dock": None,
                                                       "phase": "%s:%s" % (kind, m.group(2) if kind == "phase" else m.group(1))})
            m = HANDS_RX.search(msg)
            if m:
                events.setdefault(m.group(1), []).append({"t": l["rt"], "needs_hands": m.group(2)[:200]})
            m = HANDS_CLEAR_RX.match(msg)
            if m:
                events.setdefault(m.group(1), []).append({"t": l["rt"], "needs_hands": None})
    for tid in ids:
        fe = (final.get("turtles") or {}).get(tid) or {}
        dock = (fe.get("dockX"), fe.get("dockZ")) if fe.get("dockX") is not None else None
        samples = []
        for l in own.get(tid, []):
            m = DOCK_RX.search(l["msg"])
            if m:
                dock = (int(m.group(1)), int(m.group(3)))
            if "Docked at" in l["msg"]:
                samples.append({"t": l["rt"], "pos": None, "phase": None, "on_dock": True})
                continue
            for rx in OWN_POS_RX:
                m = rx.search(l["msg"])
                if m:
                    p = [int(m.group(1)), int(m.group(2)), int(m.group(3))]
                    samples.append({"t": l["rt"], "pos": p, "phase": None,
                                    "on_dock": (p[0], p[2]) == dock if dock else None})
                    break
        samples += events.get(tid, [])
        if fe:
            s = _snap_sample(final, fe, t0)
            s["phase"] = None           # the final status is another vocabulary than the log's phases: not a "new phase"
            samples.append(s)
        out[tid] = {"id": tid, "samples": sorted(samples, key=lambda s: s["t"]), "heard": [l["rt"] for l in own.get(tid, [])],
                    "heard_complete": False, "gaps": [], "end": end, "present": None, "role": fe.get("role")}
    return out


# ---------------------------------------------------------------------------------------------------------------------------
# Counting
# ---------------------------------------------------------------------------------------------------------------------------


def jobs_done(lines):
    types, done = {}, []
    for l in lines:
        for m in JOB_TYPE_RX.finditer(l["msg"]):
            types.setdefault(m.group(1), m.group(2))
    for l in lines:
        if l["src"] != "server":
            continue
        m = JOB_DONE_RX.match(l["msg"])
        if m:
            done.append({"t": l["rt"], "job": m.group(1), "type": types.get(m.group(1), "UNKNOWN")})
            continue
        m = ZONE_DONE_RX.match(l["msg"])
        if m:
            done.append({"t": l["rt"], "job": m.group(1), "type": "MINE zone complete"})
            continue
        if SECTOR_DONE_RX.match(l["msg"]):
            done.append({"t": l["rt"], "job": None, "type": "MINE sector done"})
    return done


def long_sites(R):
    lanes = {}
    for i, lane in enumerate(feeder.LONG_SITES):
        for zid in lane:
            z = next((z for z in feeder.ZONES if z["id"] == zid), None)
            if z:
                lanes[feeder.zone_key(z)] = i
    out = [{"site": "long%d" % (i + 1), "zones": list(lane), "jobs": set(), "open_ms": 0, "snapshots": 0}
           for i, lane in enumerate(feeder.LONG_SITES)]
    snaps = R["snapshots"]
    for k, s in enumerate(snaps):
        nxt = snaps[k + 1]["t"] if k + 1 < len(snaps) else s["t"]
        open_lanes = set()
        for j in s.get("jobs") or []:
            if j[1] == "MINE" and j[3] in lanes:
                out[lanes[j[3]]]["jobs"].add(j[0])
                open_lanes.add(lanes[j[3]])
        for i in open_lanes:
            out[i]["snapshots"] += 1
            out[i]["open_ms"] += min(max(0, nxt - s["t"]), SNAP_GAP_MS)
    return out


def fault_stats(R):
    rows = {}
    for e in R["entries"]:
        rows.setdefault(e.get("fault"), {"planned": 0, "start": 0, "begin": 0, "fail": 0, "undo": 0, "end": 0, "end-retry": 0,
                                         "retry": 0, "late_max_ms": 0})["planned"] += 1
    if R["kind"] == "sim":
        for f in R["sim_faults"] or []:
            rows.setdefault(f.get("name"), {"planned": 0, "begin": 0})["begin"] += 1
        return rows, len(R["sim_faults"] or [])
    if R["fault_lines"] is None:        # no faults.jsonl: what fired is unknown, never 0
        for row in rows.values():
            for k in list(row):
                if k != "planned":
                    row[k] = TRUNCATED
        return rows, 0
    for r in R["fault_lines"] or []:
        f = r.get("fault")
        if f is None:
            continue
        row = rows.setdefault(f, {"planned": 0, "start": 0, "begin": 0, "fail": 0, "undo": 0, "end": 0, "end-retry": 0, "retry": 0,
                                  "late_max_ms": 0})
        ph = r.get("phase")
        if ph in row:
            row[ph] += 1
        if ph == "begin":
            row["late_max_ms"] = max(row["late_max_ms"], int(r.get("late_ms") or 0))
    return rows, len(R["fault_lines"] or [])


def housekeeping(R):
    if R["kind"] == "sim":
        return None
    if R["hk"] is None:
        return {"lines": 0, "tags": {}, "low": [], "unknown": 0, "missing": True}
    tags, low = {}, []
    for line in R["hk"]:
        m = HK_RX.match(line)
        tag = m.group(2) if m else "unparsed"
        tags[tag] = tags.get(tag, 0) + 1
        if tag == "storage-headroom-low":
            low.append(line)
    return {"lines": len(R["hk"]), "tags": tags, "low": low, "unknown": tags.get("storage-headroom-unknown", 0), "missing": False}


def _why_quotes(by_node, a, end, n=5):
    """The lines that say WHY, for each of a finding's reasons: around each stuck episode; the server's NEEDS HANDS line nearest
    the raise and the latest hands line after it (so a clear that the final /state contradicts shows); the turtle's own last
    lines before it went silent. Deduplicated, at most n. THE REASON-SPECIFIC LINES COME FIRST (final review): the NEEDS HANDS
    raise and its latest hands line, and a gone turtle's own last lines, are what the finding is about; the stuck episodes'
    context lines come after them, so a turtle with three episodes cannot push its NEEDS HANDS line out of the n."""
    tid, ls, out = a["id"], by_node.get(a["id"], []), []
    context = []
    if a.get("needs_hands_raised") is not None and a.get("needs_hands"):
        hands = [l for l in ls if "NEEDS HANDS" in l["msg"] or "back in service" in l["msg"]]
        raised = [l for l in hands if "NEEDS HANDS" in l["msg"]]
        if raised:
            near = min(raised, key=lambda l: abs(l["rt"] - a["needs_hands_raised"]))
            out.append(near["raw"][:260])
            after = [l for l in hands if l["rt"] > near["rt"]]
            if after:
                out.append(after[-1]["raw"][:260])
        context += _quotes(by_node, tid, a["needs_hands_raised"] - 10 * MIN, a["needs_hands_raised"] + MIN, 1)
    if (a["gone"]["silent_ms"] or 0) > GONE_MS and a["gone"]["since"] is not None:
        own = [l for l in ls if l["src"] == tid and l["rt"] <= a["gone"]["since"] + 1000]
        out += [l["raw"][:260] for l in own[-2:]]
    for e in a["episodes"]:
        out += _quotes(by_node, tid, e["since"] - 10 * MIN, e["until"] if e["until"] is not None else end, 2)
    out += context
    for sl in a["silences"]:
        own = [l for l in ls if l["src"] == tid and l["rt"] <= sl["since"] + 1000]
        out += [l["raw"][:260] for l in own[-1:]]
    seen, uniq = set(), []
    for q in out:
        if q not in seen:
            seen.add(q)
            uniq.append(q)
    return uniq[:n]


def _quotes(by_node, tid, a, b, n=3):
    ls = [l for l in by_node.get(tid, []) if a <= l["rt"] <= b]
    bad = [l for l in ls if l["level"] in ("WARN", "ERROR") or FAIL_RX.search(l["msg"])]
    pick = (bad or ls)[-n:]
    return [l["raw"][:260] for l in pick]


def _by_node(lines):
    out = {}
    for l in lines:
        names = {l["src"]} if l["src"].startswith("node_") else set()
        names |= set(NODE_RX.findall(l["msg"]))
        for n in names:
            out.setdefault(n, []).append(l)
    return out


def drift_series(R, windows, fd):
    fleet = _merge([(w["begin"], w["end"]) for w in windows if w.get("targets") is None])
    disk, queue = [], []
    for s in R["snapshots"]:
        if _covered(s["t"], s["t"] + 1, fleet):
            continue
        used = s.get("disk_bytes")
        if used is None and s.get("disk_free") is not None:
            used = DISK_CAPACITY - s["disk_free"]
        if used is not None:
            disk.append((s["t"], used))
        if s.get("pending") is not None:
            queue.append((s["t"], s["pending"]))
    rec = [(e["until"], e["recovery_ms"]) for a in fd["all"].values() for e in a["episodes"] if e["recovery_ms"] is not None]
    return {"disk_used": disk, "lua_memory": [], "queue": queue, "recovery_ms": sorted(rec)}


def _norm(text):
    return re.sub(r"\d+", "N", re.sub(r"^\S+\s+\S+\s+\S+\s+", "", text))[:140]


def _expected_card(expected, texts):
    for x in expected or []:
        rx = re.compile(x["pattern"])
        if any(rx.search(t or "") for t in texts):
            return x["card"]
    return None


def build_report(run_dir, expected=None):
    """Everything write_report prints, as a dict."""
    expected = EXPECTED_ISSUES if expected is None else expected
    R = load_run(run_dir)
    W = run_windows(R)
    end = R["end"]
    tls = timelines(R)
    fd = findings(tls, W, end)
    by_node = _by_node(R["lines"])
    done = jobs_done(R["lines"])
    fstats, fevidence = fault_stats(R)
    hk = housekeeping(R)
    log_gaps = _gaps([l["rt"] for l in R["lines"]], end, LOG_GAP_MS)
    snap_gaps = _gaps([s["t"] for s in R["snapshots"]], end, SNAP_GAP_MS) if R["kind"] == "t2" else []

    # quotes, reasons, expected
    for a in fd["turtles"]:
        a["quotes"] = _why_quotes(by_node, a, end) or _quotes(by_node, a["id"], -10 ** 15, end)
        a["expected"] = _expected_card(expected, a["reasons"] + a["quotes"])

    # hours
    n_hours = max(1, int(math.ceil(end / float(HOUR))))
    hours = []
    onsets = [e["onset"] for a in fd["all"].values() for e in a["episodes"]]
    began = [int(r.get("wall_ms", 0)) for r in (R["fault_lines"] or []) if r.get("phase") == "begin"] if R["kind"] == "t2" else \
        [int(f.get("t_ms") or 0) for f in R["sim_faults"] or []]
    for h in range(n_hours):
        a, b = h * HOUR, min((h + 1) * HOUR, max(end, h * HOUR + 1))
        n_lines = sum(1 for l in R["lines"] if a <= l["rt"] < b)
        n_snaps = sum(1 for s in R["snapshots"] if a <= s["t"] < b)
        why = None
        if n_lines == 0:
            why = "no fleet log line in this hour"
        elif R["kind"] == "t2" and n_snaps == 0:
            why = "no fresh /state snapshot in this hour"
        unseen = _covered(a, b, _merge([tuple(g) for g in log_gaps] + [tuple(g) for g in snap_gaps]))
        row = {"hour": h, "log_lines": n_lines, "snapshots": n_snaps if R["kind"] == "t2" else None, "truncated": why,
               "unseen_ms": unseen}
        for key, vals in (("jobs_done", [d["t"] for d in done if d["type"] not in ("MINE sector done",)]),
                          ("sectors", [d["t"] for d in done if d["type"] == "MINE sector done"]),
                          ("stuck_onsets", onsets), ("jams_begun", [j["start"] for j in fd["jams"]])):
            row[key] = TRUNCATED if why else sum(1 for t in vals if a <= t < b)
        row["faults_fired"] = TRUNCATED if (R["kind"] == "t2" and R["fault_lines"] is None) else sum(1 for t in began if a <= t < b)
        hours.append(row)

    drift = {m: judge_drift(s, end, m) for m, s in drift_series(R, W, fd).items()}
    drift["lua_memory"]["why"] = "no computer publishes its Lua memory in /state: no source, so it cannot be judged (TRUNCATED)"

    # cards
    cards, exp = [], {}
    seed = R["seed"]

    def faults_near(t):
        return ["%s %s" % (w["id"], w["fault"]) for w in W if w["begin"] <= t and w["end"] >= t - 30 * MIN][:8]

    groups = {}
    for a in fd["turtles"]:
        if a["verdict"] not in ("decommissioned", "lost"):
            if a["expected"]:
                exp.setdefault(a["expected"], []).append("%s %s" % (a["id"], a["verdict"]))
            continue
        if a["expected"]:
            exp.setdefault(a["expected"], []).append("%s %s: %s" % (a["id"], a["verdict"], "; ".join(a["reasons"])))
            continue
        key = (a["verdict"], re.sub(r"\d+", "N", (a["reasons"] or ["?"])[0].split(":")[0]), _norm(a["quotes"][0]) if a["quotes"] else "")
        groups.setdefault(key, []).append(a)
    for (verdict, kind, _), members in sorted(groups.items(), key=lambda kv: -len(kv[1])):
        t = min(e["since"] for m in members for e in m["episodes"]) if any(m["episodes"] for m in members) else end
        first = _norm(members[0]["quotes"][0]) if members[0]["quotes"] else "no log line names it"
        cards.append({"title": "%d turtle(s) %s: %s (\"%s\")" % (len(members), verdict, kind, first[:90]),
                      "turtles": [m["id"] for m in members], "why": members[0]["reasons"],
                      "lines": [q for m in members[:3] for q in m["quotes"][:2]], "seed": seed,
                      "schedule": R["schedule_path"], "faults_near": faults_near(t), "at": t})
    for j in fd["jams"]:
        if j["clear"] is None:
            lines = [q for tid in j["members"][:3] for q in fd["all"][tid].get("quotes", _quotes(by_node, tid, j["start"] - 10 * MIN,
                                                                                                    end))[:1]]
            card = _expected_card(expected, lines)
            if card:
                exp.setdefault(card, []).append("uncleared jam from run %s (%d turtles)" % (_hm(j["start"]), j["peak"]))
                continue
            cards.append({"title": "Jam in the base never cleared (%d turtles at peak)" % j["peak"], "turtles": j["members"],
                          "why": ["a jam from run %s, still %d or more stuck at the end" % (_hm(j["start"]), JAM_COUNT)],
                          "lines": lines, "seed": seed, "schedule": R["schedule_path"], "faults_near": faults_near(j["start"]),
                          "at": j["start"]})
    for m, d in drift.items():
        if d["verdict"] == "FAIL":
            cards.append({"title": "Drift: %s grows steadily over the run" % m, "turtles": [], "why": [d["why"]], "lines": [],
                          "seed": seed, "schedule": R["schedule_path"], "faults_near": [], "at": None})
    for line in (hk or {}).get("low", []):
        card = _expected_card(expected, [line])
        if card:
            exp.setdefault(card, []).append(line)
        else:
            cards.append({"title": "Storage headroom low outside a scheduled storage fault", "turtles": [], "why": [line],
                          "lines": [line], "seed": seed, "schedule": R["schedule_path"], "faults_near": [], "at": None})
    for r in (R["fault_lines"] or []):
        if r.get("phase") == "fail":
            cards.append({"title": "Harness: fault %s %s never began" % (r.get("id"), r.get("fault")), "turtles": [],
                          "why": [str(r.get("error"))[:200]], "lines": [], "seed": seed, "schedule": R["schedule_path"],
                          "faults_near": [], "at": r.get("wall_ms")})

    stuck_end = sum(1 for a in fd["all"].values() if any(e["open"] for e in a["episodes"]))
    gone_end = sum(1 for a in fd["all"].values() if (a["gone"]["silent_ms"] or 0) > GONE_MS)
    hands_end = sum(1 for a in fd["all"].values() if a["needs_hands"] and a["verdict"] != "expected_hands")
    not_recovered = sorted((a["id"] for a in fd["all"].values() if a["verdict"] in ("decommissioned", "lost")), key=_node_key)
    unknown_where = sum(1 for a in fd["all"].values() if a["verdict"] == "decommissioned" and a.get("present") is None)
    removals = [w for w in W if w["fault"] == "remove_item"]
    # a turtle whose job failed: the failure lines name the job, so the job is traced to the turtle it was last given to
    # ... then judged on what it did next: home (on its dock in a later sample) AND a later job (accepted or dispatched to it)
    failed_job, fail_lines, holder, given, last_fail = {}, 0, {}, {}, {}
    for l in R["lines"]:
        if l["src"] != "server":
            continue
        m = ACCEPT_RX.match(l["msg"]) or DISPATCH_RX.match(l["msg"])
        if m:
            holder[m.group(1)] = m.group(2)
            given.setdefault(m.group(2), []).append(l["rt"])
            continue
        m = JOB_FAIL_RX.match(l["msg"])
        if m:
            fail_lines += 1
            tid = holder.get(m.group(1) or m.group(2))
            if tid in fd["all"]:
                last_fail[tid] = l["rt"]
    for tid, tf in last_fail.items():
        home = any(s.get("on_dock") and s["t"] > tf for s in tls[tid]["samples"]) if tid in tls else False
        again = any(t > tf for t in given.get(tid, []))
        if home and again:
            how = "home and back to work"
        elif end - tf < 30 * MIN:
            how = "too late to judge (failed %d min before the end)" % ((end - tf) // MIN)
        else:
            how = "never home" if not home else "home, but no later job"
        failed_job[tid] = {"verdict": fd["all"][tid]["verdict"], "failed_at": tf, "how": how}
    return {
        "run": run_dir, "kind": R["kind"], "t0_epoch_ms": R["t0"], "end_ms": end, "seed": seed, "schedule": R["schedule_path"],
        "notes": R["notes"], "windows": [dict(w, targets=sorted(w["targets"]) if w["targets"] is not None else None) for w in W],
        "verdicts": {tid: a["verdict"] for tid, a in fd["all"].items()}, "counts": fd["counts"], "stuck_ever": fd["stuck_ever"],
        "stuck_at_end": stuck_end, "gone_at_end": gone_end, "hands_at_end": hands_end, "not_recovered": not_recovered,
        "findability_unknown": unknown_where, "remove_item_windows": len(removals), "failed_job": failed_job, "failed_job_lines": fail_lines,
        "turtles": fd["turtles"], "jams": fd["jams"], "jam_evidence": fd["jam_evidence"], "jobs": done,
        "long_sites": [dict(s, jobs=sorted(s["jobs"])) for s in long_sites(R)] if R["kind"] == "t2" else None,
        "faults": fstats, "fault_evidence": fevidence, "housekeeping": hk, "hours": hours, "drift": drift,
        "log_gaps": [{"from": a, "to": b} for a, b in log_gaps], "snap_gaps": [{"from": a, "to": b} for a, b in snap_gaps],
        "cards": cards, "expected": exp,
        "evidence": {"log_lines": len(R["lines"]), "unparsed_lines": R["unparsed"], "snapshots": len(R["snapshots"]),
                     "stale_snapshots": R["stale"], "turtles": len(fd["all"]), "loaders": fd["loaders"], "fault_lines": fevidence,
                     "windows": len(W)},
    }


# ---------------------------------------------------------------------------------------------------------------------------
# report.md
# ---------------------------------------------------------------------------------------------------------------------------


def _cell(v):
    return TRUNCATED if v == TRUNCATED else ("" if v is None else str(v))


def _render(rep):
    ev = rep["evidence"]
    c = rep["counts"]
    o = ["# Shakeout report", "",
         "- Run folder: %s (%s)" % (rep["run"], "T2" if rep["kind"] == "t2" else "SIMULATOR"),
         "- Length: %.2f h on the run's clock; seed %s; schedule %s" % (rep["end_ms"] / float(HOUR), rep["seed"], rep["schedule"]),
         "- Evidence: %d fleet log lines (%d unparsed), %d fresh /state snapshots (%d stale), %d fault-log lines, %d fault windows, "
         "%d turtles judged" % (ev["log_lines"], ev["unparsed_lines"], ev["snapshots"], ev["stale_snapshots"], ev["fault_lines"],
                                ev["windows"], ev["turtles"]), ""]
    if ev.get("loaders"):
        o.append("- Not judged: %d chunk loader(s), which hover over their miner's sector by design: %s"
                 % (len(ev["loaders"]), ", ".join(ev["loaders"])))
    for n in rep["notes"]:
        o.append("- TRUNCATED: " + n)
    judged = ev["turtles"]
    o += ["", "## Pass bar", "",
          "Every count is of %d turtles judged (evidence: %d snapshots, %d log lines)." % (judged, ev["snapshots"], ev["log_lines"]),
          "",
          "- No turtle lost: **%d lost**%s" % (c["lost"], " (%d decommissioned with findability unknown -- TRUNCATED: no "
                                                "final.json, chunk not loaded, or a simulator run)" % rep["findability_unknown"]
                                                if rep["findability_unknown"] else ""),
          "- Everything recovered: **%d turtle(s) not recovered** (each counted once; of them %d stuck at the end, %d gone at the "
          "end, %d NEEDS HANDS never cleared -- one turtle can be several); and **%d jam(s) never cleared**"
          % (len(rep["not_recovered"]), rep["stuck_at_end"], rep["gone_at_end"], rep["hands_at_end"],
             sum(1 for j in rep["jams"] if j["clear"] is None)),
          "- A turtle that fails a job gets itself home and back to work: **%d of %d** judged did NOT (on its dock after the "
          "failure AND given a later job); %d too late to judge (evidence: %d failed/retried job lines, traced to %d turtles)%s" % (
              sum(1 for v in rep["failed_job"].values() if not v["how"].startswith(("home and back", "too late"))),
              sum(1 for v in rep["failed_job"].values() if not v["how"].startswith("too late")),
              sum(1 for v in rep["failed_job"].values() if v["how"].startswith("too late")),
              rep["failed_job_lines"], len(rep["failed_job"]),
              "" if rep["failed_job"] else " -- TRUNCATED: no failed job traced to a turtle, so this item has no evidence"),
          "- No turtle decommissioned: **%d decommissioned** (and %d expected hands, counted apart)" % (c["decommissioned"],
                                                                                                       c["expected_hands"]),
          "- Verdicts: %s; stuck at least once: %d" % (", ".join("%s %d" % (k, c[k]) for k in VERDICTS), rep["stuck_ever"])]
    if judged == 0:
        o.append("- TRUNCATED: no turtle could be judged, so none of the counts above is evidence")

    o += ["", "## Stuck or failed turtles", "",
          "%d turtle(s) not ok, of %d judged (rule: off its dock with no progress for over %d real min outside its faults)."
          % (len([a for a in rep["turtles"] if not a.get("expected")]), judged, STUCK_MS // MIN), ""]
    for a in rep["turtles"]:
        if a.get("expected"):
            continue
        eps = "; ".join("stuck from %s (stopped %s) %s%s" % (
            _hm(e["onset"]), _hm(e["since"]), "until %s, recovered in %d min from %s" % (
                _hm(e["until"]), e["recovery_ms"] // MIN, _hm(e["recovery_from"])) if not e["open"] else "to the END",
            ((", faults " + ",".join(e["faults"])) if e["faults"] else "") +
            ((", later faults (not its cause) " + ",".join(e["later_faults"])) if e.get("later_faults") else ""))
            for e in a["episodes"])
        sil = "; ".join("silent %d min from %s" % (s["silent_ms"] // MIN, _hm(s["since"])) for s in a["silences"])
        o.append("- **%s** %s at %s: %s" % (a["id"], a["verdict"], (a["episodes"][-1]["pos"] if a["episodes"] else "?"),
                                          "; ".join(x for x in (eps, sil, "; ".join(a["reasons"])) if x) or "-"))
        for q in a.get("quotes") or []:
            o.append("    `%s`" % q.replace("`", "'"))
        if not a.get("quotes"):
            o.append("    (no log line names it: the why is TRUNCATED, not guessed)")

    o += ["", "## Jams", "",
          "%d jam(s), %d never cleared (rule: %d or more stuck at once inside world.BASE_AREAS; evidence: %d stuck episodes in the "
          "base)." % (len(rep["jams"]), sum(1 for j in rep["jams"] if j["clear"] is None), JAM_COUNT, rep["jam_evidence"]),
          "Detector control: %s -- %s: %s jam(s), %s uncleared, %s stuck turtles." % (
              JAM_CONTROL["run"], JAM_CONTROL["what"], JAM_CONTROL["jams"], JAM_CONTROL["uncleared"],
              JAM_CONTROL["stuck_turtles"]), ""]
    for j in rep["jams"]:
        o.append("- from run %s, %s, peak %d: %s" % (
            _hm(j["start"]), "cleared at %s after %d min" % (_hm(j["clear"]), j["duration_ms"] // MIN) if j["clear"] is not None
            else "**NEVER CLEARED** (%d min to the end)" % (j["duration_ms"] // MIN), j["peak"], " ".join(j["members"][:20]) +
            (" ..." if len(j["members"]) > 20 else "")))

    o += ["", "## Jobs completed by type", ""]
    by = {}
    for d in rep["jobs"]:
        by[d["type"]] = by.get(d["type"], 0) + 1
    o.append("Evidence: %d fleet log lines%s." % (ev["log_lines"], "; %d log gap(s) TRUNCATED, see the last section" %
                                                    len(rep["log_gaps"]) if rep["log_gaps"] else ""))
    o += ["", "| type | completed |", "|---|---|"] + ["| %s | %d |" % (k, v) for k, v in sorted(by.items())]
    if not by:
        o.append("| (none) | %s |" % ("0" if ev["log_lines"] else TRUNCATED))
    if rep["long_sites"] is not None:
        o += ["", "Long-running sites (feeder.LONG_SITES lanes, from /state jobs' zoneKey):", "",
              "| site | jobs | open h | snapshots |", "|---|---|---|---|"]
        for s in rep["long_sites"]:
            o.append("| %s | %d | %.1f | %d |" % (s["site"], len(s["jobs"]), s["open_ms"] / float(HOUR), s["snapshots"]))

    o += ["", "## Faults fired by type", "", "Evidence: %d fault-log lines." % rep["fault_evidence"], "",
          "| fault | planned | begun | failed | undone | ended | latest begin (s late) |", "|---|---|---|---|---|---|---|"]
    for f, r in sorted(rep["faults"].items(), key=lambda kv: str(kv[0])):
        o.append("| %s | %s | %s | %s | %s | %s | %s |" % (f, r.get("planned", ""), r.get("begin", ""), r.get("fail", ""),
                                                          r.get("undo", ""), r.get("end", ""),
                                                          r["late_max_ms"] if r.get("late_max_ms") == TRUNCATED else
                                                          (r.get("late_max_ms") or 0) // 1000))
    if not rep["faults"]:
        o.append("| (none fired) | | | | | | |")

    o += ["", "## Decommissioned turtles and why", ""]
    dec = [a for a in rep["turtles"] if a["verdict"] in ("decommissioned", "lost")]
    o.append("%d decommissioned, %d lost, of %d judged." % (rep["counts"]["decommissioned"], rep["counts"]["lost"], judged))
    for a in dec:
        pres = {True: "a turtle is there", False: "NOT there", None: "findability not checked or chunk not loaded: unknown"}[
            a.get("present")]
        o.append("- **%s** %s: %s (%s)%s" % (a["id"], a["verdict"], "; ".join(a["reasons"]), pres,
                                            " [EXPECTED: %s]" % a["expected"] if a.get("expected") else ""))
        o += ["    `%s`" % q.replace("`", "'") for q in (a.get("quotes") or [])[:2]]

    o += ["", "## Expected hands", ""]
    eh = [a for a in rep["turtles"] if a["verdict"] == "expected_hands"]
    o.append("%d turtle(s): an item was taken by a remove_item fault and it asked for hands (counted apart from decommissioned). "
             "Evidence: %d remove_item fault window(s), %d turtles judged." % (len(eh), rep["remove_item_windows"], judged))
    for a in eh:
        o.append("- %s: %s (faults %s)" % (a["id"], a["needs_hands"], ",".join(a["touching"])))

    o += ["", "## First 6 h against last 6 h", ""]
    hrs = rep["hours"]
    if len(hrs) > 12:
        shown = hrs[:6] + hrs[-6:]
    else:
        shown = hrs
        o.append("The run is %.1f h: no separate first and last 6 h, every hour shown." % (rep["end_ms"] / float(HOUR)))
    o += ["", "| hour | log lines | snapshots | jobs done | sectors | stuck onsets | jams begun | faults fired | unseen min | note |",
          "|---|---|---|---|---|---|---|---|---|---|"]
    for h in shown:
        o.append("| %d | %d | %s | %s | %s | %s | %s | %s | %d | %s |" % (
            h["hour"], h["log_lines"], "n/a" if h["snapshots"] is None else h["snapshots"], _cell(h["jobs_done"]),
            _cell(h["sectors"]), _cell(h["stuck_onsets"]), _cell(h["jams_begun"]), _cell(h["faults_fired"]), h["unseen_ms"] // MIN,
            ("TRUNCATED: " + h["truncated"]) if h["truncated"] else ("partial" if h["unseen_ms"] else "")))
    if len(hrs) > 12:
        for name, part in (("first 6 h", hrs[:6]), ("last 6 h", hrs[-6:])):
            tr = sum(1 for h in part if h["truncated"])
            onset = sum(h["stuck_onsets"] for h in part if h["stuck_onsets"] != TRUNCATED)
            fired = sum(h["faults_fired"] for h in part if h["faults_fired"] != TRUNCATED)
            o.append("- %s: %d stuck onsets for %d faults fired (%.2f per fault)%s" % (
                name, onset, fired, onset / float(fired) if fired else 0.0,
                "; %d hour(s) TRUNCATED, so these are lower bounds" % tr if tr else ""))
    o += ["", "Judged (fails if it grows steadily):", ""]
    for m, d in rep["drift"].items():
        o.append("- %s: **%s** (evidence: %d samples) -- %s" % (m, d["verdict"], d["evidence"], d.get("why", "")))

    o += ["", "## Housekeeping", ""]
    hk = rep["housekeeping"]
    if hk is None:
        o.append("n/a (simulator run)")
    elif hk["missing"]:
        o.append("TRUNCATED: no shakeout/housekeeping.log, so storage headroom is unknown for the whole run")
    else:
        o.append("%d HOUSEKEEPING lines: %s. %d storage-headroom-low (a FINDING unless inside a scheduled storage fault); %d "
                 "unknown readings (TRUNCATED)." % (hk["lines"], ", ".join("%s %d" % kv for kv in sorted(hk["tags"].items())),
                                                    len(hk["low"]), hk["unknown"]))
        o += ["    `%s`" % l for l in hk["low"][:5]]

    o += ["", "## EXPECTED (board cards open at run time)", ""]
    if not rep["expected"]:
        o.append("None matched.")
    for card, items in sorted(rep["expected"].items()):
        o.append("- %s: %d match(es)" % (card, len(items)))
        o += ["    - %s" % i for i in items[:5]]

    o += ["", "## Draft board cards", "", "%d card(s), each with its replay seed and schedule." % len(rep["cards"]), ""]
    for cd in rep["cards"]:
        o += ["### %s" % cd["title"], "",
              "- Replay: seed %s, schedule %s%s" % (cd["seed"], cd["schedule"],
                                                    ("; at run %s" % _hm(cd["at"])) if cd["at"] is not None else ""),
              "- Faults within 30 min before: %s" % (", ".join(cd["faults_near"]) or "none"),
              "- Why: %s" % "; ".join(cd["why"])]
        if cd["turtles"]:
            o.append("- Turtles (%d): %s%s" % (len(cd["turtles"]), " ".join(cd["turtles"][:30]),
                                               " ..." if len(cd["turtles"]) > 30 else ""))
        o += ["    `%s`" % q.replace("`", "'") for q in cd["lines"][:6]]
        o.append("")

    o += ["", "## Evidence and gaps", ""]
    o.append("%d fleet-log gap(s) over %d min, %d /state gap(s) over %d min: every count over a gap is TRUNCATED (a lower bound), "
             "never zero; the stuck and gone clocks do not run over a /state gap." % (
                 len(rep["log_gaps"]), LOG_GAP_MS // MIN, len(rep["snap_gaps"]), SNAP_GAP_MS // MIN))
    for g in rep["log_gaps"][:40]:
        o.append("- TRUNCATED fleet log: run %s to %s" % (_hm(g["from"]), _hm(g["to"])))
    for g in rep["snap_gaps"][:40]:
        o.append("- TRUNCATED /state: run %s to %s" % (_hm(g["from"]), _hm(g["to"])))
    return "\n".join(o) + "\n"


def write_report(run_dir, expected=None, out=None):
    """Writes report.md and report.json to `out` (default <run>/shakeout/); returns report.md's path."""
    rep = build_report(run_dir, expected=EXPECTED_ISSUES if expected is None else expected)
    out = out or os.path.join(run_dir, "shakeout")
    os.makedirs(out, exist_ok=True)
    path = os.path.join(out, "report.md")
    with open(path, "w", encoding="utf8", newline="\n") as f:
        f.write(_render(rep))
    with open(os.path.join(out, "report.json"), "w", encoding="utf8", newline="\n") as f:
        json.dump(rep, f, indent=1, default=lambda v: sorted(v) if isinstance(v, set) else repr(v))
    return path


if __name__ == "__main__":
    ap = argparse.ArgumentParser(description="the shakeout report of a run folder (T2 or simulator)")
    ap.add_argument("run_dir")
    ap.add_argument("--out", help="where report.md and report.json go (default <run>/shakeout)")
    a = ap.parse_args()
    print(write_report(a.run_dir, out=a.out))
