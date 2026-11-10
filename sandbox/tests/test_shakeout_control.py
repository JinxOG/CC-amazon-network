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


if __name__ == "__main__":
    unittest.main()
