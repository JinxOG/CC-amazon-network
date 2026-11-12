"""Shakeout Task 3: Control.set_slot can give a stack NBT (an ender chest tuned to a frequency)."""
import os
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "t2"))
import control  # noqa: E402


class Recorder(control.Control):
    """A Control with no server: records every command and answers the way the game does."""

    def __init__(self):
        self.sent = []

    def _pos(self, computer_id):
        return (10, 67, -20)

    def command(self, text):
        self.sent.append(text)
        if text.startswith("data get block"):
            return "Found no elements matching Items[{Slot:3b}]" if len(self.sent) < 3 else "x has data: {Slot:3b}"
        return "Modified block data of 10, 67, -20" if "append" in text else "ok"


def append_command(rec):
    return [c for c in rec.sent if "append" in c][0]


class SetSlotTag(unittest.TestCase):
    def test_set_slot_with_tag_sends_tag(self):
        r = Recorder()
        r.set_slot(5, 3, "enderstorage:ender_chest", 1, tag="{Frequency:{left:0,middle:0,right:14}}")
        self.assertIn(',tag:{Frequency:{left:0,middle:0,right:14}}}', append_command(r))

    def test_set_slot_without_tag_unchanged(self):
        r = Recorder()
        r.set_slot(5, 3, "minecraft:coal", 2)
        self.assertEqual(append_command(r), 'data modify block 10 67 -20 Items append value {Slot:3b,id:"minecraft:coal",Count:2b}')


class Owner(unittest.TestCase):
    REAL = 'x has the following block data: {Owner: {UpperId: -47L, LowerId: -81L, Name: "HighJinxOG"}, Fuel: 5, id: "computercraft:turtle_advanced"}'

    def test_owner_of_reads_the_compound(self):
        self.assertEqual(control.Control.owner_of(self.REAL), '{UpperId:-47L,LowerId:-81L,Name:"HighJinxOG"}')
        self.assertIsNone(control.Control.owner_of("{Fuel: 5, id: x}"))

    def test_spawn_turtle_gives_the_new_turtle_the_world_copy_owner(self):
        r = Recorder()
        r.computers = lambda: {7: {"on": True, "pos": (1, 2, 3)}}
        r.block_data = lambda pos, path="": self.REAL
        out = []
        r.command = lambda text: out.append(text) or "Changed the block"
        with self.assertRaises(RuntimeError):      # no new computer ever appears in the fake; only the setblock matters here
            self._spawn_setblock(r)
        self.assertIn(',Owner:{UpperId:-47L,LowerId:-81L,Name:"HighJinxOG"}}', out[0])

    def test_spawn_turtle_refuses_when_no_world_turtle_has_an_owner(self):
        r = Recorder()
        r.computers = lambda: {7: {"on": True, "pos": (1, 2, 3)}}
        r.block_data = lambda pos, path="": "{Fuel: 5, id: x}"
        out = []
        r.command = lambda text: out.append(text) or "Changed the block"
        with self.assertRaises(RuntimeError) as e:
            self._spawn_setblock(r)
        self.assertIn("Owner", str(e.exception))
        self.assertEqual(out, [])                     # nothing was placed: an ownerless turtle is never spawned

    @staticmethod
    def _spawn_setblock(r):
        import time
        orig = time.sleep
        time.sleep = lambda s: None
        try:
            r.spawn_turtle(5, 5, 5, "SUPPORT")
        finally:
            time.sleep = orig


if __name__ == "__main__":
    unittest.main()
