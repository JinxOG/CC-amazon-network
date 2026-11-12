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


class ComputerList(unittest.TestCase):
    """`computercraft dump` stops at 99 rows ("1 additional rows..."): every computer past that was invisible (diag-dump-limit-b,
    2026-11-12). computers() reads the control mod's full list, and never trusts a cut-off dump."""

    @staticmethod
    def control(replies):
        r = Recorder()
        r.command = lambda text: replies[text] if text in replies else "Unknown or incomplete command"
        return r

    def test_reads_the_mods_full_list(self):
        many = ",".join('{"id":%d,"on":%s,"x":%d,"y":67,"z":-2800}' % (i, "true" if i % 2 else "false", i) for i in range(150))
        r = self.control({"t2 computers": '{"computers":[%s,{"id":999,"on":true}]}' % many})
        got = r.computers()
        self.assertEqual(len(got), 151)
        self.assertEqual(got[149], {"on": True, "pos": (149, 67, -2800)})
        self.assertEqual(got[2], {"on": False, "pos": (2, 67, -2800)})
        self.assertIsNone(got[999]["pos"])                    # a computer with no position is listed, not dropped

    def test_falls_back_to_the_dump_without_the_mod(self):
        r = self.control({"computercraft dump": "Computer | On | Position\n=====\n#94      | Y  | 154, 67, -2793\n#3 | N | 1, 2, 3"})
        self.assertEqual(r.computers(), {94: {"on": True, "pos": (154, 67, -2793)}, 3: {"on": False, "pos": (1, 2, 3)}})

    def test_a_cut_off_dump_is_refused_not_trusted(self):
        r = self.control({"computercraft dump": "Computer | On | Position\n#94 | Y | 154, 67, -2793\n1 additional rows\u2026"})
        with self.assertRaises(RuntimeError) as e:
            r.computers()
        self.assertIn("additional rows", str(e.exception))


if __name__ == "__main__":
    unittest.main()
