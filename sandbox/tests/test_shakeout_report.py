"""Shakeout Task 7: the report (sandbox/t2/shakeout/report.py). Timelines, fault windows and run folders are all built here; nothing
touches a real run.

    python -I sandbox/tests/test_shakeout_report.py
"""
import calendar
import json
import os
import random
import shutil
import sys
import tempfile
import time
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "t2"))
from shakeout import report  # noqa: E402

MIN = 60000
HOUR = 60 * MIN
DOCK = (157, 67, -2806)
OFF = (190, 67, -2800)          # off the dock, inside the base box (world.BASE_AREAS)
T0 = calendar.timegm((2026, 11, 10, 0, 0, 0)) * 1000


def timeline(points, tid="node_5", end=None, dock=DOCK, heard=None):
    """points: [(t_ms, pos, phase)]; a sample every point, each a heartbeat."""
    samples = [{"t": t, "pos": list(p), "phase": ph, "on_dock": tuple(p) == dock, "seen": t, "needs_hands": None}
               for t, p, ph in points]
    return {"id": tid, "samples": samples, "end": end if end is not None else points[-1][0], "heard": heard or [],
            "heard_complete": True, "gaps": []}


def sitting(t_from, t_to, pos=OFF, every=MIN, phase="IN_PROGRESS/TRAVELLING"):
    return [(t, pos, phase) for t in range(t_from, t_to + 1, every)]


def window(fid, fault, begin, end, targets=None):
    return {"id": fid, "fault": fault, "begin": begin, "end": end, "targets": targets}


class StuckVsActiveFault(unittest.TestCase):
    def test_stuck_vs_active_fault(self):
        fault = [window("f001", "radio_loss", 0, 20 * MIN)]
        # off the dock, no progress, for 15 minutes INSIDE the window, then home
        inside = timeline(sitting(0, 15 * MIN) + [(16 * MIN, DOCK, "IDLE/")])
        self.assertEqual(report.classify(inside, fault), "ok")
        # the control: the same 15 minutes with no fault active IS stuck (the check can fail)
        self.assertEqual(report.classify(inside, []), "stuck_recovered")
        # 15 minutes still AFTER the window has closed: stuck
        after = timeline(sitting(20 * MIN, 35 * MIN) + [(36 * MIN, DOCK, "IDLE/")])
        self.assertEqual(report.classify(after, fault), "stuck_recovered")
        # one sitting through the window and 15 minutes past it: the clock starts when the window closes
        a = report.analyse(timeline(sitting(0, 35 * MIN) + [(36 * MIN, DOCK, "IDLE/")]), fault)
        self.assertEqual(len(a["episodes"]), 1)
        self.assertEqual(a["episodes"][0]["onset"], 30 * MIN)
        # a schedule entry (planned window: t_ms .. t_ms + dur_ms + quiet_ms) is taken as well as a measured window
        entries = [{"id": "f001", "t_ms": 0, "fault": "radio_loss", "args": {"dur_ms": 20 * MIN}, "quiet_ms": 0}]
        self.assertEqual(report.classify(inside, entries), "ok")
        # stuck at the end of the run (no progress ever again): decommissioned
        self.assertEqual(report.classify(timeline(sitting(20 * MIN, 50 * MIN)), fault), "decommissioned")

    def test_a_fault_aimed_at_another_turtle_excuses_nothing(self):
        other = [window("f002", "low_fuel", 0, 20 * MIN, targets={"node_9"})]
        t = timeline(sitting(0, 15 * MIN) + [(16 * MIN, DOCK, "IDLE/")])
        self.assertEqual(report.classify(t, other), "stuck_recovered")
        mine = [window("f002", "chunk_unload", 0, 20 * MIN, targets={"node_5"})]
        self.assertEqual(report.classify(t, mine), "ok")

    def test_gone_outside_a_fault_is_decommissioned(self):
        t = timeline([(0, OFF, "x")], end=40 * MIN)
        t["samples"][0]["seen"] = 0
        self.assertEqual(report.analyse(t, [])["gone"]["silent_ms"], 40 * MIN)
        self.assertEqual(report.classify(t, []), "decommissioned")
        # the same silence inside a bridge-down window (and 9 minutes after it) is not gone
        self.assertEqual(report.analyse(t, [window("f1", "bridge_down", 0, 31 * MIN)])["gone"]["silent_ms"], 9 * MIN)
        self.assertEqual(report.classify(t, [window("f1", "bridge_down", 0, 31 * MIN)]), "ok")


class TwoFaultsOneCount(unittest.TestCase):
    def test_two_faults_one_count(self):
        hits = [window("f010", "turtle_reboot", 0, 0, targets={"node_5"}),
                window("f011", "low_fuel", 4 * MIN, 4 * MIN, targets={"node_5"}),
                window("f012", "put_back_turned", 5 * MIN, 5 * MIN, targets={"node_9"})]   # someone else's
        t = timeline(sitting(0, 30 * MIN) + [(31 * MIN, DOCK, "IDLE/")])
        a = report.analyse(t, hits)
        self.assertEqual(a["verdict"], "stuck_recovered")
        self.assertEqual(len(a["episodes"]), 1, "two faults in one window are ONE finding")
        ep = a["episodes"][0]
        self.assertEqual(ep["faults"], ["f010", "f011"])
        self.assertEqual(ep["recovery_from"], 4 * MIN, "recovery is measured from the LAST fault that touched it")
        self.assertEqual(ep["recovery_ms"], 27 * MIN)
        # and the report's findings list carries it once
        found = report.findings({"node_5": t}, hits, 31 * MIN)
        self.assertEqual([f["id"] for f in found["turtles"]], ["node_5"])
        self.assertEqual(found["counts"]["stuck_recovered"], 1)


class FixRound1(unittest.TestCase):
    def test_a_fault_mid_episode_does_not_shorten_recovery(self):
        # stuck from 0 to 120 min; an unrelated fleet-wide radio_loss fires at 100: recovery is 121 min, not 21
        t = timeline(sitting(0, 120 * MIN) + [(121 * MIN, DOCK, "IDLE/")])
        a = report.analyse(t, [window("f009", "radio_loss", 100 * MIN, 105 * MIN)])
        self.assertEqual(len(a["episodes"]), 1)
        ep = a["episodes"][0]
        self.assertEqual(ep["recovery_from"], 0)
        self.assertEqual(ep["recovery_ms"], 121 * MIN)
        self.assertEqual(ep["faults"], [])
        self.assertEqual(ep["later_faults"], ["f009"])

    def test_window_end_is_start_plus_quiet_not_end_plus_quiet(self):
        e = {"id": "f001", "t_ms": 0, "fault": "server_crash", "args": {"down_ms": 5 * MIN}, "quiet_ms": 8 * MIN}
        lines = [{"wall_ms": 1000, "id": "f001", "fault": "server_crash", "phase": "start"},
                 {"wall_ms": 2000, "id": "f001", "fault": "server_crash", "phase": "begin", "detail": {}},
                 {"wall_ms": 5 * MIN + 2000, "id": "f001", "fault": "server_crash", "phase": "end"}]
        w = report.windows_from([e], lines, 60 * MIN)[0]
        self.assertEqual((w["begin"], w["end"]), (1000, 1000 + 8 * MIN))
        late = lines[:2] + [dict(lines[2], wall_ms=20 * MIN)]          # an end that came late is the end
        self.assertEqual(report.windows_from([e], late, 60 * MIN)[0]["end"], 20 * MIN)
        self.assertEqual(report.windows_from([e])[0]["end"], 8 * MIN, "planned: t_ms + max(dur, quiet_ms)")

    def test_a_self_ending_fault_closes_at_its_duration_not_at_the_run_end(self):
        # shakeout-side-a: radio_loss logs start and begin, never end (the control mod ends it by itself); its window ran to the
        # run's end, and from minute 40 of 180 nothing any turtle did was judged
        e = {"id": "s002", "t_ms": 40 * MIN, "fault": "radio_loss", "args": {"dur_ms": 4 * MIN, "rate": 0.5}, "quiet_ms": 0}
        lines = [{"wall_ms": 40 * MIN, "id": "s002", "fault": "radio_loss", "phase": "start"},
                 {"wall_ms": 40 * MIN + 500, "id": "s002", "fault": "radio_loss", "phase": "begin", "detail": {}}]
        w = report.windows_from([e], lines, 180 * MIN)[0]
        self.assertEqual((w["begin"], w["end"]), (40 * MIN, 44 * MIN))
        # a fault with an end verb that never logged its end still holds its window to the run's end (it may be still on)
        g = {"id": "s003", "t_ms": 0, "fault": "gps_down", "args": {"dur_ms": 4 * MIN, "count": 1, "pick": 0}, "quiet_ms": 0}
        gl = [dict(l, id="s003", fault="gps_down", wall_ms=l["wall_ms"] - 40 * MIN) for l in lines]
        self.assertEqual(report.windows_from([g], gl, 180 * MIN)[0]["end"], 180 * MIN)

    def test_self_ending_is_exactly_the_faults_with_a_duration_and_no_end_verb(self):
        from shakeout import schedule
        rng = schedule._Rng(1)
        want = {f for f, fa in schedule.APPLY.items() if fa.end is None and f not in ("restart_burst5",)
                and int((schedule._args(f, rng) or {}).get("dur_ms") or 0) > 0}
        self.assertEqual(set(report.SELF_ENDING), want)

    def test_a_turtle_stuck_after_a_radio_burst_is_still_judged(self):
        t = timeline(sitting(60 * MIN, 180 * MIN))
        e = {"id": "s002", "t_ms": 40 * MIN, "fault": "radio_loss", "args": {"dur_ms": 4 * MIN, "rate": 0.5}, "quiet_ms": 0}
        lines = [{"wall_ms": 40 * MIN, "id": "s002", "fault": "radio_loss", "phase": "start"},
                 {"wall_ms": 40 * MIN, "id": "s002", "fault": "radio_loss", "phase": "begin", "detail": {}}]
        a = report.analyse(t, report.windows_from([e], lines, 180 * MIN), end_ms=180 * MIN)
        self.assertEqual(a["verdict"], "decommissioned", a["reasons"])

    def test_a_hovering_loader_is_listed_not_judged(self):
        tls = {"loader_224": dict(timeline(sitting(0, 120 * MIN, pos=(552, 185, -2359)), tid="loader_224"), role="LOADER"),
               "node_5": timeline(sitting(0, 120 * MIN))}
        fd = report.findings(tls, [], 120 * MIN)
        self.assertEqual(sorted(fd["all"]), ["node_5"])
        self.assertEqual(fd["loaders"], ["loader_224"])
        self.assertEqual(fd["all"]["node_5"]["verdict"], "decommissioned", "the same stillness in a turtle is still judged")

    def test_excused_share_of_a_day_stays_under_37_percent(self):
        from shakeout import schedule
        for seed in (1, 2, 3):
            w = report.windows_from(schedule.make_schedule(seed, 24, schedule.DEFAULT_RATES))
            fleet = report._merge([(x["begin"], x["end"]) for x in w if x["targets"] is None])
            share = report._covered(0, 24 * HOUR, fleet) / float(24 * HOUR)
            self.assertLessEqual(share, 0.37, (seed, share))
            self.assertGreater(share, 0.2, (seed, share))      # the windows are there at all

    def test_needs_hands_quotes_the_raise_and_lost_line_says_unknown(self):
        hands = lambda t: {"node_8": {"x": 171, "y": 67, "z": -2810, "status": "IDLE", "phase": "DOCKED", "dockX": 171,  # noqa: E731
                                      "dockZ": -2810, "lastSeen": T0 + t - 1000, "online": True, "role": "MINER",
                                      "needsHands": "stuck_no_fix: facing unknown" if t >= 30 * MIN else None}}
        extra = [(30 * MIN, "server", "ERROR", "NEEDS HANDS: node_8 — stuck_no_fix: facing unknown at 171,67,-2810. It carries on")]
        extra += [(m * MIN, "node_8", "INFO", "[node_8][INFO] loop baseline: healthy") for m in range(35, 120, 7)]
        run = make_run(hours=2, extra_lines=extra, turtles_at=hands)
        try:
            rep = report.build_report(run)
            a = next(x for x in rep["turtles"] if x["id"] == "node_8")
            self.assertEqual(a["verdict"], "decommissioned")
            self.assertTrue(any("NEEDS HANDS: node_8" in q for q in a["quotes"]), a["quotes"])
            with open(report.write_report(run), encoding="utf8") as f:
                md = f.read()
            lost = next(l for l in md.splitlines() if l.startswith("- No turtle lost"))
            self.assertIn("1 decommissioned with findability unknown", lost)
            self.assertIn("TRUNCATED", lost)
        finally:
            shutil.rmtree(run, ignore_errors=True)
        run = make_run(hours=2, extra_lines=extra, turtles_at=hands, final={"node_8": {"present": True}})
        try:
            with open(report.write_report(run), encoding="utf8") as f:
                lost = next(l for l in f.read().splitlines() if l.startswith("- No turtle lost"))
            self.assertNotIn("TRUNCATED", lost)
        finally:
            shutil.rmtree(run, ignore_errors=True)

    def test_reason_lines_come_first_within_the_cap(self):
        # final review: three stuck episodes (two context lines each) used to fill the five quotes before the NEEDS HANDS line
        def line(t, src, level, msg):
            return {"rt": t, "src": src, "level": level, "msg": msg, "raw": "%d %s %s %s" % (t, src, level, msg)}
        ls = []
        for k in range(3):
            base = (10 + 30 * k) * MIN
            ls += [line(base - MIN, "node_8", "WARN", "episode %d warn a" % k), line(base, "node_8", "WARN", "episode %d warn b" % k)]
        ls.append(line(100 * MIN, "server", "ERROR", "NEEDS HANDS: node_8 stuck_no_fix: facing unknown"))
        ls.append(line(110 * MIN, "node_8", "INFO", "last own line before silence"))
        a = {"id": "node_8", "episodes": [{"since": (10 + 30 * k) * MIN, "until": (12 + 30 * k) * MIN} for k in range(3)],
             "needs_hands_raised": 100 * MIN, "needs_hands": "stuck_no_fix", "silences": [],
             "gone": {"silent_ms": 3 * HOUR, "since": 110 * MIN}}
        q = report._why_quotes({"node_8": ls}, a, 4 * HOUR)
        self.assertEqual(len(q), 5)
        self.assertTrue(any("NEEDS HANDS: node_8" in x for x in q), q)
        self.assertTrue(any("last own line before silence" in x for x in q), q)
        self.assertIn("NEEDS HANDS", q[0], "the reason's own line is first")

    def test_missing_faults_file_is_truncated_not_zero(self):
        e = {"id": "f001", "t_ms": 0, "fault": "radio_loss", "args": {"dur_ms": MIN}, "quiet_ms": 0}
        run = make_run(hours=1, faults_file=False, entries=[e])
        try:
            rep = report.build_report(run)
            self.assertEqual(rep["faults"]["radio_loss"]["planned"], 1)
            self.assertEqual(rep["faults"]["radio_loss"]["begin"], report.TRUNCATED)
            with open(report.write_report(run), encoding="utf8") as f:
                row = next(l for l in f.read().splitlines() if l.startswith("| radio_loss |"))
            self.assertIn("TRUNCATED", row)
            self.assertTrue(all(h["faults_fired"] == report.TRUNCATED for h in rep["hours"]))
        finally:
            shutil.rmtree(run, ignore_errors=True)

    def test_not_recovered_counts_turtles_once_and_failed_job_needs_home_and_work(self):
        def ts(t):
            return {
                # node_9: failed at 20, home from 25, a new job at 40 -> home and back to work
                "node_9": {"x": 185, "y": 67, "z": -2806, "status": "IDLE", "dockX": 185, "dockZ": -2806, "lastSeen": T0 + t,
                           "online": True} if t >= 25 * MIN else
                          {"x": 100 + t // MIN, "y": 67, "z": -2700, "status": "BUSY", "dockX": 185, "dockZ": -2806,
                           "lastSeen": T0 + t, "online": True},
                # node_10: failed at 20, wanders (never stuck), never home
                "node_10": {"x": 300 + t // MIN, "y": 70, "z": -2600, "status": "BUSY", "dockX": 199, "dockZ": -2806,
                            "lastSeen": T0 + t, "online": True},
                # node_12: failed at 20, home from 25, never given work again -> not "back to work"
                "node_12": {"x": 227, "y": 67, "z": -2806, "status": "IDLE", "dockX": 227, "dockZ": -2806, "lastSeen": T0 + t,
                            "online": True} if t >= 25 * MIN else
                           {"x": 400 + t // MIN, "y": 67, "z": -2700, "status": "BUSY", "dockX": 227, "dockZ": -2806,
                            "lastSeen": T0 + t, "online": True},
                # node_11: stuck, silent AND needs hands at the end: one turtle, counted once
                "node_11": {"x": 900, "y": 20, "z": -2900, "status": "ERROR", "dockX": 213, "dockZ": -2806, "lastSeen": T0,
                            "online": False, "needsHands": "stuck_no_fix"},
            }
        extra = [(10 * MIN, "server", "INFO", "Dispatched job_0101 [DELIVER] -> node_9"),
                 (10 * MIN, "server", "INFO", "Dispatched job_0103 [DELIVER] -> node_10"),
                 (20 * MIN, "server", "WARN", "Job permanently failed: job_0101 (departure_failed)"),
                 (20 * MIN, "server", "WARN", "Job permanently failed: job_0103 (departure_failed)"),
                 (11 * MIN, "server", "INFO", "Dispatched job_0104 [DELIVER] -> node_12"),
                 (20 * MIN, "server", "WARN", "Job permanently failed: job_0104 (departure_failed)"),
                 (40 * MIN, "server", "INFO", "Job job_0102 accepted by node_9")]
        run = make_run(hours=2, extra_lines=extra, turtles_at=ts)
        try:
            rep = report.build_report(run)
            self.assertEqual(rep["failed_job"]["node_9"]["how"], "home and back to work")
            self.assertEqual(rep["failed_job"]["node_10"]["how"], "never home")
            self.assertEqual(rep["failed_job"]["node_12"]["how"], "home, but no later job")
            self.assertEqual(rep["not_recovered"], ["node_11"])
            with open(report.write_report(run), encoding="utf8") as f:
                md = f.read()
            self.assertIn("**1 turtle(s) not recovered**", md)
            self.assertIn("**0 jam(s) never cleared**", md)
            self.assertIn("**2 of 3** judged did NOT", md)
            self.assertIn("Evidence: 0 remove_item fault window(s)", md)
        finally:
            shutil.rmtree(run, ignore_errors=True)


class GrowthFailsFlatPasses(unittest.TestCase):
    def series(self, f, hours=24, every=10 * MIN, seed=7):
        rng = random.Random(seed)
        return [(t, f(t, rng)) for t in range(0, hours * HOUR, every)]

    def test_growth_fails_flat_passes(self):
        grow = self.series(lambda t, r: 200000 + 8000 * t / HOUR + r.uniform(-3000, 3000))
        flat = self.series(lambda t, r: 300000 + r.uniform(-5000, 5000))
        g = report.judge_drift(grow, 24 * HOUR, "disk_used")
        f = report.judge_drift(flat, 24 * HOUR, "disk_used")
        self.assertEqual(g["verdict"], "FAIL", g)
        self.assertEqual(f["verdict"], "PASS", f)
        self.assertEqual(g["evidence"], len(grow))
        # a run too short for a first and a last 6 hours cannot be judged: TRUNCATED, never PASS
        short = self.series(lambda t, r: 300000, hours=3)
        self.assertEqual(report.judge_drift(short, 3 * HOUR, "disk_used")["verdict"], "TRUNCATED")
        self.assertEqual(report.judge_drift([], 24 * HOUR, "disk_used")["verdict"], "TRUNCATED")

    def test_disk_growth_in_a_run_folder_fails(self):
        run = make_run(hours=24, disk=lambda t: 200000 + 8000 * t / HOUR)
        try:
            rep = report.build_report(run)
            self.assertEqual(rep["drift"]["disk_used"]["verdict"], "FAIL", rep["drift"]["disk_used"])
            self.assertEqual(rep["drift"]["lua_memory"]["verdict"], "TRUNCATED")
        finally:
            shutil.rmtree(run, ignore_errors=True)
        run = make_run(hours=24, disk=lambda t: 300000 + (t // MIN) % 7 * 900)
        try:
            self.assertEqual(report.build_report(run)["drift"]["disk_used"]["verdict"], "PASS")
        finally:
            shutil.rmtree(run, ignore_errors=True)


class BridgeGapIsTruncated(unittest.TestCase):
    def test_bridge_gap_is_truncated(self):
        run = make_run(hours=4, missing_hours={2}, jobs_in_hours={0: 3, 3: 2})
        try:
            rep = report.build_report(run)
            hours = {h["hour"]: h for h in rep["hours"]}
            self.assertEqual(hours[2]["jobs_done"], report.TRUNCATED)
            self.assertEqual(hours[2]["log_lines"], 0)
            self.assertEqual(hours[0]["jobs_done"], 3)
            self.assertEqual(hours[1]["jobs_done"], 0, "an hour WITH log lines and no jobs is a real zero")
            self.assertEqual(hours[3]["jobs_done"], 2)
            self.assertTrue(any(g["from"] <= 2 * HOUR and g["to"] >= 3 * HOUR - 2 * MIN for g in rep["log_gaps"]), rep["log_gaps"])
            path = report.write_report(run)
            with open(path, encoding="utf8") as f:
                md = f.read()
            head = [c.strip() for c in next(l for l in md.splitlines() if l.startswith("| hour |")).split("|")]
            row = [c.strip() for c in next(l for l in md.splitlines() if l.startswith("| 2 |")).split("|")]
            for col in ("jobs done", "stuck onsets", "jams begun"):
                self.assertEqual(row[head.index(col)], "TRUNCATED", (col, row))
            one = [c.strip() for c in next(l for l in md.splitlines() if l.startswith("| 1 |")).split("|")]
            self.assertEqual(one[head.index("jobs done")], "0")
            self.assertIn("TRUNCATED", row[head.index("note")])
            # node_5's heartbeats jump 65 minutes across the gap; nobody saw that hour, so it is not "gone" (and the run has one
            # turtle judged, the evidence count says so)
            self.assertEqual(rep["verdicts"], {"node_5": "ok"})
        finally:
            shutil.rmtree(run, ignore_errors=True)

    def test_report_reads_files_not_the_bridge(self):
        run = make_run(hours=2)
        try:
            import urllib.request
            real = urllib.request.urlopen
            urllib.request.urlopen = lambda *a, **k: (_ for _ in ()).throw(AssertionError("the report asked the bridge"))
            try:
                rep = report.build_report(run)
            finally:
                urllib.request.urlopen = real
            self.assertGreater(rep["evidence"]["log_lines"], 0)
        finally:
            shutil.rmtree(run, ignore_errors=True)


class JamsAndSections(unittest.TestCase):
    def test_jam_needs_three_in_the_base_and_clears_below_three(self):
        tls = {}
        for i, (a, b) in enumerate([(0, 40), (2, 45), (4, 30)]):
            tls["node_%d" % i] = timeline(sitting(0, b * MIN, pos=(190 + i, 67, -2800)) + [(b * MIN + MIN, DOCK, "IDLE/")],
                                          tid="node_%d" % i)
        tls["node_far"] = timeline(sitting(0, 60 * MIN, pos=(900, 20, -2900)), tid="node_far")    # out of the base
        out = report.findings(tls, [], 60 * MIN)
        self.assertEqual(len(out["jams"]), 1, out["jams"])
        jam = out["jams"][0]
        self.assertEqual(jam["start"], 10 * MIN)
        self.assertEqual(jam["clear"], 31 * MIN)           # node_2 recovered at 31: two left
        # three more stuck in the base until the end: the jam never drops below three, so it is UNCLEARED
        for n in (3, 4, 6):
            tls["node_%d" % n] = timeline(sitting(0, 60 * MIN, pos=(200 + n, 67, -2790)), tid="node_%d" % n)
        out = report.findings(tls, [], 60 * MIN)
        self.assertEqual(len(out["jams"]), 1, out["jams"])
        self.assertIsNone(out["jams"][0]["clear"])
        self.assertEqual(out["jams"][0]["peak"], 6)

    def test_expected_hands_and_expected_issues(self):
        hit = [window("f020", "remove_item", 0, 0, targets={"node_5"})]
        t = timeline(sitting(0, 60 * MIN, pos=DOCK, phase="IDLE/"))
        for s in t["samples"][2:]:
            s["needs_hands"] = "needs_hands: loader missing"
        self.assertEqual(report.classify(t, hit), "expected_hands")
        self.assertEqual(report.classify(t, []), "decommissioned", "NEEDS HANDS never cleared, no fault to explain it")
        run = make_run(hours=2, extra_lines=[(30 * MIN, "node_7", "WARN", "[node_7][WARN] departure_failed: blocked by a turtle")],
                       stuck_node=True)
        try:
            rep = report.build_report(run, expected=[{"card": "Departure blocked", "pattern": r"departure_failed"}])
            self.assertIn("Departure blocked", rep["expected"])
            self.assertFalse(any("departure_failed" in json.dumps(c) for c in rep["cards"]))
            rep2 = report.build_report(run, expected=[])
            self.assertTrue(any("departure_failed" in json.dumps(c) for c in rep2["cards"]))
            with open(report.write_report(run), encoding="utf8") as f:
                md = f.read()
            for section in report.SECTIONS:
                self.assertIn("## " + section, md)
        finally:
            shutil.rmtree(run, ignore_errors=True)


CONTROL = "G:/TurtleOS-Sandbox/run/20261103-181857-w3_atc_base150-1"


class ControlRunMustFail(unittest.TestCase):
    @unittest.skipUnless(os.path.exists(os.path.join(CONTROL, "state.json")), "the control run folder is not on this machine")
    def test_control_run_jams_and_sticks(self):
        """Task 7 step 4: W3's simulator boot rush on the code without the ATC (2026-11-03, rev 4fb6b50: 138 turtles off their
        docks, 565 'blocked over 30 s' lines). The jam and stuck checks must FAIL here, or they prove nothing elsewhere."""
        rep = report.build_report(CONTROL)
        self.assertEqual(rep["kind"], "sim")
        self.assertGreaterEqual(sum(1 for j in rep["jams"] if j["clear"] is None), 1, rep["jams"])
        self.assertGreaterEqual(rep["stuck_ever"], 100)
        self.assertGreater(rep["counts"]["decommissioned"], 0)
        self.assertEqual(rep["stuck_ever"], report.JAM_CONTROL["stuck_turtles"], "JAM_CONTROL states what this code measured")


def iso(ms):
    return time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(ms / 1000.0)) + ".%03dZ" % (ms % 1000)


def make_run(hours, missing_hours=(), jobs_in_hours=None, disk=None, extra_lines=(), stuck_node=False, turtles_at=None,
             faults_file=True, entries=None, final=None):
    """A T2 shakeout run folder: schedule.json, shakeout/faults.jsonl, shakeout/state.jsonl (a snapshot every 5 minutes, none in a
    missing hour: the bridge was down) and bridge/logs (a server line a minute, none in a missing hour)."""
    run = tempfile.mkdtemp()
    os.makedirs(os.path.join(run, "shakeout"))
    os.makedirs(os.path.join(run, "bridge", "logs"))
    with open(os.path.join(run, "schedule.json"), "w") as f:
        json.dump({"format": "shakeout-schedule/1", "seed": 42, "hours": hours, "entries": entries or []}, f)
    if faults_file:
        open(os.path.join(run, "shakeout", "faults.jsonl"), "w").close()
    if final is not None:
        with open(os.path.join(run, "shakeout", "final.json"), "w") as f:
            json.dump(final, f)
    lines, seq = [], 0
    jobs_in_hours = jobs_in_hours or {}
    for h in range(hours):
        if h in missing_hours:
            continue
        for m in range(60):
            t = h * HOUR + m * MIN
            seq += 1
            lines.append((t, "server#%d" % seq, "INFO", "loop rollup: iters=10"))
        for j in range(jobs_in_hours.get(h, 0)):
            t = h * HOUR + (j + 1) * 7 * MIN + 1000
            jid = "job_%02d%02d" % (h, j)
            lines.append((t - 500, "server#%d" % (seq + 1), "INFO", "Job queued: %s [DELIVER] p=5" % jid))
            lines.append((t, "server#%d" % (seq + 2), "INFO", "Job complete: %s" % jid))
            seq += 2
    for t, src, lvl, msg in extra_lines:
        seq += 1
        lines.append((t, "%s#%d" % (src, seq), lvl, msg))
    random.Random(1).shuffle(lines)            # arrival order is not time order
    with open(os.path.join(run, "bridge", "logs", "2026-11-10.txt"), "w", encoding="utf8") as f:
        for t, src, lvl, msg in lines:
            f.write("%s  %-14s %-6s %s\n" % (iso(T0 + t), src, lvl, msg))
    with open(os.path.join(run, "shakeout", "state.jsonl"), "w") as f:
        f.write(json.dumps({"header": {"t0_epoch_ms": T0}}) + "\n")
        for t in range(0, hours * HOUR, 5 * MIN):
            if t // HOUR in missing_hours:
                continue
            turtles = {"node_5": {"x": DOCK[0], "y": DOCK[1], "z": DOCK[2], "status": "IDLE", "phase": None, "dockX": DOCK[0],
                                  "dockZ": DOCK[2], "lastSeen": T0 + t - 2000, "online": True, "role": "DELIVERY"}}
            if stuck_node:
                turtles["node_7"] = {"x": OFF[0], "y": OFF[1], "z": OFF[2], "status": "ERROR", "phase": None, "dockX": 171,
                                     "dockZ": -2806, "lastSeen": T0 + t - 2000, "online": True, "role": "DELIVERY"}
            if turtles_at:
                turtles.update(turtles_at(t))
            f.write(json.dumps({"wall_ms": t, "epoch_ms": T0 + t, "fresh": True, "updatedAt": T0 + t - 1000,
                                "disk_bytes": int(disk(t)) if disk else 250000, "disk_free": None, "pending": 2, "jobs": [],
                                "turtles": turtles}) + "\n")
    return run


if __name__ == "__main__":
    unittest.main()
