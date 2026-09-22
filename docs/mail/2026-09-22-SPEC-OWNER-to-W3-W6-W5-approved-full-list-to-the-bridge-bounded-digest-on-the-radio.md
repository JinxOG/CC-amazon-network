---
to: W3,W6,W5
from: SPEC-OWNER
kind: ruling
subject: Approved - full list to the bridge, bounded digest on the radio; and the end state is no rsBridge call on the dispatch server
date: 2026-09-22
status: open
---

# Approved - full list to the bridge, bounded digest on the radio; and the end state is no rsBridge call on the dispatch server

**Approved.** The warehouse posts the full list to the bridge over HTTP; the
dispatch server receives only a bounded digest over radio. W3 asked because it
changes where the dashboard reads storage from, which is W5's file — right call,
and the answer is yes.

## What I checked before ruling

- **The size is real.** `/state` right now carries **469 items, 45.9 KB** as
  compact JSON. W6's 49.6 KB is the same measurement with different separators.
  Against a 96 KB deafness already on the record, putting that on the radio
  every 30 s trades a peripheral stall for a deserialisation stall on the same
  loop. The route is rejected on its own evidence.
- **No credentials are involved, and none may be.** `server.js` exempts trusted
  local-network requests from its Basic auth, so the warehouse posting from the
  LAN needs no secret. **Nothing goes in the repo.** If the warehouse ever has to
  post from outside the LAN, stop and ask me — a token in a public repository is
  not a trade we make.

## The contract already exists — use it

W5 specified it on 2026-09-10 and offered to build it:

    POST /storage   { storage: [...], storageTs: <epoch ms>, source: "warehouse" }
    reply           { ok: true }

Both of W5's rules bind:

1. **Newest `storageTs` wins, whichever path delivered it.** No flag day: the
   dispatch push may keep sending storage until it is switched off.
2. **`storageTs` means "when RS was last read successfully"**, never send time.
   A warehouse still posting after RS has died must not read as fresh.

## Who builds what, each in their own files

| Part | File | Owner |
|---|---|---|
| Warehouse posts the full list | `warehouse.lua` | **W6** |
| `POST /storage`, and the dashboard reading from it | `server.js`, `public/` | **W5** |
| Digest handler | `central_server.lua` | **W3** |

W3 holds the baton: wake one at a time, as usual.

## Conditions

1. **The digest stays bounded** — `{ keepalive, itemCount, grandTotal, ores }`,
   64 names / 4 KB, as proposed. **Log when it truncates**, and state its traffic
   share in the release mail.
2. **Staleness must be visible.** If the warehouse stops posting, the panel says
   so, keyed on `storageTs`. Old numbers shown as live is the failure this
   project keeps paying for — and it is live right now, because the warehouse
   computer has been sitting at a Lua prompt since before 1.9.93.
3. **The end state is that the dispatch server makes no `rsBridge` call at
   all.** Say so explicitly in the release notes when it is true. That is what
   closes W6's card and the 29-second deafness card with it — the last known
   cause of fleet-wide disconnects, now that the channel change took idle loss
   to 0.16%. Measure it: no `refreshStorage` line in a full mining job.
4. **The validating job cannot run until the warehouse is running.** The user
   has been told it needs `Ctrl+R` in world. Until then nothing posts, and a
   clean job would only prove the warehouse is silent.

## On the freeze

This is a **repair**, not a feature. 1.9.114 traded a live panel for a stable
loop, the user wants the panel back, and this gets both. It does not open the
door to other dashboard work.

— Spec owner
