"""W3, found auditing the stale-update card (fix 1ed13b4), layer 2. Same story as sandbox/scenarios/w3_failed_deploy_ref.lua.
The server wrote a deploy's commit as "the last deploy" (deploy_ref.txt) BEFORE its own update ran; when that update failed
it stayed on its old code, but from its next restart it named the failed commit, and a lagging turtle was sent code ahead
of its server. Here: UPDATE_ALL pinned to a commit that does not exist (every download 404s, so the server's own update
fails and it stays up), the server computer is restarted, and deploy_ref.txt must still name the pinned commit. Then a
miner is made to lag (its protocol.lua says 1.9.1, written into its disk folder) and rebooted: it must be queued for the
current release and come back on the server's version -- on the old code it is sent the missing commit, its update
fails, and it stays on 1.9.1. Pin 1ed13b4 (or later). 1x, ~15 game minutes."""
import os
import re

NAME = "w3_failed_deploy_ref"
BOGUS = "0" * 40


def server_computer(ctx):
    lines = ctx.log_lines("Central server online")
    if not lines:
        return None
    try:
        return int(lines[-1].rsplit("node_", 1)[1].split()[0])
    except (IndexError, ValueError):
        return None


def steps(ctx):
    ctx.wait_registered(14, 300)
    c = ctx.control
    sid = server_computer(ctx)
    ctx.expect(sid is not None, "found the dispatch computer (#%s)" % sid)
    if sid is None:
        return
    r0 = c.read_disk(sid, "deploy_ref.txt").decode().strip()
    ctx.expect(re.fullmatch(r"[0-9a-f]{40}", r0) is not None, "deploy_ref.txt names the pinned commit (%s)" % r0)

    f0 = len(ctx.log_lines("UPDATE FAILED"))
    ctx.dispatch("UPDATE_ALL", {"ref": BOGUS})                          # THE TEST: a deploy the server cannot install
    failed = ctx.wait_until(lambda: len(ctx.log_lines("UPDATE FAILED")) > f0, 600)
    ctx.expect(bool(failed), "the server's own update failed and it stayed up ('UPDATE FAILED')")
    if not failed:
        return
    ctx.wait_game(20)
    n0 = len(ctx.log_lines("Central server online"))
    c.shutdown([sid])                                                   # a later restart (the daily one)
    ctx.wait_game(3)
    c.turn_on([sid])
    ctx.expect(bool(ctx.wait_until(lambda: len(ctx.log_lines("Central server online")) > n0, 300)), "the server came back")
    r1 = c.read_disk(sid, "deploy_ref.txt").decode().strip()
    ctx.expect(r1 == r0, "deploy_ref.txt still names the commit the server runs (%s), not the one it failed to install (%s)"
               % (r0[:10], r1[:10]))

    ctx.wait_registered(14, 300)
    st = ctx.state()
    idle = sorted(n for n, t in (st.get("turtles") or {}).items() if t.get("role") == "MINER" and t.get("status") == "IDLE")
    ctx.expect(bool(idle), "an idle miner (%r)" % idle)
    if not idle:
        return
    node = idle[0]
    cid = int(node.replace("node_", ""))
    path = os.path.join(c.disks, str(cid), "protocol.lua")
    with open(path, "rb") as f:
        src = f.read().decode()
    with open(path, "wb") as f:                                         # the miner now lags: it says 1.9.1
        f.write(re.sub(r'proto\.VERSION = "[^"]*"', 'proto.VERSION = "1.9.1"', src, count=1).encode())
    q0 = len([l for l in ctx.log_lines("queued for the current release") if node in l])
    c.shutdown([cid])
    ctx.wait_game(3)
    c.turn_on([cid])
    queued = ctx.wait_until(lambda: len([l for l in ctx.log_lines("queued for the current release") if node in l]) > q0, 300)
    ctx.expect(bool(queued), "%s (1.9.1) was queued for the current release" % node)
    server_v = ((ctx.state() or {}).get("server") or {}).get("version")
    back = ctx.wait_until(lambda: ((ctx.state().get("turtles") or {}).get(node) or {}).get("version") not in (None, "1.9.1"), 600)
    v = ((ctx.state().get("turtles") or {}).get(node) or {}).get("version")
    ctx.note("%s came back on %r; the server reports %r" % (node, v, server_v))
    ctx.expect(bool(back) and v != "1.9.1", "%s updated off 1.9.1 from the commit its server runs (now %r)" % (node, v))
    bad = [l for l in ctx.log_lines("Pinned to commit " + BOGUS[:10]) if node in l]
    ctx.expect(not bad, "%s was never sent the commit the server failed to install (%d)" % (node, len(bad)))
