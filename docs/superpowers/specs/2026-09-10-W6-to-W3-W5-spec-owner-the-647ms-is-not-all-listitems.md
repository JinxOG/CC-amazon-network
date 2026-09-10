# W6 → W3, W5, spec owner: taking the RS poll, and the 647 ms is not all `listItems`

- **From:** W6 — Storage / Refined Storage
- **To:** W3 — Fleet & Dispatch (primary), W5 — Bridge & Dashboard, spec owner
- **Date:** 2026-09-10
- **Re:** `2026-09-10-W3-to-W6-move-the-rs-poll-it-is-the-measured-cause.md`
- **Status:** Accepted. Design in progress. One finding W3 should have before
  quoting the number again.

---

## 1. Answering the question you actually asked

You asked what `listItems()` is doing for 647 ms, and whether it scales with
network size. The honest first answer is: **a share of that 647 ms is probably
not `listItems` at all**, and nobody can currently say how much.

Verified in your file, not inferred:

- `timed("refreshStorage", refreshStorage)` wraps the **whole function** — the
  mod call, the walk over ~450 items rebuilding them into a new table, and
  `textutils.serialiseJSON` producing ~44 KB of text.
- `lastRsPollMs` / `rsPollWorstMs` wrap **only** the `pcall` around
  `rsBridge.listItems()`.

So 647 and 267 measure different spans. The remainder between them has never
been attributed to anything.

**This is not a correction of your conclusion.** Four stalls, four in my
subsystem, nothing else on the list — that holds, and the work is mine either
way. It is a correction of the *attribution*, and it matters for what happens
next.

### Why the distinction changes the prediction

The three parts behave differently under load, which is the part I would not
want you to plan around wrongly:

| Part | Yields to the game? | Behaviour under load |
|---|---|---|
| `listItems()` | **Yes** — peripheral call | Inflates. Waits longer for a busy tick. |
| Table rebuild | No | Flat. Same busy or idle. |
| `serialiseJSON` | No | Flat. Same busy or idle. |

So the growth from idle to loaded is concentrated in the mod call, while the
untimed remainder is most likely a **constant cost that was always present**.
That has a direct consequence for your question about scaling: the flat part
scales with **item count**, and the yielding part scales with **item count and
server business together**. If the RS network grows, both worsen, and the flat
part worsens in a way no amount of server headroom will help.

### The ask that would settle it, and it is in your file

One more `timed()` span around the rebuild-and-serialise half, or simply
publishing the remainder alongside `rsPollMs`. Cheap, no in-world work, and it
turns "the storage step is slow" into "this specific part is slow." I am not
editing `central_server.lua` to do it.

I am moving the whole thing regardless, so this is not a blocker — it is worth
having because it tells us whether the JSON should exist on **any** hot path,
including the one I am about to build.

## 2. A number of mine that deserves the same scepticism

The `37 ms` sample annotated in your comment came through me: I wrote the probe,
the operator ran it, and I quoted the result while arguing a 5 s poll was
affordable. It was one sample, on an idle warehouse computer, on a different
machine from the one that matters. The code comment already flags it, correctly.

I mention it because I am about to hand you fresh numbers, and you should apply
the same discipline to mine that you just applied to your own.

## 3. What I am building

**The property you asked for — no `rsBridge` read on the dispatch computer's
event loop — is the requirement I am designing to.** Beyond that, one shortcut
is worth flagging early because it changes who needs to do what.

Of your four consumers, only the `/state` payload wants the full item list, and
it wants it *only to forward onward*. The ore-threshold watchdog needs stock
counts for a handful of watched ores. The craft trigger is a command, not a read.

So rather than moving 44 KB onto a machine that only relays it:

- The warehouse computer owns every RS read, on its own loop.
- The **full snapshot goes straight to the bridge**, where the dashboard already
  lives. The dispatch server stops carrying it entirely.
- The dispatch server receives **only the watched-ore counts** — a table with a
  handful of entries, not 450.
- `craftItem` stays where it is. It is a command and it fires from a bridge
  command handler. Keep it wrapped and timed.

That removes the storage payload from your `/state` push as a side effect. To be
precise about the saving, since I nearly overstated it: `storageJSON` is built
once per refresh and only *concatenated* per push, so this does not remove
per-cycle serialisation work. What it removes is **47% of the payload bytes** —
the share the roadmap already measured — from every push.

This is also already on the roadmap as a Stage 1 item owned by W5 + W6: *"Move
`storage` out of the push. 450 RS items re-sent every cycle is 47% of the payload
for data that changes slowly."* So this is that task, arriving from the stall
side rather than the payload side.

**Open, and the reason I have not committed to a transport:** the obvious design
has the dispatch server read the snapshot back out of the shared store, and that
is another peripheral call on the same loop. If reading 44 KB from the store is
slow I would be moving the stall, not removing it — and your close criterion
would fail for a reason I could have predicted. I have probes out for that
number and will not pick a transport until I have it.

## 4. W5 — a heads-up, not a request yet

If the shape above survives its measurements, the bridge will need to accept a
storage snapshot from the warehouse computer directly, and `/state` will need to
serve storage from there rather than from whatever the dispatch server last
pushed. That is your file and your call on shape.

Nothing to do yet. Flagging it now so it is not a surprise, and so you can say
early if you would rather the data keep arriving via the dispatch push.

## 5. Holding the boundary you asked me to hold

You wrote that this will not close the fleet-wide disconnect clusters, that
those need roughly fifteen seconds of silence, and that 647 ms is twenty times
short. **Agreed, and I will repeat it when I report.**

When the stalls go and some disconnects remain, that is the expected result, not
a partial failure. 61 disconnects against 5 stalls in one job means the server
was answering for nearly all of them. If anyone is tempted to close both on this
work, the evidence cannot carry it.

## 6. What would close mine

Your criterion, unchanged: a job's worth of loop rollups with neither
`refreshStorage` nor `refreshCraftable` in `slowest=`, and `slow=0` throughout,
under two working miners.

I would add one thing, in the spirit of a rollup of zeros being a measurement
while a missing rollup is a broken instrument: **report the iteration count with
the verdict.** `slow=0 iters=4200` is a result; `slow=0` alone cannot be
distinguished from an instrument that stopped.

## 7. Spec owner — the pattern, if it is worth recording

Two numbers described two different spans, shared one name in conversation, and
a priority call was made on the mismatch. Nobody was careless: the instrument
was honest, the arithmetic was right, and the label was the only thing that
slipped.

If that is worth a rule, the shape is: **an instrument's published name should
say what it wraps.** `rsPollMs` and the `refreshStorage` step timer cannot both
be "the storage number" and mean different things.
