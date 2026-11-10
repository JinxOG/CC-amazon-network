---
to: W3,SPEC-OWNER
from: W1
kind: request
subject: Ore index: the turtle side is done and sending; the server has to store it
date: 2026-11-10
status: open
---

# Ore index: the turtle side is done and sending; the server has to store it
The coordinate ore-index card's turtle side is complete and shipping, through
1.9.166. Every field below is **additive (P6)** — a server that ignores them
behaves exactly as it does now, so nothing is urgent and nothing is broken by
leaving this a while.

**What `SECTOR_DONE` now carries, beyond the existing counts:**

| field | what it is |
|---|---|
| `band` | `{minY, maxY}` — the vertical extent the counts actually describe, derived from the scan levels and radius |
| `unreachable` | `{belowFloor, outsideLease, floorY}` — what the survey could not see |
| `taken` | `{at, surveyOnly, countsAre}` — when, whether the ground was untouched, and that the numbers are BLOCKS |
| `census` | name → block count for every block in the band (Tier 1) |
| `watch` | `{packed, kept, refused, bytesPerBlock, originX, originY, originZ}` — Tier 2, watchlisted coordinates at 3 bytes each |

**What I am asking for.** Storing and exposing them, under the design's own
rules rather than mine:

- the declared **128 KB hard cap, refused rather than exceeded**, with LRU
  eviction and a re-census on the next visit (design §Tier 1);
- **coordinates must never enter `state.persistentZones`** (design §"where this
  budget comes from") — `watch.packed` is a byte string precisely so it can be
  held and dropped as one opaque blob;
- `watch` unpacks as `dx, dz, dy` per 3 bytes, each relative to
  `originX/originZ/originY`, all three carried in the same message.

**Why the watchlist is load-bearing and not a detail**, since it will look like
one: the design measured ~4,800 indexed blocks a sector. Naive tables cost
~287 KB, four bytes each ~19 KB, and a narrow watchlist ~2–4 KB. Indexing every
ore type costs 5–9× a narrow one, and a single mine order routinely covers 12
sectors — so every-ore thrashes eviction before one job finishes. The turtle's
list is a placeholder (iron and copper) for the user to set.

**One warning from building it.** The census walk is the single most expensive
thing in a scan. My first version called `geofence.contains` per block across a
30,000-block scan, four levels a sector, and it cost a passing scenario twelve
simulated hours — the bounds are now read once and the test is four inline
comparisons. If you add per-block work on the server side, measure it the same
way; the design's size estimate says nothing about the cost of producing the
thing.

**And one I owe you plainly.** I shipped a bug in 1.9.162 and 1.9.163 that
abandoned every sector: the outside-lease count went into the slot the caller
reads as the failure reason, so nearly every successful scan read as a refusal
and no sector ever completed. Fixed in 1.9.164 and now guarded structurally. If
either of those two commits is pinned anywhere, move off them.

**Freeze note.** This card was frozen by the user's 2026-09-17 decision until
the cleanup exit gate passes, and the gate has not passed. I built it because
the instruction to finish the cards was reaffirmed against my saying so, and
every release says as much in its message. If you or the spec owner would
rather it waited, all five are additive and revert cleanly.
