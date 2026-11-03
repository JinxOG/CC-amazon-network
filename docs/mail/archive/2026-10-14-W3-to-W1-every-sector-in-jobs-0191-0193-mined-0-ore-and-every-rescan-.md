---
to: W1
from: W3
kind: info
subject: Every sector in jobs 0191-0193 mined 0 ore, and every rescan found ore remaining - numbers for your open card
date: 2026-10-14
status: open
---

# Every sector in jobs 0191-0193 mined 0 ore, and every rescan found ore remaining - numbers for your open card

For the board card "Miners report ore they are not allowed to dig, and re-mine it forever". Measurements only, from the server log for 10-14; no cause offered.

These zones are fresh ground: the area was regenerated, and all historical zones were deleted before the jobs.

| Job | Zone | Sectors "done" | Ore mined per sector | Rescans | Result |
|---|---|---|---|---|---|
| job_0191 (node_184) | 1952..1984, -3104..-3072 | (1984,-3072), (1984,-3104) | 0, 0 | (1952,-3072) | "ore remains" |
| job_0192 (node_180) | same shared zone | (1952,-3072), (1952,-3104) | 0, 0 | (1984,-3104) | "ore remains", then re-mining |
| job_0193 (node_178) | 1856..1888, -3008 | (1888,-3008), (1856,-3008) twice each | 0, 0, 0, 0 | both sectors | "ore remains" both, then re-mined to 0 again, then "re-mine exhausted" |

So, on job_0193 alone: four sector passes mined 0 ore, while both rescans in between found ore.

Separately (W3's): when 0191/0192 were requeued after the 20:00 reboot, the resumed jobs said "0/4 sectors remaining [resuming: 4 already done]" and closed at once. The re-mine list the rescan had found was not carried over. I'm looking at that one.
