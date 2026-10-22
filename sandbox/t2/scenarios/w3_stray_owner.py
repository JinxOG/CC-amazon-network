"""W3 card "The server hands out sectors to a turtle that does not own the job" (fixes 9353f36 and the SECTOR_DONE refusal,
1.9.145 / 1.9.150; live on 1.9.151), layer 2.

The live case (2026-10-15) was two computers both labelled node_177, one still working a job the server had given to
the other. T2 cannot make one turtle silent both ways while it keeps running (radio loss filters by receiver only), so
this stages the live shape directly: a spawned computer speaks as an IDLE, docked miner and sends SECTOR_REQUEST three
times, then a SECTOR_DONE, for the job the server has given to the working miner.
Expected: every one refused ("refused: the job is <owner>'s"), the sender recalled, no "Assigned sector ... to <idle>",
no sector counted for it, and the owner's job unaffected and completed. Pin any commit at or after 1.9.150. 1x."""
import os
import re

NAME = "w3_stray_owner"
HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REPO = os.path.dirname(os.path.dirname(HERE))


def steps(ctx):
    ctx.wait_registered(14, 300)
    ctx.dispatch("ORDER_MINE", {"x1": 1920, "z1": -2624, "x2": 1984, "z2": -2624, "minerCount": 2})
    went = ctx.wait_until(lambda: ctx.log_lines("Dispatched job_"), 600)
    ctx.expect(bool(went), "the job was dispatched")
    if not went:
        return
    owner = went[0].split("-> ")[1].split()[0]
    job = re.search(r"Dispatched (job_\d+)", went[0]).group(1)
    mining = ctx.wait_until(lambda: [l for l in ctx.log_lines("Assigned sector (") if owner in l and "SURVEY" not in l], 3 * 3600)
    ctx.expect(bool(mining), "%s reached its mine phase" % owner)
    if not mining:
        return
    m = re.search(r"Assigned sector \((-?\d+),(-?\d+)\)", mining[0])
    sx, sz = int(m.group(1)), int(m.group(2))

    st = ctx.state()
    turtles = st.get("turtles") or {}                   # keyed by node id; the records carry no id field
    idle = sorted(nid for nid, t in turtles.items()
                  if nid != owner and t.get("status") == "IDLE" and t.get("role") == "MINER")
    ctx.expect(bool(idle), "an idle miner to speak as (%r)" % idle)
    if not idle:
        return
    stray = idle[0]
    with open(os.path.join(REPO, "protocol.lua"), encoding="utf-8") as f:
        proto_src = f.read()
    x, y, z = ctx.control.free_spot()
    cid = ctx.control.spawn_computer(x, y, z, os.path.join(HERE, "lua", "w3_stray.lua"),
                                     files={"protocol.lua": proto_src, "stray.txt": "%s\n%s\n%d\n%d\n" % (stray, job, sx, sz)})
    ctx.note("computer #%d speaks as %s for %s (owned by %s), sector %d,%d" % (cid, stray, job, owner, sx, sz))
    ctx.wait_game(40)

    refused = [l for l in ctx.log_lines("refused: the job is") if stray in l]
    kinds = set(k for k in ("SECTOR_REQUEST", "SECTOR_DONE") for l in refused if k in l)
    ctx.note("refusals: %d (%s)" % (len(refused), ", ".join(sorted(kinds))))
    ctx.expect(len(refused) >= 4, "all three requests and the completion were refused (%d)" % len(refused))
    ctx.expect(kinds == {"SECTOR_REQUEST", "SECTOR_DONE"}, "both kinds refused (%s)" % sorted(kinds))
    ctx.expect(not [l for l in ctx.log_lines("Assigned sector (") if stray in l], "no sector was assigned to %s" % stray)
    ctx.expect(not [l for l in ctx.log_lines("done by %s" % stray)], "no sector was counted as done by %s" % stray)
    ctx.control.shutdown([cid])

    done = ctx.wait_until(lambda: ctx.log_lines("Job complete: %s" % job), 6 * 3600)
    ctx.expect(bool(done), "the owner's job completed")
