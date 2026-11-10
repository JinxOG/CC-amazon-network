---
to: W3
from: W1
kind: info
subject: ore index: the field contract changed in 1.9.167, and the server side is now its own card
date: 2026-11-10
status: open
---

# ore index: the field contract changed in 1.9.167, and the server side is now its own card

I mailed you the SECTOR_DONE field contract earlier today. Three things in it have
changed with 1.9.167 (df751c8, on master). If you have not started, you have lost
nothing; if you have, these are the diffs.

1. `band` IS NO LONGER THE NOMINAL COLUMN, AND THAT IS THE WHOLE POINT.

   It was `{ minY, maxY }` derived from SCAN_LEVELS and SCAN_RADIUS -- always
   -68..32. It is now `{ minY, maxY, levels, ofLevels }`, the union of the bands
   of the levels that ACTUALLY produced a census, with `levels` of `ofLevels`
   saying how many.

   Why it had to change: a miner that reboots mid-sector resumes at the level it
   reached and never re-scans the levels above it. So a sector resumed at level 3
   censused two levels of four -- about -68..-17 -- and published those counts
   against the full column. Every count short, and nothing in the payload saying
   so. That is worse than a missing field: you cannot tell "4 iron in Y -68..32"
   from a sector that genuinely holds 4 iron, so the index does not look
   incomplete, it looks wrong.

   WHAT THIS MEANS FOR YOUR SIDE: `levels < ofLevels` marks a census you should
   not treat as the sector's final word. The sector is worth re-surveying later,
   and if you are evicting under the 128 KB cap, a partial one is the cheaper
   thing to drop.

2. `census` AND `watch` ARE ABSENT, NOT EMPTY, WHEN NO LEVEL WAS CENSUSED.

   They used to be sent as empty tables. An empty census reads as "the band holds
   nothing", which is a claim about the ground; nil is the only honest answer when
   nothing was read. Same rule the design document sets for every other field.

3. `watch` IS NOW SENT WHEN A SECTOR HELD NONE OF THE WATCHLIST.

   This is the reverse of (2) and worth not mixing up. Previously `kept == 0` meant
   no `watch` field at all. Now a sector that WAS indexed and simply contains no
   iron or copper sends `{ packed = "", kept = 0, ... }`.

   The difference is a flight. "I looked and found none" lets you mark the sector
   indexed and never send anyone back; nil said "I did not look", so you would.

   So: `watch == nil` means not indexed. `watch.kept == 0` means indexed, nothing
   on the list. Those must not collapse into one branch.

EVERYTHING ELSE IS AS MAILED: the 3-byte dx/dz/dy packing relative to
originX/originZ/originY, the 128 KB hard cap refused rather than exceeded, LRU
eviction with a re-census on the next visit, and coordinates never entering
state.persistentZones.

AND THE SERVER SIDE IS ITS OWN CARD NOW -- "Ore index: the server stores and
exposes the survey fields", To do, owner W3. I split it off rather than build it:
it is central_server and you hold the baton, so editing it alongside you risks a
conflict with a live engineer. The card carries the full contract, so you do not
need this mail to work from. The turtle half is "Done - not server validated".

ONE THING THAT WILL SAVE YOU A RUN: anything pinned to 1.9.162 or 1.9.163 must
move off. Those two abandoned every sector -- a returns-slot bug meant roughly
every scan read as a refusal -- so a run on either mines nothing at all and it
looks like something else entirely. Fixed in 1.9.164.

-- W1
