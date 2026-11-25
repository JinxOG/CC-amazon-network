"""The shakeout's stand-in player (sandbox/t2/shakeout/player.py). The user, 2026-11-24: a crash can leave a moving turtle in two
places (T2 payload-h's node_397, payload-i's node_215 in three); the server parks every copy and asks for hands (duplicate_id).
The 24-hour test MODELS A PLAYER: PLAYER_DELAY_S after the alarm it removes one copy, and from then on the fleet must recover by
itself. Run: python -m unittest sandbox.tests.test_shakeout_player"""
import json
import os
import shutil
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "t2"))
from shakeout import player  # noqa: E402

ALARM = ("2026-11-24T11:59:00.000Z  server#901     ERROR  NEEDS HANDS: node_215 — duplicate_id: node_215 heard at 207,67,-2801 "
         "and 191,67,-2801. Two turtles share this id: a player has to remove one. Both are told to stay where they are, and "
         "the ATC drops the id.\n")


class FakeRaw:
    """The raw control: answers `execute if block` for the cells that hold a turtle, records every command."""

    def __init__(self, turtles_at):
        self.turtles_at = set(turtles_at)
        self.commands = []

    def command(self, text):
        self.commands.append(text)
        parts = text.split()
        if text.startswith("execute if block"):
            cell = tuple(int(v) for v in parts[3:6])
            return "Test passed" if cell in self.turtles_at else "Test failed"
        if text.startswith("setblock") and parts[4] == "minecraft:air":
            self.turtles_at.discard(tuple(int(v) for v in parts[1:4]))
            return "Changed the block"
        return ""


class FakeCtx:
    def __init__(self, run, raw):
        self.run, self._raw, self.interventions, self.notes, self.dispatched = run, raw, [], [], []

    def dispatch(self, type_, params):
        self.dispatched.append((type_, params))
        return {"ok": True}

    def note(self, s):
        self.notes.append(s)


class PlayerRemovesOneCopy(unittest.TestCase):
    def setUp(self):
        self.run = tempfile.mkdtemp()
        os.makedirs(os.path.join(self.run, "bridge", "logs"))
        os.makedirs(os.path.join(self.run, "shakeout"))
        self.log = os.path.join(self.run, "bridge", "logs", "2026-11-24.txt")
        open(self.log, "w").close()

    def tearDown(self):
        shutil.rmtree(self.run, ignore_errors=True)

    def _faults(self):
        p = os.path.join(self.run, "shakeout", "faults.jsonl")
        return [json.loads(l) for l in open(p, encoding="utf8")] if os.path.exists(p) else []

    def test_waits_the_delay_then_removes_one_copy_and_logs_both(self):
        raw = FakeRaw({(207, 67, -2801), (191, 67, -2801)})
        ctx = FakeCtx(self.run, raw)
        p = player.Player(ctx, t0=1000.0)
        with open(self.log, "a", encoding="utf8") as f:
            f.write(ALARM)
        p.tick(1100.0)                                   # alarm seen: logged, nothing removed yet
        self.assertFalse([c for c in raw.commands if c.startswith("setblock")])
        p.tick(1100.0 + player.PLAYER_DELAY_S - 1)       # still inside the player's delay
        self.assertFalse([c for c in raw.commands if c.startswith("setblock")])
        p.tick(1100.0 + player.PLAYER_DELAY_S + 1)
        removed = [c for c in raw.commands if c.startswith("setblock")]
        self.assertEqual(len(removed), 1, raw.commands)
        self.assertEqual(len(raw.turtles_at), 1, "exactly one copy is left")
        lines = self._faults()
        self.assertEqual([(l["fault"], l["phase"]) for l in lines], [("player_dup_fix", "start"), ("player_dup_fix", "end")])
        self.assertEqual(lines[0]["wall_ms"], 100000)               # 1100 - t0 1000, in ms on the run's clock
        self.assertTrue(lines[1]["ok"])
        self.assertEqual(raw.turtles_at, {(207, 67, -2801)}, "the first-named copy (the newest stream's) is the one kept")
        self.assertEqual(ctx.dispatched, [("RELEASE_TURTLE", {"turtleId": "node_215"})], "then the hold is released")
        self.assertTrue(any(i["verb"] == "command" for i in ctx.interventions), "a world change is an INTERVENTION")
        self.assertTrue(any(i["verb"] == "dispatch" for i in ctx.interventions), "so is the release")
        p.tick(1100.0 + 2 * player.PLAYER_DELAY_S)       # done: the same alarm is never acted on twice
        self.assertEqual(len([c for c in raw.commands if c.startswith("setblock")]), 1)

    def test_three_copies_named_leave_one_in_one_fix(self):
        raw = FakeRaw({(223, 67, -2801), (207, 67, -2801), (191, 67, -2801)})     # three copies, as payload-i's node_215
        ctx = FakeCtx(self.run, raw)
        p = player.Player(ctx, t0=0.0)
        with open(self.log, "a", encoding="utf8") as f:
            f.write(ALARM.replace("and 191,67,-2801.", "and 191,67,-2801 and 223,67,-2801."))
        p.tick(10.0)
        p.tick(10.0 + player.PLAYER_DELAY_S + 1)
        self.assertEqual(raw.turtles_at, {(207, 67, -2801)})
        self.assertEqual([l["phase"] for l in self._faults()], ["start", "end"])
        self.assertEqual(len(ctx.dispatched), 1)

    def test_a_later_alarm_for_the_same_id_is_a_new_fix(self):
        raw = FakeRaw({(207, 67, -2801), (191, 67, -2801)})
        ctx = FakeCtx(self.run, raw)
        p = player.Player(ctx, t0=0.0)
        with open(self.log, "a", encoding="utf8") as f:
            f.write(ALARM)
        p.tick(10.0)
        p.tick(10.0 + player.PLAYER_DELAY_S + 1)
        raw.turtles_at.add((223, 67, -2801))                  # a later crash copies it again
        with open(self.log, "a", encoding="utf8") as f:
            f.write(ALARM.replace("191,67,-2801", "223,67,-2801").replace("11:59:00", "12:20:00"))
        p.tick(2000.0)
        p.tick(2000.0 + player.PLAYER_DELAY_S + 1)
        self.assertEqual(raw.turtles_at, {(207, 67, -2801)}, raw.turtles_at)
        self.assertEqual([l["phase"] for l in self._faults()], ["start", "end", "start", "end"])

    def test_nothing_at_either_cell_is_logged_not_guessed(self):
        raw = FakeRaw(set())
        ctx = FakeCtx(self.run, raw)
        p = player.Player(ctx, t0=0.0)
        with open(self.log, "a", encoding="utf8") as f:
            f.write(ALARM)
        p.tick(10.0)
        p.tick(10.0 + player.PLAYER_DELAY_S + 1)
        self.assertFalse([c for c in raw.commands if c.startswith("setblock")])
        end = [l for l in self._faults() if l["phase"] == "end"][0]
        self.assertFalse(end["ok"])
        self.assertIn("no turtle", end["why"])


if __name__ == "__main__":
    unittest.main()
