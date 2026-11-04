"""W3 card GPS 2, the watcher's FAILED verdict (2026-11-03), layer 2. Same story as sandbox/scenarios/w3_gps2_restart.lua on the
real game: the GPS hosts are shut down while a job waits, and the dispatch computer is switched off and on two minutes into
the outage. Live 10-29..11-02 one ~91 h outage read as seven 'GPS CHECK FAILED' (six were restarts) and its one 'back after'
counted from the last restart. Needs the fleet on 6b08923 or later (pin it). 1x is fine; about 15 game minutes."""
import importlib.util
import os
import re

NAME = "w3_gps2_restart"
_spec = importlib.util.spec_from_file_location("w3_low_disk", os.path.join(os.path.dirname(os.path.abspath(__file__)), "w3_low_disk.py"))
_low = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_low)
server_computer = _low.server_computer                     # the RUNNING dispatch computer, not a stray SERVER disk


def steps(ctx):
    ctx.wait_registered(14, 300)
    c = ctx.control
    sid = server_computer(ctx)
    ctx.expect(sid is not None, "found the dispatch computer (#%s)" % sid)
    if sid is None:
        return
    ctx.wait_game(120)                                   # the server's first pings and judgements, GPS healthy
    st0 = ctx.state()
    ctx.expect((st0.get("gps") or {}).get("ok") is True, "/state gps.ok is true before the outage (%r)" % st0.get("gps"))
    n_failed0 = len(ctx.log_lines("GPS CHECK FAILED"))
    n_sent0 = len(ctx.log_lines("Dispatched job_"))

    hosts = c.gps_down()
    t_down = ctx.game_seconds()
    ctx.note("GPS hosts shut down: %r" % hosts)
    ctx.wait_game(45)
    ctx.dispatch("ORDER_MINE", {"x1": 1920, "z1": -2624, "x2": 1984, "z2": -2624, "minerCount": 2})
    ctx.wait_game(75)                                    # two minutes into the outage

    n_online = len(ctx.log_lines("Central server online"))
    c.shutdown([sid])                                    # THE TEST: the restart in the middle of the outage
    ctx.wait_game(5)
    c.turn_on([sid])
    t_boot = ctx.game_seconds()
    booted = ctx.wait_until(lambda: len(ctx.log_lines("Central server online")) > n_online, 600)
    ctx.expect(bool(booted), "the dispatch computer restarted during the outage")
    carried = ctx.wait_until(lambda: ctx.log_lines("still down after a server restart"), 120)
    ctx.expect(bool(carried), "the restarted server said the outage was still on (%s)" % (carried[-1:] if carried else "nothing"))
    ctx.wait_game(60)
    st = ctx.state()
    ctx.expect((st.get("gps") or {}).get("ok") is False, "/state gps.ok is still false after the restart (%r)" % st.get("gps"))
    failed = len(ctx.log_lines("GPS CHECK FAILED")) - n_failed0
    ctx.expect(failed == 1, "one outage, one 'GPS CHECK FAILED', the restart included (%d)" % failed)
    sent_during = len(ctx.log_lines("Dispatched job_")) - n_sent0
    ctx.expect(sent_during == 0, "no job went out during the outage, restart included (%d)" % sent_during)

    c.gps_up()
    t_up = ctx.game_seconds()
    back = ctx.wait_until(lambda: ctx.log_lines("GPS check: back after"), 300)
    ctx.expect(bool(back), "the alert cleared when the hosts came back")
    secs = None
    if back:
        m = re.search(r"back after (\d+)s", back[-1])
        secs = int(m.group(1)) if m else None
    # The outage lasted (t_up - t_down) game seconds; the old code counts only from the boot, (t_up - t_boot), at least
    # 60 s shorter. Halfway between the two tells them apart.
    bar = (t_up - t_down) - (t_boot - t_down) / 2
    ctx.expect(secs is not None and secs >= bar, "'back after' counts from the outage's start: %s s, outage %d s, since the "
               "boot %d s (%s)" % (secs, t_up - t_down, t_up - t_boot, back[-1:] if back else "nothing"))
    went = ctx.wait_until(lambda: len(ctx.log_lines("Dispatched job_")) > n_sent0, 300)
    ctx.expect(bool(went), "the waiting job went out once GPS was back")
    st2 = ctx.state()
    ctx.expect((st2.get("gps") or {}).get("ok") is True, "/state gps.ok is true again (%r)" % st2.get("gps"))
