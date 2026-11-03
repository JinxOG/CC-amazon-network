---
to: SPEC-OWNER
from: W1
kind: info
subject: W1 queue empty: six cards closed, three not startable by me
date: 2026-11-02
status: open
---

# W1 queue empty: six cards closed, three not startable by me
Six cards fixed, each with a VALIDATION block and moved to "Done - not server
validated". Releases 1.9.157, 1.9.158, 1.9.159 and 1.9.160, all pushed to
master and byte-verified on the test server wherever a layer 2 was possible.
Nothing deployed to the live fleet.

1. **Ore below the dig floor is no longer reported as found** (1.9.157). Layer 2
   run w1-bf-a, read-only: the same sector one commit apart, "ore remains"
   became "clean", and the wasted re-mine trip is gone. Its failing half came
   free on untouched ground in run w1-skip-c.
2. **A sector that refuses every ore now says why** (1.9.154 + 1.9.157). Layer 2
   run w1-skip-d, 10 of 10. NOTE: 1.9.154 alone does NOT close it. Its line
   prints only when an ATTEMPTED ore failed, so a scan whose ore was all below
   the floor printed nothing at all and read exactly like empty ground -- that
   card's complaint in its most literal form. 1.9.157 closes it.
3. **A skipped scan level is no longer a finished sector** (1.9.158). Layer 2 run
   w1-scan-b, 10 of 10, and it caught it in the SURVEY pass.
4. **Mined material stranded in slot 14** (1.9.158). Layer 2 run w1-coal-b, 6 of
   6. TWO gates, and the second -- tidyAtDock scanning slots 5-13 only, so a
   miner whose one stranded item was in slot 14 came home, decided it carried
   nothing and left again -- was found by writing the test, not by running it.
5. **The miner ships its crash line before rebooting** (1.9.159). Layer 1 both
   ways; layer 2 NOT POSSIBLE by your 2026-10-26 ruling on W3's half.
6. **Adjacent-block dig: measured, then shipped** (1.9.160). 160 ore delivered on
   both arms, 30.7 -> 30.1 min, zero problems either side, 79 of 158 ores dug
   from beside. It matches its own arithmetic: 79 moves avoided at the T2-fitted
   400 ms is 31.6 s against a measured 36 s.

## Three things for you

**(a) An imported-world simulator scenario never installs the working tree.**
import_layout sets installed = true on every computer and fleet.lua writes the
repo's files only when not spec.installed. Both arms of my first measurement
therefore ran the snapshot's code and came back byte-identical; --code rev: is
equally powerless there, so neither arm was what it was labelled. Every
synthetic-world scenario is fine. Worth a line in the sandbox README before it
catches someone else.

**(b) 24 source-reading tests had been ERRORING, not asserting.** f:read("a") is
Lua 5.3 spelling and invalid on the 5.2 interpreter the suite runs on, so each
raised before its first assertion. 730/23 became 758/0 with a one-character fix.
The sharp edge: an erroring test is RED, so the mutation harness had been
scoring their mutants as killed. The verdicts held once they ran, but none were
earned. Carded -- the harness should require the intended test to PASS on
unmutated code before it credits a kill.

**(c) t2 reports omit world-changing rcon from INTERVENTIONS.** command is in
READ_ONLY, so run w1-skip-d reports "nobody reached into the run" having
force-loaded a chunk, filled 27 blocks of bedrock and placed an ore block.
Carded for the sandbox owner; the fix wanted is a verb-level split, not dropping
command from READ_ONLY.

## My remaining three are not startable by me

- **Ore index**: frozen behind the cleanup exit gate. Condition 1, the depth
  floor, has now landed and is noted on the card.
- **Flight lane**: needs a live job for evidence, and its own 2026-10-14..16
  evidence has aged out of the 14-day /logs retention. The GPS outage that
  blocked it is resolved -- the operator had not logged in for over seven days,
  so the GPS hosts' chunks unloaded.
- **Host sleep**: the watchdog half is built (sandbox/t2/watch_run.py); the
  other half is scenario.py taking the keep-awake hold itself and putting the
  Kernel-Power check in every report, which is the sandbox owner's file.

Baton available.
