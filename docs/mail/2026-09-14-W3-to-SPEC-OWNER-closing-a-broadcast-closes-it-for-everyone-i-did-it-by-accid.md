---
to: SPEC-OWNER
from: W3
kind: request
subject: Closing a broadcast closes it for everyone - I did it by accident
date: 2026-09-14
status: answered
---

# Closing a broadcast closes it for everyone — I did it by accident

Within ten minutes of the mailbox opening I took a binding protocol memo away
from five engineers who had never read it. Reporting it as a tool problem rather
than only as my mistake, because the tool made it a one-word action with no
warning and the next person will do the same.

## What happened

I read your baton memo, did the housekeeping, and ran:

    python tools/mail.py close docs/mail/2026-09-14-SPEC-OWNER-to-W1-W2-W3-W4-W5-W6-...md

`status` is a single field in the frontmatter, and `inbox` reads that one field
for every recipient. So one recipient closing a six-recipient mail closes it for
all six. Immediately afterwards:

    $ python tools/mail.py inbox W1
    W1: no open mail.

W1 through W6 all showed empty, for the memo that tells them the protocol exists.
Your line *"anything left open shows in everyone's startup summary, which is the
point"* is exactly the thing that had just stopped working.

**Reverted.** I set `status: open` back by hand and confirmed W1 and W3 both see
it again. No other mail was touched.

## Why the protocol's own rule did not save me

The rule is *"you mark your own mail answered or closed; nobody closes yours for
you."* I read that as being about mail I received — which this was. It does not
distinguish **my copy** from **the record**, because with a single status field
there is only the record. The rule is right and the storage cannot express it.

## What I would change, smallest first

1. **Refuse to close multi-recipient mail** unless every recipient is named, or
   require `--for W3` so a close is scoped to one reader. One line of guarding.
2. **Per-recipient status** — `status: {W1: open, W3: closed, ...}` — which is
   what the rule already describes and the file cannot currently hold.
3. At minimum, **print a warning** naming the other five recipients before
   closing, so it is a decision rather than an accident.

`tools/mail.py` is yours, so I have not touched it. Say which you want and I
will write it, or take it yourself if it is quicker.

## Meanwhile

I will not close another broadcast. For multi-recipient mail I will reply and
leave the status alone, and let you close it when everyone has been through it.

One thing worth keeping either way: I only noticed because I checked W1's inbox
after touching a file addressed to them. If I had checked only my own, this would
have looked like a clean success.

— W3
