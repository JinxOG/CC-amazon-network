"""W3 card GPS 2 (the central server checks GPS itself), layer 2. Needs the fleet on commit 27fe82c or later
(`run.py pin <run-id> <sha>`). The GPS host computers are shut down while a job waits; the server must raise its
alert (/state 'gps', ok=false), send nothing out, then clear the alert and dispatch once the hosts are back on.
Same checks as the layer-1 scenario sandbox/scenarios/w3_gps2_server_check.lua. 1x is fine; about 15 game minutes."""
NAME = "w3_gps2_server_check"


def steps(ctx):
    ctx.wait_registered(14, 300)
    ctx.wait_game(120)                                   # the server's first pings and judgements, GPS healthy
    st0 = ctx.state()
    ctx.expect((st0.get("gps") or {}).get("ok") is True, "/state gps.ok is true before the outage (%r)" % st0.get("gps"))

    hosts = ctx.control.gps_down()
    ctx.note("GPS hosts shut down: %r" % hosts)
    ctx.wait_game(45)                                    # one 15 s ping and its 3 s judgement, with room to spare
    ctx.dispatch("ORDER_MINE", {"x1": 1920, "z1": -2624, "x2": 1984, "z2": -2624, "minerCount": 2})
    ctx.wait_game(180)
    st = ctx.state()
    ctx.expect((st.get("gps") or {}).get("ok") is False, "/state gps.ok is false during the outage (%r)" % st.get("gps"))
    ctx.expect(len(ctx.log_lines("GPS CHECK FAILED")) >= 1, "the server logged GPS CHECK FAILED")
    ctx.expect(len(ctx.log_lines("Dispatch hold: GPS check failing")) >= 1, "it logged the dispatch hold")
    sent_during = len(ctx.log_lines("Dispatched job_"))
    ctx.expect(sent_during == 0, "no job went out during the outage (%d)" % sent_during)

    ctx.control.gps_up()
    back = ctx.wait_until(lambda: ctx.log_lines("GPS check: back after"), 300)
    ctx.expect(bool(back), "the alert cleared when the hosts came back")
    went = ctx.wait_until(lambda: ctx.log_lines("Dispatched job_"), 300)
    ctx.expect(bool(went), "the waiting job went out once GPS was back")
    st2 = ctx.state()
    ctx.expect((st2.get("gps") or {}).get("ok") is True, "/state gps.ok is true again (%r)" % st2.get("gps"))
    lost = [l for l in ctx.log_lines("Server unreachable")]
    ctx.note("unreachable warnings during the whole run: %d" % len(lost))
