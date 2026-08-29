# Deploying the bridge

The Node bridge (`server.js`) runs on the Minecraft host. §4.2 of the integration
spec requires it to **start automatically with its machine** and calls a manual
restart after a reboot "a defect, not a workflow."

§4.2 names "a Windows service (NSSM) or Task Scheduler". **That is wrong for this
host, which is Linux.** The requirement stands; the mechanism is systemd. A
correction to §4.2 is pending with the spec owner.

## Install

`cc-dashboard.service` is a template unit — `%i` is the user whose home holds the
repo clone. For user `jonx` with the clone at `/home/jonx/cc-dashboard`:

```bash
sudo cp deploy/cc-dashboard.service /etc/systemd/system/cc-dashboard@.service
sudo systemctl daemon-reload
sudo systemctl enable --now cc-dashboard@jonx
```

Check it:

```bash
systemctl status cc-dashboard@jonx
journalctl -u cc-dashboard@jonx -f
```

## Before enabling it

**Stop the unsupervised copies first**, or systemd will bind-conflict with them.
`server.js` now exits on `EADDRINUSE` instead of lingering, so a conflict is
loud — but two orphaned processes have already come from double-starts:

```bash
pkill -f 'node server.js'
```

**Create `.env`** in the clone. It is read by the unit via `EnvironmentFile` and
must not be committed:

```
RCON_PASSWORD=<the rotated password>
```

`server.js` has no default for this. Without it the bridge still runs — dashboard,
`/state` and `/command` all work — but Dynmap marker updates are disabled and it
says so once at startup. That is deliberate: the password used to be a literal in
`server.js` in a public repository, and a default would invite the next one.

Confirm `.env` is ignored by git before writing anything into it. The repo has no
`.gitignore` at time of writing, so add one:

```
.env
node_modules/
logs/
locations.json
```

## What this replaces

Both services previously ran under `setsid nohup`, which survives a logout but
not a reboot, and is supervised by nothing. `logs/wrapper.out` and
`dashboard.out` grew without rotation. The unit sends output to the journal,
which rotates and caps on its own.

## What it does not cover

The CC-side wrapper service is not templated here — only the bridge. If it has
the same `setsid nohup` problem it needs its own unit, and that is worth doing at
the same time.
