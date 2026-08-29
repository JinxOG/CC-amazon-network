# Spec owner → W5: `server.js` has diverged, and it still holds the old RCON password

**From:** Spec owner
**To:** W5 — Bridge, Dashboard & Generators
**Date:** 2026-08-28
**Subject:** §13 ownership of `server.js`, §4.2 operational requirement
**Status:** Action required before any deploy

---

## Context

A server operator worked on the Minecraft host (192.168.86.35) across 27–29 Aug
and made changes to `~/cc-dashboard/`, which is **a clone of this repository**.
Their work is uncommitted in that working tree. Yours is committed on `master`.
Both touch `server.js`.

Their change set: an inline `.env` loader, RCON password sourced from
`process.env` instead of a literal, and a Basic Auth gate ahead of all routing.
`+70 −1`. The dashboard had been internet-exposed through the ngrok tunnel with
no authentication on any route.

Verified by request 2026-08-28: `/ping` returns **200**, `/state` returns
**401**. In-game CC computers are unaffected — they connect from loopback, which
stays open.

## 1. Deploys are blocked, and the block is currently protecting you

`POST /self-update` runs `git pull origin master`. Git refuses to merge over
uncommitted changes to a tracked file, so self-update is dead until the
operator commits.

**Do not "fix" this by discarding their changes.** `master` at HEAD contains:

```
server.js:52       password: 'zoomer',
```

That is the pre-rotation RCON password, hardcoded, in a **public** repository.
Pulling `master` onto the server today would re-introduce it *and* delete the
auth gate. The broken pull is the only thing currently preventing that.

## 2. The merge is yours to own

`fc0af64` — your fix stopping the bridge discarding fields it was not told to
expect — is on `master` and touches the same file. The operator's auth work is
in their working tree. **Both must survive.** Neither side should resolve this
by taking their own version wholesale.

The operator has been asked to commit, fetch, merge and push. Coordinate with
them on the conflict rather than racing it.

## 3. Delete the literal regardless

Even after rotation makes `zoomer` worthless, `server.js:52` must stop
hardcoding a credential. Source it from `process.env` the way the operator's
version does. Rotation neutralises the value; only the code change neutralises
the pattern.

While you are there, confirm nothing else was ever committed alongside it.

## 4. Your Stage 1 auto-start task has a second vote

§4.2 requires the bridge to start automatically with its host, and calls manual
restart after a reboot "a defect, not a workflow." The operator independently
found the same thing: both services run under `setsid nohup`, neither is
supervised, and neither returns after a reboot. `logs/wrapper.out` and
`dashboard.out` also grow without rotation.

**§4.2 currently specifies the wrong platform.** It says "a Windows service
(NSSM) or Task Scheduler." The bridge runs on a **Linux** host. The requirement
is right; the mechanism named is not. A correction is pending the spec owner's
next pass — build systemd units, not a Windows service.

## 5. One defect worth fixing while you are in that file

The `uncaughtException` handler at the top of `server.js` swallows
`EADDRINUSE`. A second `node server.js` therefore fails to bind but never
exits — it lingers as a silent zombie. Two orphaned processes (PIDs 3077167 and
2423081) came from exactly this, and it recurs on every accidental double-start.

This is a **P7 violation**: degraded, with no way to say so. A failed bind
should exit loudly.

## Not your problem, recorded so you do not chase it

The LAN range `192.168.86.0/24` reaches `/command` and `/self-update` without
credentials. That restores pre-existing behaviour rather than adding exposure,
and it is a deliberate trust boundary for the operator to sign off, not a
regression in your code.
