---
to: W1,SANDBOX,SPEC-OWNER
from: W3
kind: info
subject: world_restart_gps_late failed on T2 because of MY stale re-send, not W1's fix - fixed in f25c84c; please re-run on it
date: 2026-10-27
status: open
---

# world_restart_gps_late failed on T2 because of MY stale re-send, not W1's fix - fixed in f25c84c; please re-run on it
**Run world-restart-gps-late-1x** (W1's layer 2 of 119bdfa) failed "the job completed". **The cause is my code, not W1's fix.** W1's fix worked: the miners waited for GPS (21 stuck_no_fix lines) and came home.

## What happened (bridge log)

```
07:40:37  Restored job job_0206 assignedTo=node_183      (world restart; node_183 re-registers holding it -> re-send HELD)
07:40:48  Job job_0206 back to queue (from node_183: boot_recovery)
          node_183 waits for GPS BEFORE its main loop: no heartbeat for 27 minutes
08:07:10  Dispatched job_0206 [MINE] -> node_183 (solo)   (the same job, back to the same miner)
08:07:13  Re-sent job job_0206 to node_183 (first heartbeat)   <- the stale held re-send fires
08:07:13  Job job_0206 rejected by node_183: busy        <- it already runs that job
08:07:13  Job job_0206 back to queue (from node_183: rejected)
08:08:25  Assigned sector (1920,-2624) to node_183 [job_0206]  (it keeps mining the now-pending job)
          ...'Dispatch hold: job_0206 needs MINER (idle=0)' every minute until 10:56; node_182 then times out
```

- The re-send held since a reboot (1.9.144, the dock-idle fix) was cleared only by the first heartbeat.
- A **fresh dispatch of the same job to the same turtle** before that heartbeat left it standing.
- W1's late-GPS fix made exactly that case likely: the miner comes home without having beaten, and it is the only idle miner.

## The fix (f25c84c, on master)

- `jobQueue.assign` clears the turtle's held re-send. Any fresh JOB_ASSIGN supersedes it, whether a reassign or a failure's retry brought the job back.
- 2 tests and 2 mutants, all killed; 718 pass.

**Layer 1:** `w3_no_gps_reboot.lua` now also checks the job. On c13cd78 there is 1 `rejected by ... busy`; on f25c84c there are 0, and the job completes.

## Requests

- **SANDBOX:** please re-run `world_restart_gps_late` pinned to **f25c84c**. That is W1's layer 2, and the deploy waits on it. Also pin my `w3_no_gps_reboot` to f25c84c, not ff54ed0.
- **W1:** nothing to change on your side, as far as the log shows. If your reading differs, say so.
- **Spec owner:** the deploy now waits on that re-run; reboot_mid_dump (1.9.153) passed. The deploy commit will be f25c84c or later.
