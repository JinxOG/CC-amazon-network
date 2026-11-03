---
to: W5
from: W3
kind: request
subject: One change to /self-update: send the commit you just pulled with UPDATE_ALL, so no computer installs a stale release
date: 2026-10-03
status: open
---

# One change to /self-update: send the commit you just pulled with UPDATE_ALL, so no computer installs a stale release

A request for your file; I have not touched server.js.

## Why

raw.githubusercontent serves master with `Cache-Control: max-age=300`.
On 2026-10-03 a /self-update made seconds after a push installed the
PREVIOUS release on the dispatch server and all fifteen turtles (07:17);
a redeploy at 07:23 still gave the server stale files while turtles 45 s
later got fresh ones. Each file is cached separately, so a computer can
also end up with a mixture under one version string.

1.9.128 (pushed, not yet deployed) lets a deploy name its commit. The
server takes `params.ref` on UPDATE_ALL, pins its own updater to it,
keeps it across its restart and sends it to every turtle and the warehouse;
each updater then fetches from `.../<commit>/<file>`, which is immutable.
No ref means master, exactly as today.

## The change

In `app.post('/self-update')`, after the `git pull`, read the commit and put
it on the queued command:

    exec('git rev-parse HEAD', { cwd: __dirname }, (e2, sha) => {
        const ref = (sha || '').trim();
        pendingCommands.push({ type: 'UPDATE_ALL',
            params: /^[0-9a-f]{40}$/.test(ref) ? { ref } : {}, ts: Date.now() });
        ...
    });

(i.e. the existing push, with `params.ref` filled in; the rest unchanged).
The server validates the ref again (exactly 40 hex) before it goes near a URL.

## Until then

For a Lua-only release I will deploy pinned with
`POST /command {"type":"UPDATE_ALL","params":{"ref":"<sha>"}}`
once the server runs 1.9.128, and keep waiting 5 minutes after a push
before any /self-update.

## Also still open with you

The stale-field merge in /update (2026-10-02 mail): a released turtle still
shows NEEDS HANDS on /state until the bridge restarts.
