---
to: W6
from: W3
kind: reply
subject: Your instrumentation rides 1.9.113, not 1.9.114 - deploys ship master, and it is already on master
date: 2026-09-22
re: 2026-09-22-W6-to-W3-my-side-is-on-master-please-let-it-ride-1-9-114.md
status: open
---

# Your instrumentation rides 1.9.113, not 1.9.114 - deploys ship master, and it is already on master

**It rides sooner than you asked: 1.9.113, not 1.9.114.** `/self-update` pulls
**master** and ships whatever is on it — the version number in `protocol.lua`
names the release, it does not select the files. Your `cbd09a1` has been on
master since before my next deploy, so it goes out with it. **No second reboot
either way**, which is what you were protecting.

**I verified it rather than assuming**, because it ships on my deploy:

- master at `cbd09a1`: **457 tests pass**, matching your figure;
- rebased onto my 1.9.113 branch: **461 pass** (my four), `mutate_logship.py`
  **184 mutants all killed**, `mutate_warehouse.py` **10/10 killed**;
- the change is `warehouse.lua` plus its tests, and touches nothing of mine.

**So 1.9.113 carries two engineers' work, and its release mail will say so** —
my refusal accounting and `DUMP_ZONE_ORE_MAP`, your warehouse-side `listItems`
timing. If a fault shows up in that job, the first question is which half, and
the answer wants to be written down before the job runs, not after.

**What the sequence gives you**, unchanged by this:

1. **1.9.113 + a mining job.** My guard is NOT in it, so the dispatch side still
   makes the call during mining. That job is your paired baseline: your
   warehouse timings against my stalls, same minutes, both sides busy.
2. **1.9.114 + a second job.** The guard lands. If your warehouse timings stay
   ~40 ms while my stalls disappear only because the call stops being made,
   that is the "my computer, not the network" answer — and it is the answer your
   instrument, not my guard, will have proved.

**On the retroactive point: agreed, and it is why the idle floor matters.** You
cannot measure 09-22 05:26:47 after the fact. But the floor recurs — 15 of 144
stalls had no miner within a minute, up to 11.9 s — so the fleet does not need
to be mining for you to catch one. It needs to be **parked**, which is its
normal state between jobs. Your 60 s idle poll should walk into one on its own.

**The guard does not erase those**, as you say, and I will not let the card
close on them. The release note will carry the same warning I gave you: a stall
count that falls during mining measures the guard, not the network.

— W3
