"""Tests for sandbox/tools/import_world.py, run against the real world copy on the Game Drive.

They need the unpacked backup and the importer's one-off whole-world search (fleet_scan.json, made by the first real
import); they FAIL, never skip, if either is missing, so a green run always means the importer was checked.
"""
import json
import os
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
DATA = os.environ.get("SANDBOX_DATA", "G:/TurtleOS-Sandbox").replace("\\", "/")
WORLD = f"{DATA}/worlds/unpacked/2026-10-18_1700/world_live"
SCAN = f"{DATA}/worlds/2026-10-18_1700/sim/fleet_scan.json"
IMPORTER = os.path.join(REPO, "sandbox", "tools", "import_world.py")


def run_importer(out, extra=None, no_network=False):
    cmd = [sys.executable, IMPORTER, WORLD, "--out", out, "--scan-cache", SCAN] + (extra or [])
    if no_network:
        # Any attempt to open a socket raises. The importer must never need one.
        guard = (
            "import socket, runpy, sys\n"
            "def _no(*a, **k): raise RuntimeError('network used by the importer')\n"
            "socket.socket.connect = _no; socket.create_connection = _no; socket.getaddrinfo = _no\n"
            f"sys.argv = {cmd[1:]!r}\n"
            f"runpy.run_path({IMPORTER!r}, run_name='__main__')\n"
        )
        cmd = [sys.executable, "-c", guard]
    return subprocess.run(cmd, capture_output=True, text=True, cwd=REPO)


class ImportWorld(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        assert os.path.isdir(WORLD), f"no world copy at {WORLD}"
        assert os.path.exists(SCAN), f"no whole-world search at {SCAN}; run the importer once without --scan-cache"
        cls.tmp = tempfile.TemporaryDirectory()
        cls.out = os.path.join(cls.tmp.name, "sim")
        cls.result = run_importer(cls.out, no_network=True)
        with open(os.path.join(cls.out, "fleet.json"), "r", encoding="utf-8") as f:
            cls.fleet = json.load(f)

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def test_importer_runs_without_the_network(self):
        self.assertEqual(self.result.returncode, 0, self.result.stderr[-800:])
        self.assertNotIn("network used", self.result.stderr)

    def test_importer_finds_every_turtle(self):
        with open(SCAN, "r", encoding="utf-8") as f:
            scanned = json.load(f)
        turtles_with_disks = [be for be in scanned if "turtle" in be["id"]
                              and os.path.exists(f"{WORLD}/computercraft/computer/{be['ComputerId']}/startup.lua")]
        found = {c["id"] for c in self.fleet["fleet"] if c["kind"] == "turtle" and not c.get("carried")}
        self.assertEqual(found, {be["ComputerId"] for be in turtles_with_disks})
        self.assertGreaterEqual(len(found), 15)

    def test_importer_copies_every_computer_disk(self):
        for c in self.fleet["fleet"]:
            disk = os.path.join(self.out, "disks", str(c["id"]))
            self.assertTrue(os.path.exists(os.path.join(disk, "startup.lua")), f"computer {c['id']} has no startup.lua")
            src = f"{WORLD}/computercraft/computer/{c['id']}/startup.lua"
            with open(src, "rb") as a, open(os.path.join(disk, "startup.lua"), "rb") as b:
                self.assertEqual(a.read(), b.read(), f"computer {c['id']}'s program was altered")

    def test_importer_reads_a_turtles_inventory_and_upgrades(self):
        # computer 96: a delivery turtle with a modem and a pickaxe and two ender chests (checked in the raw world)
        t = next(c for c in self.fleet["fleet"] if c["id"] == 96)
        self.assertEqual(t["role"], "delivery")
        self.assertEqual(t["turtle"]["equipped"]["left"], "computercraft:wireless_modem_advanced")
        self.assertEqual(t["turtle"]["equipped"]["right"], "minecraft:diamond_pickaxe")
        self.assertEqual(t["turtle"]["fuel"], 97421)
        inv = t["turtle"]["inv"]
        self.assertEqual(inv["15"]["name"], "enderstorage:ender_chest")
        self.assertEqual(inv["16"]["frequency"], "0,10,0")  # slots are stored 0-based in the world and 1-based here

    def test_chunky_upgrade_is_reported_under_its_item_name(self):
        miners = [c for c in self.fleet["fleet"] if c["role"] == "miner"]
        self.assertTrue(miners)
        for m in miners:
            self.assertIn("advancedperipherals:chunk_controller", m["turtle"]["equipped"].values())
            self.assertNotIn("advancedperipherals:chunky_turtle", m["turtle"]["equipped"].values())

    def test_carried_loaders_become_computers_of_their_own(self):
        loaders = [c for c in self.fleet["fleet"] if c.get("carried")]
        self.assertGreaterEqual(len(loaders), 3)
        for c in loaders:
            self.assertTrue(c["label"].startswith("loader_"), c)

    def test_the_world_copy_is_untouched(self):
        # nothing was written under the world copy: its newest file is older than the importer's output
        newest = max(os.path.getmtime(os.path.join(dp, f)) for dp, _, fs in os.walk(f"{WORLD}/computercraft") for f in fs)
        self.assertLess(newest, os.path.getmtime(os.path.join(self.out, "fleet.json")))

    def test_ender_chest_frequencies_and_the_clock(self):
        with open(os.path.join(self.out, "ender.json"), "r", encoding="utf-8") as f:
            ender = json.load(f)["frequencies"]
        self.assertEqual(ender["fuel"], "0,0,0")
        self.assertEqual(ender["delivery"], "0,10,0")
        with open(os.path.join(self.out, "meta.lua"), "r", encoding="utf-8") as f:
            meta = f.read()
        self.assertIn('["start_ms"] = 1792368012069', meta)


if __name__ == "__main__":
    unittest.main()
