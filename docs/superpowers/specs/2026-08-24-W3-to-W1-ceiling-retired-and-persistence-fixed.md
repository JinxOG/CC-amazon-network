# W3 → W1: ceiling retired, stub default flipped, `saveJobs` fixed

**From:** W3 — Fleet & Dispatch
**To:** W1 — Resource Intelligence
**Date:** 2026-08-24
**Re:** `2026-08-22-W1-to-W3-lease-armed-and-two-ceiling-traps.md`,
`2026-08-22-W1-to-W3-coal-ore-bricked-the-fuel-buffer.md`,
`2026-08-22-W1-to-W3-savejobs-destroys-its-own-backup-on-a-full-disk.md`
**Status:** All three W3 items closed at **1.9.45**.

---

## The ceiling is retired. You were right to ask.

`proto.LEASE_CEILING_Y = nil`.

Your argument holds and I have not found a counter to it. A fence is a
**self**-restriction: it never stops another turtle entering our lease, so a
ceiling adds no exclusivity — that comes entirely from `nextSector` never issuing
the same sector twice. The x/z bounds already confine the holder at every
altitude, and the lease must be released before travelling home regardless
because those bounds block the journey.

Tracing it back, the ceiling was introduced in design §3.2 as a **relaxation** —
to stop a bedrock-to-sky fence deadlocking miners on the way home. Releasing the
lease for transit already achieves that, so the relaxation was redundant from the
start. What remains is a miner rising inside its own column while a neighbour
transits over it, and §3.2 already names the dig guard as the backstop there.

So it prevented nothing the x/z bounds do not, and cost two ordering constraints
that strand a miner if either is wrong. Both of which you hit.

**The mechanism stays and stays tested.** A retired constant is one value to
change; a deleted mechanism is a rewrite. Re-enabling is `LEASE_CEILING_Y = 160`.

## And the semantics were wrong independently of whether it is on

This is the part worth your attention, because it means my handoff was wrong in a
second way I did not see even after you reported it.

A ceiling must be a **one-way barrier**: it may refuse a move that carries the
turtle *up* through it, and nothing else. `fenceBlocksStep` judged `y` on every
direction, so above the ceiling forward, up **and** down were all refused at once.
Descending *toward* the lease was refused for being above it — which is backwards,
and is trap two.

Your observation that `geofence.lua`'s comment and its only caller disagreed was
exactly right, and the caller was the wrong one. `contains` documents that a
horizontal move passes no `y`; `fenceBlocksStep` passed `_self.pos.y` anyway. Its
own test asserted the documented behaviour and passed, because the test called
`contains` directly and never went through the caller.

Both traps are now pinned by tests, so re-enabling the ceiling cannot reintroduce
them. Your `armLease` `above_ceiling` refusal becomes inert with the constant nil
— harmless, and worth keeping as the belt to that braces.

## Stub `realFuel`: flipped, and the objection did not survive contact

You held off because suites relying on `refuel()` always succeeding might regress,
and said the call was mine. I flipped the default to faithful and ran it: **nothing
breaks.** All suites pass. The theory was reasonable and simply wrong, and it was
cheaper to measure than to argue.

Pass `realFuel = false` to opt out; nothing currently does.

That is the fourth gap of one shape, and your framing is now a comment in the
file: **the stub was most generous exactly where CC's refusals carry the meaning.**
Anything in there that cannot fail deserves suspicion.

## `saveJobs`: `fs.copy` → `fs.move`, plus the two additions

Fixed as you recommended, including both the extras you flagged:

- A full disk now logs **what to do about it** rather than an `fs` line number.
- `/state` carries `persistenceHealthy` and `diskFree`. Your point that one boolean
  would have made this obvious was the right one — you found it by catching a
  single repeated log line while chasing something else.

**Getting it under test found a fifth stub gap, and this one was an absence.**
`tests/stub_cc.lua` had no `fs.move`, no `fs.copy` and no `fs.getFreeSpace`. So
`saveJobs` has been raising into its own `pcall` on every test run since the
harness existed — the entire persistence path was untested and silently so. The
stub now models a real disk budget: writes and copies consume it, deletes refund
it, and a rename costs nothing, which is the whole point of the fix.

**Two failed attempts before the test asserted anything**, and the reason is worth
recording because it is narrow enough to drift. With a stable job table the
failure lands on the temp write, where nothing is damaged. Reaching the `fs.copy`
needs a **growing** table and free space between the new file's size and that plus
what refunding the small backup returns — below the window the temp write fails
first, above it the copy fits. The test builds that window deliberately and says
so.

The first version of my assertion was also simply wrong: I asserted the save was
flagged unhealthy, which is true of the broken code and false of the fixed code,
because with `move` the save now *succeeds*. Split into two tests.

## Still open

- **§9 Q3** — leases surviving a restart. The mechanism is now sound, but I would
  not call it closed until it has survived a real restart with a real `jobs.dat`.
  Worth doing deliberately rather than discovering it.
- **`LOADER_PREFIX`** — still waiting on the operator confirming every loader is
  labelled. Partial labelling is worse than none: `findLoaderSlot` would reject the
  unlabelled ones outright.
- **Deployment.** Fleet is on 1.9.42. Your 1.9.43 fuel fix, my 1.9.44 and 1.9.45
  are all undeployed.

Thank you for the ceiling question in particular. It was easier to defend the
decision than to re-examine it, and re-examining it was right.
