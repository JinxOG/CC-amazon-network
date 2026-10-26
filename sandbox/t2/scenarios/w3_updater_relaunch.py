"""W3 card "The updater restarts when its own file list changes" (1.9.94), layer 2 ONLY (spec owner, 2026-10-26: the
simulator does not model the OTA). The fleet starts pinned to bfc2770 (1.9.151). The scenario sends the real deploy,
UPDATE_ALL pinned to 69a2938 on the THROWAWAY branch w3-throwaway-relaunch (never merged, never deployed live), which:
  - adds w3_noop.lua to the updater's COMMON list,
  - makes turtle_base.lua hard-require it (the 2026-09-10 outage shape: the old updater, running the old list, shipped
    a require without its file and every turtle failed to boot),
  - names itself 1.9.151-relaunch-test.
The OLD updater (bfc2770's) must notice its own file changed, relaunch with the new list and ship w3_noop.lua.
Pass: every turtle that was registered boots 'v1.9.151-relaunch-test', 0 'UPDATE FAILED', and w3_noop.lua is on a turtle's
disk. Afterwards SANDBOX re-pins the fleet to bfc2770 and W3 deletes the branch. 1x, ~10 game minutes."""
NAME = "w3_updater_relaunch"
THROWAWAY = "69a2938785be27e0bf291a9206e7212f7fe946fe"
VERSION = "v1.9.151-relaunch-test"


def steps(ctx):
    ctx.wait_registered(14, 300)
    st = ctx.state()
    nodes = sorted(n for n, t in (st.get("turtles") or {}).items() if n.startswith("node_") and t.get("role") != "LOADER")
    ctx.note("registered before the deploy: %d (%s)" % (len(nodes), " ".join(nodes)))
    failed0 = len(ctx.log_lines("UPDATE FAILED"))
    ctx.dispatch("UPDATE_ALL", {"ref": THROWAWAY})                      # THE TEST: the real deploy path

    def booted():
        return sorted(set(n for n in nodes for l in ctx.log_lines(VERSION + " booting") if ("=== %s " % n) in l))

    ok = ctx.wait_until(lambda: len(booted()) >= len(nodes), 900)
    got = booted()
    ctx.expect(bool(ok), "every registered turtle booted %s (%d of %d; missing %s)"
               % (VERSION, len(got), len(nodes), " ".join(n for n in nodes if n not in got)))
    ctx.expect(len(ctx.log_lines("UPDATE FAILED")) == failed0, "no UPDATE FAILED")
    ctx.expect(bool(ctx.log_lines("Restarted into " + VERSION.lstrip("v"))) or bool(ctx.log_lines("online " + VERSION)),
               "the dispatch server came up on the throwaway too")
    sample = int(nodes[0].replace("node_", "")) if nodes else None
    has = False
    if sample is not None:
        try:
            has = b"ok = true" in ctx.control.read_disk(sample, "w3_noop.lua")
        except OSError:
            has = False
    ctx.expect(has, "w3_noop.lua (the module the relaunch must ship) is on %s's disk" % (nodes[0] if nodes else "?"))
