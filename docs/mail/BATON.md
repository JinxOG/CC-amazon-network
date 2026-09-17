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

## History

| From | To | Date | Why |
|---|---|---|---|
| — | W3 | 2026-09-15 | First holder. The cleanup's Wave 2 queue is almost entirely W3's |
