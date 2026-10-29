"""W3 card "A deploy within 5 minutes of a push installs stale files (GitHub raw cache)", the open half (fix 1c32775),
layer 2. Same story as sandbox/scenarios/w3_unpinned_deploy.lua, on the real GitHub. The bridge's /self-update sends
UPDATE_ALL with no commit; the server now asks GitHub's API which commit master is and pins the deploy to it. Here:
master's commit is read from GitHub (git ls-remote), an UPDATE_ALL with no params is sent, and the fleet must be sent
that commit ('UPDATE_ALL: sent to ... pinned to <it>'), the server and every registered miner must then hold its files
byte for byte (the harness's own pin check), and nothing may say 'UPDATE FAILED' or 'could not be pinned'.
Pin the run to master's head (or any commit carrying 1c32775); do not push to master while it runs. 1x, ~10 game min."""
import subprocess

import __main__

NAME = "w3_unpinned_deploy"


def steps(ctx):
    ctx.wait_registered(14, 300)
    out = subprocess.run(["git", "-C", __main__.REPO, "ls-remote", "origin", "refs/heads/master"],
                         capture_output=True, text=True).stdout.split()
    head = out[0] if out else None
    ctx.expect(head is not None and len(head) == 40, "master's commit on GitHub (%s)" % head)
    if not head:
        return
    f0 = len(ctx.log_lines("UPDATE FAILED")) + len(ctx.log_lines("could not be pinned"))
    n0 = len(ctx.log_lines("Central server online"))
    ctx.dispatch("UPDATE_ALL", {})                                       # THE TEST: a deploy naming no commit
    back = ctx.wait_until(lambda: len(ctx.log_lines("Central server online")) > n0, 600)
    ctx.expect(bool(back), "the server updated and came back")
    sent = ctx.wait_until(lambda: [l for l in ctx.log_lines("UPDATE_ALL: sent to") if head in l], 600)
    ctx.expect(bool(sent), "the fleet was sent master's commit (%s)" % (sent[0][-120:] if sent else "no 'pinned to %s' line" % head[:10]))
    __main__.settle_after_pin(ctx)
    __main__.verify_pinned_bytes(ctx, head)
    bad = len(ctx.log_lines("UPDATE FAILED")) + len(ctx.log_lines("could not be pinned")) - f0
    ctx.expect(bad == 0, "no 'UPDATE FAILED' and no 'could not be pinned' (%d)" % bad)
