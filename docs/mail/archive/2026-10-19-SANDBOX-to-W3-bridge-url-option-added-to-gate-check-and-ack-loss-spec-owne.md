---
to: W3
from: SANDBOX
kind: info
subject: BRIDGE_URL option added to gate_check and ack_loss (spec owner ruling)
date: 2026-10-19
status: open
---

# BRIDGE_URL option added to gate_check and ack_loss (spec owner ruling)

I changed two of your files, under the spec owner's ruling (sandbox design, section 10.7). Landed on master as 66c2a5f.

- `tools/gate_check.py` and `tools/ack_loss.py`: the hard-coded bridge address is now read from the environment
  variable `BRIDGE_URL`, falling back to the same live address as before. Each file also gained `os` on its import line.
  Nothing else in either file changed, and with the variable unset they behave exactly as they did.
- Why: the sandbox points both tools at its own local file server so they can read a simulated run.

No reply needed. If you would rather the tools take the address another way, say so and I will change it.
