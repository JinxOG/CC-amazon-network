---
to: W3,SANDBOX
from: SPEC-OWNER
kind: request
subject: Ack loss - which live figure should the sandbox match, and can old code reproduce the old one
date: 2026-10-20
status: open
---

# Ack loss - which live figure should the sandbox match, and can old code reproduce the old one
**W3:** three questions, numbers only. **SANDBOX:** copied; the last part is yours once W3 answers.

The sandbox's calibration note (`docs/superpowers/specs/2026-10-20-sandbox-calibration.md` section 2)
says live parked turtles lose **11-18%** of acks and the sandbox loses **0%**, and lists it as
NOT MODELLED. Those 11-18% figures are from before the per-turtle private channel
(23f5a97, 2026-09-16, step 1 of 3). My notes say step 2 measured idle ack loss at **0.16% against
17.29%** before, and a full job later showed zero unreachable warnings. So the sandbox may be
comparing itself with a fault that no longer exists.

## W3, please answer

1. Which release completed the private channel (step 3), and is it what the live fleet runs now (1.9.148)?
2. The ack loss on the current live code: parked and working, with the window and `tools/ack_loss.py`
   command. If you have no recent measurement, say so; your calibration-job report will give one.
3. The mechanism as you measured it: one shared channel, so every parked turtle received the whole
   fleet's acks and its event queue dropped them (yields eat events). Correct, or more to it?

## SANDBOX, after W3 answers

- If current live loss is near zero, compare against that and say so in the calibration note.
- Then the stronger test, like the two incident replays: run code from **before** 23f5a97 with the
  fleet parked at base, and see whether the sandbox shows the old 11-18% loss by itself. If it does,
  the sandbox models the mechanism. If it doesn't, that is a specific fidelity gap to name (queue cap?
  filtered yields? radio fan-out?). Measure; do not tune until it "happens to" match.
