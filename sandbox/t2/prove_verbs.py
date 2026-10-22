"""Proves each T2 control verb against a LIVE run, one at a time, and says what it saw.

    python sandbox/t2/run.py start <run-id>          # fleet registered, idle
    python sandbox/t2/prove_verbs.py <run-id> [verb-name-part ...]   # writes <run>/VERBS.json and prints a table

Every verb is shown to change something real and to have the effect that the simulator's verb has. A verb that fails is
reported as FAILED with the evidence; nothing is skipped silently. Run on a run that nobody needs afterwards: the last
steps crash the server, restore a save point and unload the chunks.
"""
import json
import os
import sys
import time

sys.path.insert(0, os.path.dirname(__file__))
import control as ctl  # noqa: E402
import run as runmod  # noqa: E402

results = []


ONLY = sys.argv[2:]


def prove(name, fn):
    if ONLY and not any(o in name for o in ONLY):
        return
    t0 = time.time()
    try:
        evidence = fn()
        results.append({"verb": name, "result": "PROVED", "evidence": evidence, "seconds": round(time.time() - t0)})
    except ctl.Unsupported as e:
        results.append({"verb": name, "result": "UNSUPPORTED (raises, as designed)", "evidence": str(e), "seconds": 0})
    except Exception as e:  # noqa: BLE001
        results.append({"verb": name, "result": "FAILED", "evidence": "%s: %s" % (type(e).__name__, e), "seconds": round(time.time() - t0)})
    print(results[-1]["result"], "-", name, "-", str(results[-1]["evidence"])[:200], flush=True)


def wait_for(cond, seconds, every=3):
    t0 = time.time()
    while time.time() - t0 < seconds:
        v = cond()
        if v:
            return v
        time.sleep(every)
    return None


def bridge_fuel(node):
    d = json.loads(runmod.bridge_get("/state"))
    t = d["turtles"].get(node)
    return t and t.get("fuel")


def main():
    c = ctl.Control(sys.argv[1])
    run = c.run

    def v_dump():
        comps = c.computers()
        assert len(comps) >= 25, "only %d computers listed" % len(comps)
        assert comps[181]["on"], "#181 not on"
        return "%d computers listed, %d on, #181 at %s" % (len(comps), sum(1 for v in comps.values() if v["on"]), comps[181]["pos"])
    prove("computers (dump)", v_dump)

    def v_disk():
        data = c.read_disk(181, "startup.lua")
        names = c.list_disk(181)
        assert len(data) > 100 and "protocol.lua" in names
        again = c.computers()[181]["on"]
        assert again, "reading the disk switched it off"
        return "read %d bytes of #181 startup.lua; %d files in its folder; still on" % (len(data), len(names))
    prove("read_disk / list_disk", v_disk)

    def v_fuel():
        c.set_fuel(182, 4321)
        assert c.get_fuel(182) == 4321
        seen = wait_for(lambda: bridge_fuel("node_182") == 4321, 40)
        assert seen, "the bridge never showed fuel 4321 for node_182 (saw %s)" % bridge_fuel("node_182")
        return "set #182 fuel 4321; NBT reads 4321; the fleet's own heartbeat reports 4321 to the bridge, no reboot"
    prove("set_fuel", v_fuel)

    def v_slot():
        got = c.set_slot(182, 5, "minecraft:coal", 7)
        assert "minecraft:coal" in got and "7b" in got, got
        c.clear_slot(182, 5)
        assert "coal" not in c.get_slot(182, 5)
        return "slot 5 of #182 set to 7 coal and cleared (NBT level: the block entity inventory)"
    prove("set_slot / clear_slot", v_slot)

    def v_power():
        c.shutdown([143])
        off = wait_for(lambda: c.computers()[143]["on"] is False, 20)
        assert off, "#143 did not go off"
        c.turn_on([143])
        on = wait_for(lambda: c.computers()[143]["on"] is True, 20)
        assert on, "#143 did not come back"
        return "#143 shut down (dump N) and turned on again (dump Y)"
    prove("shutdown / turn_on", v_power)

    def v_gps():
        hosts = c.gps_hosts()
        assert len(hosts) >= 4, "found GPS hosts %s" % hosts
        c.gps_down()
        assert wait_for(lambda: all(not c.computers()[h]["on"] for h in hosts), 20), "not all hosts went off"
        c.gps_up()
        assert wait_for(lambda: all(c.computers()[h]["on"] for h in hosts), 30), "not all hosts came back"
        return "GPS hosts %s found from their disks, shut down, and turned on again" % hosts
    prove("gps_down / gps_up", v_gps)

    def v_lag():
        c.tick_rate(5)
        time.sleep(15)
        g0, t0 = int(__import__("re").search(r"(\d+)", c.command("time query gametime")).group(1)), time.time()
        time.sleep(30)
        g1, t1 = int(__import__("re").search(r"(\d+)", c.command("time query gametime")).group(1)), time.time()
        c.tick_rate(20)
        rate = (g1 - g0) / (t1 - t0)
        assert 3.5 <= rate <= 6.5, "ticks per second %.2f" % rate
        return "tick rate 5: the game ran %.2f ticks per real second for 30 s, then back to 20" % rate
    prove("tps_drop / server_lag", v_lag)

    # chunk_unload is a control-mod verb: proved in prove_mod.py m3, not here

    def v_teleport():
        import glob
        def inits(node):
            n = 0
            for f in glob.glob(os.path.join(run, "bridge", "logs", "*.txt")):
                n += sum(1 for line in open(f, encoding="utf8", errors="replace") if node + "#" in line and "[INIT] Protected slot 3" in line)
            return n
        comps = c.computers()
        x, y, z = comps[141]["pos"]
        fuel = c.get_fuel(141)
        n0 = inits("node_141")
        c.teleport(141, x, y, z - 6)
        assert wait_for(lambda: c.computers().get(141, {}).get("pos") == (x, y, z - 6), 20), "dump shows %s" % c.computers().get(141)
        time.sleep(10)
        assert c.computers()[141]["on"], "the computer went off"
        assert inits("node_141") == n0, "the turtle restarted (new INIT lines)"
        fuel_after = c.get_fuel(141)   # not asserted: the turtle may act on its stale position and spend fuel
        c.teleport(141, x, y, z)
        return "#141 moved from %s to %s with /clone move: dump shows the new position, computer still on, no restart (no new INIT lines); fuel %d -> %d (the turtle reacts to the move); moved back" % ((x, y, z), (x, y, z - 6), fuel, fuel_after)
    prove("teleport", v_teleport)

    def v_spawn():
        x, y, z = c.free_spot()
        new = c.spawn_turtle(x, y, z, "SUPPORT")
        node = "node_%d" % new
        ok = wait_for(lambda: node in json.loads(runmod.bridge_get("/state"))["turtles"], 90)
        assert ok, "%s never registered with the bridge" % node
        t = json.loads(runmod.bridge_get("/state"))["turtles"][node]
        assert t.get("role") == "SUPPORT"
        return "spawned computer #%d at %s with SUPPORT code copied from a donor; %s registered with the bridge as %s (fuel %s)" % (new, (x, y, z), node, t.get("role"), t.get("fuel"))
    prove("spawn_turtle", v_spawn)

    def v_listener():
        x, y, z = c.free_spot(tall=2)
        lid = c.spawn_listener(x, y, z)
        lines = []
        def heard():
            lines[:] = c.harvest_radio(lid)
            return sum(1 for l in lines if '"HEARTBEAT"' in l) >= 10
        assert wait_for(heard, 120, every=10), "heard only %d lines" % len(lines)
        acks = sum(1 for l in lines if "HEARTBEAT_ACK" in l)
        return "listener #%d at %s: %d messages heard (%d heartbeats, %d acks), logged with time, channel and text; segments harvested to <run>/radio/<id>/" % (lid, (x, y, z), len(lines), sum(1 for l in lines if '"HEARTBEAT"' in l), acks)
    prove("radio listener", v_listener)

    def v_save():
        c.set_fuel(182, 1234)
        dest = c.save_point("p%d" % int(time.time()))
        assert os.path.isdir(os.path.join(dest, "computercraft", "computer", "182"))
        c.set_fuel(182, 999)
        c.restore_save_point(os.path.basename(dest))
        assert wait_for(lambda: c.computers().get(182), 120)
        f = c.get_fuel(182)
        assert f == 1234, "after the restore #182 fuel is %s" % f
        return "save point taken with #182 fuel 1234, fuel changed to 999, restored: fuel 1234 again after a server restart"
    prove("save_point / restore_save_point (and world_restart)", v_save)

    def v_crash():
        before = sum(1 for _ in open(os.path.join(run, "bridge", "bridge.out"), errors="replace"))
        c.server_crash()
        assert not runmod.alive(c._pids()["server"]), "the process is still alive"
        c.restart_after_crash()
        assert wait_for(lambda: len(c.computers()) >= 25, 120), "computers did not come back"
        d = json.loads(runmod.bridge_get("/state"))
        online = sum(1 for t in d["turtles"].values() if t.get("online"))
        assert wait_for(lambda: sum(1 for t in json.loads(runmod.bridge_get("/state"))["turtles"].values() if t.get("online")) >= 10, 180), "turtles not back online"
        return "server process killed (no save), started again on the same folder; %d computers listed, turtles back online (bridge kept running)" % len(c.computers())
    prove("server_crash / restart_after_crash", v_crash)



    with open(os.path.join(run, "VERBS.json"), "w") as f:
        json.dump(results, f, indent=1)
    print("\n%-52s %s" % ("verb", "result"))
    for r in results:
        print("%-52s %s" % (r["verb"], r["result"]))


if __name__ == "__main__":
    main()
