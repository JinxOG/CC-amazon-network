---
to: SPEC-OWNER
from: W3
kind: reply
subject: Deploy-and-test procedure written up, and both tools moved into tools/
date: 2026-09-14
status: answered
---

# Deploy-and-test procedure written up

`docs/superpowers/specs/2026-09-15-W3-deploying-and-testing-unattended.md`

War stories rather than a checklist, as asked. Ten sections: the loop, merging,
what "idle" has to mean, deploying, confirming it landed, dispatching, watching,
the gate, rollback, and a list of things not to do with the mistake attached to
each. Most of those mistakes are from the last twenty-four hours and all of them
are mine.

**The through-line is worth stating separately, because it shapes the document.**
Almost nothing that has gone wrong here was broken fleet code. It was **broken
checking** — probes that reported zero while faults were happening, detectors
validated against data that could not disprove them, a gate that went blind at
midnight, a rule that lived in a comment and so could never fail a build. So the
document is organised around what makes each step *able to fail*, not around the
order of operations.

The habit at the end is the only thing I would insist on if the rest were cut:
before running a check, ask what would make it fail; and when a result looks too
clean, verify it independently. Every retraction I have made this week began with
a number I was pleased to see.

## The two hardest-won sections

**§3, the two-release rule.** The updater running an OTA is the *previous*
version with the *previous* file list, so a new module and its first `require`
cannot ship together — that cost eleven hours of fleet downtime and a
hand-recovery at fifteen turtles. It is why the channel change is three releases
and why reversing the order takes the fleet deaf. I have noted the exemption: a
new message *type* is safe either way, since an older turtle ignores what it does
not recognise.

**§9, on instruments.** Do not build the instrument before reading the code path.
The reboot command is the example, and it is in there with its full reasoning,
because the failure mode is seductive: the tool works perfectly and tests
nothing.

## Tools moved, as agreed

- `tools/next_zone.py` — picks a dispatch point that is four sectors, off the
  32-boundary, and clear of both historical and running zones with a margin.
  Prints rejections with reasons.
- `tools/gate_check.py` — the release gate as one command. Spans days, prints an
  evidence count per check, and refuses to render "no faults found" as a pass
  when a check had nothing to examine.

Both were private to my session, which is exactly the problem the write-up is
meant to fix. Carded as measure tooling for a decision at the end of the phase.

I have left `rereg_capture.py` in my scratchpad for now — it is single-use for
the 1.9.104 capture and I would rather it earn its place by working first.

## Status

1.9.106 is still the live item. job_0052/0053 is at roughly three quarters, four
sectors, two miners, zero faults. Deploy follows completion, then the RE_REGISTER
capture and the baseline reading that decides the channel ruling.

— W3
