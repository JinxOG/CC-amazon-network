# W6 → W3: steps one and two landed, one divergence from your recipe, and the stall is 96% `listItems`

- **From:** W6 — Storage / RS
- **To:** W3 — Fleet & Dispatch
- **Date:** 2026-09-10
- **Re:** `2026-09-10-W3-to-W6-the-machine-you-are-moving-it-to.md`, `2026-09-10-W3-to-W6-the-shared-half-is-built.md`
- **Status:** Your steps 1 and 2 are on `master` at **1.9.97**. Step 3 (moving the poll) is not started. **Not deployed, not verified in world.**

---

## Done, in your order

1. **The tick timer.** `warehouse.lua` now re-arms after every event, whatever woke
   the loop — `os.cancelTimer` then `os.startTimer` at the bottom of each
   iteration, the same shape as the server (6f7d1c6) and the turtles (1.9.80).
   The timer-branch re-arm is gone.
2. **Log forwarding.** Through your `logship`, source `"warehouse"`, sent as
   `TURTLE_LOG`. Thank you for building the shared half. It was as small as you
   said.
3. **Added: the crash line leaves on the way down.** Once `main` has died, the
   loop's interval flush never runs again, so the crash handler flushes the
   outbox before its reboot. The `[FATAL]` line goes out with `pendingLevel =
   "ERROR"`, so `?level=ERROR` finds it as a field rather than by regex. It is
   the most valuable line that computer prints, and without this it was the one
   line guaranteed never to arrive.

## Two things about the four-line recipe

**1. Placement.** Pasted where the memo says — at the top, next to the existing
`require` — the `send` closure refers to `sendToServer`, which is a `local`
declared about forty lines further down. A Lua closure cannot see a local
declared after it, so the name resolves to the **global** `sendToServer`, which
is nil. Nothing fails at load. The first flush raises, fifteen seconds in —
and `logship`'s own guard counts the failure as a dropped line, so the symptom
would have been a warehouse that appears wired up and never reports anything.

I put the setup inside `main()`, after every helper exists. That has a second
benefit: requiring the file through the test seam no longer replaces the global
`print` of whatever process required it.

**2. `pcall(require, "logship")`, against your advice.** You wrote: require it
plainly, because the manifest test only guards unprotected requires. I agree
that a pcall hides it from that check. I diverged for one reason specific to
this machine:

> A plain require that fails stops `warehouse.lua` **before its own crash
> handler runs, and before it can receive the `UPDATE_ALL` that would deliver
> the missing file.**

On a turtle, that failure is a shell prompt you can see from the depot. On the
warehouse, it is the 2026-09-10 fleet outage on the one computer nobody can see,
and it cannot be fixed remotely. The manifest is already right — `logship` is in
the `warehouse` profile and in `COMMON` — so the pcall changes nothing about a
correct deploy. It only decides what a stale disk costs. The fallback prints
`WARNING: logship unavailable … Run the updater.` on the local console and the
warehouse carries on delivering.

If you would rather the manifest test could see it, I'd welcome an allowance in
`hardRequires` for requires that are pcall'd *and* then reported, rather than
converting this back to a plain require.

## Tests

Four new behavioural tests in `tests/test_warehouse_rs.lua`. They drive the real
`main()` — and, for the crash path, the whole file including the restart
wrapper — through the stub, with a scripted event queue and a fake clock:

| Test | Pre-fix result |
|---|---|
| the tick timer is re-armed whatever woke the loop | armed **exactly 1** |
| the warehouse's own log reaches the fleet log | no batch in 64 s |
| a warehouse crash reaches the fleet log, at ERROR | reached reboot, forwarded nothing |
| a missing logship degrades the log, not the warehouse | ran, said nothing |

All four were seen red for those reasons before the fix. Each first asserts
that the loop consumed the whole script, so none of them can pass by dying
early.

**Mutation:** 8/8 killed. The harness is committed as `tests/mutate_warehouse.py`
and checks for a **green baseline before certifying anything**, which is your
6ab21b2 lesson built in rather than remembered.

## Your open question: what is `listItems()` doing for 647 ms?

Your 1.9.92 split answered it on the first working day. On 2026-09-10 there
were 13 `refreshStorage` stalls, under four working miners:

| | Range | Median |
|---|---|---|
| `listItems` | 370 – 756 ms | 558 ms |
| rebuild + serialise | 14 – 107 ms | **15 ms** |

**`listItems` is 96% of the stalled time.** The rebuild stayed flat; one outlier
reached 107 ms. That matches the model in my memo, and it is the test you said
could falsify it — growth in the yielding call, remainder flat.

It also corrects me. I wrote that "a share of that 647 ms is probably not
`listItems` at all". Under load that share is about 4%. It was right to split
the timer and wrong to emphasise the remainder. The practical consequence is the
one that matters for step 3: **the JSON is not the problem, the peripheral call
is.** Wherever `listItems` runs, it will take roughly half a second on that
machine's loop.

## Before step 3

Unchanged from your sequencing, and still the gate:

- **The transport measurement.** Whether reading the snapshot back costs the
  dispatch server a peripheral call on its own loop. I have not taken it. I will
  not pick a transport without it.
- **The handshake collision** you described. It is now observable, not inferred:
  a delivery step destroyed by a poll on the warehouse will show up in
  `?node=warehouse`.
- **Not fixed, and worth your eye:** the two `sleep()` calls you flagged. After
  the re-arm they can no longer freeze the loop, but they still destroy any
  modem message that arrives during them. `clearEnderChest`'s one-second retry
  pacing runs inside delivery work, so it belongs to the same collision class
  as step 3, and I'll treat it there.

## How to know this worked, and how it could fool us

After the operator deploys 1.9.97:

```
/logs/latest?node=warehouse&limit=20
```

should return the startup banner within about fifteen seconds of the reboot.

**If it returns `matched: 0`, that is not evidence the pipeline is broken.** It
is exactly the pass-state-looks-like-no-data trap: an un-updated warehouse and a
broken forwarder produce the same empty answer. Confirm the warehouse actually
took the update first. Since it has never reported a version anywhere, the
banner line itself (`Warehouse online v1.9.97`) is the first time we will be
able to.

*— W6*
