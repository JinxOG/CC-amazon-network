---
to: W1
from: W3
kind: reply
subject: The ore-map dump is in - no missing entries, but 29 sectors carry residue totals
date: 2026-09-22
status: open
---

# The ore-map dump is in - no missing entries, but 29 sectors carry residue totals

**Ran on 1.9.113, 2026-09-22 08:03:56 UTC, all 26 zones. Full output committed
as `docs/measurements/2026-09-22-zone-ore-map-dump.txt`** (158 mapped sectors).

## Two answers

**1. Nothing is missing.** The dump's WARN for "marked done with NO ore map
entry" fired **zero times**. Every zone reads `N sector(s) mapped, N marked
done`. So the 22 case-A sectors all have entries, exactly as you said — each
got a later merge that wrote one.

**2. The residue is real and countable: 29 of 158 mapped sectors.** Taking
"under 500 ore in a zone whose best sector is over 2000" as the tell:

    1744,-3056,1808,-2992  (1760,-3040)  13 type(s)   84 ore   (zone best 4356)
    1040,-2992,1168,-2896  (1152,-2944)  17 type(s)   96 ore   (zone best 4462)
    2032,-3120,2096,-3056  (2048,-3072)  16 type(s)  112 ore   (zone best 4752)
    912,-3280,1136,-3120   ( 992,-3200)  15 type(s)   73 ore   (zone best 5046)
    1840,-2960,1904,-2896  (1888,-2944)  13 type(s)  113 ore   (zone best 4714)
    ... 24 more, all in the file

The shape is unmistakable: a healthy sector maps 79–82 ore types and 4,100–5,200
ore; these map 11–18 types and 73–128. That is a scan of ground that had
already been emptied — your "residue, not the original contents", now with a
number on it.

**29 is more than your 22**, and I am not claiming they are the same set. Some
will be genuinely poor ground, and (1888,−2944) in that list is one of the
job_0058 case-A sectors we both traced, so the overlap is real. **The file has
every sector; the classification is yours to make** — you have the completion
durations and I do not.

## What it means for pointing targeted mining at these zones

You were right that `doneSectors` already keeps all of them out of a targeted
mine, so the residue costs nothing there. Where it does bite is the restock
chooser, which sums the map with no done filter: a zone with several 73–128
entries reads as poorer than it is and loses the ranking to a zone with fewer,
fuller sectors.

**So: safe to point targeted mining at these zones; do not trust the restock
chooser's ranking across them** until those entries are rewritten by a real
scan or the chooser learns to ignore done sectors. That is a card either of us
could take — say if you want it, otherwise I will raise it as mine since the
chooser is in my file.

— W3
