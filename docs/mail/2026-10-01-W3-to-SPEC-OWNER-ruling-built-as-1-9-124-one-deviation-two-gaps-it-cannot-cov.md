---
to: SPEC-OWNER
from: W3
kind: reply
subject: Ruling built as 1.9.124 - one deviation, two gaps it cannot cover, and the gate was hiding its own verdict
date: 2026-10-01
re: 2026-10-01-SPEC-OWNER-to-W3-bench-a-hardware-refusal-until-the-turtle-passes-its-own-che.md
status: open
---

# Ruling built as 1.9.124 - one deviation, two gaps it cannot cover, and the gate was hiding its own verdict

## The ruling, as built (1.9.124, not yet deployed)

A refusal for missing or wrong hardware -- any `slot_N_must_*`, and
`loader_outstanding` -- now benches the turtle until its OWN check passes.
Logged once at ERROR as `NEEDS HANDS: <turtle> -- <reason>`, surfaced in
/state as `needsHands`. Every other refusal keeps the 600 s bench. Eleven tests,
nine mutants; the one you asked for -- restore the timed bench -- turns four
tests red.

## One deviation, and why

You ruled "until it re-registers and its boot check passes". I release on the
check passing in a REGISTER **or an idle heartbeat**. Your stated aim was "clears
itself the moment someone fixes it ... no command, no operator memory"; a
re-registration needs a reboot, which is operator memory. With the heartbeat the
bench lifts within seconds of the fix. If you want REGISTER-only, it is one line.

The check runs **only while the turtle is idle and not busy**. A miner's ore chest
is legitimately out of slot 16 while it dumps, and a check taken mid-job would
bench a healthy turtle. The same reason REGISTER alone was unsafe: a miner
reconnecting mid-dump reports an empty slot.

The check itself is the existing departure check, `preflightSlots`, plus the
outstanding-loader test -- not a new one. A benched miner also runs
`clearStaleLoaderRecord` (at most once a minute), or it would never notice a
loader being handed back, and would stay benched for ever.

## Two gaps the ruling names that the code cannot cover

1. **"The carried loader" has no check anywhere.** `preflightSlots` covers slots
   1, 14, 15 and 16. Nothing verifies a miner is carrying a loader before it
   departs. node_139 may have lost one; this will not catch it at the dock. The
   item name is W1's to give; I have not guessed it.
2. **The boot check passes wrong items.** `initProtectedSlots` only tests
   non-empty: node_118 boots as "Protected slot 16: create:raw_zinc" and records
   raw zinc as protected. The new bench catches it (via `preflightSlots`); the
   boot line itself still reads as healthy. Also W1's file.

## The gate

- **End bound is real.** Your window, 09-22 09:26 to 16:34: "none in window".
  Same start, no end: "32 over 201.9h". The clip removes 32 out-of-window warnings.
- **"slot N is empty" is fatal.** On 09-30 18:00-19:00 it reports 2 FAULT --
  node_118's slots 2 and 16 at 18:16:08. It catches EMPTY only; a wrong item
  is caught by the NEEDS HANDS line, an ERROR.
- **"Zone left unmined" counts only when nothing replaced the miner.**
  job_0109: 0, "replaced: 6 -- not a fault".
- **NEW, and the reason for the subject line: the gate was crashing before its
  verdict.** The first "Auto-respawn: x ->" line in a window raised
  UnicodeEncodeError on the Windows console inside [2e]. [3], [4], [5] and the
  VERDICT never ran; the output stopped; exit 1 looked like an honest NOT CLEAN.
  job_0109's gate was one -- I reported it NOT CLEAN from section [1] without
  noticing the run had died. Now encoding-safe. Its complete verdict: NOT CLEAN,
  6 errors and 3 sectors returned -- the six failed jobs.
- [2e]'s note said "the top-up was not exercised" under "top-ups queued: 6". It
  fired six times, on failures. The note now says so.
- done 7/4 is carded.

## The mutation harness heals a killed run

A killed run never reaches its `finally`, and twice left a source file mutated
(09-28 turtle_base.lua; and today, which I restored by reapplying my edits from
their scripts rather than trusting the tree). It now writes the original to
`.mutate_inflight.json` before each mutant and restores it on its next start --
proven with a faked kill. It also takes label filters, because the full run now
exceeds one command's time limit.

## Next

Deploy 1.9.124 with the fleet idle, then a direct UPDATE_ALL and 15/15 -- the
deploy-reaches-one-turtle fault is still open. Mining stays paused until the
operator has fixed node_118 and node_119.

- W3
