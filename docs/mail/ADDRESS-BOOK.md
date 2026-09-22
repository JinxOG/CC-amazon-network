# Address book

Who to `SendMessage` when you ring the doorbell. **Session names are not
guessable** — several look alike — so nobody fills in a row but its owner.

## READ THIS BEFORE YOU RING ANYONE

**`cc-amazon-network-5e` is W6. `cc-amazon-network-e5` is W3.** Same characters,
last two reversed. W6 spotted it; it is the worst failure mode this book has,
because ringing the wrong one looks exactly like a delivered message nobody
answers. Copy the name, never type it.

**`cc-amazon-network-89` holds three workstreams** -- W2, W4 and W5 (code side)
-- confirmed by itself, 2026-09-14. Ringing any of the three reaches the same
session, so **name the workstream in your first line**: it decides which files
are in scope.

**W5 is two people.** That session is the code side and writes `server.js` and
`public/`. The server PC engineer writes no code, is **not a session here**, and
is reached only through the user -- deploys, restarts and anything needing the
machine itself. Do not ring 89 for a restart.

## Names changed again on 2026-09-16 — ring by the live row, not the book

The user gave sessions role titles, e.g. `(W3)Delivery/Logistics Engineer` and
`Head Engineer`. **Several titles now appear twice** — one live, one an old
offline session — and one offline row carries a W number that its session does
not hold (W1 said on 2026-09-14 that `(W1)Mining system engineer` is not them).

So, when you ring:

1. Run `ListAgents` **at send time**.
2. Take the row that is **interactive** and matches the engineer you mean.
3. If two rows share the name, send with the **`[ref]`** the listing shows, e.g.
   `Head Engineer [0ee45c]`. A bare name that matches two rows is ambiguous.
4. Treat a title as a hint, not a confirmation. The row below, re-confirmed by its
   owner, outranks it.

## Add your own row, once

When you next wake, run `ListAgents`. The first line says *"This session is
&lt;name&gt; [id]"*. That is you. Add the row, commit it, done.

| Engineer | Session name | Confirmed by |
|---|---|---|
| Head engineer / spec owner | `Head Engineer` — **the interactive row**; ref `[0ee45c]` on 2026-09-16 | itself, 2026-09-16 (was `cc-amazon-network-a2`) |
| W1 — Resource Intelligence | `(W1)Mining system engineer` | itself, 2026-09-21 |
| W2 — Planner | `cc-amazon-network-89` | itself, 2026-09-14 |
| W3 — Fleet & Dispatch | `(W3)Delivery/Logistics Engineer [77672f]` — **use the ref**, the title is shared | itself, 2026-09-22 (refs seen: `[845183]` 09-16, `[77672f]` 09-22; before that `cc-amazon-network-fe`, `-e5`) |
| W4 — Construction | `cc-amazon-network-89` | itself, 2026-09-14 |
| W5 — Bridge & Dashboard | `cc-amazon-network-89` (code side — see below) | itself, 2026-09-14 |
| W6 — Storage & RS | `cc-amazon-network-5e` | itself, 2026-09-14 |

**One session holds W2, W4 and W5.** `cc-amazon-network-89` answers to all three,
so ringing any of them reaches the same place. Say which workstream you mean in
your first line: it decides which files are in scope, and being woken for the
wrong one is a reply rather than a job.

**W5 is two people** (user ruling 2026-09-10). The session above is the **code
side** — it writes and commits the bridge and dashboard. The **server PC
engineer** writes no code: they deploy, restart and maintain the Minecraft server
and its machine. They are **not a session here**, so anything needing the machine
itself still goes through the user.

Candidate names seen in `ListAgents` on 2026-09-14, **unverified and not to be
messaged on this basis**: `(W1)Mining system engineer`, `Mining system engineer`,
`RS System interface Engineer`, `Head Engineer`, `Dispatch background
conversation`. (`cc-amazon-network-e5` was on this list and is now confirmed as
W3 in the table above, by itself.) Two of the rest are plainly the same
workstream and one carries a title this session actually holds, which is exactly
why guessing is banned.

## SESSION NAMES CHANGE WHEN A SESSION RESTARTS

W3 was `cc-amazon-network-e5` and is now `cc-amazon-network-fe` — same engineer,
same machine, same work, new name after a resume. **A row can go stale without
anyone touching it**, and the failure is silent: the sender gets "No agent named
... is reachable" only at the moment they try to ring, which may be hours after
the mail was filed.

So: **re-run `ListAgents` and check your own row at the start of every session**,
not only the first one. And if a ring fails, suspect a stale row before
suspecting the recipient is asleep — mail is filed either way and will be seen at
their next startup.

## Refs seen in ListAgents on 2026-09-22 (observations, not confirmations)

Rows are owner-filled, so these are only what one session saw. Ring by a fresh
`ListAgents`, not by this list.

- `Head Engineer [eb03c8]` — the row above says `[0ee45c]`, which **failed to
  resolve** on 2026-09-22 ("No agent named ... is reachable"). Two `Head
  Engineer` rows were listed, `[eb03c8]` (active 1d) and `[27a598]` (33d).
- `(W1)Mining system engineer [0a6b60]` — answered W3's query on 2026-09-21, so
  this one **is** W1 despite the 2026-09-14 note above. W1 says its own row is
  fixed.
- `RS System interface Engineer [3f4849]`, `(W5+4+2)Build system Engineer
  [bc19b4]`, `Mining system engineer [8de21b]`, `Dispatch background
  conversation [335556]` — all offline when seen.

## If a row is empty

Write the mail anyway and say in your reply to the sender that you could not
ring. The startup check catches it when that engineer next wakes. If the work is
blocked on them, mail the head engineer — a stalled baton is theirs to unstick.
