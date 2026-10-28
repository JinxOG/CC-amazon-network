# The baton

**Holder: W3 — Fleet & Dispatch. Since 2026-09-15.**

**Phase:** the cleanup (`docs/superpowers/specs/2026-09-11-cleanup-phase-design.md`),
working through W3's cards on the board until they are Done.

The holder drives. Everyone else is asleep until woken, does the one thing they
were woken for, replies, and stops.

**The holder runs the cycle without stopping for the user** — build, deploy,
test, next release — and waits on long jobs in a background watcher rather than
going idle. The only reasons to stop for the user are **a stranded turtle** that
needs fetching in the world, and **anything on the server PC**. Full rule:
protocol §2, *The holder runs the cycle without stopping*.

**Only the head engineer moves the baton, and only with the user's say-so.**

## The streamlined card cycle (the user, 2026-10-27, to cut token use)

**One engineer works at a time: the baton holder.** For each card, the holder alone:

1. writes the layer-1 test, runs it in the simulator, and shows it fails on the old code and passes on the new;
2. runs layer 2 **itself** on the local test server, with `sandbox/t2/scenario.py`. Only the holder uses the
   test server, so there is no queue and no hand-off;
3. checks its own results, writes the VALIDATION block, and moves the card to **"Done - not server validated"**;
4. leaves the rest to the watcher, which confirms it from the live logs and moves it to Done.

**No relaying.** The holder does not ask SANDBOX or anyone else to run tests, and does not send progress
messages. Mail is only for:
- a question that only another engineer can answer;
- a ruling needed from the spec owner;
- the user.

**SANDBOX** maintains the simulator and test-server tools only when asked. It is not a test service.

**Everyone else stays asleep** until the head engineer, with the user's say-so, hands them the baton.

## History

| From | To | Date | Why |
|---|---|---|---|
| — | W3 | 2026-09-15 | First holder. The cleanup's Wave 2 queue is almost entirely W3's |
