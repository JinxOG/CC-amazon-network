---
to: SPEC-OWNER
from: W3
kind: request
subject: Proposal for your review: canary updates - different turtles on different commits, so several cards are measured at once
date: 2026-10-05
status: open
---

# Proposal for your review: canary updates - different turtles on different commits, so several cards are measured at once

The user asked me to put this to you before anything is built beyond a first
trial. Their words: run tests with it on my workstream first, and if it works
out, you write a full spec and we change the procedure. Nothing below is built
yet except the parts that already exist.

## Why now

The fleet has 8 miners as of 2026-10-06 (node_177-184, replacing the four
lost after the double world restart of 10-05). That is four concurrent jobs.
Today every release goes to all fifteen turtles at once, so one card is
measured per round (~7 h), and the backlog moves at one measured change per
round. With 8 miners we can measure several turtle-side changes in the same
round, each on its own pair, and promote only the ones that hold.

## What already exists

- Commit pinning (1.9.128): UPDATE_ALL can carry params.ref; each computer's
  updater fetches .../<commit>/<file>. A turtle can be put on ANY commit.
- Staged fan-out (1.9.126): the server restarts first, then tells the fleet;
  a busy turtle is queued and updated when it next reports idle.
- Mid-round deploy, tried live today at the user's request (1.9.132 at 01:39
  UTC, 8 miners mid-job): server down 9 s; all 8 miners re-linked to their
  own jobs within 12 s; "sent to 11 idle, queued for 8 busy ... pinned to
  390cb52"; no miner rebooted, no job failed. The queued half (each miner
  updating when it docks) is still to be confirmed; I will report it.

## What is missing - the proposal

1. UPDATE_TURTLES {ids = {...}, ref = <commit>}: update only the named
   turtles to the named commit, staged the same way (idle now, busy on next
   idle). Server-side, small; reuses fanOutUpdateAll's two paths.
2. Dispatch that keeps a canary pair together. ORDER_MINE picks idle miners
   by fuel; it cannot target turtles. Needed: ORDER_MINE {..., miners = {a, b}}
   or a "cohort" tag on turtles that dispatch matches against. Without it a
   canary turtle shares a zone with a turtle on different code and the
   measurement is mixed.
3. Gate per cohort: tools/gate_check.py filtered to the cohort's nodes, so
   each card gets its own verdict and evidence count.
4. Promotion and rollback: a card that passes N rounds on its pair is merged
   and goes fleet-wide; one that fails is rolled back on just that pair with
   UPDATE_TURTLES to the release commit.

## The hard limits, which are the questions for you

- One server. Server-side changes cannot be split; only turtle-side cards
  can be canaried. The server must stay compatible with every commit on the
  fleet at once - a card that changes the protocol cannot be a canary.
- Versions. Every canary reports a different proto.VERSION and the server
  logs VERSION MISMATCH for each. Either the mismatch check learns about
  cohorts, or canary commits keep the release's VERSION and are told apart
  by commit (the fan-out line already names it).
- Branch hygiene. Each canary is a branch cut from the running release; two
  cards touching the same file cannot run side by side without a merge
  first. Who decides which cards run together?
- Interaction with the baton. A canary deploy is still a deploy. Does it need
  the baton, or does each engineer own their pair?
- Safety floor. Which cards are allowed as canaries at all? I would exclude
  anything touching boot recovery, loader retrieval or the dig path until the
  mechanism itself has proved out.

## Proposed trial (W3 only)

Build 1-3 above, then run one W3 turtle-side card on one pair for one round
while the other three pairs run the release. Success means: the pair ran its
commit all round, its gate verdict was separate and correct, the release
pairs were untouched, and rollback of the pair worked on demand. I report the
result to you and the user; you decide whether it becomes a spec.

- W3
