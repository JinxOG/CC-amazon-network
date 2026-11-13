"""T2: a stop the harness does is a stop it has SEEN happen (shakeout-faults-b, 2026-11-13).

That run lost its bridge and then its game server because every kill was a `taskkill` whose answer nobody read and every
"is it alive?" was a substring of tasklist's output:
  - bridge_down's taskkill left the bridge answering on 3000 (its begin measured ping 2.3 ms);
  - bridge_slow then bound its proxy to 127.0.0.1:3000 BESIDE that bridge, and every end-retry's taskkill of the proxy and
    of the 3001 bridge left both alive for 40 minutes;
  - disk_full's world restart relaunched 3 s after "stop" while the old server was still shutting down (it then hung for
    17 minutes on an RCON client thread), so the new one exited at start-up, again and again.
Here: run.alive() says True / False only when tasklist said so; run.kill() returns only once the process is gone;
run.world_in_use() reads the world's session.lock; and the bridge stop refuses to call a port quiet that still answers.

    python -I sandbox/tests/test_t2_kill.py
"""
import json
import os
import subprocess
import sys
import tempfile
import time
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "t2"))
import run as runmod  # noqa: E402
from shakeout import schedule  # noqa: E402


def sleeper(seconds=60):
    return subprocess.Popen([sys.executable, "-I", "-c", "import time; time.sleep(%d)" % seconds],
                            creationflags=runmod.DETACHED)


class Fake:
    def __init__(self, stdout, returncode=0):
        self.stdout, self.stderr, self.returncode = stdout, "", returncode


class Alive(unittest.TestCase):
    def test_a_running_process_is_alive_and_a_gone_one_is_not(self):
        p = sleeper()
        try:
            self.assertIs(runmod.alive(p.pid), True)
        finally:
            p.kill()
            p.wait()
        self.assertIs(runmod.alive(p.pid), False)

    def _with_tasklist(self, stdout, returncode=0):
        real = runmod.subprocess.run
        runmod.subprocess.run = lambda *a, **k: Fake(stdout, returncode)
        self.addCleanup(setattr, runmod.subprocess, "run", real)

    def test_an_unreadable_tasklist_answer_raises_instead_of_reading_as_dead(self):
        self._with_tasklist("", 1)
        with self.assertRaises(RuntimeError):
            runmod.alive(23320)

    def test_a_longer_pid_in_the_answer_is_not_this_pid(self):
        self._with_tasklist("java.exe                     23320 Console                    1  6,258,344 K\n")
        with self.assertRaises(RuntimeError):     # neither a row for 2332 nor tasklist's "No tasks": not an answer
            runmod.alive(2332)

    def test_tasklists_no_tasks_line_is_dead(self):
        self._with_tasklist("INFO: No tasks are running which match the specified criteria.\n")
        self.assertIs(runmod.alive(2332), False)


class Kill(unittest.TestCase):
    def test_kill_returns_only_once_the_process_is_gone(self):
        p = sleeper()
        runmod.kill(p.pid)
        self.assertIs(runmod.alive(p.pid), False)

    def test_killing_a_process_already_gone_is_fine(self):
        p = sleeper()
        p.kill()
        p.wait()
        runmod.kill(p.pid)

    def test_a_process_that_outlives_the_kill_raises_with_taskkills_answer(self):
        real_run, real_alive = runmod.subprocess.run, runmod.alive
        runmod.subprocess.run = lambda *a, **k: Fake("ERROR: The process with PID 4242 could not be terminated.", 1)
        runmod.alive = lambda pid: True
        self.addCleanup(setattr, runmod.subprocess, "run", real_run)
        self.addCleanup(setattr, runmod, "alive", real_alive)
        with self.assertRaises(RuntimeError) as cm:
            runmod.kill(4242, seconds=0.2)
        self.assertIn("could not be terminated", str(cm.exception))

    def test_no_pid_is_nothing_to_kill(self):
        self.assertEqual(runmod.kill(None), "")


class WorldInUse(unittest.TestCase):
    def setUp(self):
        self.run = tempfile.mkdtemp()
        os.makedirs(os.path.join(self.run, "world"))
        self.lock = os.path.join(self.run, "world", "session.lock")
        with open(self.lock, "wb") as f:
            f.write("☃".encode("utf8"))

    def test_a_world_with_no_lock_file_is_not_in_use(self):
        os.remove(self.lock)
        self.assertFalse(runmod.world_in_use(self.run))

    def test_a_lock_nobody_holds_is_not_in_use(self):
        self.assertFalse(runmod.world_in_use(self.run))

    def test_a_lock_another_process_holds_is_in_use_until_it_lets_go(self):
        code = ("import msvcrt, sys, time; f = open(sys.argv[1], 'r+b'); msvcrt.locking(f.fileno(), msvcrt.LK_NBLCK, 3); "
                "print('held', flush=True); time.sleep(30)")
        p = subprocess.Popen([sys.executable, "-I", "-c", code, self.lock], stdout=subprocess.PIPE, text=True)
        try:
            self.assertEqual(p.stdout.readline().strip(), "held")
            self.assertTrue(runmod.world_in_use(self.run))
        finally:
            p.kill()
            p.wait()
        self.assertFalse(runmod.world_in_use(self.run))


class Ctx:
    def __init__(self):
        self.run = tempfile.mkdtemp()
        self.interventions = []
        with open(runmod.pids_path(self.run), "w") as f:
            json.dump({"run": self.run, "bridge": 4242}, f)


class BridgeStop(unittest.TestCase):
    def setUp(self):
        self.killed = []
        saved = {"kill": runmod.kill, "ping": schedule._bridge_ping, "owners": schedule._listeners}
        runmod.kill = lambda pid, seconds=30: self.killed.append(pid) or "SUCCESS"
        schedule._listeners = lambda port: [23332]
        self.addCleanup(lambda: (setattr(runmod, "kill", saved["kill"]), setattr(schedule, "_bridge_ping", saved["ping"]),
                                 setattr(schedule, "_listeners", saved["owners"])))
        schedule.BRIDGE_QUIET_S = 0.2

    def test_a_port_that_goes_quiet_is_a_stop(self):
        schedule._bridge_ping = lambda port, timeout=10: None
        ctx = Ctx()
        schedule._bridge_stop(ctx, {"id": "f010"})
        self.assertEqual(self.killed, [4242])

    def test_a_port_that_still_answers_is_refused_with_who_listens(self):
        schedule._bridge_ping = lambda port, timeout=10: 2.3
        ctx = Ctx()
        with self.assertRaises(RuntimeError) as cm:
            schedule._bridge_stop(ctx, {"id": "f010"}, port=3000)
        self.assertIn("23332", str(cm.exception))
        self.assertIn("3000", str(cm.exception))

    def test_every_intervention_is_on_disk_as_it_happens(self):
        schedule._bridge_ping = lambda port, timeout=10: None
        ctx = Ctx()
        schedule._bridge_stop(ctx, {"id": "f010"})
        with open(os.path.join(ctx.run, "shakeout", "interventions.jsonl")) as f:
            rows = [json.loads(l) for l in f]
        self.assertEqual([r["verb"] for r in rows], ["bridge_stop"])
        self.assertEqual(rows[0]["fault"], "f010")
        self.assertIn("4242", rows[0]["args"][0])


class Listeners(unittest.TestCase):
    def test_a_listening_socket_is_found_by_port(self):
        import socket
        s = socket.socket()
        s.bind(("127.0.0.1", 0))
        s.listen(1)
        try:
            self.assertIn(os.getpid(), schedule._listeners(s.getsockname()[1]))
        finally:
            s.close()


if __name__ == "__main__":
    unittest.main(verbosity=1)
