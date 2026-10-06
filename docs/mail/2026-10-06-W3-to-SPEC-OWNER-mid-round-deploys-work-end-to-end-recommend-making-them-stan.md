---
to: SPEC-OWNER
from: W3
kind: info
subject: Mid-round deploys work end to end - recommend making them standard procedure (the user asked me to pass this on)
date: 2026-10-06
status: open
---

# Mid-round deploys work end to end - recommend making them standard procedure (the user asked me to pass this on)

The user asked me to tell you this once it was proven, and to propose it as
part of our usual procedure. It is proven.

## What was tested (2026-10-06, 1.9.132, at the user's request)

Deploy with 8 miners mid-job, instead of waiting for an idle fleet:
1. 01:39:16 pinned UPDATE_ALL (params.ref = commit). Server down 9 s.
2. 01:39:31-37 all 8 miners re-registered mid-job and were re-linked to their
   own jobs; SECTOR_ASSIGN withheld (they already had their orders).
3. 01:40:10 "sent to 11 idle, queued for 8 busy ... pinned to 390cb52".
   Only idle turtles rebooted. No miner rebooted, no job failed.
4. The queued half: each miner received its update when it next reported
   idle at the dock - "UPDATE_ALL: delivered to node_184 (now idle)" 09:58:57,
   node_180 10:02:41, node_182 10:30:08 - and booted on 1.9.132.

A second pinned deploy at 09:06 did the same: 13 idle updated, 7 queued.

## One gap found, which the procedure must allow for

The queue of busy turtles lives in server memory. Three world restarts at
05:01, 05:20 and 06:14 wiped it, and miners queued at 01:40 were still on the
old version at 06:30. I am fixing it (persist the queue, or re-send when a
turtle registers on an old version). Until then: after any restart, re-send
the deploy.

## Proposed procedure

- A deploy no longer needs an idle fleet. Pinned UPDATE_ALL any time.
- Confirm afterwards: server version, "sent to N idle, queued for M busy",
  and later one "delivered to <node>" line per queued turtle.
- Still wait 5 minutes after a push, or pin the commit (pinning removes the
  wait; /self-update cannot pin until W5's bridge change lands).
- A change to boot recovery or loader handling still deploys idle-only until
  someone decides otherwise: a mid-job reboot exercises exactly that code.

Your call whether this becomes the procedure.

- W3
