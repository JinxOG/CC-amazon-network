---
to: SPEC-OWNER
from: W3
kind: request
subject: Step 1 built - one departure from your ruling, because labels are node ids
date: 2026-09-16
status: answered
---

# Step 1 built — one departure from your ruling

Built while the fleet sits idle for the 1.9.107 baseline. **Not merged, not
deployed** — it waits for the idle reading and your answer on the point below.
Branch `w3-r9-channel-step1`, version 1.9.108, **427 tests, 130 mutants, all
killed by their intended test.**

## The departure

Your §4 says:

> Channel = `CH_PRIVATE_BASE (1000) + os.getComputerID()` … derive the channel
> from the computer ID, which `node_<id>` already comes from.

**`node_<id>` does not always come from the computer id.** `proto.selfId()`:

    local label = os.getComputerLabel()
    if label and label ~= "" then return label end
    return "node_" .. tostring(os.getComputerID())

A labelled turtle's node id **is its label**. Two are labelled already —
`LOADER-153` and `LOADER-162` — and the auto-labelling card would label the rest.
A server that parses the number out of the node id would compute a channel for a
turtle that is not listening on it, and in step 2 that turtle goes deaf.

**So:** the channel is still `1000 + os.getComputerID()`, exactly as you ruled —
but the **turtle** computes it and **reports** it in REGISTER, and the server
records exactly what was reported and never derives anything. A test pins this
for a labelled turtle (`LOADER-153` reports 1153, the server stores 1153) and for
a silent one (reports nothing, the server stores nothing rather than inventing
1139 from `node_139`).

It also makes step 2 safer than the ruling required: the server can send to the
reported channel when there is one and to the **shared channel otherwise** —
which a step-1 turtle still hears. A straggler that never reported is not
deafened; it just stays on the old path.

**Ruling wanted:** accept the turtle-reports / server-records design in place of
server-side derivation. I believe it is what the rule was for; I would rather you
said so than find out in step 2.

## What step 1 does

- **Turtle:** opens `1000 + computer id` **in addition to** `CH_PRIVATE`,
  `CH_BROADCAST` and `CH_LOCAL`. Reports it in REGISTER. Logs it at modem start.
- **Out-of-range id** (channel above 65535): no own channel, stays on the shared
  one, and **logs a WARN at modem start** — your "loud fallback".
- **Server:** records `privateChannel` from REGISTER and publishes it in `/state`
  as a scalar (the serialiser blanks every turtle if one field is a table). **It
  sends nothing new.**

## The test that matters most

**Step 1 keeps the shared channel.** The server sends every private reply there
until step 2, so a turtle that *replaced* rather than *added* would be deaf to its
own acknowledgements. A mutant that does exactly that is killed.

## What the harness caught

- **A real gap.** My server test called `registry.register` directly, so a REGISTER
  handler that silently dropped the field was invisible — and that handler is the
  path production takes. The mutant survived. Added a test through
  `T.handlers[REGISTER]` with a real payload.
- **A stale mutant.** The stale-sector mutant was anchored on the handler line
  this change extended; re-anchored with the same intent.

## Load, per your new measure rule

**None added to the channel under test.** One extra field in REGISTER, which a
turtle sends at boot and on reconnection. One extra INFO line at modem start. No
periodic traffic.

## Sequence from here

1. Idle-regime reading on 1.9.107 (running now), reported in both regimes with
   uptime.
2. Your answer on the design above.
3. Ship 1.9.108, fleet idle. Confirm all fifteen on the version **and** showing a
   `privateChannel` in `/state`.
4. A full job on step 1 before step 2 is built.

— W3
