#!/usr/bin/env python3
"""Mutation harness for the warehouse event loop and its log forwarding.

Same discipline as tests/mutate_logship.py: a test that has never been seen to
fail is not evidence of anything. Each entry below breaks warehouse.lua in one
specific way and names the test that must go red for it.

    python tests/mutate_warehouse.py

Outcomes:

  KILLED     the named test went red. What you want.
  SURVIVED   the code was broken and the named test stayed green. A gap.
  MALFORMED  the mutant did not apply exactly once. NOT a pass: a mutant that
             never ran looks exactly like a test that cannot fail.

The baseline is checked FIRST, and the run stops if any target test is already
red. A red baseline would make every mutant look killed -- which is how a
harness certifies nothing while reporting success (6ab21b2).

Every mutation is applied to the real file and reverted in a finally block, so
an interrupted run leaves the tree clean.
"""

import os
import re
import subprocess
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TARGET = os.path.join(REPO, "warehouse.lua")

T_TIMER = "the tick timer is re-armed whatever woke the loop"
T_SHIP = "the warehouse's own log reaches the fleet log"
T_CRASH = "a warehouse crash reaches the fleet log, at ERROR"
T_MISSING = "a missing logship degrades the log, not the warehouse"

T_PROBE_IDLE = "the probe never runs while a delivery is in flight"
T_PROBE_BACKOFF = "a slow reading backs the probe off instead of paying again"

T_PROBE_WIRED = "the probe actually runs in the loop and its reading reaches the fleet log"

T_DIGEST_CAP = "the watchlist is capped, so the digest cannot grow into a 65 KB message again"
T_DIGEST_TRIM = "an oversized digest drops the ore stock and still reports the counts"
T_DIGEST_SENT = "the digest actually reaches the radio"

T_MSGNAME = "a missing message constant falls back AND says it fell back"

MUTANTS = [
    ("make the fallback silent again",
     "    return key, true",
     "    return key, false",
     T_MSGNAME),

    # -- The digest: cap, degradation, and whether it is sent at all ----------
    ("let the watchlist grow past its cap",
     "\n            if #out >= DIGEST_MAX_NAMES then break end",
     "",
     T_DIGEST_CAP),

    ("send the oversized digest anyway",
     "    if size <= DIGEST_MAX_BYTES then return full, nil end",
     "    do return full, nil end",
     T_DIGEST_TRIM),

    ("build the digest but never send it",
     "\n    sendToServer(MSG_STORAGE_DIGEST, nil, payload)",
     "",
     T_DIGEST_SENT),

    # The wiring, as opposed to the logic. Deleting the call site leaves both
    # guard tests green, because a pure function does not care who calls it.
    ("never call the probe from the loop",
     "\n        storageProbe(os.epoch(\"utc\"))",
     "",
     T_PROBE_WIRED),

    # -- The storage timing probe's two guards, promised to W3 2026-09-22 ---
    # The probe is itself an enumeration, and an enumeration is the yield that
    # destroys a delivery step. A promise with no failing test behind it is
    # just a comment.
    ("let the probe run mid-handshake (drop the idle guard)",
     "    if not idle then return false end\n    return now >= probeNextAt",
     "    return now >= probeNextAt",
     T_PROBE_IDLE),

    ("never back off after a slow reading",
     "    probeInterval = (ms >= PROBE_SLOW_MS) and PROBE_BACKOFF_MS or PROBE_EVERY_MS",
     "    probeInterval = PROBE_EVERY_MS",
     T_PROBE_BACKOFF),

    ("re-arm only in the timer branch again (the 2026-09-04 shape)",
     "        os.cancelTimer(tickTimer)\n        tickTimer = os.startTimer(1)\n    end\n",
     "    end\n",
     T_TIMER),
    ("the outbox never ticks",
     "        if _log then _log:tick() end\n",
     "",
     T_SHIP),
    ("print is not captured",
     '            source = "warehouse",\n',
     '            source = "warehouse", capture = false,\n',
     T_SHIP),
    ("batches go out under the wrong message type",
     "sendToServer(proto.MSG.TURTLE_LOG, nil,",
     'sendToServer("NOT_A_LOG", nil,',
     T_SHIP),
    ("the crash handler does not flush",
     "    if _log then pcall(function() _log:flush() end) end\n",
     "",
     T_CRASH),
    ("the crash line carries no level",
     '    if _log then _log.pendingLevel = "ERROR" end\n',
     "",
     T_CRASH),
    ("a plain require, so a stale disk stops the warehouse",
     'local okLS, logship = pcall(require, "logship")',
     'local okLS, logship = true, require("logship")',
     T_MISSING),
    ("a missing module is silent",
     '        log("WARNING: logship unavailable ("',
     '        local _ = ("WARNING: logship unavailable ("',
     T_MISSING),
]


def run_suite():
    out = subprocess.run(["lua", "tests/run.lua"], cwd=REPO,
                         capture_output=True, text=True, encoding="utf-8",
                         errors="replace")
    text = out.stdout + out.stderr
    failed = set(re.findall(r"^FAIL  (.+?)\s*$", text, re.M))
    passed = set(re.findall(r"^PASS  (.+?)\s*$", text, re.M))
    return passed, failed


def main():
    raw = open(TARGET, "rb").read().decode("utf-8")
    nl = "\r\n" if "\r\n" in raw else "\n"
    src = raw.replace("\r\n", "\n")

    passed, failed = run_suite()
    targets = {m[3] for m in MUTANTS}
    missing = [t for t in targets if t not in passed]
    if missing or failed:
        print("BASELINE NOT GREEN — refusing to certify anything.")
        for t in sorted(missing):
            print("  target not passing:", t)
        for t in sorted(failed):
            print("  already failing:   ", t)
        return 2

    print(f"baseline green: {len(passed)} passed, 0 failed\n")
    results = []
    try:
        for desc, old, new, test in MUTANTS:
            n = src.count(old)
            if n != 1:
                results.append(("MALFORMED", desc, f"anchor matched {n} times"))
                continue
            open(TARGET, "wb").write(src.replace(old, new, 1).replace("\n", nl).encode("utf-8"))
            _, f = run_suite()
            results.append(("KILLED" if test in f else "SURVIVED", desc, test))
    finally:
        open(TARGET, "wb").write(raw.encode("utf-8"))

    for verdict, desc, detail in results:
        print(f"{verdict:10} {desc}\n{'':11}-> {detail}")
    bad = [r for r in results if r[0] != "KILLED"]
    print(f"\n{len(results) - len(bad)}/{len(results)} killed")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
