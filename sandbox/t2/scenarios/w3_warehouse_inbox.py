"""W3, the warehouse inbox leak (fix abe3e62, warehouse.lua is W6's file, edited with the user's go 2026-11-04), layer 2.
The warehouse now keeps only the four message types its state machine reads (DELIVERY_ARRIVED, CHESTS_PLACED, BATCH_DONE,
ITEM_COLLECTED), at most 64 of each. The risk of that change is a delivery that waits for one of those and never sees it.
So: one delivery, end to end, on the real game -- the warehouse must queue it, load it, and the job must complete -- with
the fleet chattering on the server channel the whole time. Pin the commit under test. 1x."""
import re

NAME = "w3_warehouse_inbox"


def pick_item(st):
    best = None
    for e in st.get("storage") or []:
        if not isinstance(e, dict):
            continue
        n, a = e.get("name"), e.get("amount") or e.get("count") or 0
        if n == "minecraft:cobblestone" and a >= 64:
            return n
        if isinstance(n, str) and a >= 64 and (best is None or a > best[1]):
            best = (n, a)
    return best and best[0]


def steps(ctx):
    ctx.wait_registered(14, 300)
    c = ctx.control
    have = ctx.wait_until(lambda: pick_item(ctx.state()), 180)
    ctx.expect(bool(have), "the warehouse's storage list reached /state, with an item to send (%s)" % have)
    if not have:
        return
    x, y, z = c.free_spot()
    ctx.note("delivery of 16 %s to %d,%d,%d" % (have, x, y, z))
    queued0 = len(ctx.log_lines("Job queued: job_"))
    ctx.dispatch("ORDER_DELIVERY", {"items": [{"name": have, "count": 16}], "destination": {"x": x, "y": y, "z": z}})
    queued = ctx.wait_until(lambda: ctx.log_lines("Job queued: job_")[queued0:], 120)
    ctx.expect(bool(queued), "the delivery job was queued (%s)" % (queued[:1] if queued else "nothing"))
    if not queued:
        return
    job = re.search(r"(job_\d+)", queued[0]).group(1)
    went = ctx.wait_until(lambda: [l for l in ctx.log_lines("Dispatched %s" % job)], 300)
    ctx.expect(bool(went), "%s was dispatched to a delivery turtle (%s)" % (job, went[:1] if went else "nothing"))
    done = ctx.wait_until(lambda: [l for l in ctx.log_lines("Job complete: %s" % job)], 2400)
    ctx.expect(bool(done), "%s completed: the warehouse saw the turtle arrive and loaded it" % job)
    wh = [l for l in ctx.log_lines("") if "warehouse" in l.lower() and ("ERROR" in l or "crash" in l.lower())]
    ctx.expect(not wh, "the warehouse logged no error or crash (%d: %s)" % (len(wh), wh[:2]))
    ctx.note("warehouse lines for the job: %s" % [l for l in ctx.log_lines(job) if "warehouse" in l.lower()][:6])
