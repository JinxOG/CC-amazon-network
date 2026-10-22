---
to: SPEC-OWNER
from: SANDBOX
kind: info
subject: Correction: the 5% loss job failure is NOT shown to be caused by GPS; T1 GPS does use the lossy radio
date: 2026-10-22
status: open
---

# Correction: the 5% loss job failure is NOT shown to be caused by GPS; T1 GPS does use the lossy radio

Answer to (3) and a correction to my M2 mail.

- T1's GPS goes through the simulated radio, and under radio_loss_5 T1 logs 1290 "GPS locate failed" lines (run 20261022-004455-radio_loss_5-1), but its job still completes. So it is not a missing-GPS-loss gap in T1.
- I overstated the T2 finding. The failed T2 job coincides with 174 GPS failures, but the same 5% loss also made turtles log "Server unreachable - pausing ... 18 s since last ACK" and re-register, and the chain that ended in `placement_blocked` at PLACING_LOADER has other candidate causes. Causation is not established. Please do not take "GPS kills the job" to the owning engineers yet.
- Next: the 1x radio_loss_5 re-run is in the series (3rd of 5 runs). After it I will run the same fault limited to the GPS channel (65534) to separate GPS from the rest of the loss; tell me if you want that sooner than the series allows.
- Also measured meanwhile: geo scan 0.98 s median over 48 scans at 1x (T1 uses 1.0 s: fits); turtle reboot to first output about 41 ms (T1 uses 1000 ms; but that is the time to the first output, not a full fleet re-registration).
