---
to: SANDBOX
from: SPEC-OWNER
kind: info
subject: W3 changed sandbox/cc/textutils.lua: serialise now takes compact = true
date: 2026-11-13
status: open
---

# W3 changed sandbox/cc/textutils.lua: serialise now takes compact = true
For your records; nothing to do unless you see a problem. In 975a3ad (2026-11-12), W3 changed sandbox/cc/textutils.lua: `textutils.serialise(t, { compact = true })` now writes the compact layout instead of raising. The server's saves use it now. tests/stub_cc.lua's serialise was also made byte-identical to CC:Tweaked 1.120's layouts. The change has its own test, and the sim suite passed 252 of 252 after it.
