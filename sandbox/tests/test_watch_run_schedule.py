"""Shakeout Task 6: watch_run --schedule (sandbox/t2/watch_run.py). The clock, the run folder, the host's sleep log and the server
pid are all fakes; nothing here touches a real run.

    python -I sandbox/tests/test_watch_run_schedule.py
"""
import datetime
import json
import os
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "t2"))
import watch_run  # noqa: E402

MIN = 60000


class FakeTime:
    """A clock that only moves when the watchdog sleeps."""

    def __init__(self, start):
        self.now = start

    def time(self):
        return self.now

    def sleep(self, s):
        self.now += s

    def strftime(self, fmt):
        return "00:00:00"


class Harness:
    def __init__(self):
        self.run = tempfile.mkdtemp()
        os.makedirs(os.path.join(self.run, "shakeout"))
        self.t0 = datetime.datetime.now().timestamp()
        self.clock = FakeTime(self.t0)
        self.alive = {}
        self.fleet_lines = 100
        self.sched = os.path.join(self.run, "schedule.json")
        self.pids = {"server": 111}
        self._write_pids()
        self.saved = (watch_run.time, watch_run.runmod.run_dir, watch_run.runmod.pids_path, watch_run.log_state,
                      watch_run.slept_since, watch_run.alive)
        watch_run.time = self.clock
        watch_run.runmod.run_dir = lambda rid: self.run
        watch_run.log_state = lambda run: (self.fleet_lines, self.fleet_lines, self.clock.now)
        watch_run.slept_since = lambda epoch: []
        watch_run.alive = lambda pid: self.alive.get(pid, True)

    def _write_pids(self):
        with open(os.path.join(self.run, "pids.json"), "w") as f:
            json.dump(self.pids, f)

    def write_schedule(self, entries):
        with open(self.sched, "w") as f:
            json.dump({"entries": entries}, f)
        os.utime(self.sched, (self.t0, self.t0))      # the schedule starts when the run does

    def log_fault(self, eid, fault, phase, wall_ms, **extra):
        ts = datetime.datetime.fromtimestamp(self.t0 + wall_ms / 1000.0).strftime("%Y-%m-%dT%H:%M:%S")
        rec = dict({"wall_ms": wall_ms, "time": ts, "id": eid, "fault": fault, "phase": phase}, **extra)
        with open(os.path.join(self.run, "shakeout", "faults.jsonl"), "a") as f:
            f.write(json.dumps(rec) + "\n")

    def watch(self, *args):
        out = []
        import io
        buf = io.StringIO()
        old = sys.stdout
        sys.stdout = buf
        try:
            code = watch_run.main(["r", "--poll", "120"] + list(args))
        finally:
            sys.stdout = old
        return code, buf.getvalue()

    def close(self):
        (watch_run.time, watch_run.runmod.run_dir, watch_run.runmod.pids_path, watch_run.log_state,
         watch_run.slept_since, watch_run.alive) = self.saved


class WatchTests(unittest.TestCase):
    def setUp(self):
        self.h = Harness()

    def tearDown(self):
        self.h.close()

    def test_watch_fails_unscheduled_quiet(self):
        # the same silence, no --schedule: exactly as before, exit 3 after the idle limit
        code, out = self.h.watch("--max-hours", "0.25")
        self.assertEqual(code, 3, out)
        self.assertIn("QUIET", out)

    def test_watch_fails_quiet_with_schedule_that_does_not_cover_it(self):
        self.h.write_schedule([{"id": "f001", "t_ms": 90 * MIN, "fault": "radio_loss", "args": {}, "quiet_ms": 0}])
        code, out = self.h.watch("--schedule", self.h.sched, "--max-hours", "0.25")
        self.assertEqual(code, 3, out)

    def test_watch_excuses_scheduled_quiet(self):
        # a 15-minute silence covered by a 20-minute quiet window: no failure
        self.h.write_schedule([{"id": "f001", "t_ms": 0, "fault": "bridge_down", "args": {}, "quiet_ms": 20 * MIN}])
        code, out = self.h.watch("--schedule", self.h.sched, "--max-hours", "0.25")
        self.assertEqual(code, 0, out)
        self.assertNotIn("QUIET:", out)

    def test_a_window_does_not_excuse_a_silence_that_began_before_it(self):
        # shakeout-faults-d: the dispatch computer was wedged from minute 0; f001's window opened at minute 5 and reset the
        # count to zero, so 17 silent minutes never tripped the watchdog. Silence older than the window is not the fault's.
        self.h.write_schedule([{"id": "f001", "t_ms": 6 * MIN, "fault": "server_crash", "args": {}, "quiet_ms": 20 * MIN}])
        self.h.log_fault("f001", "server_crash", "begin", 6 * MIN)
        code, out = self.h.watch("--schedule", self.h.sched, "--max-hours", "0.5", "--idle-min", "10")
        self.assertEqual(code, 3, out)
        self.assertIn("QUIET", out)

    def test_a_window_still_excuses_a_fleet_that_was_talking_when_it_opened(self):
        self.h.write_schedule([{"id": "f001", "t_ms": 6 * MIN, "fault": "server_crash", "args": {}, "quiet_ms": 20 * MIN}])
        self.h.log_fault("f001", "server_crash", "begin", 6 * MIN)
        real = watch_run.log_state
        calls = {"n": 0}

        def talking_until_minute_6(run):
            calls["n"] += 1
            if self.h.clock.now - self.h.t0 <= 6 * 60:
                self.h.fleet_lines += 50
            return real(run)
        watch_run.log_state = talking_until_minute_6
        code, out = self.h.watch("--schedule", self.h.sched, "--max-hours", "0.4", "--idle-min", "10")
        self.assertEqual(code, 0, out)

    def test_late_begin_is_not_excused_by_the_plan(self):
        # planned at minute 0 (quiet 20 min) but it really fired at minute 40: the plan's window must not excuse minute 0-15
        self.h.write_schedule([{"id": "f001", "t_ms": 0, "fault": "bridge_down", "args": {}, "quiet_ms": 20 * MIN}])
        self.h.log_fault("f001", "bridge_down", "begin", 40 * MIN, late_ms=40 * MIN)
        code, out = self.h.watch("--schedule", self.h.sched, "--max-hours", "0.25")
        self.assertEqual(code, 3, out)

    def test_window_is_anchored_at_the_actual_begin(self):
        # planned minute 0, quiet 8 min; it really began at minute 5, so the window runs 5-13 and the silence is excused
        # until minute 13 (a plan-only watchdog would call it quiet at minute 18, the actual window at minute 23)
        self.h.write_schedule([{"id": "f001", "t_ms": 0, "fault": "bridge_down", "args": {}, "quiet_ms": 8 * MIN}])
        self.h.log_fault("f001", "bridge_down", "begin", 5 * MIN)
        real = watch_run.log_state

        def talking_until_minute_4(run):      # the fleet talks into the window (a silence older than it is not excused)
            if self.h.clock.now - self.h.t0 <= 4 * 60:
                self.h.fleet_lines += 50
            return real(run)
        watch_run.log_state = talking_until_minute_4
        code, out = self.h.watch("--schedule", self.h.sched, "--max-hours", "0.6", "--idle-min", "10")
        self.assertEqual(code, 3, out)
        self.assertGreaterEqual((self.h.clock.now - self.h.t0) / 60.0, 22.5)

    def test_scheduled_restart_with_server_pid_gone_is_expected(self):
        self.h.write_schedule([{"id": "f001", "t_ms": 0, "fault": "world_restart", "args": {}, "quiet_ms": 20 * MIN}])
        self.h.alive[111] = False
        code, out = self.h.watch("--schedule", self.h.sched, "--max-hours", "0.25")
        self.assertEqual(code, 0, out)

    def test_pid_is_reread_so_a_new_server_counts(self):
        self.h.write_schedule([{"id": "f001", "t_ms": 0, "fault": "world_restart", "args": {}, "quiet_ms": 20 * MIN}])
        self.h.alive[111] = False
        self.h.alive[222] = True
        self.h.pids = {"server": 222}
        self.h._write_pids()          # the relaunched server's pid is what pids.json holds now
        code, out = self.h.watch("--schedule", self.h.sched, "--max-hours", "0.25")
        self.assertEqual(code, 0, out)

    def test_server_gone_outside_any_window_still_stops(self):
        self.h.write_schedule([{"id": "f001", "t_ms": 300 * MIN, "fault": "world_restart", "args": {}, "quiet_ms": 20 * MIN}])
        self.h.alive[111] = False
        code, out = self.h.watch("--schedule", self.h.sched, "--max-hours", "0.25")
        self.assertEqual(code, 4, out)

    def test_started_but_not_begun_restart_holds_its_window_open(self):
        # a restart that fired on time, whose verb is still running (a start line, no begin yet) 20 minutes after the plan:
        # the server is down and the fleet silent, and that is the restart, not a void
        self.h.write_schedule([{"id": "f001", "t_ms": 0, "fault": "world_restart", "args": {}, "quiet_ms": 10 * MIN}])
        self.h.log_fault("f001", "world_restart", "start", 0)
        self.h.alive[111] = False
        code, out = self.h.watch("--schedule", self.h.sched, "--max-hours", "0.4")
        self.assertEqual(code, 0, out)

    def test_started_window_is_capped(self):
        # ...but not forever: 10 + 30 minutes after the start with still no begin, the dead server is STOPPED
        self.h.write_schedule([{"id": "f001", "t_ms": 0, "fault": "world_restart", "args": {}, "quiet_ms": 10 * MIN}])
        self.h.log_fault("f001", "world_restart", "start", 0)
        self.h.alive[111] = False
        code, out = self.h.watch("--schedule", self.h.sched, "--max-hours", "1.5")
        self.assertEqual(code, 4, out)
        self.assertGreaterEqual((self.h.clock.now - self.h.t0) / 60.0, 40)

    def test_failed_fault_has_no_window(self):
        self.h.write_schedule([{"id": "f001", "t_ms": 0, "fault": "bridge_down", "args": {}, "quiet_ms": 20 * MIN}])
        self.h.log_fault("f001", "bridge_down", "start", 0)
        self.h.log_fault("f001", "bridge_down", "fail", 1000, error="x")
        code, out = self.h.watch("--schedule", self.h.sched, "--max-hours", "0.25")
        self.assertEqual(code, 3, out)

    def test_failed_restart_keeps_its_window_so_the_relaunch_is_not_a_void(self):
        # world_restart failed (no retry), the server is down until the driver relaunches it: start to fail line + the grace
        self.h.write_schedule([{"id": "f001", "t_ms": 0, "fault": "world_restart", "args": {}, "quiet_ms": 10 * MIN}])
        self.h.log_fault("f001", "world_restart", "start", 0)
        self.h.log_fault("f001", "world_restart", "fail", 6 * MIN, error="x")
        self.h.alive[111] = False
        code, out = self.h.watch("--schedule", self.h.sched, "--max-hours", "0.2")     # 12 minutes: inside fail line + 5 min grace
        self.assertEqual(code, 0, out)
        code, out = self.h.watch("--schedule", self.h.sched, "--max-hours", "1")
        self.assertEqual(code, 4, "...but a server still dead well past the grace is STOPPED: %s" % out)

    def test_max_hours_default_is_raised_only_with_a_schedule(self):
        self.assertEqual(watch_run.default_max_hours(None), 6.0)
        self.assertGreaterEqual(watch_run.default_max_hours("x.json"), 24.0)


if __name__ == "__main__":
    unittest.main()
