# W3 → W5: write the log we are already sending

- **From:** W3 — Fleet & Dispatch
- **To:** W5 — Bridge & Dashboard
- **Date:** 2026-09-07
- **Status:** Phase 1 is yours and needs no CC-side change. Phase 2 is mine and
  is specified here so Phase 1 does not have to be rewritten when it lands.
- **Protocol at time of writing:** 1.9.83

---

## What the operator asked for

A continuous log of every turtle and every computer, written to a plain text file
readable on the server PC.

**Most of it already exists.** Turtles capture every `print()` and forward it to
the server; the server keeps its own log and everyone else's; and every 3 seconds
it POSTs a slice of all of it to you. Nothing writes it down. That last step is
Phase 1 and it is entirely inside `server.js`.

## What you already receive, exactly

Both arrive in the `/update` payload you already parse.

```
serverLog : [ { ts = <epoch ms>, level = "INFO"|"WARN"|"ERROR", msg = <string> } ]
            the last 100 entries of a 500-entry ring

turtleLogs: { [nodeId] = [ { ts = <epoch ms>, msg = <string> } ] }
            the last 10 entries per node, of a 60-entry ring
```

`msg` on a turtle line already carries its own prefix — `[node_118][INFO] ...` —
because turtles capture `print()` verbatim. Do not add a second one.

## Phase 1 — append what arrives

**Requirements.**

1. **One line per entry, plain text, greppable.** Suggested shape, because the
   thing an operator does with this file is `grep node_119` or `grep WARN`:

   ```
   2026-09-07T14:26:09.412Z  server    WARN   Bridge push timed out (>4s)
   2026-09-07T14:26:11.008Z  node_118  INFO   [node_118][INFO] phase: SCANNING
   ```

2. **Deduplicate.** You receive overlapping windows every 3 seconds, so the same
   line arrives repeatedly. Key on `(source, ts, msg)`.

   **State the known weakness rather than discovering it later:** two identical
   messages from the same node in the same millisecond collapse into one. That is
   rare and it is acceptable for Phase 1. Phase 2 removes it properly.

3. **Rotate daily** (`logs/YYYY-MM-DD.txt`) and prune beyond N days — 14 is a
   reasonable default. This file grows without limit otherwise, and the whole
   reason it lives on your side is that your disk is the one with room.

4. **Never block the `/update` response on the write.** The CC server is
   synchronous: whatever time you take answering is time it is deaf to the radio.
   That is the single most expensive property in this system — it is what loses
   heartbeats. Append asynchronously, respond immediately.

**Measured volume, so you can size it:** roughly 1,000 lines per 15 minutes with
two miners working, around 100 bytes each — order of 400 KB/hour, 10 MB/day.
Trivial on your disk, impossible on the CC computer's 1 MB.

## What Phase 1 will NOT capture, and please say so rather than claiming "all"

- **Turtle bursts.** A turtle's outgoing queue holds 40 lines and flushes every
  15 seconds; the server ships only the **last 10 per node per push**. A turtle
  printing more than that between pushes loses its oldest lines before you ever
  see them. Boot sequences do exactly this.
- **The other computers.** Warehouse and admin forward nothing at all today.
- **Anything printed while a node is off the air** — a miner's deliberate
  comms gap during the loader swap, or a rebooting computer.

That window of 10 was not an oversight and **must not simply be widened.**
Shipping all 60 per node made the payload 96 KB of 190 KB, and the time spent
serialising it made the server deaf long enough to drop heartbeats. Widening it
would trade a logging gap for a fleet outage.

## Phase 2 — mine, and the contract to build Phase 1 against

I will add a **monotonic per-source sequence number** to every log entry:

```
serverLog : [ { ts, level, msg, seq } ]
turtleLogs: { [nodeId] = [ { ts, msg, seq } ] }
```

`seq` starts at 1 on boot and increases by one per line, per source. It never
repeats within a boot. A reboot restarts it at 1, so **treat `(source, boot, seq)`
as the identity** — I will publish a `bootId` per source alongside it.

Then the server sends **only entries newer than the last sequence you
acknowledged**, rather than a fixed window. You will return the highest `seq` you
have stored per source in your `/update` response, in the same place commands
already come back.

Two consequences worth stating plainly:

- **Completeness improves** — no more losing a burst between pushes.
- **The payload gets smaller on average, not bigger.** An idle fleet sends
  nothing instead of re-sending the same 10 lines per node forever. That is the
  opposite of the change that caused the 2026-08-30 deafness, and I will measure
  `pushBuildMs` before and after rather than assert it.

**If you key Phase 1 on `(source, ts, msg)` and simply prefer `seq` when it
appears, Phase 1 does not need rewriting.** That is the only thing I am asking
you to design for now.

## Why this is worth doing before the computer split

The 24-second fleet-wide re-registration cycle is still unexplained. Every
diagnosis of it so far has come from sampling `/state` every 2 seconds and
reasoning about what fell between samples — and I have been wrong twice that way,
once under-reporting the rate by a factor of ten. A continuous log turns that
guesswork into reading.

It is also the cheapest thing on the list: the data is already crossing the wire.

## What I need back

1. Whether the async append fits how `server.js` handles `/update` today, or
   whether it needs restructuring — if the latter, say so and I will re-sequence
   this against the split work rather than assume it is free.
2. Where you want the ack for Phase 2 to ride. I assumed the existing commands
   channel; if that is awkward, name a better one and I will build to it.
