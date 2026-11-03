"""W3 card "The server keeps its own disk tidy, and reports it (no in-game visits)" (db099c4 report, e2f8049 tidy and install,
171af0b stripped writes), layer 2. Same story as sandbox/scenarios/w3_disk_retention.lua and w3_stripped_fleet.lua, on the
real game. After the pin (the real update path), the dispatch computer's startup.lua must be the commit's server STRIPPED
(the runner's pinned-code check accepts either form; this one asks for the stripped form) and /state must carry the disk
report. Then the leftovers the tidy is for are planted straight into its disk folder -- the installer's old
central_server.lua, an interrupted save's .tmp, a .bak beside its live file, a 30 KB crash.log -- and the computer is
switched off and on, as a reboot would: the tidy runs at boot and must remove the first three, trim crash.log to its newest
8 KB, and leave every live file. Last, one mining job must go out and complete, so the stripped server is shown working end
to end. Pin the commit under test; --tickrate 200 is fine (the job is one sector)."""
import importlib.util
import os
import subprocess

import run as runmod  # noqa: E402  (sandbox/t2 is on the path: the runner put it there)

NAME = "w3_disk_tidy"
_spec = importlib.util.spec_from_file_location("w3_low_disk", os.path.join(os.path.dirname(os.path.abspath(__file__)), "w3_low_disk.py"))
_low = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_low)
server_computer = _low.server_computer                     # the RUNNING dispatch computer, not a stray SERVER disk

LIVE = ("startup.lua", "protocol.lua", "updater.lua", "cloudstore.lua", "jobs.dat")
CRASH_LINE = "[1788683956366 2026-09-06 01:39:16] server.run crashed: planted by w3_disk_tidy, line %05d\n"


def steps(ctx):
    ctx.wait_registered(14, 300)
    c = ctx.control
    sid = server_computer(ctx)
    ctx.expect(sid is not None, "found the dispatch computer (#%s)" % sid)
    if sid is None:
        return
    folder = os.path.join(c.disks, str(sid))
    on_disk = lambda: sorted(c.list_disk(sid))           # noqa: E731

    # 1. Stripped on disk, and reported.
    pin = getattr(ctx, "pin", None) or "HEAD"
    raw = subprocess.run(["git", "-C", runmod.REPO, "show", "%s:central_server.lua" % pin],
                         capture_output=True).stdout.replace(b"\r\n", b"\n")
    srv = c.read_disk(sid, "startup.lua").replace(b"\r\n", b"\n")
    comment_lines = sum(1 for line in srv.split(b"\n") if line.lstrip().startswith(b"--"))
    ctx.note("startup.lua on the dispatch computer: %d bytes (the commit's file is %d), %d comment lines" % (len(srv), len(raw), comment_lines))
    ctx.expect(raw and len(srv) < len(raw) * 0.7 and comment_lines < 5,
               "the server went to disk stripped (%d of %d bytes)" % (len(srv), len(raw)))
    ctx.expect(raw and srv.count(b"\n") == raw.count(b"\n"), "with its line breaks kept, so crash lines still match the repo")
    ctx.note("files at start: %s" % on_disk())
    if ctx.log_lines("Disk tidy: removed central_server.lua"):
        ctx.note("the boot after the pin already removed an installer's central_server.lua: %s" % ctx.log_lines("Disk tidy: removed central_server.lua")[-1])
    ctx.wait_game(20)
    rep = (ctx.state() or {}).get("disk")
    ctx.note("/state disk: %r" % rep)
    ok_rep = isinstance(rep, dict) and isinstance(rep.get("free"), (int, float)) and isinstance(rep.get("largest"), list)
    ctx.expect(ok_rep, "/state carries the disk report (free, files, largest)")
    if ok_rep:
        sizes = [e.get("size", 0) for e in rep["largest"]]
        ctx.expect(0 < len(sizes) <= 5 and sizes == sorted(sizes, reverse=True), "the largest files are listed, at most five, biggest first (%s)" % sizes)
        ctx.expect("startup.lua" in [e.get("name") for e in rep["largest"]], "and the server itself is among them")

    # 2. Leftovers planted, then a reboot.
    with open(os.path.join(folder, "central_server.lua"), "wb") as f:
        f.write(raw)
    with open(os.path.join(folder, "w3_plant.tmp"), "wb") as f:
        f.write(b"x" * 5000)
    with open(os.path.join(folder, "jobs.dat"), "rb") as f:
        jobs = f.read()
    with open(os.path.join(folder, "jobs.dat.bak"), "wb") as f:
        f.write(jobs)
    with open(os.path.join(folder, "crash.log"), "w", encoding="utf-8", newline="\n") as f:
        for i in range(30 * 1024 // len(CRASH_LINE % 0) + 1):
            f.write(CRASH_LINE % i)
    ctx.note("planted: central_server.lua (%d), w3_plant.tmp (5000), jobs.dat.bak (%d), crash.log (~30 KB)" % (len(raw), len(jobs)))
    n_online, n_freed = len(ctx.log_lines("Central server online")), len(ctx.log_lines("Disk tidy: freed"))
    c.shutdown([sid])                                                       # THE TEST: a reboot with leftovers on disk
    ctx.wait_game(5)
    c.turn_on([sid])
    back = ctx.wait_until(lambda: len(ctx.log_lines("Central server online")) > n_online, 600)
    ctx.expect(bool(back), "the dispatch computer booted again")
    freed = ctx.wait_until(lambda: len(ctx.log_lines("Disk tidy: freed")) > n_freed, 300)
    ctx.expect(bool(freed), "the boot's tidy ran and said what it freed (%s)" % (ctx.log_lines("Disk tidy: freed")[-1:] or "nothing"))
    for line in ctx.log_lines("Disk tidy: ")[-8:]:
        ctx.note("server: %s" % line)
    files = on_disk()
    ctx.note("files after the reboot: %s" % files)
    for name in ("central_server.lua", "w3_plant.tmp", "jobs.dat.bak"):
        ctx.expect(name not in files, "%s was removed" % name)
    crash = len(c.read_disk(sid, "crash.log")) if "crash.log" in files else 0
    ctx.expect(0 < crash <= 8192, "crash.log was trimmed to its newest 8 KB (%d bytes)" % crash)
    for name in LIVE:
        ctx.expect(name in files, "the live file %s is still there" % name)

    # 3. The stripped, tidied server still runs a job end to end.
    ctx.wait_registered(14, 600)
    n_disp = len(ctx.log_lines("Dispatched job_"))
    ctx.dispatch("ORDER_MINE", {"x1": 1984, "z1": -2624, "x2": 1984, "z2": -2624, "minerCount": 1})
    went = ctx.wait_until(lambda: len(ctx.log_lines("Dispatched job_")) > n_disp and ctx.log_lines("Dispatched job_")[-1], 600)
    ctx.expect(bool(went), "a mining job went out (%s)" % went)
    if not went:
        return
    job = "job_" + went.split("job_", 1)[1].split()[0]
    done = ctx.wait_until(lambda: ctx.log_lines("Job complete: " + job), 3 * 3600)
    ctx.expect(bool(done), "and completed (%s)" % (done[-1] if done else "no 'Job complete: %s'" % job))
