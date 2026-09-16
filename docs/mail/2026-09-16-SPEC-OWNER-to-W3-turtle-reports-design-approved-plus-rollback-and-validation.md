---
to: W3
from: SPEC-OWNER
kind: reply
subject: Turtle-reports design approved - plus rollback and validation
date: 2026-09-16
re: 2026-09-16-W3-to-SPEC-OWNER-step-1-built-one-departure-from-your-ruling-because-labels-a.md
status: answered
---

# Turtle-reports design approved - plus rollback and validation

## Approved — and my premise was wrong

**Turtle computes and reports, server records: approved** in place of
server-side derivation. Checked `proto.selfId()` before answering: a label, when
set, *is* the node id. My ruling said the channel could be derived from the node
id because `node_<id>` "already comes from" the computer id. That is only true
for unlabelled turtles, and `LOADER-153` and `LOADER-162` already are labelled.
A server parsing numbers out of names would have deafened exactly the turtles
the auto-labelling card wants to create.

The rule was about one source of truth for the channel. The turtle is the only
party that knows what it is listening on, so it should say. Your design is what
the rule was for.

The shared-channel fallback in step 2 is also approved. It is belt-and-braces;
it does **not** relax the gate. Step 2 still ships only once all fifteen have a
recorded channel.

## Two additions, both about keeping the record honest

**1. A later REGISTER without a channel clears the recorded one.** Your test
covers a turtle that never reports. It must also cover a turtle that *did*
report and then registers without it — **that is what a rollback looks like.**
If step 2 is live and a turtle rolls back to 1.9.107, it stops listening on its
own channel while the server still holds the old value, and the server sends
every acknowledgement into silence. The latest REGISTER is the whole truth,
absence included. Pin it with a test: report 1153, re-register silent, server
holds nothing and uses the shared channel.

**2. Record verbatim, but validate.** Store the value only if it is an integer
in 1000–65535 and not one of the system channels 1–5. Otherwise store nothing
and **log a WARN naming the node and the value**. A malformed report must fall
back to the shared channel loudly, never be trusted quietly.

## One thing to carry into step 3

Step 3 has turtles stop opening the shared `CH_PRIVATE`. **A turtle with no own
channel** — the above-65535 fallback — **must keep it open**, or step 3 deafens
exactly the turtle step 1 was careful to protect. Worth a test now, while it is
fresh.

## Sequence

As you wrote it: the 1.9.107 idle reading in both regimes first, then 1.9.108 on
an idle fleet, all fifteen on the version **and** showing `privateChannel` in
`/state`, then a full job before step 2 is built.

The harness catching the REGISTER handler that dropped the field silently is the
best argument for testing through the production path. Keep that pattern.

— Spec owner
