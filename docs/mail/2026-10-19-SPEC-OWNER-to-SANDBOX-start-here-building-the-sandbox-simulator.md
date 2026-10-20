---
to: SANDBOX
from: SPEC-OWNER
kind: request
subject: Start here - building the sandbox simulator
date: 2026-10-19
status: open
---

# Start here - building the sandbox simulator
You are the **sandbox builder**. Your mail name is `SANDBOX`. You are not one of
W1-W6 and you own no fleet code. Your job is one thing: build the sandbox
simulator, task by task, from the plan below.

## Read these first, in this order

1. **The design** - `docs/superpowers/specs/2026-10-18-sandbox-simulator-design.md`.
   Read all of it before Task 1. Where the plan and the design disagree, the design wins.
2. **The plan** - `docs/superpowers/plans/2026-10-19-sandbox-simulator.md`. 26 tasks in
   six phases. Its "Global Constraints" section is binding for every task.
3. **How engineers work here** - `docs/superpowers/specs/2026-09-15-engineer-mail-and-baton-protocol.md`,
   section 8 (worktrees, pushing, verifying a push). You do not hold the baton and
   do not run the fleet's deploy cycle; the rest of that document is background.

## Set up once

- Your own worktree, never the primary checkout:
  `git worktree add -B sandbox .claude/worktrees/sandbox origin/master`, then work only in it.
- Execute with `superpowers:subagent-driven-development` (or `superpowers:executing-plans`),
  one task at a time, test first, one commit per task.
- Push: `git push origin HEAD:master`, then prove it landed:
  `git fetch origin && git merge-base --is-ancestor <sha> origin/master`. Explicit paths
  in every `git add`; never `-A`.

## Where everything is

All sandbox data lives on the Game Drive, `G:\TurtleOS-Sandbox` (Bash: `/g/TurtleOS-Sandbox`),
read through the `SANDBOX_DATA` setting. Never put data in the repo: it syncs to OneDrive and
the repo is public.

| What | Where |
|---|---|
| The real world, unpacked (read-only) | `worlds/unpacked/2026-10-18_1700/world_live/` |
| The original download, untouched | `worlds/incoming/latest-backup.zip` (+ `latest-backup.contents.txt`) |
| Where backups live on the server | `worlds/incoming/backup-locations.txt` (for reference; you never fetch) |
| Test runs and snapshots | `run/` |
| The Lua interpreter you install in Task 1 | `interpreter/` |
| A saved storage list for Task 22 | `storage/` (empty today) |

The world is the server's FTB Backups 2 copy from 2026-10-18 17:00. Checked: size matches the
server's, 2,377 files, `level.dat` reads, 176 overworld region files, 159 computer disks under
`computercraft/computer/`. It is also needed only from Phase 5 (Task 22) on; Phases 0-4 use the
synthetic world.

## Stop and ask the user (in your own session) before you

- **install anything** - Task 1 needs an interpreter and maybe Zig; nothing is installed until they say yes;
- **read the live bridge** - the one `/state` read in Task 22, and live logs in Task 25;
- **pick a mining zone** for the first real-world run (Task 23) and calibration (Task 25);
- ask them to **run a live job** for forward calibration (Task 25).

The user wants plain English: no file paths or jargon in what you say to them, and short.

## Never

- edit a fleet file (any `.lua` at the repo root) - if one cannot run unchanged, stop and mail me;
- SSH to, or contact from sandbox code, the server (`192.168.86.35`, `100.103.179.74`);
- write into the unpacked world or the zip - import into a new folder;
- copy CC:Tweaked ROM code (licence) - rebuild it from https://tweaked.cc;
- deploy, `/self-update`, send `/command`, or start mining jobs on the live server.

## Reporting

- **The board** (private kanban, https://github.com/users/JinxOG/projects/1): your card is
  "Sandbox simulator - build it" (item `PVTI_lAHOByrE-s4BjIXSzhCBOC0`). Move it to
  **In progress** when you start Task 1, and to **Done - not yet seen on the real server**
  when spec section 15 holds. `gh` is not on PATH in Bash:
  `"/c/Program Files/GitHub CLI/gh.exe" project item-edit --id PVTI_lAHOByrE-s4BjIXSzhCBOC0 --project-id PVT_kwHOByrE-s4BjIXS --field-id PVTSSF_lAHOByrE-s4BjIXSzhh93j8 --single-select-option-id <status>`
  with `<status>` = In progress `e945401c`, Done - not yet seen on the real server `7a904d67`.
  Never edit the board's option lists: that replaces them.
- **At the end of each phase**, mail me one short note: which tasks are done, the
  `sandbox/sim test` result line, and anything you had to assume.
  `python tools/mail.py new --to SPEC-OWNER --from SANDBOX --kind info --subject "..."`
- **When stuck** on a design question, mail me (`--kind request`) and continue with
  another task if one is free; do not guess around the design.
- When you finish a message of mine, `python tools/mail.py close <file> --as SANDBOX`.
