#!/usr/bin/env python3
"""Mutation harness for the log outbox and the deploy manifests.

Companion to tests/bridge/mutate_fleetlog.sh, same discipline: a test that has
never been seen to fail is not evidence of anything. Every assertion added for
logship.lua, for the turtle-side wiring, and for the deploy manifests is listed
here with a deliberate break and the name of the test that must go red for it.

    python tests/mutate_logship.py

Three outcomes, and the middle one is the reason this file exists rather than a
handful of manual edits:

  KILLED     the intended test went red. What you want.
  SURVIVED   the code was broken and every test stayed green. A gap -- unless
             the mutant is EQUIVALENT (see READY_GUARD_EQUIVALENT below), in
             which case surviving is correct and the entry should say so.
  MALFORMED  the mutant did not apply cleanly or does not compile. This is NOT
             a pass: a mutant that never ran looks exactly like a test that
             cannot fail, and the two must never be reported the same way.

Every mutation is applied to the real file and reverted in a finally block, so
an interrupted run leaves the tree clean.
"""

import io
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
os.chdir(ROOT)

LOGSHIP = "an urgent outbox does not wait for the interval"
QUIET = "a quiet outbox still flushes on the interval"
SHIP = "a computer with no turtle behind it ships its lines"
LEVEL = "a level the caller knows is carried, not left to a regex"
LATE = "lines printed before the transport exists are kept, not lost"
RADIO = "a node with no radio keeps its lines until it has one"
CAPTURE = "a second outbox replaces the capture rather than stacking on it"
BOOT = "a later boot has a higher bootId"
LOOP = "the control loop asks the outbox to tick every iteration (SOURCE-ONLY, weaker)"
STALL = "a real stall arms the log retry (SOURCE-ONLY, weaker)"
MANIFEST = "every role is sent every module its own files require"
RELAUNCH = "an updater that predates a new module still ships it"
ORDER = "the relaunch happens before any role file lands"
CURRENT = "an updater that is already current does not relaunch"
INSTALL = "install.lua ships the same modules as updater.lua"

# (label, file, [(old, new), ...], test that must go red)
MUTANTS = [
    ("seq never advances", "logship.lua",
     [("    self._seq = self._seq + 1\n", "    self._seq = self._seq\n")], SHIP),

    ("level dropped from the entry", "logship.lua",
     [("        level = level,\n", "        level = nil,\n")], LEVEL),

    ("level sticks after it is cleared", "logship.lua",
     [("        level = level,\n", '        level = level or "WARN",\n')], LEVEL),

    ("tick no longer short-circuits on urgency", "logship.lua",
     [("    if self._urgent or now - self._lastFlush >= self.INTERVAL_MS then",
       "    if now - self._lastFlush >= self.INTERVAL_MS then")], LOGSHIP),

    ("high-water mark never trips", "logship.lua",
     [("    if #self._queue >= self.FLUSH_AT then self._urgent = true end",
       "    if false then self._urgent = true end")], LOGSHIP),

    ("interval stretched tenfold", "logship.lua",
     [("    if self._urgent or now - self._lastFlush >= self.INTERVAL_MS then",
       "    if self._urgent or now - self._lastFlush >= self.INTERVAL_MS * 10 then")], QUIET),

    ("no transport discards the queue", "logship.lua",
     [('    if type(self._send) ~= "function" then return false end',
       '    if type(self._send) ~= "function" then self._queue = {} return false end')], LATE),

    ("ready() no longer consulted", "logship.lua",
     [("    if self._ready and not self._ready() then return false end\n", "")], RADIO),

    # The guard MOVED rather than deleted: still present, but consulted only
    # after the batch has been pulled out of the queue, so the lines are gone
    # whether or not there was anywhere to send them. Two steps, because a
    # single-anchor version of this is an equivalent mutant -- see below.
    ("ready() moved below the queue drain", "logship.lua",
     [("    if self._ready and not self._ready() then return false end\n", ""),
      ("    self._send(batch, self._bootId)\n    return true",
       "    if self._ready and not self._ready() then return false end\n"
       "    self._send(batch, self._bootId)\n    return true")], RADIO),

    ("capture chains instead of replacing", "logship.lua",
     [("    if _G[RAW_KEY] == nil then _G[RAW_KEY] = print end\n    local raw  = _G[RAW_KEY]",
       "    local raw  = print")], CAPTURE),

    ("bootId is a constant", "logship.lua",
     [('        _bootId      = os.epoch("utc"),', "        _bootId      = 1,")], BOOT),

    # Turtle-side wiring. Both the deleted and the commented-out form, because
    # the first version of the loop assertion matched a COMMENTED-OUT call and
    # stayed green -- the mutation that found it is the reason both are here.
    ("control loop stops ticking the outbox", "turtle_base.lua",
     [("            _log:tick(now)", "            -- _log:tick(now)")], LOOP),

    ("control loop's tick call commented out", "turtle_base.lua",
     [("            _log:tick(now)", "            --[[ _log:tick(now) ]]")], LOOP),

    ("control loop stops realigning the interval", "turtle_base.lua",
     [('    _log:resetInterval(os.epoch("utc"))', "    -- realign removed")], LOOP),

    ("control loop's realign commented out", "turtle_base.lua",
     [('    _log:resetInterval(os.epoch("utc"))',
       '    --[[ _log:resetInterval(os.epoch("utc")) ]]')], LOOP),

    ("a real stall no longer arms the retry", "turtle_base.lua",
     [("        _log:markSuspect()\n        _missedHeartbeats = 0",
       "        _missedHeartbeats = 0")], STALL),

    # The updater's self-refresh. Every one of these anchors also appears in
    # updater.lua's PROSE, which is why the test strips comments before matching
    # -- and why the commented-out forms are mutated here explicitly.
    # The self-refresh. These four killed the two SOURCE-ORDERING assertions
    # originally written for it -- `if false and ...` leaves the text in place,
    # and so does moving the readSelf() that feeds it -- which is why the test
    # they point at now loads updater.lua into a fake CC computer and runs it.
    ("the self-change comparison can never fire", "updater.lua",
     [("if selfBefore and selfAfter and selfAfter ~= selfBefore then",
       "if false and selfBefore and selfAfter and selfAfter ~= selfBefore then")],
     RELAUNCH),

    ("selfAfter is read before the download instead of after", "updater.lua",
     [("local selfAfter = readSelf()\n", ""),
      ("local selfBefore = readSelf()",
       "local selfBefore = readSelf()\nlocal selfAfter = readSelf()")],
     RELAUNCH),

    ("the relaunch is commented out", "updater.lua",
     [('    shell.run("updater")\n    return',
       '    --[[ shell.run("updater") ]]\n    return')],
     RELAUNCH),

    # The updater still notices it replaced itself, but only once the role files
    # have already landed from the stale list -- 2026-09-10 again with an extra
    # reboot in it.
    ("the check moves below the role download", "updater.lua",
     [("local selfAfter = readSelf()\n"
       "if selfBefore and selfAfter and selfAfter ~= selfBefore then", "if false then"),
      ('print("Verifying...")',
       "local selfAfter = readSelf()\n"
       "if selfBefore and selfAfter and selfAfter ~= selfBefore then\n"
       '    shell.run("updater")\n    return\nend\n'
       'print("Verifying...")')],
     ORDER),

    # Relaunching every single run doubles the traffic of a fifteen-turtle
    # rollout and doubles the window in which a machine is mid-update.
    ("the updater relaunches unconditionally", "updater.lua",
     [("if selfBefore and selfAfter and selfAfter ~= selfBefore then",
       "if selfBefore and selfAfter then")],
     CURRENT),

    # Deploy manifests.
    ("updater drops logship from COMMON", "updater.lua",
     [('    "logship.lua",\n', "")], MANIFEST),

    ("updater drops waypoints from COMMON", "updater.lua",
     [('    "waypoints.lua",\n', "")], MANIFEST),

    ("updater drops turtle_base from MINER", "updater.lua",
     [('    MINER     = {\n        "turtle_base.lua",\n', "    MINER     = {\n")], MANIFEST),

    ("install drops logship from the delivery profile", "install.lua",
     [('        { src = FILES.logship,         name = "logship.lua"     },\n', "")], INSTALL),

    ("install drops turtle_base from the support profile", "install.lua",
     [('        { src = FILES.turtle_base,    name = "turtle_base.lua" },\n'
       '        { src = FILES.support_turtle, name = "startup.lua"     },',
       '        { src = FILES.support_turtle, name = "startup.lua"     },')], INSTALL),

    # The guards that stop a broken parse from being reported as a pass. A
    # manifest test whose scanner finds nothing agrees with every manifest.
    ("the require scanner matches nothing", "tests/test_deploy_manifest.lua",
     [("    for name in src:gmatch('require%s*%(%s*\"([%w_]+)\"') do out[#out + 1] = name end",
       "    if src then return out end")], MANIFEST),

    ("the role parse finds nothing", "tests/test_deploy_manifest.lua",
     [("    for name, body in rolesBlock:gmatch(", '    for name, body in (""):gmatch(')], MANIFEST),
]

# Deliberately NOT in the list above, recorded so nobody adds it back and reads
# the result as a gap: adding a SECOND ready() check just before self._send,
# while leaving the original in place, is an EQUIVALENT mutant. It changes no
# behaviour, so every test staying green is the correct outcome, not a hole.
READY_GUARD_EQUIVALENT = True


def compiles(path):
    r = subprocess.run(["luac", "-p", path], capture_output=True, text=True)
    return r.returncode == 0, (r.stdout + r.stderr).strip()


def run_suite():
    r = subprocess.run(["lua", "tests/run.lua"], capture_output=True, text=True)
    return r.stdout + r.stderr


def main():
    problems = []
    for label, path, steps, target in MUTANTS:
        original = io.open(path, encoding="utf-8").read()
        mutated, bad = original, None
        for old, new in steps:
            n = mutated.count(old)
            if n != 1:
                bad = f"anchor matched {n} times"
                break
            mutated = mutated.replace(old, new)
        if bad:
            problems.append(f"MALFORMED  {label}: {bad} in {path}")
            continue

        io.open(path, "w", encoding="utf-8", newline="").write(mutated)
        try:
            ok, err = compiles(path)
            if not ok:
                problems.append(f"MALFORMED  {label}: mutant does not compile -- {err}")
                continue
            red = [l for l in run_suite().splitlines() if l.startswith("FAIL  ")]
            if any(l.startswith("FAIL  " + target) for l in red):
                print(f"KILLED     {label}  ({len(red)} red)")
            else:
                problems.append(
                    f"SURVIVED   {label}: '{target}' stayed green; red were {red}")
        finally:
            io.open(path, "w", encoding="utf-8", newline="").write(original)

    print()
    if problems:
        print("\n".join(problems))
        return 1
    print(f"{len(MUTANTS)} mutants, every one killed by its intended test")
    return 0


if __name__ == "__main__":
    sys.exit(main())
