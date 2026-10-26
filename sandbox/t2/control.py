"""T2 control verbs: what the simulator's `sim:` methods do, done to a running test server with real Minecraft commands.
Each verb is proven against a live run by sandbox/t2/prove_verbs.py; a verb Minecraft cannot do raises Unsupported
with the reason. Nothing is faked.

    c = Control("v-a")
    c.computers()                       # {id: {"on": bool, "pos": (x, y, z)}} from /computercraft dump
    c.read_disk(181, "startup.lua")     # plain file read under the run's world, without disturbing the computer
    c.set_fuel(182, 5000)               # /data modify block ... Fuel
    c.shutdown([48, 49]) / c.turn_on([48, 49]) / c.gps_down() / c.gps_up()
    c.tps_drop(5, seconds=20)           # server_lag / tps_drop: tick rate down for a while, then back
    c.server_crash() / c.world_restart()
    c.save_point("name") / c.restore_save_point("name")
"""
import json
import os
import re
import shutil
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(__file__))
import run as runmod  # noqa: E402
from rcon import Rcon  # noqa: E402


class Unsupported(Exception):
    """Minecraft offers no way to do this verb; the message says why."""


class Control:
    def __init__(self, run_id):
        self.run_id = run_id
        self.run = runmod.run_dir(run_id)
        self.world = os.path.join(self.run, "world")
        self.disks = os.path.join(self.world, "computercraft", "computer")
        self._rcon = None
        self._gps_hosts_down = None
        self._listener = None
        self._harvested = {}
        self._scheduled = []

    # -- plumbing -----------------------------------------------------------------------------------------------
    def rcon(self):
        if self._rcon is None:
            host, port, pw = open(os.path.join(self.run, "rcon.txt")).read().split()
            self._rcon = Rcon(host, int(port), pw, timeout=120)
        return self._rcon

    def command(self, text):
        try:
            return self.rcon().command(text)
        except (OSError, RuntimeError):
            self._rcon = None
            return self.rcon().command(text)

    def _pids(self):
        with open(runmod.pids_path(self.run)) as f:
            return json.load(f)

    # -- reading ------------------------------------------------------------------------------------------------
    def computers(self):
        out = {}
        for line in self.command("computercraft dump").splitlines():
            m = re.match(r"#(\d+)\s*\|\s*([YN])\s*\|\s*(-?\d+),\s*(-?\d+),\s*(-?\d+)", line)
            if m:
                out[int(m.group(1))] = {"on": m.group(2) == "Y", "pos": tuple(int(m.group(i)) for i in (3, 4, 5))}
        return out

    def read_disk(self, computer_id, path):
        """File contents (bytes) from a computer's disk folder; the computer is not touched."""
        with open(os.path.join(self.disks, str(computer_id), path), "rb") as f:
            return f.read()

    def list_disk(self, computer_id, path=""):
        return sorted(os.listdir(os.path.join(self.disks, str(computer_id), path)))

    def block_data(self, pos, path=""):
        x, y, z = pos
        return self.command(("data get block %d %d %d %s" % (x, y, z, path)).strip()).strip()

    # -- turtles ------------------------------------------------------------------------------------------------
    def _pos(self, computer_id):
        comps = self.computers()
        if computer_id not in comps:
            raise KeyError("no loaded computer #%d" % computer_id)
        return comps[computer_id]["pos"]

    def get_fuel(self, computer_id):
        m = re.search(r"(-?\d+)\s*$", self.block_data(self._pos(computer_id), "Fuel"))
        return int(m.group(1))

    def set_fuel(self, computer_id, level):
        x, y, z = self._pos(computer_id)
        out = self.command("data modify block %d %d %d Fuel set value %d" % (x, y, z, level))
        if "Modified" not in out and "Nothing changed" not in out:   # "Nothing changed": it already had this level
            raise RuntimeError(out)

    def get_slot(self, computer_id, slot):
        out = self.block_data(self._pos(computer_id), "Items[{Slot:%db}]" % slot)
        return out.split("data: ", 1)[-1] if "data:" in out else out

    def set_slot(self, computer_id, slot, item, count=1):
        """Puts a stack in a turtle's inventory slot (0-15) at the NBT level, replacing what was there."""
        x, y, z = self._pos(computer_id)
        self.clear_slot(computer_id, slot)
        out = self.command("data modify block %d %d %d Items append value {Slot:%db,id:\"%s\",Count:%db}" % (x, y, z, slot, item, count))
        if "Modified" not in out:
            raise RuntimeError(out)
        return self.get_slot(computer_id, slot)

    def clear_slot(self, computer_id, slot):
        """Empties a turtle slot. `data remove` on the item list does not empty it (the block entity keeps the old stack
        for a slot missing from the list), so the slot is overwritten with an empty stack, which is dropped when saved."""
        x, y, z = self._pos(computer_id)
        for _ in range(8):
            if "Found no elements" in self.block_data((x, y, z), "Items[{Slot:%db}]" % slot):
                return
            self.command('data modify block %d %d %d Items[{Slot:%db}] set value {Slot:%db,id:"minecraft:air",Count:0b}'
                         % (x, y, z, slot, slot))
        raise RuntimeError("slot %d of #%d would not clear" % (slot, computer_id))

    def free_spot(self, y=67, tall=2):
        """A position near the base where `tall` blocks above each other are air (for spawn_turtle / spawn_listener)."""
        for x in range(160, 200, 3):
            for z in range(-2790, -2750, 3):
                if all("Test passed" in self.command("execute if block %d %d %d air" % (x, y + k, z)) for k in range(tall)):
                    return (x, y, z)
        raise RuntimeError("no free spot found near the base")

    def role_of(self, computer_id):
        try:
            return self.read_disk(computer_id, "role.txt").decode("utf8", "replace").strip()
        except OSError:
            return None

    def spawn_turtle(self, x, y, z, role, fuel=50000, facing="north", donor=None, right=None, startup=None, items=None):
        """Places a new advanced turtle with a wireless modem at x, y, z (the spot must be air in a loaded chunk), gives it the
        code of an existing computer of the same role (the files at the top of the donor's disk; no state files) and turns
        it on. The fleet sees it register as a new node. Returns its computer id. `right` is a tool or peripheral upgrade for the
        right side (for example "minecraft:diamond_pickaxe"); `items` maps slot (0-15) to (item, count), set before the turtle starts; `startup` is a path of a Lua file to install as the new turtle's
        startup.lua in place of the donor's (a probe program; the turtle is then not a fleet node)."""
        before = set(self.computers())
        right_nbt = ',RightUpgrade:"%s"' % right if right else ""
        out = self.command('setblock %d %d %d computercraft:turtle_advanced[facing=%s]{LeftUpgrade:"computercraft:wireless_modem_advanced",'
                           'LeftUpgradeNbt:{active:1b},Fuel:%d%s}' % (x, y, z, facing, fuel, right_nbt))
        if "Changed the block" not in out:
            raise RuntimeError(out)
        new = None
        for _ in range(20):
            added = set(self.computers()) - before
            if added:
                new = added.pop()
                break
            time.sleep(1)
        if new is None:
            raise RuntimeError("the new turtle never appeared in the computer list")
        if donor is None:
            donor = next((int(d) for d in sorted(os.listdir(self.disks), key=int) if d.isdigit() and self.role_of(int(d)) == role
                          and int(d) != new), None)
        if donor is None:
            raise RuntimeError("no computer with role %s to copy the code from" % role)
        dest = os.path.join(self.disks, str(new))
        os.makedirs(dest, exist_ok=True)
        for name in os.listdir(os.path.join(self.disks, str(donor))):
            src = os.path.join(self.disks, str(donor), name)
            if os.path.isfile(src) and not name.endswith((".dat", ".log", ".json")) and name not in ("update_failed.txt", "update_ref.txt"):
                shutil.copy(src, os.path.join(dest, name))
        if startup:
            shutil.copy(startup, os.path.join(dest, "startup.lua"))
        for slot, (item, count) in (items or {}).items():
            self.set_slot(new, slot, item, count)    # before it is turned on, so a program starts with them
        self.turn_on([new])
        return new

    def spawn_computer(self, x, y, z, startup, files=None, modem=True):
        """An advanced computer at x, y, z (and a wireless modem on top when `modem`, facing=down), running the Lua file `startup`
        as its startup.lua; `files` maps names to text written beside it. The spot and the block above must be air in a loaded
        chunk. Returns the computer id (placing it with {On:1b} is what gives it an id; it is restarted after its files are in)."""
        before = set(self.computers())
        out = self.command("setblock %d %d %d computercraft:computer_advanced[facing=north]{On:1b}" % (x, y, z))
        if "Changed the block" not in out:
            raise RuntimeError(out)
        if modem:
            out = self.command("setblock %d %d %d computercraft:wireless_modem_advanced[facing=down]" % (x, y + 1, z))
            if "Changed the block" not in out:
                raise RuntimeError(out)
        new = None
        for _ in range(20):
            added = set(self.computers()) - before
            if added:
                new = added.pop()
                break
            time.sleep(1)
        if new is None:
            raise RuntimeError("the computer never appeared in the computer list")
        dest = os.path.join(self.disks, str(new))
        os.makedirs(dest, exist_ok=True)
        for name, text in (files or {}).items():
            with open(os.path.join(dest, name), "w") as f:
                f.write(text)
        shutil.copy(startup, os.path.join(dest, "startup.lua"))
        self.shutdown([new])
        time.sleep(2)
        self.turn_on([new])
        return new

    def spawn_listener(self, x, y, z, channels=None):
        """RETIRED by the control mod's radio log (radio_log("on"), t2_lines("radio")) now that the mod exists; kept for runs without it.
        A radio listener: an advanced computer at x, y, z with a wireless modem on top, running sandbox/t2/lua/radio_log.lua,
        which logs every message on `channels` (default 1-5 and the private channel 1000+id of every computer now loaded,
        at most 128 channels). The spot and the block above it must be air in a loaded chunk. Returns the computer id."""
        before = set(self.computers())
        out = self.command("setblock %d %d %d computercraft:computer_advanced[facing=north]{On:1b}" % (x, y, z))   # On:1b is what gives it an id
        if "Changed the block" not in out:
            raise RuntimeError(out)
        out = self.command("setblock %d %d %d computercraft:wireless_modem_advanced[facing=down]" % (x, y + 1, z))
        if "Changed the block" not in out:
            raise RuntimeError(out)
        new = None
        for _ in range(20):
            added = set(self.computers()) - before
            if added:
                new = added.pop()
                break
            time.sleep(1)
        if new is None:
            raise RuntimeError("the listener computer never appeared in the computer list")
        if channels is None:
            ids = sorted(self.computers())
            channels = [1, 2, 3, 4, 5] + [1000 + i for i in ids if i != new][:123]
        dest = os.path.join(self.disks, str(new))
        os.makedirs(dest, exist_ok=True)
        with open(os.path.join(dest, "channels.txt"), "w") as f:
            f.write(chr(10).join(str(ch) for ch in channels[:128]) + chr(10))
        shutil.copy(os.path.join(os.path.dirname(__file__), "lua", "radio_log.lua"), os.path.join(dest, "startup.lua"))
        self.shutdown([new])
        time.sleep(2)
        self.turn_on([new])
        self._listener = new
        self._harvested = {}
        return new

    def harvest_radio(self, listener=None):
        """Copies the listener's segment files into <run>/radio/ (growing ones are re-copied) and returns the lines heard so far."""
        listener = listener or self._listener
        out_dir = os.path.join(self.run, "radio", str(listener))
        os.makedirs(out_dir, exist_ok=True)
        for name in self.list_disk(listener):
            if name.startswith("radio.") and name.endswith(".log"):
                shutil.copy(os.path.join(self.disks, str(listener), name), os.path.join(out_dir, name))
        lines = []
        for name in sorted(os.listdir(out_dir), key=lambda n: int(n.split(".")[1])):
            with open(os.path.join(out_dir, name), encoding="utf8", errors="replace") as f:
                lines += [l.rstrip(chr(10)) for l in f if not l.startswith("#")]
        return lines

    # -- computers on and off -----------------------------------------------------------------------------------
    def shutdown(self, ids):
        for i in ids:
            self.command("computercraft shutdown #%d" % i)

    def turn_on(self, ids):
        for i in ids:
            self.command("computercraft turn-on #%d" % i)

    # A GPS host's whole program is the one call `shell.run("gps", "host", x, y, z)` (the fleet's own host computers: the repo's gps_host.lua says
    # so). Anything else is NOT a host, whatever words it contains: the central server's startup.lua mentions "gps host" in a comment (GPS 2), and
    # a text match once shut the server down (gps2-1x, 2026-10-22).
    GPS_HOST_PROGRAM = re.compile(r'^\s*shell\.run\(\s*"gps"\s*,\s*"host"\s*,\s*-?\d+\s*,\s*-?\d+\s*,\s*-?\d+\s*\)\s*$')
    NEVER_A_HOST_ROLES = ("SERVER", "WAREHOUSE", "ADMIN", "DELIVERY", "SUPPORT", "MINER", "LOADER")

    @staticmethod
    def match_gps_hosts(programs, roles):
        """programs: {computer id: startup.lua text}; roles: {computer id: role.txt text or None}. Returns the sorted ids that are GPS hosts: their
        startup.lua is exactly the host call. Raises (and returns nothing) if that set would ever include a computer with a fleet role (the
        central server, the warehouse, a turtle...): a host never has one, so a match on such a computer means the match is wrong."""
        ids = sorted(i for i, text in programs.items() if Control.GPS_HOST_PROGRAM.match(text.strip()))
        bad = [i for i in ids if (roles.get(i) or "").strip().upper() in Control.NEVER_A_HOST_ROLES]
        if bad:
            raise RuntimeError("refusing: computers %s would be treated as GPS hosts but have a fleet role (%s)"
                               % (bad, ", ".join("#%d=%s" % (i, (roles.get(i) or "").strip()) for i in bad)))
        return ids

    def gps_hosts(self):
        """Computers whose disk runs the GPS host program (found by reading disks, not by guessing ids); see match_gps_hosts."""
        programs, roles = {}, {}
        for d in os.listdir(self.disks):
            try:
                i = int(d)
                programs[i] = self.read_disk(i, "startup.lua").decode("utf8", "replace")
            except (OSError, ValueError):
                continue
            roles[i] = self.role_of(i)
        return self.match_gps_hosts(programs, roles)

    def gps_down(self, hosts=None):
        hosts = hosts or self.gps_hosts()
        for i in hosts:
            if (self.role_of(i) or "").strip().upper() in self.NEVER_A_HOST_ROLES:
                raise RuntimeError("refusing to shut down #%d as a GPS host: its role is %s" % (i, self.role_of(i)))
        self._gps_hosts_down = hosts
        self.shutdown(hosts)
        return hosts

    def gps_up(self):
        self.turn_on(self._gps_hosts_down or self.gps_hosts())

    # -- the server itself --------------------------------------------------------------------------------------
    def tick_rate(self, rate):
        self.command("tickrate %d" % rate)

    def tps_drop(self, rate, seconds):
        """server_lag / tps_drop: the tick rate goes down to `rate` for `seconds` (real seconds), then back to 20."""
        self.tick_rate(rate)
        time.sleep(seconds)
        self.tick_rate(20)

    def _wait_dead(self):
        pid = self._pids()["server"]
        for _ in range(90):
            if not runmod.alive(pid):
                return
            time.sleep(2)
        subprocess.run(["taskkill", "/F", "/PID", str(pid)], capture_output=True)

    def server_crash(self):
        """Kills the Minecraft process (no save). The bridge keeps running. Follow with restart_after_crash()."""
        subprocess.run(["taskkill", "/F", "/PID", str(self._pids()["server"])], capture_output=True)
        self._wait_dead()
        self._rcon = None

    def restart_after_crash(self):
        return runmod.relaunch(self.run_id)

    def world_restart(self):
        """A clean stop (the world is saved) and a start on the same run folder."""
        try:
            self.command("tickrate 20")
            self.command("stop")
        except Exception:
            pass
        self._rcon = None
        self._wait_dead()
        return runmod.relaunch(self.run_id)

    # -- save points --------------------------------------------------------------------------------------------
    def save_point(self, name):
        """save-all, then a copy of the world folder under <run>/savepoints/<name>."""
        dest = os.path.join(self.run, "savepoints", name)
        if os.path.exists(dest):
            raise FileExistsError(dest)
        self.command("save-off")
        try:
            self.command("save-all flush")
            shutil.copytree(self.world, dest, ignore=shutil.ignore_patterns("session.lock"))
        finally:
            self.command("save-on")
        return dest

    def restore_save_point(self, name):
        """Stops the server, puts the saved world back in place of the current one, starts again."""
        src = os.path.join(self.run, "savepoints", name)
        if not os.path.isdir(src):
            raise FileNotFoundError(src)
        try:
            self.command("tickrate 20")
            self.command("stop")
        except Exception:
            pass
        self._rcon = None
        self._wait_dead()
        shutil.rmtree(self.world)
        shutil.copytree(src, self.world)
        return runmod.relaunch(self.run_id)

    # -- the control mod (sandbox/t2mod): /t2 commands and the files it writes under <run>/t2control/ ------------------------------
    def t2(self, text):
        """One /t2 command; returns the reply (one line of JSON, as a dict)."""
        reply = self.command("t2 " + text).strip()
        try:
            return json.loads(reply)
        except ValueError:
            raise RuntimeError("t2 %s -> %r" % (text, reply))

    def radio_log(self, state="on"):
        return self.t2("radio log " + state)

    def events_log(self, state="on"):
        return self.t2("events log " + state)

    def t2_status(self):
        return self.t2("status")

    def t2_lines(self, name):
        """The lines of <run>/t2control/<name>.jsonl as dicts (name: radio, events, interventions)."""
        path = os.path.join(self.run, "t2control", name + ".jsonl")
        out = []
        if os.path.exists(path):
            with open(path, encoding="utf8") as f:
                for line in f:
                    line = line.strip()
                    if line:
                        out.append(json.loads(line))
        return out

    # -- radio faults: the same names and arguments as the simulator's sim:radio_loss / sim:radio_latency (times in game ms) ----
    def radio_loss(self, t, dur, rate, channel=None, to=None, seed=None):
        """Loses a share `rate` (0..1) of the radio messages that would reach a program, for `dur` game ms starting `t` game ms after the
        scenario began (t=0: now). Optional channel and receiver computer id. Returns the reply (seed and expiry tick)."""
        opts = ("channel %d " % channel if channel is not None else "") + ("to %d " % to if to is not None else "") + ("seed %d" % seed if seed is not None else "")
        return self._at(t, lambda: self.t2(("radio loss %s %d %s" % (rate, max(1, -(-int(dur) // 1000)), opts)).strip()))

    def radio_latency(self, t, dur, ms, channel=None, max_ms=None, seed=None):
        """Delays by `ms` game ms (or a range ms..max_ms) the radio messages that would reach a program, for `dur` game ms from `t`."""
        opts = ("channel %d " % channel if channel is not None else "") + ("seed %d" % seed if seed is not None else "")
        return self._at(t, lambda: self.t2(("radio latency %d %d %d %s" % (ms, max_ms if max_ms is not None else ms, max(1, -(-int(dur) // 1000)), opts)).strip()))

    def radio_clear(self):
        return self.t2("radio clear")

    def _at(self, t, fn):
        """Runs now when t is 0; otherwise the scenario runner's polling loop runs it when that game time is reached."""
        if not t:
            return fn()
        self._scheduled.append((t, fn))
        return {"scheduled_for_game_ms": t}

    def run_due(self, game_ms):
        """Called by the scenario runner while it waits: starts the scheduled faults that are due."""
        due = [x for x in self._scheduled if x[0] <= game_ms]
        self._scheduled = [x for x in self._scheduled if x[0] > game_ms]
        for _, fn in due:
            fn()

    # -- chunk loading ------------------------------------------------------------------------------------------
    def chunk_loaders(self):
        """The chunk-loader turtles whose computers are loaded right now: [{computer, chunk_x, chunk_z, uuid}] (control mod)."""
        return self.t2("chunk list")["loaders"]

    def chunk_unload(self, t=0, area=None, dur=60000, computer=None):
        """Unloads chunks for `dur` game ms from `t` (control mod, M3); their computers shut down and, when the time is up, the tickets are
        put back and the computers boot again. `area=(x1, z1, x2, z2)` in blocks (the simulator's argument) releases EVERY Forge chunk
        ticket on those chunks, whatever mod holds it (Advanced Peripherals loaders, the Chunk Loaders mod, ...) and refuses new ones
        meanwhile. `computer=<id>` releases only that one Advanced Peripherals loader's own ticket. Returns the replies."""
        seconds = max(1, -(-int(dur) // 1000))

        def go():
            if computer is not None:
                return [self.t2("chunk unload %d %d" % (computer, seconds))]
            if area is None:
                raise ValueError("chunk_unload needs an area (x1, z1, x2, z2) or a computer id")
            x1, z1, x2, z2 = area
            return [self.t2("chunk unload area %d %d %d %d %d" % (x1, z1, x2, z2, seconds))]
        return self._at(t, go)

    # -- turtle controls through the control mod (M4) ----------------------------------------------------------
    def turtle_move(self, computer_id, x, y, z, facing=None):
        """Moves a turtle to x, y, z through the call a turtle uses to move itself: the computer stays on and knows where it is.
        `facing` is n, e, s or w (optional). Needs the control mod; `teleport` is the older /clone way."""
        return self.t2(("turtle move %d %d %d %d %s" % (computer_id, x, y, z, facing or "")).strip())

    def turtle_save(self, computer_id, name):
        """Saves a turtle (position, facing, inventory, fuel, upgrades) and its computer's disk folder together, under `name`."""
        return self.t2("turtle save %d %s" % (computer_id, name))

    def turtle_restore(self, name):
        """Puts a saved turtle back as it was (shuts it down, moves it back, restores its data and disk folder, turns it on)."""
        return self.t2("turtle restore %s" % name)

    # -- peripheral faults through the control mod (M5) -----------------------------------------------------------
    def peripheral_stall(self, t, dur, peripheral_type, extra_ms):
        """Makes every call to a peripheral of this TYPE (the name a program finds it by, such as rsBridge) take `extra_ms` longer, for
        `dur` game ms from `t`. The extra time passes on the computer's own thread; the server tick is not touched."""
        return self._at(t, lambda: self.t2("peripheral stall %s %d %d" % (peripheral_type, extra_ms, max(1, -(-int(dur) // 1000)))))

    def peripheral_fail(self, t, dur, peripheral_type):
        """Makes every call to a peripheral of this TYPE raise an error, for `dur` game ms from `t`."""
        return self._at(t, lambda: self.t2("peripheral fail %s %d" % (peripheral_type, max(1, -(-int(dur) // 1000)))))

    def peripheral_clear(self):
        return self.t2("peripheral clear")

    def rs_stall(self, t, dur, seconds):
        """The simulator's rs_stall: the Refined Storage bridge's calls (type rsBridge) take `seconds` longer, for `dur` game ms from `t`."""
        return self.peripheral_stall(t, dur, "rsBridge", int(seconds * 1000))

    def rs_offline(self, t, dur):
        """The simulator's rs_offline: every call to the Refined Storage bridge raises an error, for `dur` game ms from `t`."""
        return self.peripheral_fail(t, dur, "rsBridge")

    # -- pause and step through the control mod (M6) ------------------------------------------------------------
    def pause(self):
        """Stops the server running game ticks: no world, no computers, no timers. Console commands still work. The real clock keeps going,
        so anything a program measures with os.epoch (the fleet's own deadlines) runs on while the game stands still."""
        return self.t2("pause")

    def resume(self):
        return self.t2("resume")

    def step(self, ticks):
        """Lets exactly `ticks` more game ticks run, then pauses again (pauses first if the server was running)."""
        return self.t2("step %d" % ticks)

    # -- verbs Minecraft cannot do ------------------------------------------------------------------------------
    def teleport(self, computer_id, x, y, z):
        """Moves a turtle's block (and everything in it) to x, y, z with /clone ... replace move. The computer stays on and
        is not restarted (proved in prove_verbs.py); its own idea of where it is stays stale until it next asks GPS. The
        destination should be air in a loaded chunk; whatever is there is replaced."""
        sx, sy, sz = self._pos(computer_id)
        out = self.command("clone %d %d %d %d %d %d %d %d %d replace move" % (sx, sy, sz, sx, sy, sz, x, y, z))
        if "Successfully" not in out:
            raise RuntimeError(out)
        return (sx, sy, sz)
