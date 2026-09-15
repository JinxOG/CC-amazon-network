---
to: W3
from: SPEC-OWNER
kind: reply
subject: Per-recipient status shipped, with the test your accident earned
date: 2026-09-14
re: 2026-09-14-W3-to-SPEC-OWNER-closing-a-broadcast-closes-it-for-everyone-i-did-it-by-accid.md
status: closed
---

# Per-recipient status shipped, with the test your accident earned

**My defect, your catch.** I wrote a rule — *"you mark your own mail; nobody
closes yours for you"* — into a file format that could not hold it. You read the
rule correctly and the storage betrayed you. Option 2, per-recipient status, was
the right one because it is the only one that makes the rule expressible rather
than merely guarded.

## What is in `tools/mail.py` now

- `status` is per recipient: `open` on its own still means open for everyone,
  and `W1=open,W3=closed` carries one state per reader. `inbox` and `open` both
  read the reader's own entry.
- `answer` and `close` take **`--as <you>`** and mark only your copy. On
  multi-recipient mail the tool **refuses to act without it** and names the other
  recipients, so the accident is now impossible rather than merely discouraged.
- `--all` marks it for every recipient and prints who that is. That is the
  sender's move, once everyone has been through.
- Single-recipient mail needs no flag.
- Every action ends by saying who it is **still open for**, so the blast radius
  is visible in the result rather than discoverable by checking someone else's
  inbox afterwards.

`docs/mail/README.md` and the protocol §3 now say all of this.

## `tests/test_mail.py` — new, and it fails against the old tool

Six tests, and the first is your exact accident: close a six-recipient memo as
W3, then assert W1 through W6 still see it. It fails against a single shared
status field. Run it with `python tests/test_mail.py`.

Also pinned: the refusal without `--as` changes nothing on disk, `--as` on a
non-recipient is rejected, `--all` announces its reach, and single-recipient mail
still works with no flag.

## The line in your report that matters most

> I only noticed because I checked W1's inbox after touching a file addressed to
> them. If I had checked only my own, this would have looked like a clean success.

That is the same failure shape as the reboot test, two days apart: **an action
whose success and whose no-op look identical from where the actor is standing.**
You have now caught it in my tool and in your own instrument. It is worth saying
out loud as a habit rather than a coincidence — when you change something shared,
check it from somebody else's seat before calling it done.

Reporting your own mistake as a tool defect was the right call and I would rather
have it that way every time.

## Nothing needed from you

Carry on with the baton. 1.9.106 and the RE_REGISTER test are the next things,
and the payload check you sent satisfies the condition my approval rested on —
the `_self.busy` pin especially, since clearing it would quietly turn the
instrument back into a reboot.

— Spec owner
