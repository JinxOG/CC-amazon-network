---
to: SPEC-OWNER
from: W1
kind: reply
subject: the dumping miner: ~2000 ore is right, the dumps are healthy, and nothing was re-scanned - my log line was the problem
date: 2026-11-24
status: open
---

# the dumping miner: ~2000 ore is right, the dumps are healthy, and nothing was re-scanned - my log line was the problem

Your three questions from 2026-11-12, measured from `w3-bay-types-c`'s own log.
Late, and that is on me. The short version: all three answers are "normal", and
the reason you had to ask is a line of mine that named no level.

## 1. Is about 2000 ore at one level in that sector what you expect?

**Yes.** node_179 found 2018 at Y=16 on the survey pass and 2013 on the mining
re-scan. I had independently measured 2013 ores at that same level of that same
sector weeks earlier, in run `w1_skip_reason-1102-101833`, and it is the reason I
chose (1920,-2624) for the resume card — a sector whose first level has real work
in it. Two measurements taken for different purposes agreeing to within five ore
is about as solid as this gets.

## 2. Is a DUMPING phase every 1-3 minutes normal progress for that much ore?

**Yes, and I can say so from evidence rather than impression.** node_179 logged
41 DUMPING phases. Of those, 10 came from the before-every-dig room hook, each
reporting `only 1 free mining slot(s)` — the threshold that triggers it.

The number that settles it: **zero `banking left N free mining slot(s)`
warnings.** That line fires when a dump completes and the pack is still nearly
full, which is the signature of a dump that freed nothing — rock recorded as
protected hardware, or a chest that could not be placed. None appeared, so every
dump did its job.

So the picture is a miner working 2013 ore at one level through nine payload
slots, plus the tunnelling debris that getting to each ore produces. Filling up
every minute or two is the volume, not a fault. If it had been a fault, that
warning is what you would have seen.

## 3. Do the repeated Y=16 scan lines mean ore is being mined, or the level redone?

**Neither — nothing was re-scanned, and this is the one that was my fault.**

Those four consecutive lines were the four DIFFERENT levels of the survey pass.
The phase lines above them name the levels correctly:

```
phase SCANNING — 1920,-2624 Y=16     Found 2018 ore blocks at this level
phase SCANNING — 1920,-2624 Y=0      Found 1827 ore blocks at this level
phase SCANNING — 1920,-2624 Y=-32    Found 1175 ore blocks at this level
phase SCANNING — 1920,-2624 Y=-52    Found  686 ore blocks at this level
```

Descending, as ore density should. Then at 13:47:43 RETRIEVING and
PLACING_LOADER, and at 13:48:58 one genuine re-scan of Y=16 finding 2013 — that
is the survey-to-mine handover: the miner surveys all four levels, comes back for
its loader, re-places it at the level it will work, and takes a fresh list.

**The server logged only TWO `Sector (1920,-2624) Y=16 scan` lines all job**
(13:43:56 and 13:49:01), not one every 3-6 minutes. The "every 3-6 min"
impression came from my per-level line, which said **"at this level"** and named
no level — while carrying the number a reader naturally compares. Four of those
in a row read exactly like one level being scanned over and over.

**Fixed in 1.9.173 (5158fe3):** it now reads `Found N ore blocks at Y=<level>
before cross-level dedup`. One omission cost you an investigation, and it was
mine.

And in the spirit of saying what went wrong rather than only what was fixed: my
first version of that fix referenced a variable that does not exist in
`scanSector`, so it would have raised on every scan of every level. It compiled,
and the syntax check passed. What caught it was an unrelated test failing on the
changed text, which made me go and read the scope.

## What this does NOT say

Nothing here examines whether the survey-then-mine double scan of the first level
is worth its cost. A radius-16 scan reads about 17,500 blocks, and the first
level is scanned twice per sector by design. That may be the right trade — the
survey decides whether the sector is worth mining at all — but I have not
measured it and am not claiming it either way. Say the word if you want that
measured as its own question.

-- W1
