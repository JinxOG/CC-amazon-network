"""The T2 run tool must refuse to start a server whose ComputerCraft HTTP rules are not the safe set."""
import os
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "t2"))
import prepare_run  # noqa: E402
import control  # noqa: E402

NL = chr(10)

LIVE_STYLE = '''[http]
	enabled = true

	[[http.rules]]
		host = "$private"
		action = "allow"

	[[http.rules]]
		host = "*"
		action = "allow"

[peripheral]
	command_block_enabled = false
'''


class Rules(unittest.TestCase):
    def test_the_live_copy_rules_are_refused(self):
        self.assertFalse(prepare_run.rules_are_safe(LIVE_STYLE))

    def test_rewriting_makes_them_safe_and_keeps_the_rest(self):
        out = prepare_run.rewrite_http_rules(LIVE_STYLE)
        self.assertTrue(prepare_run.rules_are_safe(out))
        self.assertIn("[peripheral]", out)
        self.assertIn("command_block_enabled", out)
        self.assertNotIn('action = "allow"\n\n\t[[http.rules]]\n\t\thost = "*"', out)

    def test_allowing_private_addresses_is_refused(self):
        bad = prepare_run.rewrite_http_rules(LIVE_STYLE).replace('host = "$private"\n\t\taction = "deny"', 'host = "$private"\n\t\taction = "allow"')
        self.assertFalse(prepare_run.rules_are_safe(bad))

    def test_allowing_everything_else_is_refused(self):
        bad = prepare_run.rewrite_http_rules(LIVE_STYLE)
        bad = bad[:bad.rindex('action = "deny"')] + 'action = "allow"' + bad[bad.rindex('action = "deny"') + len('action = "deny"'):]
        self.assertFalse(prepare_run.rules_are_safe(bad))

    def test_another_port_on_localhost_is_refused(self):
        bad = prepare_run.rewrite_http_rules(LIVE_STYLE).replace("port = 3000", "port = 8123")
        self.assertFalse(prepare_run.rules_are_safe(bad))

    def test_an_extra_allowed_host_is_refused(self):
        bad = prepare_run.rewrite_http_rules(LIVE_STYLE).replace(
            '[[http.rules]]\n\t\thost = "$private"', '[[http.rules]]\n\t\thost = "192.168.0.0/16"\n\t\taction = "allow"\n\n\t[[http.rules]]\n\t\thost = "$private"', 1)
        self.assertFalse(prepare_run.rules_are_safe(bad))

    def test_the_pin_reads_the_version_of_the_commit_it_pins(self):
        import run
        v = run.code_version("HEAD")
        self.assertRegex(v or "", r"^\d+\.\d+\.\d+$")

    def test_pin_refuses_anything_but_a_full_commit_id(self):
        import run
        for bad in ("master", "abc123", "x" * 40, ""):
            with self.assertRaises(SystemExit):
                run.pin("none", bad)

    def test_the_run_tool_has_every_command_its_cli_offers(self):
        import run
        for name in ("start", "stop", "pin", "relaunch", "launch", "bridge_post", "code_version"):
            self.assertTrue(callable(getattr(run, name, None)), name)

    def test_the_control_mod_in_another_mods_folder_is_refused(self):
        import tempfile
        import zipfile
        d = tempfile.mkdtemp()
        # by file name
        open(os.path.join(d, "t2control-0.1.0.jar"), "wb").write(b"not even a zip")
        with self.assertRaises(SystemExit) as cm:
            prepare_run.check_placement([d])
        self.assertIn("outside the test server", str(cm.exception))
        os.remove(os.path.join(d, "t2control-0.1.0.jar"))
        # by the mod id inside, under another name
        with zipfile.ZipFile(os.path.join(d, "renamed.jar"), "w") as z:
            z.writestr("META-INF/mods.toml", NL.join(['modLoader="javafml"', '[[mods]]', 'modId="t2control"', 'version="1"']))
        with self.assertRaises(SystemExit):
            prepare_run.check_placement([d])
        os.remove(os.path.join(d, "renamed.jar"))
        # an ordinary mod is fine, and so is a folder that does not exist
        with zipfile.ZipFile(os.path.join(d, "other.jar"), "w") as z:
            z.writestr("META-INF/mods.toml", NL.join(['modLoader="javafml"', '[[mods]]', 'modId="something_else"']))
        prepare_run.check_placement([d, os.path.join(d, "missing")])

    def test_the_user_instances_hold_no_control_mod_now(self):
        self.assertEqual(prepare_run.mod_found_outside(), [])

    def test_the_start_function_checks_before_starting(self):
        import phase0
        import tempfile
        run = tempfile.mkdtemp()
        cfg = os.path.join(run, "world", "serverconfig")
        os.makedirs(cfg)
        with open(os.path.join(cfg, "computercraft-server.toml"), "w") as f:
            f.write(LIVE_STYLE)
        with self.assertRaises(SystemExit) as cm:
            phase0.start(run)
        self.assertIn("unsafe HTTP rules", str(cm.exception))


class GpsHosts(unittest.TestCase):
    HOST = 'shell.run("gps","host", 322, 92, -2814)'
    SERVER_TEXT = "-- run the gps host command to test" + chr(10) + ("x = 1" + chr(10)) * 500       # the real server's startup.lua mentions "gps host" in a comment

    def test_only_the_exact_host_call_is_a_host(self):
        programs = {48: self.HOST, 49: 'shell.run("gps", "host", 322, 92,-2809)' + NL, 95: self.SERVER_TEXT, 3: "print('hi')"}
        self.assertEqual(control.Control.match_gps_hosts(programs, {95: "SERVER"}), [48, 49])

    def test_a_server_that_looks_like_a_host_is_refused_not_shut_down(self):
        # the refusal is the test: even a server whose whole startup.lua is the host call must never be returned
        with self.assertRaises(RuntimeError):
            control.Control.match_gps_hosts({95: self.HOST, 48: self.HOST}, {95: "SERVER"})

    def test_a_warehouse_or_a_turtle_with_a_host_program_is_refused(self):
        for role in ("WAREHOUSE", "MINER", "DELIVERY", "ADMIN"):
            with self.assertRaises(RuntimeError):
                control.Control.match_gps_hosts({7: self.HOST}, {7: role + NL})

    def test_text_that_merely_mentions_gps_host_is_not_a_host(self):
        self.assertEqual(control.Control.match_gps_hosts({95: self.SERVER_TEXT, 5: 'print("gps host")'}, {}), [])


class ChunkloaderActivity(unittest.TestCase):
    def test_last_seen_times_are_set_to_now_in_the_copy_only(self):
        import struct
        import tempfile
        marker = bytes([4, 0, 4]) + b"time"
        player = b"player"
        body = (bytes([10, 0, 0, 9, 0, 5]) + b"times" + bytes([10, 0, 0, 0, 2])
                + marker + struct.pack(">q", 1000) + bytes([11, 0, 6]) + player + bytes([0, 0, 0, 4]) + b"\x01" * 16 + b"\x00"
                + marker + struct.pack(">q", 2000) + bytes([11, 0, 6]) + player + bytes([0, 0, 0, 4]) + b"\x02" * 16 + b"\x00\x00")
        d = tempfile.mkdtemp()
        os.makedirs(os.path.join(d, "chunkloaders"))
        p = os.path.join(d, "chunkloaders", "active_players.nbt")
        with open(p, "wb") as f:
            f.write(body)
        n = prepare_run.refresh_chunkloader_activity(d, now_ms=123456789)
        self.assertEqual(n, 2)
        with open(p, "rb") as f:
            new = f.read()
        self.assertEqual(len(new), len(body))
        self.assertEqual(new.count(marker + struct.pack(">q", 123456789)), 2)
        self.assertNotIn(struct.pack(">q", 1000), new)
        self.assertEqual(prepare_run.refresh_chunkloader_activity(os.path.join(d, "nothing")), 0)


if __name__ == "__main__":
    unittest.main()
