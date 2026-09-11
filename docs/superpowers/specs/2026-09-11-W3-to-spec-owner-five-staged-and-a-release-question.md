# W3 → spec owner: five pieces staged, one release question, one sign-off needed

- **From:** W3 — Fleet & Dispatch
- **To:** spec owner; cc W1, W5, W6
- **Date:** 2026-09-11
- **Re:** `2026-09-11-cleanup-phase-design.md`
- **Status:** Wave 1 (my rows) and Wave 2 cards 3, 4, 6 and 7 are **built, tested
  and pushed on branches — none on `master`, none deployed.** Two things need you:
  a ruling on release order (§2) and a sign-off on card 5 (§3).

---

## 1. What is staged

Each on its own branch, **stacked in queue order** — each branch contains the
ones before it — so a release is a fast-forward of `master` to one branch tip.

| Branch | Version | Work | Suite | Mutants |
|---|---|---|---|---|
| `w3-wave1-removals` | 1.9.100 | Wave 1: `stress_test.lua` out of the updater; `test_turtle.lua` → `tests/inworld/` | 372 | — |
| `w3-card3-disk-warning` | 1.9.101 | Card 3: warn < 350 KB, ERROR < 300 KB, checked every minute | 378 | 63/63 |
| `w3-card4-stale-sector` | 1.9.102 | Card 4: replay a sector order only to a miner that is waiting | 385 | 73/73 |
| `w3-card6-optional-require` | *(test only)* | Card 6: the install check sees guarded-and-reported requires | 387 | 79/79 |
| `w3-card7-push-witness` | 1.9.103 | Card 7, **measure** half: what ran between a push and its timeout | 394 | 89/89 |

Every mutation run checks for a green baseline before certifying anything.

**Two findings on the way that change what you would expect:**

- **Card 3** — the old warning text called the zone files "expendable" because
  zones are also in the cloud store. True for *finished* zones only; live zones
  are on disk and nowhere else. An operator following it would delete every
  mine in progress. Fixed in the same message.
- **Card 4** — I did **not** remove `reSendSector`, though the miner's own 20 s
  `SECTOR_REQUEST` retry makes it nearly redundant. §8 counts it as flaw 1's
  footprint; deleting it would destroy a measurement you asked for. It is gated
  instead (W6's first suggestion), and every withheld replay is **logged**, so
  the flaw-1 count does not silently shrink. No change to `ore_turtle.lua`.

## 2. The release question — needs your ruling

§5.1 says Wave 1's removals go first, as a removals-only release. **They cannot,
from `master` as it stands:** 1.9.98 (detached-modem log loss) and 1.9.99 (the
live-zone backup) are already on `master`, undeployed, and any deploy ships
`master`. The fleet is on **1.9.97**, which has not yet run a mining job either.

My proposal — you decide:

| Release | Contents | Also measures |
|---|---|---|
| **R1** | `master` as it is: 1.9.97 → 1.9.99 | the two log cards (a full-job audit), the disk card (a file listing) |
| **R2** | Wave 1 removals, 1.9.100 | the updater card — this release changes `updater.lua` itself, so the self-restart runs in the world for the first time |
| **R3** | Card 7's witness, 1.9.103 — **pulled ahead of cards 3 and 4** | the §7 gate's check 7 cannot be judged without it |
| R4, R5 | Card 3, then card 4 | — |
| any time | Card 6 | test only; nothing ships to an in-game computer |

R1's two fixes are repairs of measured faults (the disk filled; 190 log lines
lost in one job), so they fit §3.1. The alternative is reverting them off
`master` to let Wave 1 go first. I'd rather not, but it is your call.

**Pulling R3 ahead** means cherry-picking it off the stack and renumbering; say
the word and I'll do it. Versions are stamped in stack order today and will be
renumbered to whatever order you set.

## 3. Card 5 — needs your sign-off in the card body

*Crash handlers must send their last log lines before rebooting* is W1's card,
and its body still says "Delivery/support are frozen (Invariant H) — needs a
ruling." Per §5.3 I have **not touched** `delivery_turtle.lua` or
`support_turtle.lua`. When the card body says `Signed off: spec owner, <date>`,
the W3 half is small: call `base.flushLogs()` before each crash reboot, as W6
did for the warehouse.

## 4. Card 7 — what the witness is for

~83–123 pushes a day time out while the bridge answers in 1–3 ms: the reply
arrives and the server does not hear it. **Suspected** — from the code, not yet
from a measurement: the push goes out at the bottom of the loop, its reply is
queued a millisecond later, and if another event is queued ahead of it the next
turn handles that one first. If that is a peripheral call (the storage scan
above all), CC's filtered wait discards every queued event that does not match,
the reply included. The 1.9.77 fix guarded the same turn, not the next one.

The witness prints the evidence on every timeout and can say the opposite —
"no events ran after the push", or "no storage call ran in the window". If the
hypothesis holds, W6's card 1 (moving the RS poll) fixes most of it.

**W5, for your side:** dashboard commands ride back to the server inside these
replies, so a lost reply may be a **lost command**. Does the bridge re-queue a
command whose delivery was never acknowledged?

## 5. Not started, and why

- **The disconnect fix** — waits on W1's investigation, and jumps the queue when
  it lands. W1: the witness verdict now separates radio-off, comms gap, loop
  paused and "radio on and loop turning" (1.9.98); that last one is §7's
  failure case.
- **Wave 3 slimming** of `central_server.lua` and `turtle_base.lua` — §6 rule 4:
  not until their Wave 2 cards close, and three of them are mine and staged.
- **Measuring the three *Needs measuring* cards** — each needs a release in the
  world (table in §2).

## 6. Board

Cards 3, 4, 6 → *In progress* (built, not shipped — rule 2). New card *Find why
dashboard updates get lost* (card 7) created, W3, *In progress*. Card 5 not
touched: W1's.

— W3
