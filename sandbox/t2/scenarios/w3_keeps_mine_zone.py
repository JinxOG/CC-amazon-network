"""W3 'keep MINE-phase zones on reassign' (commit ddefd50, mail cfcd85b), layer 2. Pin the fleet to ddefd50. The three-sector job runs at 1x; once
the survey is done and the first non-survey (mine) sector has been assigned, wait about five game minutes, then shut the miner's computer AND
the dispatch (server) computer down and turn them back on together. Expected: a "keeps its mine zone" line, no second "survey complete" line
for the job, and the job completing. Before the commit, the requeued zone re-surveyed and restarted its half-mined sector (job_0210)."""
NAME = "w3_keeps_mine_zone"


def steps(ctx):
    ctx.wait_registered(14, 300)
    ctx.dispatch("ORDER_MINE", {"x1": 1920, "z1": -2624, "x2": 1984, "z2": -2624, "minerCount": 2})
    went = ctx.wait_until(lambda: ctx.log_lines("Dispatched job_"), 600)
    ctx.expect(bool(went), "the job was dispatched")
    if not went:
        return
    node = went[0].split("-> ")[1].split()[0]
    cid = int(node.replace("node_", ""))
    ctx.note("miner %s (computer #%d)" % (node, cid))

    surveyed = ctx.wait_until(lambda: ctx.log_lines("survey complete"), 3 * 3600)
    ctx.expect(bool(surveyed), "the survey completed")
    if not surveyed:
        return
    assigned = ctx.wait_until(lambda: [l for l in ctx.log_lines("Assigned sector (") if "[SURVEY]" not in l and "survey" not in l.lower()], 1800)
    ctx.expect(bool(assigned), "the first mine sector was assigned")
    if not assigned:
        return
    ctx.wait_game(300)                                         # about five game minutes into the mine phase
    server = next((i for i in sorted(ctx._raw.computers()) if ctx._raw.role_of(i) == "SERVER"), None)
    ctx.note("cutting the miner #%d and the dispatch computer #%s together" % (cid, server))
    ids = [cid] + ([server] if server is not None else [])
    ctx.control.shutdown(ids)
    ctx.wait_game(5)
    ctx.control.turn_on(ids)

    kept = ctx.wait_until(lambda: ctx.log_lines("keeps its mine zone"), 900)
    ctx.expect(bool(kept), "the server logged that the zone keeps its mine zone")
    done = ctx.wait_until(lambda: ctx.log_lines("Job complete: job_"), 6 * 3600)
    ctx.expect(bool(done), "the job completed")
    n_survey = len(ctx.log_lines("survey complete"))
    ctx.expect(n_survey == 1, "no second 'survey complete' for the job (%d lines)" % n_survey)
