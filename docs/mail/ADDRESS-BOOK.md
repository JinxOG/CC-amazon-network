# Address book

Who to `SendMessage` when you ring the doorbell. **Session names are not
guessable** — several look alike — so nobody fills in a row but its owner.

## READ THIS BEFORE YOU RING ANYONE

**`cc-amazon-network-5e` is W6. `cc-amazon-network-e5` is W3.** Same characters,
last two reversed. W6 spotted it; it is the worst failure mode this book has,
because ringing the wrong one looks exactly like a delivered message nobody
answers. Copy the name, never type it.

**`(W5+4+2)Build system Engineer [15934f]` holds three workstreams** -- W2, W4
and W5 (code side) -- confirmed by itself, 2026-09-22. Ringing any of the three
reaches the same session, so **name the workstream in your first line**: it
decides which files are in scope. (Was `cc-amazon-network-89`; that name is dead.)

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
| Head engineer / spec owner | `Head Engineer` — ref `[62be51]` on 2026-09-22 (was `[0ee45c]`, before that `cc-amazon-network-a2`). An offline `Head Engineer [27a598]` also exists | itself, 2026-09-22 |
| W1 — Resource Intelligence | `(W1)Mining system engineer` | itself, 2026-09-21 |
| W2 — Planner | `(W5+4+2)Build system Engineer [15934f]` | itself, 2026-09-22 |
| W3 — Fleet & Dispatch | `(W3)Delivery/Logistics Engineer [068af7]` — **use the ref**, the title is shared | itself, 2026-09-23 (refs seen: `[845183]`, `[77672f]`, `[224d49]`, `[068af7]`; the ref moves on every resume) |
| W4 — Construction | `(W5+4+2)Build system Engineer [15934f]` | itself, 2026-09-22 |
| W5 — Bridge & Dashboard | `(W5+4+2)Build system Engineer [15934f]` (code side — see below) | itself, 2026-09-22 |
| W6 — Storage & RS | `cc-amazon-network-5e` | itself, 2026-09-14 |

**One session holds W2, W4 and W5.** `(W5+4+2)Build system Engineer` answers to
all three, so ringing any of them reaches the same place. Say which workstream you
mean in your first line: it decides which files are in scope, and being woken for
the wrong one is a reply rather than a job. (Was `cc-amazon-network-89` until
2026-09-22; an offline `(W5+4+2)Build system Engineer [bc19b4]` is an earlier
instance of the same name, so **use the ref**.)

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
- `(W1)Mining system engineer` — **moved machines on 2026-09-22**: was
  `[0a6b60]` (Remote Control, another machine), now `[f715fa]` (a Claude
  Desktop session on THIS machine, started by the user). A send to the old ref
  was refused with a warning that a local session was claiming the name and
  that this looked like impersonation. **It was legitimate** — the user
  confirmed they started it. See "when a name moves machines" below.
- `RS System interface Engineer [3f4849]`, `(W5+4+2)Build system Engineer
  [bc19b4]`, `Mining system engineer [8de21b]`, `Dispatch background
  conversation [335556]` — all offline when seen.

### Later on 2026-09-22, seen by W5+4+2

The churn continued within the same day, which is the argument for rule 1 above
rather than for a better-maintained table:

- **`cc-amazon-network-a2` is dead.** A ring to it was refused outright. That was
  the name the head engineer gave for itself in a message the same day, so a name
  handed over in conversation can be stale by the time it is used.
- **The head engineer was not in the listing at all** — only an offline
  `Head Engineer [27a598]`. Neither `[62be51]` from the row above nor `[eb03c8]`
  appeared. Mail to them therefore waits for their next startup; nothing is lost,
  but do not read silence as disagreement.
- **W3 is `[068af7]`** — interactive and idle, started minutes earlier. The row
  above says `[77672f]`, so W3's ref moved again. Only one row carried that title
  in the listing, so there was no ambiguity to resolve.
- **This session became `(W5+4+2)Build system Engineer [15934f]`**, replacing
  `cc-amazon-network-89` in three rows. Nobody could have rung W2, W4 or W5
  between the rename and this edit, and there would have been no sign of it.

## When a name moves machines

A session name can move from one machine to another (the user starts a session
elsewhere). When it does, a send to the old ref is not just "not found": the
host reports that a session on this machine now **claims** that identity, hides
it from `ListAgents`, and says impersonation is suspicious.

That warning is correct to raise and wrong to act on alone. On 2026-09-22 it
fired for a W1 session the user had started themselves.

**So: do not message the new claimant, and do not assume bad faith. Ask the
user.** They know which sessions they started. Once confirmed, update the row
with the new ref and note the move, as above.

## If a row is empty

Write the mail anyway and say in your reply to the sender that you could not
ring. The startup check catches it when that engineer next wakes. If the work is
blocked on them, mail the head engineer — a stalled baton is theirs to unstick.
