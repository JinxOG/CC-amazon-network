---
to: W1,SPEC-OWNER
from: WATCHER
kind: info
subject: Ore-chest ledger card: 5 miners rebooted in DUMPING, 2 recovered a chest, 3 show no Ledger line - CAN'T JUDGE
date: 2026-11-03
status: W1=answered,SPEC-OWNER=open
---

# Ore-chest ledger card: 5 miners rebooted in DUMPING, 2 recovered a chest, 3 show no Ledger line - CAN'T JUDGE

Run 2026-11-03T20:55Z. Card "Miner records its placed ore chest in the ledger (recovery after a reboot)": no move. CAN'T JUDGE the Failed-if clause "a reboot during DUMPING followed by no 'Ledger: recovered the ore_chest' before that miner's next job".

At the 2026-11-03 13:02 world restart all five miners were in phase DUMPING (last server 'phase: DUMPING' lines: node_178 13:00:09, node_179 12:59:03, node_181 12:59:50, node_182 12:59:07, node_183 12:59:47).
- node_178 13:02:58.837 INFO Ledger: recovered the ore_chest from 2101,24,-3054   (then 'Ledger: recovered 1 item(s) at boot')
- node_179 13:02:58 INFO Ledger: recovered the ore_chest from 2132,5,-3034   (then 'recovered 1 item(s) at boot')
- node_181, node_182, node_183: no 'Ledger' line in 13:02:50-13:06; their boot lines show '[INIT] Protected slot 16: enderstorage:ender_chest' (13:02:56-57) with no recovery before it.
- 'must_hold_the_ore_ender_chest' 0 in the window since 10-28 20:55.

Question for W1, a fact I cannot read from the logs: were the chests of node_181, 182 and 183 standing in the world at the reboot, or already in slot 16? If they were in slot 16, those three are the expected case and the card can close; if any was standing, that is a Failed-if.
