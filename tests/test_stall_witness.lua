-- What a turtle says about HOW it lost the server.
--
-- Measured 2026-09-10 over a full day of fleet log: 291 disconnect events in 68
-- clusters, five of them taking 12-15 nodes at once. Both server-side
-- explanations were tested against that log and both failed:
--
--   * bridge pushes are NEGATIVELY correlated with the clusters (5 near-hits
--     where chance alone predicts 9);
--   * the server never stopped -- its 60-second loop rollup arrives on cadence
--     straight through every fleet-wide dropout at ~100ms worst busy time, and
--     the bridge, a separate process outside the game, keeps its own 60s
--     cadence unbroken.
--
-- The server was running and every turtle stopped hearing it anyway. What is
-- left is either "the messages were lost" or "the turtle was not running", and
-- from the server those two are the same event. Only the turtle can tell them
-- apart, by reporting what its own loop did.
--
-- These tests exist to make sure it reports the RIGHT one, because a witness
-- that always says the same thing is worse than no witness: it would end this
-- investigation with a confident wrong answer.

package.path = "./?.lua;" .. package.path

local stub = require("tests.stub_cc")

local MODULES = { "turtle_base", "logship", "mine_flow", "equipment", "geofence", "loader_state" }

local T0 = 1700000000000

-- os.epoch is not part of the stub. These tests drive the witness with explicit
-- clock readings, so all they need is for os.epoch to EXIST while turtle_base
-- and logship load.
--
-- Installed once, here, and deliberately NOT torn down again.
--
-- The first version restored it in a cleanup test, and that test was flaky in
-- the worst way: Lua iterates a suite table in hash order, so whether cleanup
-- ran first (harmless) or last (fatal) varied between runs. Running last, it
-- removed os.epoch while logship's print capture was still installed globally,
-- and the next print -- the RUNNER's own PASS line -- threw. A test whose result
-- depends on table ordering is worse than no test.
--
-- A real millisecond clock rather than a frozen constant, so a later suite that
-- inherits it measures elapsed time correctly instead of seeing time stand still.
if os.epoch == nil then
    os.epoch = function() return math.floor(os.time() * 1000) end
end

local function freshBase()
    for _, m in ipairs(MODULES) do package.loaded[m] = nil end
    stub.install({ fuel = 100000, equipped = { left = require("equipment").ITEMS.MODEM } })
    return require("turtle_base")
end

-- Drives the loop's witness at a steady cadence, the way an idle turtle's
-- control loop actually turns: once per wakeup timer.
local function turnFor(base, from, ms, stepMs)
    local t = from
    local stop = from + ms
    while t < stop do
        base._witnessTurn(t)
        t = t + stepMs
    end
    return t
end

local suite = {}

-- Case A: the loop kept turning the whole time and the ACKs simply never came.
-- This is the one that means the radio, the server's send path, or the event
-- queue lost the messages -- i.e. a real bug still to find.
suite["a turtle that kept running says the ACKs did not arrive"] = function(assert_eq)
    local base = freshBase()
    base._witnessAck(T0)

    -- 15 seconds is MAX_MISSED (3) x HEARTBEAT_INTERVAL (5s): exactly the window
    -- that trips serverDown. The loop wakes every 5s when idle, so three turns.
    local now = turnFor(base, T0, 15000, 5000)
    base._witnessBeat(); base._witnessBeat(); base._witnessBeat()

    local line = base._witnessVerdict(now)
    assert_eq(line:find("the ACKs did not arrive", 1, true) ~= nil, true,
        "a loop that never paused longer than its own wakeup timer must NOT be "
        .. "reported as frozen — got: " .. line)
    assert_eq(line:find("stopped running", 1, true), nil,
        "and must not also carry the opposite verdict")
    assert_eq(line:find("15.0s since last ACK", 1, true) ~= nil, true,
        "and must report the measured gap, not just a verdict — got: " .. line)
    assert_eq(line:find("3 beats attempted", 1, true) ~= nil, true,
        "including how many heartbeats went out unanswered, which is what "
        .. "separates 'nobody replied' from 'nobody asked' — got: " .. line)
end

-- Case B: the turtle's own clock jumped. Fifteen seconds of wall time passed
-- inside one iteration, which no timer in the system schedules. The turtle was
-- not slow, it was absent -- and nothing was ever wrong with the radio.
suite["a turtle whose clock jumped says it stopped running"] = function(assert_eq)
    local base = freshBase()
    base._witnessAck(T0)

    base._witnessTurn(T0)
    base._witnessTurn(T0 + 5000)      -- one ordinary wakeup
    base._witnessTurn(T0 + 18000)     -- and then 13 seconds inside one iteration
    base._witnessBeat()

    local line = base._witnessVerdict(T0 + 18000)
    assert_eq(line:find("stopped running", 1, true) ~= nil, true,
        "a 13-second gap between two consecutive iterations is not something "
        .. "any timer in this system schedules — got: " .. line)
    assert_eq(line:find("the ACKs did not arrive", 1, true), nil,
        "and must not blame the radio for it")
    assert_eq(line:find("worst pause 13.0s", 1, true) ~= nil, true,
        "and must show the pause it based that on, so the threshold can be "
        .. "argued with from the log — got: " .. line)
end

-- The threshold is the whole risk in this instrument. Set it from the busy case
-- and it cries wolf on every idle turtle, which is exactly how the phase-stuck
-- detector produced fourteen false alarms on 2026-09-09.
suite["an idle turtle's own wakeup timer is never called a freeze"] = function(assert_eq)
    local base = freshBase()
    base._witnessAck(T0)

    -- A full minute of an idle turtle: nothing but the 5s wakeup timer.
    local now = turnFor(base, T0, 60000, 5000)

    local line = base._witnessVerdict(now)
    assert_eq(line:find("stopped running", 1, true), nil,
        "five-second gaps are the design — CFG.HEARTBEAT_INTERVAL is what wakes "
        .. "an idle loop, and calling that a freeze makes the whole fleet a "
        .. "false positive — got: " .. line)
    assert_eq(line:find("loop turned 12x", 1, true) ~= nil, true,
        "and the turn count is the corroborating evidence: a turtle that really "
        .. "froze cannot also have turned twelve times — got: " .. line)
end

-- A turtle that has never heard from the server has no baseline. Reporting
-- "0.0s since last ACK" would read as a server that answered a moment ago --
-- the pass state and the no-data state looking identical, which has been the
-- most expensive recurring mistake in this system.
suite["a turtle that never connected says so rather than reporting zero"] =
function(assert_eq)
    local base = freshBase()
    base._witnessTurn(T0)
    base._witnessTurn(T0 + 5000)
    base._witnessBeat()

    local line = base._witnessVerdict(T0 + 5000)
    assert_eq(line:find("no ACK since boot", 1, true) ~= nil, true,
        "with no ACK ever received there is nothing to measure from — got: " .. line)
    assert_eq(line:find("since last ACK", 1, true), nil,
        "and it must NOT report an elapsed time, which would be measured from "
        .. "zero and read as a server that just answered")
    assert_eq(line:find("nothing to compare against", 1, true) ~= nil, true,
        "and must say why it has no answer")
end

-- The window has to close when the server is heard from, or the second stall
-- inherits the first one's evidence and every verdict after the first is about
-- the wrong event.
suite["hearing from the server clears the window"] = function(assert_eq)
    local base = freshBase()
    base._witnessAck(T0)
    base._witnessTurn(T0)
    base._witnessTurn(T0 + 20000)          -- a freeze
    -- ... during a declared, radio-less window. Every counter the window owns
    -- is dirtied here, so the reset below has all of them to clear.
    base._witnessCommsGap()
    base._witnessBeat(true)
    assert_eq(base._witnessVerdict(T0 + 20000):find("stopped running", 1, true) ~= nil,
        true, "precondition: the freeze is seen")
    assert_eq(base._witnessVerdict(T0 + 20000):find("no radio", 1, true) ~= nil,
        true, "precondition: the radio-less window is seen")

    base._witnessAck(T0 + 21000)           -- ... and then the server comes back
    base._witnessTurn(T0 + 21000)
    base._witnessTurn(T0 + 26000)
    base._witnessBeat()

    local line = base._witnessVerdict(T0 + 26000)
    assert_eq(line:find("stopped running", 1, true), nil,
        "the next stall must be judged on its OWN window — a worst pause that "
        .. "survives a reconnect makes every later verdict a copy of the first")
    assert_eq(line:find("5.0s since last ACK", 1, true) ~= nil, true,
        "and the elapsed time must restart from the reconnect — got: " .. line)
    assert_eq(line:find("1 beats attempted", 1, true) ~= nil, true,
        "as must the beat count")
    assert_eq(line:find("no radio", 1, true), nil,
        "and the radio-less count must reset, or one loader swap accuses a "
        .. "turtle of having no modem for the rest of its life")
    assert_eq(line:find("nothing was lost", 1, true), nil,
        "and the declared-gap flag with it, or the NEXT window is excused by a "
        .. "declaration that belonged to the previous one")
end

-- Reading the verdict must not consume it. Two stalls in a row is the
-- interesting case -- it is what a genuinely sick turtle looks like -- and a
-- report that wiped its own evidence would make the second one unreadable.
suite["reporting does not consume the evidence"] = function(assert_eq)
    local base = freshBase()
    base._witnessAck(T0)
    base._witnessTurn(T0)
    base._witnessTurn(T0 + 20000)
    base._witnessBeat()

    local first  = base._witnessVerdict(T0 + 20000)
    local second = base._witnessVerdict(T0 + 20000)
    assert_eq(first, second,
        "the verdict is a read, not a drain: a turtle that stalls twice without "
        .. "reconnecting must still be able to describe the second one")
end

-- THE CASE THE FIRST VERSION GOT WRONG, and the reason there is a v2.
--
-- node_138, 2026-09-10 10:08:06, the very first capture in the world:
--   "18.7s since last ACK, 3 beats sent, loop turned 102x, worst pause 0.9s
--    [this turtle kept running - the ACKs did not arrive]"
--
-- 102 turns, 0.9s worst pause: emphatically running. So the instrument reported
-- a lost-message bug. There was none. The turtle was in the loader-retrieval
-- ascent, where equipment.retrievalSwapIn takes the MODEM off to fit the chunk
-- loader. It had no radio. Nothing was lost because nothing was transmitted.
suite["a turtle with its modem swapped out is not reported as a lost message"] =
function(assert_eq)
    local base = freshBase()
    base._witnessAck(T0)
    base._witnessCommsGap()                      -- the fleet declared the window
    for i = 0, 3 do base._witnessTurn(T0 + i * 5000) end
    base._witnessBeat(true); base._witnessBeat(true); base._witnessBeat(true)

    local line = base._witnessVerdict(T0 + 15000)
    assert_eq(line:find("the ACKs did not arrive", 1, true), nil,
        "a turtle with no radio cannot be evidence that a message was lost -- "
        .. "nothing was ever transmitted -- got: " .. line)
    assert_eq(line:find("no radio for 3 of them", 1, true) ~= nil, true,
        "it must say how many beats had nowhere to go -- got: " .. line)
    assert_eq(line:find("nothing was lost", 1, true) ~= nil, true,
        "and that the gap was declared, so nobody spends an afternoon on it")
    assert_eq(line:find("3 beats attempted", 1, true) ~= nil, true,
        "ATTEMPTED, not sent: comms.toServer pcalls past a detached modem, so "
        .. "'sent' was the word that made the first capture read as a bug")
end

-- The same window with nobody having declared it is a different thing entirely:
-- a turtle that lost its modem without meaning to. Same symptom, opposite
-- meaning, and the flag is the only thing that separates them.
suite["an undeclared radio-less window is called out, not excused"] =
function(assert_eq)
    local base = freshBase()
    base._witnessAck(T0)
    for i = 0, 3 do base._witnessTurn(T0 + i * 5000) end
    base._witnessBeat(true); base._witnessBeat(true)

    local line = base._witnessVerdict(T0 + 15000)
    assert_eq(line:find("NO comms gap was declared", 1, true) ~= nil, true,
        "a turtle that lost its radio WITHOUT the fleet expecting it is a real "
        .. "fault, and must not be filed under the benign one -- got: " .. line)
    assert_eq(line:find("nothing was lost", 1, true), nil,
        "and must not claim nothing was lost, because something might have been")
end

-- The declared-gap flag has to die with its window.
--
-- Mutation found this one: removing the flag's reset from witnessAck left every
-- test green, because none of them opened a SECOND radio-less window after a
-- reconnect. In the field that is the common case -- a miner does a loader swap
-- every sector -- and a flag that survives means the first legitimate swap
-- excuses every genuine radio failure for the rest of the turtle's life.
suite["a declaration does not excuse the next window too"] = function(assert_eq)
    local base = freshBase()

    -- Window one: a proper, declared loader swap.
    base._witnessAck(T0)
    base._witnessCommsGap()
    base._witnessTurn(T0)
    base._witnessBeat(true)
    assert_eq(base._witnessVerdict(T0):find("nothing was lost", 1, true) ~= nil, true,
        "precondition: the declared window is excused")

    -- The server comes back, and then the radio goes away again with nobody
    -- declaring it. That is a fault, and it must not inherit the excuse.
    base._witnessAck(T0 + 1000)
    base._witnessTurn(T0 + 1000)
    base._witnessTurn(T0 + 6000)
    base._witnessBeat(true)

    local line = base._witnessVerdict(T0 + 6000)
    assert_eq(line:find("NO comms gap was declared", 1, true) ~= nil, true,
        "an undeclared radio-less window after a declared one is still a fault "
        .. "-- got: " .. line)
    assert_eq(line:find("nothing was lost", 1, true), nil,
        "and must NOT be excused by the previous window's declaration")
end

-- A turtle can freeze DURING a swap. An either/or verdict would report whichever
-- branch it happened to check first and hide the other.
suite["a turtle that froze during a swap reports both, not one"] = function(assert_eq)
    local base = freshBase()
    base._witnessAck(T0)
    base._witnessCommsGap()
    base._witnessTurn(T0)
    base._witnessTurn(T0 + 20000)                -- and it also stopped running
    base._witnessBeat(true)

    local line = base._witnessVerdict(T0 + 20000)
    assert_eq(line:find("no radio for 1 of them", 1, true) ~= nil, true,
        "the radio clause must be there -- got: " .. line)
    assert_eq(line:find("stopped running", 1, true) ~= nil, true,
        "and so must the freeze: clauses are ADDED, because a 20-second pause "
        .. "is worth knowing about even when the missing radio already explains "
        .. "the missing ACKs -- got: " .. line)
end

-- SOURCE-ONLY, weaker: reaching the real warn needs a registration, a modem and
-- three heartbeat boundaries to line up. What is pinned here is that the
-- production line actually CARRIES the verdict -- without this the whole
-- instrument is exercised only by its own tests and says nothing in the world.
suite["the unreachable warning carries the verdict (SOURCE-ONLY, weaker)"] =
function(assert_eq)
    local f = assert(io.open("turtle_base.lua", "r"))
    local src = f:read("*a")
    f:close()

    -- Comments stripped: every anchor below also appears in the prose above the
    -- code, and a source assertion that cannot tell those apart has already
    -- passed against broken code five times this week.
    local NL   = string.char(10)
    local code = (src:gsub("%-%-[^" .. NL .. "]*", ""))

    local at = code:find("Server unreachable", 1, true)
    assert_eq(at ~= nil, true, "the unreachable warning moved or vanished")
    local stmt = code:sub(at, at + 300)
    assert_eq(stmt:find("witnessVerdict(", 1, true) ~= nil, true,
        "the warning must carry the witness — a turtle that only says it lost "
        .. "the server leaves the two remaining explanations indistinguishable, "
        .. "which is the state this whole instrument exists to end")

    -- And the loop must feed it, or every verdict is measured from one turn.
    local runAt = code:find("function base.run(jobHandler)", 1, true)
    assert_eq(runAt ~= nil, true, "base.run moved or vanished")
    assert_eq(code:sub(runAt):find("witnessTurn(now)", 1, true) ~= nil, true,
        "the control loop must witness every iteration, or 'loop turned 1x' is "
        .. "an artefact of nobody counting rather than a turtle that froze")

    -- The two PRODUCTION setters. Every behavioural test above drives the test
    -- seams instead -- base._witnessBeat and base._witnessAck -- so deleting
    -- either of these lines leaves all of them green while the instrument
    -- reports nonsense in the field. That exact trap caught the log-retry setter
    -- on 2026-09-09; it is only in this file because mutation put it here.
    local hbAt = code:find("local function sendHeartbeat", 1, true)
    assert_eq(hbAt ~= nil, true, "sendHeartbeat moved or vanished")
    assert_eq(code:sub(hbAt, hbAt + 400):find("_beatsSinceAck", 1, true) ~= nil, true,
        "sendHeartbeat must count the beat, or 'N beats sent' is always 0 and "
        .. "cannot distinguish 'nobody replied' from 'nobody asked'")

    -- Anchored on the GATE, not on resetMissedHeartbeats: that name's first
    -- occurrence in the file is its own definition, four hundred lines above the
    -- only place it is called, and a window measured from the definition can
    -- never contain the call. This assertion failed for exactly that reason and
    -- the mutation harness reported the mutant KILLED anyway -- see the baseline
    -- check now in tests/mutate_logship.py.
    -- v2 added two more production setters, and mutation found both unguarded
    -- for the same reason as the first pair: the behavioural tests reach them
    -- through base._witnessBeat and base._witnessCommsGap. Delete either line
    -- and every one of those tests stays green while the field report is wrong.
    assert_eq(code:sub(hbAt, hbAt + 700):find("_beatsUnsent", 1, true) ~= nil, true,
        "sendHeartbeat must notice a beat that had no modem to go out on -- "
        .. "'attempted' and 'sent' are the same number without it, and that is "
        .. "exactly what made the first capture read as a lost-message bug")

    local turnAt = code:find("local function witnessTurn", 1, true)
    assert_eq(turnAt ~= nil, true, "witnessTurn moved or vanished")
    assert_eq(code:sub(turnAt, turnAt + 400):find("_self.commsGap", 1, true) ~= nil, true,
        "the loop must sample the declared-gap flag while the gap is OPEN -- it "
        .. "is cleared again by the time the turtle notices it lost the server, "
        .. "so reading it at report time always finds it false")

    local ackAt = code:find('if msg.from == "server" then', 1, true)
    assert_eq(ackAt ~= nil, true, "the server-message gate moved or vanished")
    assert_eq(code:sub(ackAt, ackAt + 300):find("witnessAck(", 1, true) ~= nil, true,
        "hearing from the server must clear the window in production too, or "
        .. "every verdict after the first describes the first one for ever")
end

return suite
