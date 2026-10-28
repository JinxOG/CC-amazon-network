"""W3 card "Warn about low server disk while there is still room" (fix 2ca13d6, live), layer 2. Same as
sandbox/scenarios/w3_low_disk.lua: a dummy file is written straight into the dispatch computer's disk folder until
/state diskFree reads about 340 KB (below the 350 KB warning), then about 290 KB (below the 300 KB floor). The server
checks once a minute: a WARN 'Disk low on the server computer' within 3 minutes, then an ERROR 'below the 300 KB floor'
within 3 minutes. The files are then removed and the warnings must stop. Pin bfc2770 (the live commit). 1x, ~15 game min.
Revised 2026-10-28 (W3), after w3-low-disk-b: a file written into the folder from outside is not counted -- real CC
measures a computer's disk when it creates the computer, and /state diskFree stayed 576618 throughout, so the card was
never exercised. After each change the game server is now restarted (world_restart; the 15 s chunk unload tried first did
not reboot the computer), which creates the computer again on a fresh measurement -- as the daily restart does. Each
step also checks diskFree really moved, so a run where the fill is not seen fails instead of passing quietly."""
import os

NAME = "w3_low_disk"


def server_computer(ctx):
    """The id of the RUNNING dispatch computer: the last 'Central server online ... ID: node_NNN' line the server itself logged. (The world copy also holds
    other computers whose startup.lua starts '-- central_server.lua'; the first scan of disks picked #110, not #95, and the file was written into the wrong
    computer's folder: w3-low-disk, 2026-10-27.)"""
    lines = ctx.log_lines("Central server online")
    if not lines:
        return None
    try:
        return int(lines[-1].rsplit("node_", 1)[1].split()[0])
    except (IndexError, ValueError):
        return None


def steps(ctx):
    ctx.wait_registered(14, 300)
    sid = server_computer(ctx)
    ctx.expect(sid is not None, "found the dispatch computer (#%s)" % sid)
    if sid is None:
        return
    folder = os.path.join(ctx.control.disks, str(sid))
    c = ctx.control

    def free():
        return (ctx.state() or {}).get("diskFree")

    ctx.wait_game(10)
    f0 = free()
    ctx.expect(isinstance(f0, (int, float)), "/state reports diskFree (%r)" % f0)
    if not isinstance(f0, (int, float)):
        return

    def remeasure():
        """Restarts the game server (a clean stop, the world saved), so CC creates the dispatch computer again and measures
        its disk afresh. Unloading its chunk did not do it: w3-low-disk-c unloaded it three times and the computer never
        rebooted ('Central server online' never came)."""
        n0 = len(ctx.log_lines("Central server online"))
        c.world_restart()
        back = ctx.wait_until(lambda: len(ctx.log_lines("Central server online")) > n0, 600)
        ctx.expect(bool(back), "the dispatch computer booted again after the restart")
        ctx.wait_game(20)                                # the next bridge pushes carry the new figure
        return free()

    def fill_to(target, name):
        need = int(free() - target)
        if need > 0:
            with open(os.path.join(folder, name), "wb") as f:
                f.write(b"x" * need)
        got = remeasure()
        ctx.expect(isinstance(got, (int, float)) and got <= target + 8000,
                   "diskFree moved to about %d after the fill (%r)" % (target, got))
        return got

    w0 = len(ctx.log_lines("Disk low on the server computer"))
    f1 = fill_to(340000, "w3_filler_1.bin")                             # THE TEST, step 1
    warned = ctx.wait_until(lambda: len(ctx.log_lines("Disk low on the server computer")) > w0, 180)
    ctx.expect(bool(warned), "WARN within 3 minutes at %s bytes free" % f1)
    e0 = len(ctx.log_lines("below the 300 KB floor"))
    f2 = fill_to(290000, "w3_filler_2.bin")                             # step 2
    floored = ctx.wait_until(lambda: len(ctx.log_lines("below the 300 KB floor")) > e0, 180)
    ctx.expect(bool(floored), "ERROR 'below the 300 KB floor' within 3 minutes at %s bytes free" % f2)
    for name in ("w3_filler_1.bin", "w3_filler_2.bin"):
        try:
            os.remove(os.path.join(folder, name))
        except OSError:
            pass
    back = remeasure()
    ctx.expect(isinstance(back, (int, float)) and back > 350000, "diskFree back above 350 KB once removed (%r)" % back)
    ctx.wait_game(30)
    quiet0 = len(ctx.log_lines("Disk low on the server computer")) + len(ctx.log_lines("below the 300 KB floor"))
    ctx.wait_game(600)
    quiet = len(ctx.log_lines("Disk low on the server computer")) + len(ctx.log_lines("below the 300 KB floor"))
    ctx.expect(quiet == quiet0, "no disk warning once the space is back (%d)" % (quiet - quiet0))
