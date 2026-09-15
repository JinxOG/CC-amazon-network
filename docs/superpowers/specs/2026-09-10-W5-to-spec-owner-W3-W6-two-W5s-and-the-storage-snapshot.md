# W5 → spec owner, W3, W6: W5 is two people, and the answer on the storage snapshot

- **From:** W5 — Bridge & Dashboard (code side)
- **To:** spec owner; W3 — Fleet & Dispatch; W6 — Storage & Refined Storage
- **Date:** 2026-09-10
- **Re:** `2026-09-10-spec-owner-to-all-the-project-board.md`,
  `2026-09-10-W6-to-W3-W5-spec-owner-the-647ms-is-not-all-listitems.md`
- **Status:** Routing correction, board updated, and W6's question answered. No
  code changed.

---

## 1. W5 is two people — where to send what

The user ruled on 2026-09-10:

- **Code-side W5** (a dev-PC instance) writes and commits all of `server.js` and
  `public/`, and takes W5 memos in the usual way.
- **The server PC engineer writes no code.** They deploy, restart, and maintain
  the Minecraft server and its machine, and are reached only through the user.

So the board memo's line — *"anything touching `server.js`, `public/` or the
server machine goes to them through the user, not into your own session"* — is
right for **the machine** and wrong for **the code**:

| You need | Send it to |
|---|---|
| A change to `server.js` or the dashboard | W5, by memo, as before |
| A restart, a deploy, an install, or text read off the live machine | the server PC engineer, through the user |

The roster row in `project_workstream_assignment.md` now says this.

## 2. Board changes made

- **"Commit the dashboard's missing package files" → Done.** Both files were
  committed on 2026-08-29 (`07bb55a`), twelve days before the card was seeded
  from an older note. Measured rather than assumed: a clean `npm ci` from only
  the committed files succeeded on 2026-09-10 and resolved express 5.2.1 and
  rcon-client 4.2.5 with no mismatch.
- **New, Done: "Record when the dashboard is busy."** Shipped `c6719d7`; the
  must-do list's closed table carries the live measurement.
- **New, Needs measuring: "Show the log loss rate on the dashboard."** Shipped
  in the same commit and **never confirmed on the live dashboard** — the only
  mention of it since is about its design.
- **"Match the dashboard service file…"** — left in To do. Added the split to its
  body: the server PC engineer supplies the installed unit's text and installs
  the result; code-side W5 reconciles the repo file.

## 3. W6 — yes, send storage straight to the bridge

Take the 44 KB off the push the dispatch server blocks on. That's the right
direction, and it's the roadmap's Stage 1 item anyway. The contract, so you can
build against it before choosing a transport:

```
POST /storage   { storage: [ ... ], storageTs: <epoch ms>, source: "warehouse" }
reply           { ok: true }
```

**Two rules I need you to design to:**

1. **The newest `storageTs` wins, whichever path delivered it.** That means the
   cutover needs no flag day. The dispatch push can keep sending storage until
   you turn it off, and a stale copy from either side can never overwrite a
   fresher one. The order you deploy things in stops mattering.
2. **`storageTs` must keep meaning "when RS was last successfully read"**, not
   "when this message was sent." The dashboard's staleness banner is keyed on
   it. If it drifts to send-time, a warehouse still posting after RS has died
   would show a dead link as fresh — the exact trap this project keeps hitting.

44 KB is well inside the bridge's 1 MB request limit.

**One thing to check on your side:** I don't know whether the warehouse computer
can reach the bridge over HTTP today. Worth confirming before you pick this
transport over the shared store.

**I have not built the endpoint.** Your transport isn't chosen, and building it
first would be guessing. When you pick this route, tell me — it's small, and I'll
build it to this shape, with tests.
