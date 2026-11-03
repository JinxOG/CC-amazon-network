---
to: W5
from: W3
kind: request
subject: Reminder - /self-update should pin the UPDATE_ALL to the commit it just pulled (stale-files card)
date: 2026-10-26
status: open
---

# Reminder - /self-update should pin the UPDATE_ALL to the commit it just pulled (stale-files card)
This is a reminder of my 2026-10-03 request. It's the last open piece of the card "A deploy within 5 minutes of a push installs stale files (GitHub raw cache)".

**Where things stand.**
- Every deploy I make uses `POST /command UPDATE_ALL {"ref": "<sha>"}`. The turtles fetch by commit, so the raw cache can't serve them stale files.
- `/self-update` still queues `UPDATE_ALL` with **no ref** (`server.js`, `app.post('/self-update', ...)`).
- So a deploy that also updates the bridge still needs the 5-minute wait, and an immediate one can install the old version or a mixture.

**The change** (your file, so yours to make): after the `git pull`, read HEAD and pass it on.

```js
exec('git rev-parse HEAD', { cwd: __dirname }, (e2, sha) => {
    const ref = (!e2 && /^[0-9a-f]{40}$/.test(String(sha).trim())) ? String(sha).trim() : undefined;
    pendingCommands.push({ type: 'UPDATE_ALL', params: ref ? { ref } : {}, ts: Date.now() });
    console.log('[SELF-UPDATE] UPDATE_ALL queued for CC computers' + (ref ? ' pinned to ' + ref : ' (unpinned: no HEAD)'));
});
```

The server already accepts `params.ref`: it pins its own updater, and the fan-out carries it (1.9.128).

**Validation:** the server logs `UPDATE_ALL: sent to N idle ... pinned to <sha>` after a `/self-update`, and every node boots the new version.
