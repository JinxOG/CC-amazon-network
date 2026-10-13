#!/usr/bin/env python3
"""Mutation harness for cloudstore.lua.

Same discipline as tests/mutate_warehouse.py, and the runner is that file's,
unchanged: baseline checked FIRST, a mutant whose anchor does not match exactly
once is MALFORMED rather than counted killed, and the file is restored in a
finally block.

cloudstore had no committed harness until 2026-10-12, which meant its tests had
never been shown able to fail by anyone but their author, on the day they were
written.

    python tests/mutate_cloudstore.py
"""

T_SECTOR_NS = "sector progress never surfaces as a zone"
T_NAMESPACE = "namespaces keys so subsystems cannot collide"
T_LIMIT     = "refuses a value over the 500000 byte limit"
T_CORRUPT   = "corrupt stored value reads as nil rather than erroring"

MUTANTS = [
    # The separation W6 warned W3 about on 2026-10-12: a sector entry under "z"
    # returns as a phantom zone, and makes the migration skip the disk import.
    ("give sector progress the zone namespace",
     '    SECTOR = "sp",   -- sector progress, in flight only',
     '    SECTOR = "z",   -- sector progress, in flight only',
     T_SECTOR_NS),

    ("drop the namespace from the key",
     '    return ns .. ":" .. tostring(key)',
     '    return tostring(key)',
     T_NAMESPACE),

    ("accept a value over the size limit",
     "local VALUE_LIMIT = 500000",
     "local VALUE_LIMIT = math.huge",
     T_LIMIT),

    ("hand back whatever decoded, table or not",
     '    if type(decoded) ~= "table" then return nil end',
     "",
     T_CORRUPT),
]

import os
import re
import subprocess
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TARGET = os.path.join(REPO, "cloudstore.lua")












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
