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

# The stall witness. The instrument that has to separate "the messages were
# lost" from "the turtle was not running" -- a witness that always says the same
# thing would end the investigation with a confident wrong answer.
W_LOST   = "a turtle that kept running says the ACKs did not arrive"
W_FROZE  = "a turtle whose clock jumped says it stopped running"
W_IDLE   = "an idle turtle's own wakeup timer is never called a freeze"
W_NEVER  = "a turtle that never connected says so rather than reporting zero"
W_CLEAR  = "hearing from the server clears the window"
W_KEEP   = "reporting does not consume the evidence"
W_WIRED  = "the unreachable warning carries the verdict (SOURCE-ONLY, weaker)"
W_RADIO  = "a turtle with its modem swapped out is not reported as a lost message"
W_UNDECL = "an undeclared radio-less window is called out, not excused"
W_BOTH   = "a turtle that froze during a swap reports both, not one"
W_STALE  = "a declaration does not excuse the next window too"

# A send that KNOWS it failed. Found in the jobs 0039-0042 audit: the outbox and
# the witness both trusted the modem HANDLE, which a swap never clears.
S_FAILKEEP = "a send that reports failure keeps the batch"
S_BACKOFF  = "a failed send waits for the interval, not every loop turn"
S_NILOK    = "a transport that returns nothing still counts as sent"
C_DETACH   = "a log batch flushed through a detached modem is kept"
C_GAP      = "a declared comms gap holds the outbox instead of transmitting into it"
W_UNSENT   = "a heartbeat into a detached modem is counted as unsent"
W_SENTOK   = "a heartbeat through a working modem is not counted as unsent"
Z_BAK      = "a live-zone save drops its backup too"
G_RULE     = "a guarded require that reports its absence is expected to ship"
G_EXEMPT   = "every guarded-require exemption has a reason and is still needed"
P_SCAN     = "a timeout after a storage scan says the scan ran in the window"
P_NONE     = "a timeout with nothing after the push says so"
P_OTHER    = "a window with no storage call says it was not the scan"
P_HIDDEN   = "a storage call behind a slower step still counts"
P_CAP      = "a long window is capped and says how much it left out"
P_STOP     = "a reply that arrived ends the window"
P_WIRED    = "the push, the reply, the timeout and the loop all feed the witness (SOURCE-ONLY, weaker)"
D_EARLY    = "the disk warning comes before the 300 KB floor, not after it"
D_QUIET    = "a disk with plenty of room says nothing"
D_FLOOR    = "crossing the floor is reported at once, inside the repeat window"
D_REPEAT   = "the same level repeats only every five minutes"
D_SAFE     = "the disk warning never calls live state expendable"
D_MINUTE   = "the disk is checked every minute, not only after a job save (SOURCE-ONLY, weaker)"
K_MID      = "a mid-sector miner is not re-sent its sector order on reconnect"
K_WAIT     = "a waiting miner is still re-sent its sector order"
K_OLD      = "a turtle that does not say is re-sent, as before"
T_WAIT     = "a job waiting for a sector order still counts as waiting between receives"
T_GOT      = "a job that has its sector order is no longer waiting for one"
T_ELSE     = "waiting for something else is not waiting for a sector order"
T_REG      = "the reconnect tells the server whether it is waiting (SOURCE-ONLY, weaker)"

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
      ("    if self._send(batch, self._bootId) == false then",
       "    if self._ready and not self._ready() then return false end\n"
       "    if self._send(batch, self._bootId) == false then")], RADIO),

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

    # ── Stall witness ────────────────────────────────────────────────────
    ("freeze bar drawn from the busy case, not the idle one", "turtle_base.lua",
     [("local WITNESS_FREEZE_MS = CFG.HEARTBEAT_INTERVAL * 1000 * 2",
       "local WITNESS_FREEZE_MS = CFG.HEARTBEAT_INTERVAL * 1000 / 2")], W_IDLE),

    ("freeze bar set so high nothing reaches it", "turtle_base.lua",
     [("local WITNESS_FREEZE_MS = CFG.HEARTBEAT_INTERVAL * 1000 * 2",
       "local WITNESS_FREEZE_MS = CFG.HEARTBEAT_INTERVAL * 1000 * 100")], W_FROZE),

    ("the worst pause is never recorded", "turtle_base.lua",
     [("        if gap > _loopGapMax then _loopGapMax = gap end",
       "        if false then _loopGapMax = gap end")], W_FROZE),

    ("loop turns are not counted", "turtle_base.lua",
     [("    _loopTurns    = _loopTurns + 1", "    _loopTurns    = _loopTurns")], W_IDLE),

    ("an ACK does not clear the worst pause", "turtle_base.lua",
     [("    _loopGapMax    = 0\nend", "end")], W_CLEAR),

    ("an ACK does not clear the beat count", "turtle_base.lua",
     [("    _beatsSinceAck = 0\n    _beatsUnsent   = 0", "    _beatsUnsent   = 0")], W_CLEAR),

    ("a turtle that never connected reports a zero elapsed time", "turtle_base.lua",
     [("    if _lastAckWall == 0 then", "    if false then")], W_NEVER),

    # The drain must land AFTER the string is built. An earlier version of this
    # mutant zeroed the gap on ENTRY, which makes both calls return the same
    # (wrong) line -- so "first == second" held and it survived for the wrong
    # reason. A mutant that does not model the fault is not evidence either way.
    ("reporting drains the evidence it just described", "turtle_base.lua",
     [('        _loopGapMax / 1000, table.concat(why, "; "))\nend',
       '        _loopGapMax / 1000, table.concat(why, "; "))\n'
       "    _loopGapMax = 0\n    _beatsSinceAck = 0\n    return __drained\nend"),
      ("    return string.format(\n"
       '        "%.1fs since last ACK, %d beats attempted, loop turned %dx, worst pause %.1fs [%s]",',
       "    local __drained = string.format(\n"
       '        "%.1fs since last ACK, %d beats attempted, loop turned %dx, worst pause %.1fs [%s]",')],
     W_KEEP),

    # The two production setters. Every behavioural test drives a seam instead,
    # so deleting either leaves them all green while the field report is wrong.
    ("sendHeartbeat stops counting the beat", "turtle_base.lua",
     [("    _beatsSinceAck  = _beatsSinceAck + 1\n", "")], W_WIRED),

    ("hearing from the server no longer clears the window", "turtle_base.lua",
     [("            witnessAck(os.epoch(\"utc\"))\n", "")], W_WIRED),

    ("the warning drops the verdict again", "turtle_base.lua",
     [("                witnessVerdict(os.epoch(\"utc\"))))", '                "waiting for reconnect..."))')],
     W_WIRED),

    ("the control loop stops witnessing", "turtle_base.lua",
     [("            witnessTurn(now)\n", "")], W_WIRED),

    # ── The third explanation, which the first capture in the world found ──
    # Guarded by the SOURCE-ONLY wiring test, not by a behavioural one: every
    # behavioural test reaches this counter through base._witnessBeat instead.
    # Now guarded BEHAVIOURALLY. Its first two versions were guarded only by a
    # source assertion -- and the check itself (`not _self.modem`) could never
    # fire in the field, which no source assertion could have noticed.
    ("a beat with no modem counts as sent", "turtle_base.lua",
     [("    if not sent then _beatsUnsent = _beatsUnsent + 1 end\n", "")], W_UNSENT),

    ("the radio clause is dropped from the verdict", "turtle_base.lua",
     [("    if _beatsUnsent > 0 then", "    if false then")], W_RADIO),

    ("a declared comms gap is never noticed", "turtle_base.lua",
     [("    if _self.commsGap then _commsGapSeen = true end\n", "")], W_WIRED),

    ("every radio-less window is excused as declared", "turtle_base.lua",
     [("            _commsGapSeen and \"a declared comms gap, nothing was lost\"",
       "            true and \"a declared comms gap, nothing was lost\"")], W_UNDECL),

    ("an ACK does not clear the comms-gap flag", "turtle_base.lua",
     [("    _commsGapSeen  = false\n", "")], W_STALE),

    ("an ACK does not clear the unsent count", "turtle_base.lua",
     [("    _beatsUnsent   = 0\n", "")], W_CLEAR),

    # Clauses ADDED, not chosen between: an either/or verdict hides whichever
    # condition it happens to test second.
    ("the verdict picks one clause instead of adding them", "turtle_base.lua",
     [("    if _loopGapMax >= WITNESS_FREEZE_MS then\n"
       '        why[#why + 1] = "this turtle stopped running"\n'
       "    end",
       "    if #why == 0 and _loopGapMax >= WITNESS_FREEZE_MS then\n"
       '        why[#why + 1] = "this turtle stopped running"\n'
       "    end")], W_BOTH),

    # ── A send that knows it failed ──────────────────────────────────────
    ("a failed send drops the batch", "logship.lua",
     [("        for i = #batch, 1, -1 do table.insert(self._queue, 1, batch[i]) end\n", "")],
     S_FAILKEEP),

    ("a transport returning nothing counts as failure", "logship.lua",
     [("    if self._send(batch, self._bootId) == false then",
       "    if not self._send(batch, self._bootId) then")], S_NILOK),

    ("a failed send is retried on every loop turn", "logship.lua",
     [("    if self._sendFailed and now - self._lastFlush < self.INTERVAL_MS then return false end\n", "")],
     S_BACKOFF),

    ("a successful send never lifts the backoff", "logship.lua",
     [("    self._sendFailed = false\n    return true", "    return true")], S_BACKOFF),

    ("a successful send reports nothing", "turtle_base.lua",
     [("        _sendFailures = 0\n        return true", "        _sendFailures = 0\n        return")],
     W_SENTOK),

    ("a failed send reports nothing", "turtle_base.lua",
     [("        pcall(base.recoverModem)\n    end\n    return false\nend",
       "        pcall(base.recoverModem)\n    end\nend")], C_DETACH),

    ("the log transport discards the send result", "turtle_base.lua",
     [("        return comms.toServer(proto.MSG.TURTLE_LOG", "        comms.toServer(proto.MSG.TURTLE_LOG")],
     C_DETACH),

    ("the outbox ignores a declared comms gap", "turtle_base.lua",
     [("return _self.modem ~= nil and not _self.commsGap end", "return _self.modem ~= nil end")],
     C_GAP),

    # The server disk: the live-zone save's backup, dropped at last.
    ("the live-zone save keeps its backup again", "central_server.lua",
     [("        dropBackupAfterVerify(ACTIVE_ZONES_FILE)\n", "")], Z_BAK),

    # ── Guarded requires the install check can now see ───────────────────
    # The one this card exists for: before it, removing cloudstore from the
    # server's list left the whole suite green.
    ("updater stops shipping cloudstore to the server", "updater.lua",
     [('        "cloudstore.lua",\n', "")], MANIFEST),

    ("install stops shipping logship to the warehouse", "install.lua",
     [('        { src = FILES.logship,        name = "logship.lua"         },\n', "")], INSTALL),

    ("the scanner stops recognising reports", "tests/test_deploy_manifest.lua",
     [("        if code:find(name .. phrase, 1, true) then return true end", "        if false then return true end")],
     G_RULE),

    ("every guarded require counts, reported or not", "tests/test_deploy_manifest.lua",
     [("        if isReported(src, name) then guarded[#guarded + 1] = name end",
       "        guarded[#guarded + 1] = name")], G_RULE),

    ("the delivery exemption is dropped", "tests/test_deploy_manifest.lua",
     [('            DELIVERY = "the load sits inside `if role == proto.ROLE.MINER`; a delivery turtle never runs it",\n', "")],
     MANIFEST),

    ("an exemption loses its reason", "tests/test_deploy_manifest.lua",
     [('            SUPPORT  = "the load sits inside `if role == proto.ROLE.MINER`; a support turtle never runs it",',
       '            SUPPORT  = "miner only",')], G_EXEMPT),

    # ── The push witness ─────────────────────────────────────────────────────
    ("the push's own turn is counted", "central_server.lua",
     [("    if w.skip then w.skip = false; w.cur = {}; return end\n", "")], P_NONE),

    ("the witness blames the scan for every window", "central_server.lua",
     [("    if PERIPHERAL_STEPS[name] then w.peripheral = true end", "    w.peripheral = true")], P_OTHER),

    ("the witness never blames the scan", "central_server.lua",
     [("    if PERIPHERAL_STEPS[name] then w.peripheral = true end", "    w.peripheral = false")], P_SCAN),

    ("an empty window is reported as a scan", "central_server.lua",
     [("    if w.turns == 0 then", "    if false then")], P_NONE),

    ("the trail drops the steps", "central_server.lua",
     [('    w.cur[#w.cur + 1] = string.format("%s %dms", name, ms)\n', "")], P_HIDDEN),

    ("a capped trail hides what it dropped", "central_server.lua",
     [('        more > 0 and string.format(" (+%d more)", more) or "",', '        "",')], P_CAP),

    ("the reply does not end the window", "central_server.lua",
     [("function pushWitness.stop() pushWitness.w = nil end", "function pushWitness.stop() end")], P_STOP),

    ("the timeout line drops the evidence", "central_server.lua",
     [("                    pushWitness.summary() or \"no window recorded\"))\n                pushWitness.stop()",
       "                    \"\"))\n                pushWitness.stop()")], P_WIRED),

    ("timed stops recording steps", "central_server.lua",
     [("        pushWitness.step(name, ms)\n", "")], P_WIRED),

    ("the loop stops counting turns", "central_server.lua",
     [("            pushWitness.turn(event)\n", "")], P_WIRED),

    # ── The low-disk warning ────────────────────────────────────────────────
    ("the warning threshold goes back to 120 KB", "central_server.lua",
     [("local DISK_WARN_BYTES  = 350000", "local DISK_WARN_BYTES  = 120000")], D_EARLY),

    ("the warning fires at any free space", "central_server.lua",
     [("(free < DISK_WARN_BYTES and 1) or 0", "1")], D_QUIET),

    ("a worse level waits for the repeat window", "central_server.lua",
     [("    if level <= _lastDiskLevel and now - _lastDiskWarn < DISK_WARN_EVERY then return end",
       "    if now - _lastDiskWarn < DISK_WARN_EVERY then return end")], D_FLOOR),

    ("the floor is only a warning", "central_server.lua",
     [("    if level == 2 then logError(msg) else logWarn(msg) end", "    logWarn(msg)")], D_FLOOR),

    ("the same level repeats every call", "central_server.lua",
     [("    if level <= _lastDiskLevel and now - _lastDiskWarn < DISK_WARN_EVERY then return end\n", "")],
     D_REPEAT),

    ("the warning calls live zones expendable again", "central_server.lua",
     [('"both LIVE state, do not delete them; a leftover active_zones.dat.bak "',
       '"zones are also in the cloud store, so the disk copy is expendable; "')], D_SAFE),

    ("the minute rollup stops checking the disk", "central_server.lua",
     [("                loopLastRollup = now2\n", "                loopLastRollup = now2\n                -- gone\n"),
      ("                warnIfDiskTight()\n            end", "            end")], D_MINUTE),

    # ── The stale sector order after a reconnect ─────────────────────────────
    ("the server replays to every reconnecting miner again", "central_server.lua",
     [("                    if la and awaitingSector ~= false then", "                    if la then")],
     K_MID),

    ("the server replays only to a miner that says so", "central_server.lua",
     [("                    if la and awaitingSector ~= false then",
       "                    if la and awaitingSector == true then")], K_OLD),

    ("the server never replays", "central_server.lua",
     [("                    if la and awaitingSector ~= false then",
       "                    if false then")], K_WAIT),

    ("the handler drops the turtle's answer", "central_server.lua",
     [("p.midJob, p.awaitingSector)", "p.midJob)")], K_MID),

    ("withholding is silent", "central_server.lua",
     [('                            "Withheld SECTOR_ASSIGN (%d,%d) from %s on re-link: "',
       '                            "SECTOR_ASSIGN (%d,%d) %s re-link: "')], K_MID),

    ("receive stops remembering what it waits for", "turtle_base.lua",
     [("    _jobAwaiting = (wantType == nil) and AWAIT_ANY or wantType\n", "")], T_WAIT),

    ("a timed-out receive forgets the wait", "turtle_base.lua",
     [("    if msg ~= nil then _jobAwaiting = nil end", "    _jobAwaiting = msg and nil or nil")],
     T_WAIT),

    ("a delivered message does not end the wait", "turtle_base.lua",
     [("    if msg ~= nil then _jobAwaiting = nil end\n", "")], T_GOT),

    ("any wait counts as waiting for a sector", "turtle_base.lua",
     [("    if type(w) == \"table\" then return w[t] == true end", "    if type(w) == \"table\" then return true end")],
     T_ELSE),

    ("the reconnect stops reporting", "turtle_base.lua",
     [("            awaitingSector = base.isAwaiting(proto.MSG.SECTOR_ASSIGN),\n", "")], T_REG),

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
    # THE BASELINE. Without it every verdict below is unsound.
    #
    # On 2026-09-10 an assertion in test_stall_witness.lua was already FAILING
    # -- it anchored on a function's definition rather than its call site -- and
    # this harness reported every mutant pointed at it as KILLED, because a test
    # that is red before the mutation is red after it too. Thirteen mutants were
    # certified by a test that could not pass. A red suite makes "the intended
    # test went red" mean nothing at all.
    red = [l for l in run_suite().splitlines() if l.startswith("FAIL  ")]
    if red:
        print("BASELINE NOT GREEN -- refusing to mutate. Fix these first:")
        for l in red:
            print("  " + l)
        return 1

    problems = []
    for label, path, steps, target in MUTANTS:
        # The RAW bytes, restored verbatim in the finally below. Reading in text
        # mode turns CRLF into LF, and writing that back left every mutated
        # file with rewritten line endings -- a phantom change git would then
        # refuse to switch branches over. Mutate an LF copy; restore the raw.
        raw = io.open(path, encoding="utf-8", newline="").read()
        original = raw.replace(chr(13) + chr(10), chr(10))
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
            io.open(path, "w", encoding="utf-8", newline="").write(raw)

    print()
    if problems:
        print("\n".join(problems))
        return 1
    print(f"{len(MUTANTS)} mutants, every one killed by its intended test")
    return 0


if __name__ == "__main__":
    sys.exit(main())
