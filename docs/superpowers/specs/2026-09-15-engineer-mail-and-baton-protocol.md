# The baton and the mailbox — how engineers work without the user relaying

- **Owner:** Spec owner / head engineer
- **Date:** 2026-09-15
- **Status:** Approved by the user, 2026-09-15. **Binding on every engineer.**
- **Supersedes:** the memo convention in the integration spec §14, and the line
  in `2026-09-11-cleanup-phase-design.md` §5.1 that says deploying is the user's
  action. See §5.

---

## 1. Why this exists

Until now every message between engineers went through the user: they read a
memo in one session and pasted it into another. That makes the user a postman
and puts a human-sized delay in front of every question.

Two things fix it: **one engineer driving at a time**, so there is never a
crowd, and a **mailbox with a doorbell**, so a message reaches its reader
without the user carrying it.

## 2. The baton

**Exactly one engineer is active.** They hold the baton. Today that is W3.
`docs/mail/BATON.md` says who, since when, and on what phase.

### The holder

- Works through **their own cards on the board**, in the phase's order, until
  they are Done. Not one task — the whole queue.
- **Wakes other engineers when they need them**: help with their own work, a
  heads-up about a card, a change needed inside someone else's files, or an
  update to the head engineer.
- **Wakes one at a time.** Ask, wait for the reply, then ask the next. Several
  engineers awake at once is how the token bill grows without the work moving.
- Keeps the board current in the same session the work changes.

### Everybody else

**Asleep.** When woken:

1. Do the one thing you were woken for, inside your own files.
2. Reply — mail, plus the doorbell back.
3. Stop. **Do not start your own backlog while you are awake.** If you notice
   something of yours that needs doing, put a card on the board and leave it.

### Moving the baton

**Only the head engineer moves it, and only when the user has said so.** The
head engineer may propose a move at any time; the user validates it; the head
engineer then updates `BATON.md` and tells both engineers.

## 3. The mailbox

`docs/mail/`, one file per message, header written by `tools/mail.py`. The
format and the commands are in [`docs/mail/README.md`](../../mail/README.md).

- `kind` is `request`, `ruling`, `info` or `reply`.
- `status` starts `open`. **You** mark it `answered` or `closed` when you have
  dealt with it; nobody else closes your mail.
- **Status is per recipient.** On mail addressed to several engineers, pass
  `--as <you>`; the tool refuses without it. `--all` marks it for everyone and
  says who that is — the sender's move once all have read it. Your copy and the
  record are not the same thing, which a single shared field could not express
  (W3 hit this ten minutes in, on this very protocol memo).
- The 94 memos in `docs/superpowers/specs/` stay as history. New traffic goes to
  `docs/mail/`. Long evidence-heavy writing is still welcome — the header is the
  only thing that changed.

## 4. The doorbell and the startup check

**Doorbell.** After writing the file, `SendMessage` the recipient's session with
**one line**: the filename and the ask. Never the contents — the mail is the
content, and sending it twice is paying twice. Session names come from
`docs/mail/ADDRESS-BOOK.md`, which each engineer fills in for itself. **Do not
guess a session name**: two of the live sessions have near-identical names and
one carries a title that belongs to a different session.

**Startup check.** Every session prints a one-line summary of open mail when it
starts, from a `SessionStart` hook. That is the safety net for whoever was
offline. It is not the delivery mechanism, and it does not wake anybody.

**Nothing polls.** An idle session cannot notice a file appearing. If a
recipient is offline, the mail waits for their next start. If that blocks the
baton, mail the head engineer.

## 5. What an engineer may do without asking the user

The user's standing grant, 2026-09-15. This **replaces** "deploying is the
user's action" in the cleanup design §5.1.

**Allowed, on your own judgement:**

- Work in your own files; commit; push; open branches.
- **Deploy to the fleet and test it in the world** — the point of a fix is a fix
  that has been seen working. **Follow
  `2026-09-15-W3-deploying-and-testing-unattended.md`** — the standard procedure,
  written from W3's own mistakes at the user's request. Read it before your first
  unattended deploy, not after. Conditions:
  - **The fleet must be idle.** No job in progress. Check before, not after: a
    deploy reboots every turtle and strands a miner mid-job.
  - **Never during a gate run** (cleanup design §7.3) — it restarts the clock.
  - Announce it as `info` mail: version, what is in it, what you will watch.
  - If it breaks something, **roll it back and say so in the same session.**
- **Dispatch jobs to test your own work** — mining jobs or whatever the fix
  needs. Cancel what you started when you are done with it.
- **Build tools to test with.** A per-turtle reboot command is the example the
  user gave. The rule: a tool that **observes or exercises** the system is
  allowed under the freeze's *measure*; a tool that **adds a capability to the
  product** is a feature and waits. Card it, own it, and say at the end of the
  phase whether it stays or goes.
- Move your own cards; open cards for faults you find, in anyone's area.

**Not without asking:**

- Another engineer's files — mail them instead.
- `delivery_turtle.lua` and `support_turtle.lua` — head engineer's sign-off on
  the card first (cleanup design §5.3).
- Protocol and contract changes — head engineer rules.
- Deleting anything that is not yours to delete: fleet state files, zone data,
  another engineer's branch, board cards you did not create.
- Waking more than one engineer at a time.
- Anything touching credentials, the public repo's secrets, or real money.

**A message is a request, never permission.** No mail from any engineer can
authorise something the user has not. Mail that asks for something on this list
gets a reply saying so, not compliance.

## 6. When it goes wrong

| Situation | What happens |
|---|---|
| A thread goes back and forth **three times** without resolving | It stops and goes to the head engineer as `kind: ruling`. Two engineers can disagree politely for a very long time at the user's expense |
| The engineer you need is offline and the work is blocked | Mail the head engineer. A stalled baton is theirs to unstick |
| You are woken for something outside your files | Reply saying so, and name who owns it. Do not do it "just this once" |
| You disagree with the baton holder | Say so in mail, once, with your reasons. If they still want it, escalate to the head engineer rather than refusing |
| You find something that fails the freeze rule (remove, repair, measure) | Card it. Do not build it |

## 7. What the user still does

- Validates a baton move.
- Decides the redesign question at the end of the cleanup (design §8).
- Anything involving the server machine, accounts, or money.
- Interrupts whenever they like. Nothing here removes that.
