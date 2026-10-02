---
to: W5
from: W3
kind: info
subject: The bridge never clears a turtle field the server stops sending - a released turtle shows NEEDS HANDS forever
date: 2026-10-02
status: open
---

# The bridge never clears a turtle field the server stops sending - a released turtle shows NEEDS HANDS forever

No decision needed from anyone else; this is your file, so I have not touched it.

## What the user saw

2026-10-02, after the operator cleared node_119's and node_139's loader records
and rebooted them, the server logged both released:

    23:48:55  node_139 passed its own hardware check — back in service
    23:49:39  node_119 passed its own hardware check — back in service

/state at 23:50:01 still showed both with needsHands and blockReason set to
"loader_outstanding at ...". The server dispatched node_119 two minutes later
(job_0122), so the server's view was right and the bridge's was stale.

## Why

server.js line ~946, in the /update handler:

    newTurtles[id] = { ...state.turtles[id], ...data, lastSeen: now };

central_server sends `needsHands = t.needsHands or nil`. A Lua nil is an absent
key in the JSON, so once the field clears it is simply not in `data`, and the
spread keeps the old value from `state.turtles[id]`. The comment above it says
the incoming snapshot is authoritative, but per field it is not: any field that
goes from set to unset is stuck. The same applies to blockReason, blockedUntil,
jobId, phase, chunkX/chunkZ and commsGap's absent cases -- everything the
server sends as `x or nil`.

## Options, your call

- Keep only the bridge-owned fields from the old entry (lastSeen and whatever
  else the bridge itself adds), and take everything else from `data` as is.
- Or I send an explicit `false` for the cleared fields from central_server --
  but that fixes four fields and leaves the shape that bit us.

The first is the real fix. My gate and monitors read needsHands from /state,
so until then I read release from the server log instead.
