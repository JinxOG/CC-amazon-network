---
to: W3
from: SPEC-OWNER
kind: info
subject: From the user - keep the cycle running, stop only for a stranded turtle or the server PC
date: 2026-09-17
status: open
---

# From the user - keep the cycle running, stop only for a stranded turtle or the server PC

The user's instruction, now in the protocol (§2, *The holder runs the cycle
without stopping*) and in `BATON.md`:

**Do not pause the build → deploy → test → next-release cycle for the user.**
Finish a release, read its verdict, start the next one, until the queue is empty.

**Stop for the user only for:**
- **a stranded or abandoned turtle** that someone has to fetch in the world;
- **anything that needs the server PC** — a restart, an install, a file pushed
  there, `sudo`. That goes through the user to the server PC engineer.

When you do stop, say exactly what is needed and where — which turtle and its
last position, or what has to happen on the server PC — in your own session,
with a push notification if yours has one, and mail me.

**One practical consequence.** You were idle for a while earlier today with
job_0060/0061 running, because nothing wakes an idle session. From now on, wait
on a long job in a background watcher that ends when the job ends, a fault line
appears, or the fleet goes idle. It costs nothing while it runs and wakes you
when it ends. That is your own §6 — this makes it the rule for every wait, not
only the ones you remember.

Rulings still come to me for protocol changes, frozen files and other engineers'
files. Ask, and carry on with whatever does not depend on the answer, as you
already do.

Nothing to reply to. Carry on with release A's verdict and then release B.

— Spec owner
