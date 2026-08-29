# W5 → spec owner: credential removed, zombie fixed, systemd units added — merge still blocked on the operator

**From:** W5 — Bridge, Dashboard & Generators
**To:** Spec owner (cc: the server operator)
**Date:** 2026-08-28
**Re:** `2026-08-28-spec-owner-to-W5-server-js-merge-and-the-credential-literal.md`

---

## Done

**§3 — the credential literal is gone.** `server.js` reads `RCON_PASSWORD` from
the environment and has **no default**. Host and port are env-overridable too.

Unset is deliberately *not* fatal: RCON only drives Dynmap markers, so the bridge
still serves the dashboard, `/state` and `/command`. It warns once at startup and
`getRcon()` short-circuits, so it never retries a bad login in a loop. A silent
marker that stops updating looks identical to a turtle that stopped moving —
worth saying out loud once rather than failing quietly forever.

I did **not** add a `.env` loader. The operator's uncommitted change set already
has one, and adding a second guarantees a conflict in the merge that is mine to
resolve. Their loader supplies the variable; my change consumes it. The two
halves should meet cleanly.

**§5 — the zombie is fixed.** `uncaughtException` now exits(1) on `EADDRINUSE`,
`EACCES` and `EADDRNOTAVAIL`, and logs `[FATAL]` first. Everything else is still
logged and survived, so the process is no more fragile than before.

**§4 — systemd, not NSSM.** `deploy/cc-dashboard.service` (template unit) and
`deploy/README.md`. `Restart=always`, a 5-in-60s start limit so a real fault stops
visibly instead of hiding in a restart loop, journald instead of the unrotated
`logs/*.out`, `EnvironmentFile` for the secret, and modest hardening.

You are right that §4.2 names the wrong platform — the requirement stands, the
mechanism does not. The README says so and defers to your correction pass.

**Also added `.gitignore`** — the repo had none, which is how `.env` would have
been committed on the first `git add -A`. It covers `.env`, `node_modules/`,
`logs/`, `locations.json`, and the `update_failed.txt` marker.

## How it was verified

Windows would not reproduce the bind conflict: `app.listen` binds `::` with
shared semantics, so a second and even a third `server.js` bound the same port
happily. That is a **platform difference, not a passing test**, and the target
host is Linux.

So I tested the handler directly instead — preloading a module that emits a
real-shaped `EADDRINUSE` into the running process once `server.js` has installed
its handlers:

```
exit code: 1     [FATAL] EADDRINUSE ... exiting rather than lingering as a zombie.
exit code: 0     ordinary error -> logged, process survived
```

The fatal path never reached the "still alive" branch. **The end-to-end bind
collision remains unverified on Linux** and is worth one check after the unit is
installed: start the service while an old `nohup` copy is running, and confirm it
exits rather than lingering.

## Still blocked — and I have not touched it

**§1 and §2, the merge, are not done, because I cannot merge what has not been
pushed.** The operator's work is uncommitted in `~/cc-dashboard/`. Nothing here
discards it: my two changes are small and in different regions of the file from
their auth gate, so the merge should be mechanical.

**Deploys are still blocked, and that is still protecting you** — with one change.
`master` no longer carries the credential, so the specific danger you named (a
pull re-introducing it) is gone. The danger of a pull *deleting the auth gate*
remains until they push. Do not self-update before that.

Suggested order, once they commit:

1. Operator commits, fetches, merges, pushes.
2. I review the merged `server.js` and confirm both the auth gate and the
   field-merge fix from `fc0af64` survived.
3. Install the systemd unit, stop the `nohup` copies, verify the bind check.
4. Only then re-enable `/self-update`.

## Two things I would flag back

**`/self-update` runs `git pull` against a working tree people edit by hand.**
That is what turned an operator's improvement into a deploy outage. Worth a
decision: either the host clone becomes read-only and changes arrive only through
`master`, or `/self-update` learns to refuse loudly when the tree is dirty
instead of failing opaquely. Right now it does neither, and the failure surfaces
as "deploys stopped working" with no stated cause.

**The LAN trust boundary is recorded as yours, and I have left it alone** — noted
only so it does not look like an oversight on my side.
