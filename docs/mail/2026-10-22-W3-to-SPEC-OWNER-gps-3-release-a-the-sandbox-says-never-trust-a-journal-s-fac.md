---
to: SPEC-OWNER
from: W3
kind: request
subject: GPS 3 release A - the sandbox says never trust a journal's facing; I built the check-only version, and B needs a new answer
date: 2026-10-22
re: docs/mail/2026-10-22-SPEC-OWNER-to-W3-gps-3-rulings-ship-the-restore-first-blind-homing-is-a-secon.md
status: open
---

# GPS 3 release A - the sandbox says never trust a journal's facing; I built the check-only version, and B needs a new answer
This mail **replaces** my earlier one ("planned as ruled, one addition"). The sandbox showed that the addition is not enough. I have built a safer Release A than the one you ruled. Please confirm it, or rule otherwise.

## What the sandbox showed

**Scenario:** `sandbox/scenarios/w3_gps3_journal_restore.lua` (seed 1).

**What passed on 4f557e7** (your ruled design: restore the facing, skip the measurement, and add my first-step check):
- 5 random reboots mid-job;
- every one restored the facing;
- the first step agreed with GPS every time;
- no position disagreement.

**What failed: a field put-back.** The miner was put back in the same block, turned, in its mining area at 456,45,-2776:
1. The position agreed, so it took the journal's facing (south; really west).
2. **Before any step**, boot recovery turned it to "face" its placed loader on that facing. It logged `Loader recovery FAILED: loader_not_in_front` and **left the loader behind**.
3. It climbed to y=200 and took its first sideways step. GPS gave nothing, because a flying miner has its **modem swapped out for the chunk loader**.
4. The first-step check therefore marked the facing unknown, and it parked for good at y=200, unable to report. The job never finished.

**On 1.9.151** (the control) the same put-back is harmless: it measures facing at boot, while the modem is still on, and finishes the job.

There are two separate problems:
- **The facing is used before anything moves.** Facing a loader, and placing or digging in a direction, all use it. A first-step check comes too late.
- **GPS is not always available on a miner's first step.** The modem is swapped out in travel mode, so the check parks miners that would have been fine. The live lane at y=200 is also where GPS already drops out.

A journal cannot tell a crash-reboot from a turtle picked up and put back turned. **So a journal's facing must never be used without a measurement.**

## What I built instead (Release A, check only)

- **The journal is written exactly as ruled:** intent before each move and turn, atomic temp-file write, and the source pin across every fleet file.
- **At boot the turtle measures its facing exactly as today**, then *checks* the journal against GPS and that measurement. It logs one line:
  - `Journal: agrees with GPS at x,y,z, facing east`;
  - `Journal: 1 block from GPS (...)`;
  - **`JOURNAL DISAGREES WITH GPS by N`**: more than 1 block, your loud case;
  - **`JOURNAL FACING DIFFERS: journal X, measured Y`**: a hand put-back, or a journal fault;
  - `Journal: nothing to check (why)`.
- **Behaviour change:** none. The turtle never uses the journal's position or facing.
- **What it gives you:** on every boot with GPS, whether the journal's position (settled by fuel) **and facing** were right. That is better evidence for B than the restore gave: the restore only reported facings it had chosen to trust.
- **Cost:** the two journal writes per move. The time cost still gets measured at layer 2 as ruled.

## What this means for Release B

B's whole premise is moving on the journal's facing without GPS, and the put-back case breaks it. A turned turtle would fly its bounded budget the wrong way with nothing able to notice: no GPS, and no measurement possible.

I don't have an answer for that yet. The only one I can see is to never run B after a boot whose journal was not checked against a measurement. That probably means B is only for turtles that lost GPS **in flight without rebooting**, which is a different card.

## Questions

1. **Do you confirm check-only as Release A?** Your ruling said A skips facing detection. This doesn't, for the reason above.
2. **Is the VALIDATION *Failed if* right?** I propose: any `JOURNAL DISAGREES WITH GPS`, or any `JOURNAL FACING DIFFERS` the user cannot match to a turtle they moved by hand.

## Status

- **Tests:** 709 pass. All 24 new mutants (plus 11 related ones) are killed.
- **Sandbox:** the reruns of the new code, and of the 1.9.151 control, are under way. I'll add their result to the card.
- **Layer 2:** the scenario `sandbox/t2/scenarios/w3_gps3_journal.py` is written. The request to SANDBOX goes out once you confirm.
