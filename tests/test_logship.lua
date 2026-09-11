-- The log outbox, exercised as what it now is: a module any computer can use.
--
-- These are deliberately NOT turtle tests. Everything here runs with no stub,
-- no modem, no registration and no control loop -- because that is exactly the
-- situation the warehouse and admin computers are in, and the whole reason the
-- outbox moved out of turtle_base.lua. If a property only holds when a turtle
-- is standing behind it, it does not hold for the two machines that were about
-- to get a hand-typed copy of it.
--
-- The turtle path keeps its own coverage in test_control_loop.lua. Those tests
-- were the regression net for the extraction and were not touched by it, apart
-- from two source assertions pinned to strings that moved.

package.path = "./?.lua;" .. package.path

local suite = {}

-- ─── Fixture ─────────────────────────────────────────────────────────────────
--
-- A deterministic clock rather than the stub's: logship touches exactly one CC
-- API (os.epoch), and standing up the whole stub to supply it would put a
-- turtle back in a test whose point is that there isn't one.
local function withShip(opts, body)
    local savedEpoch = os.epoch
    local savedPrint = print
    local savedRaw   = _G.__LOGSHIP_RAW_PRINT

    local clock = 1700000000000
    os.epoch = function() return clock end
    -- Swallowed: these tests print hundreds of lines on purpose, and the run
    -- output is how a failure is read.
    print = function() end
    _G.__LOGSHIP_RAW_PRINT = nil

    package.loaded["logship"] = nil
    local logship = require("logship")

    local sent = {}
    opts = opts or {}
    if opts.send == nil then
        opts.send = function(lines, bootId)
            sent[#sent + 1] = { lines = lines, bootId = bootId }
        end
    end

    local ship = logship.new(opts)
    local ctx = {
        ship    = ship,
        sent    = sent,
        logship = logship,
        now     = function() return clock end,
        advance = function(ms) clock = clock + ms end,
    }

    local ok, err = pcall(body, ctx)

    os.epoch = savedEpoch
    print    = savedPrint
    _G.__LOGSHIP_RAW_PRINT = savedRaw
    package.loaded["logship"] = nil
    if not ok then error(err, 0) end
end

local function linesOf(batch)
    local out = {}
    for _, e in ipairs(batch.lines) do out[#out + 1] = e.msg end
    return out
end

-- ─── The warehouse shape ─────────────────────────────────────────────────────

-- The warehouse computer forwards no logs at all today, and it is not a turtle:
-- no registration, no heartbeat, no control loop, no base. If shipping a line
-- needs any of those, moving the outbox out of turtle_base.lua bought nothing.
suite["a computer with no turtle behind it ships its lines"] = function(assert_eq)
    withShip({ source = "warehouse" }, function(c)
        print("[WH] State machine ready.")
        print("[WH] delivering to node_119")
        assert_eq(c.ship:flush(), true, "the flush must actually send")

        assert_eq(#c.sent, 1, "one batch")
        local msgs = linesOf(c.sent[1])
        assert_eq(#msgs, 2, "carrying both lines")
        assert_eq(msgs[1], "[WH] State machine ready.", "in the order printed")
        assert_eq(msgs[2], "[WH] delivering to node_119", "in the order printed")

        -- The sequence is the whole reason the retry is free: the bridge
        -- de-duplicates on (source, bootId, seq), so a line with no seq can
        -- never be acknowledged and gets re-sent for ever.
        assert_eq(c.sent[1].lines[1].seq, 1, "sequence starts at one")
        assert_eq(c.sent[1].lines[2].seq, 2, "and is monotonic")
        assert_eq(type(c.sent[1].bootId), "number", "and the batch names its boot")
    end)
end

-- The level has to survive as a FIELD. W5 keeps a regex for the bare print()
-- calls that never had a level to lose, but a parsed level and a known one must
-- not be the same thing, or `grep WARN` quietly answers for only half the fleet.
suite["a level the caller knows is carried, not left to a regex"] = function(assert_eq)
    withShip({}, function(c)
        c.ship.pendingLevel = "WARN"
        print("rsBridge call failed")
        c.ship.pendingLevel = nil
        print("ordinary chatter")
        c.ship:flush()

        local e = c.sent[1].lines
        assert_eq(e[1].level, "WARN",
            "a line printed with a known level must carry it as a field")
        assert_eq(e[2].level, nil,
            "and one printed without a level must carry none, rather than "
            .. "inheriting the last one set -- a stuck level is worse than an "
            .. "absent one, because the regex fallback cannot tell")
    end)
end

-- ─── Pacing ──────────────────────────────────────────────────────────────────

-- This is what "the control loop honours the early-flush request" could only
-- assert against source text while the pacing lived inside base.run. A node in
-- trouble talks more, so the outbox fills exactly when its contents are worth
-- having, and waiting out the interval is how node_119 lost 38 lines in one gap
-- on 2026-09-09 with a geofence refusal on the far side of it.
suite["an urgent outbox does not wait for the interval"] = function(assert_eq)
    withShip({}, function(c)
        c.ship:resetInterval(c.now())

        print("quiet")
        c.advance(1000)
        assert_eq(c.ship:tick(c.now()), false,
            "ordinary chatter a second in must NOT flush, or every node "
            .. "transmits on every line and the radio is the bottleneck")
        assert_eq(#c.sent, 0, "and nothing goes out")

        -- Past the high-water mark.
        for i = 1, 30 do print("burst " .. i) end
        assert_eq(c.ship:urgent(), true, "precondition: the outbox has asked")

        c.advance(1000)                     -- 2 s in, nowhere near 15
        assert_eq(c.ship:tick(c.now()), true,
            "a filling outbox must be flushed NOW rather than at the next "
            .. "15-second boundary")
        assert_eq(#c.sent, 1, "and the batch actually goes out")
    end)
end

suite["a quiet outbox still flushes on the interval"] = function(assert_eq)
    withShip({}, function(c)
        c.ship:resetInterval(c.now())
        print("one line, all minute")

        c.advance(14000)
        assert_eq(c.ship:tick(c.now()), false, "not before the interval")
        assert_eq(#c.sent, 0, "nothing sent yet")

        c.advance(1000)
        assert_eq(c.ship:tick(c.now()), true, "but at the interval, yes")
        assert_eq(#c.sent, 1,
            "a node that says one thing an hour must still be heard -- the "
            .. "urgent flag is a short-circuit, not the only way out")
    end)
end

-- ─── Late transport ──────────────────────────────────────────────────────────

-- A turtle captures print at module load and does not have comms.toServer for
-- another four hundred lines. Anything printed in between is boot diagnostics,
-- which is the most valuable stretch of log a node ever produces and the one
-- most likely to be thrown away by an outbox that requires a transport to exist
-- before it will accept a line.
suite["lines printed before the transport exists are kept, not lost"] =
function(assert_eq)
    withShip({ send = false }, function(c)
        -- send=false is the fixture's way of saying "construct with no
        -- transport at all"; logship treats any non-function as absent.
        print("boot line 1")
        print("boot line 2")
        assert_eq(c.ship:flush(), false,
            "a flush with nowhere to send must report that it sent nothing")

        local sent = {}
        c.ship:setTransport({
            send = function(lines, bootId) sent[#sent + 1] = { lines = lines, bootId = bootId } end,
        })
        assert_eq(c.ship:flush(), true, "and once there is a transport, it sends")

        local msgs = linesOf(sent[1])
        assert_eq(#msgs, 2, "both boot lines survived the wait")
        assert_eq(msgs[1], "boot line 1", "in order")
    end)
end

-- ready() is the modem check. A solo miner deliberately unequips its modem
-- mid-job (chunk loading outranks comms), so a flush that lands in that window
-- must be a complete no-op -- not a batch handed to a nil peripheral and lost.
suite["a node with no radio keeps its lines until it has one"] = function(assert_eq)
    withShip({}, function(c)
        local haveModem = false
        c.ship:setTransport({
            ready = function() return haveModem end,
            send  = function(lines, bootId) c.sent[#c.sent + 1] = { lines = lines, bootId = bootId } end,
        })

        print("dug through granite")
        print("loader retrieved")
        assert_eq(c.ship:flush(), false, "nothing goes out with the modem off")
        assert_eq(#c.sent, 0, "and nothing is sent")

        haveModem = true
        assert_eq(c.ship:flush(), true, "the flush after recovery sends")
        assert_eq(#linesOf(c.sent[1]), 2,
            "carrying the lines written during the gap, which are the lines "
            .. "that describe the gap")
    end)
end

-- ─── One computer, one capture ───────────────────────────────────────────────

-- The failure this prevents is silent and doubles the fleet's log traffic: if a
-- second capture wraps the first instead of replacing it, every print appends
-- to BOTH queues, both ship it, and the bridge writes one line twice under two
-- different sequence numbers -- which is exactly the case (source, bootId, seq)
-- de-duplication cannot catch, because the sequences genuinely differ.
--
-- Not hypothetical: package.loaded is cleared between test cases, so a
-- module-local "the original print" is nil again on every reload and each
-- reload would wrap the previous instance's wrapper.
suite["a second outbox replaces the capture rather than stacking on it"] =
function(assert_eq)
    withShip({}, function(c)
        local first = c.ship
        local second = c.logship.new({
            send = function() end,
        })

        print("one line")

        assert_eq(second:_queueDepth(), 1, "the live outbox gets the line")
        assert_eq(first:_queueDepth(), 0,
            "and the superseded one gets nothing -- two queues on one computer "
            .. "means every line is shipped twice under two different sequence "
            .. "numbers, which is the one duplicate the bridge cannot dedupe")
    end)
end

-- ─── Identity ────────────────────────────────────────────────────────────────

-- bootId has to be COMPARABLE -- higher is newer -- because a node's ring lives
-- on the server and outlives the node, so one push window can straddle two
-- boots. Agreed with W5 in 2026-09-08-W3-to-W5-bootid-will-be-comparable.md.
suite["a later boot has a higher bootId"] = function(assert_eq)
    withShip({}, function(c)
        local before = c.ship:_bootStamp()
        c.advance(60000)
        local later = c.logship.new({ send = function() end })
        assert_eq(later:_bootStamp() > before, true,
            "a wall-clock stamp, not a counter: the server compares the two to "
            .. "decide which lines it has already acknowledged, and a stamp "
            .. "that does not increase makes a fresh boot look acknowledged")
    end)
end

-- ─── A send that knows it failed ─────────────────────────────────────────────

-- Found in the audit of jobs 0039-0042: 190 lines missing, almost all on the
-- four miners, zero "dropped" notices, the big gaps directly after the modem
-- swap. The outbox took the batch off the queue, the transmit raised on a
-- detached modem, and the batch was gone.
suite["a send that reports failure keeps the batch"] = function(assert_eq)
    withShip({}, function(c)
        local up, got = false, {}
        c.ship:setTransport({ send = function(lines)
            if not up then return false end
            got[#got + 1] = lines
        end })
        print("dug through granite")
        print("loader retrieved")

        assert_eq(c.ship:flush(), false, "a send that failed must be reported as not sent")
        assert_eq(c.ship:_queueDepth(), 2,
            "and both lines must still be queued -- these are the lines written "
            .. "while the radio was off, which are the lines that describe why")

        up = true
        assert_eq(c.ship:flush(), true, "the next send goes out")
        assert_eq(#got, 1, "as one batch")
        assert_eq(#got[1], 2, "carrying both lines")
        assert_eq(got[1][1].msg, "dug through granite", "in the order printed")
    end)
end

-- A radio that is off for a 110-second ascent must not be asked to transmit on
-- every turn of a loop that turns several times a second.
suite["a failed send waits for the interval, not every loop turn"] = function(assert_eq)
    withShip({}, function(c)
        local up, sends = false, 0
        c.ship:setTransport({ send = function()
            sends = sends + 1
            if not up then return false end
        end })
        c.ship:resetInterval(c.now())
        for i = 1, 30 do print("burst " .. i) end
        assert_eq(c.ship:urgent(), true, "precondition: the outbox has asked")

        c.advance(1000)
        assert_eq(c.ship:tick(c.now()), true, "the first attempt goes immediately")
        assert_eq(sends, 1, "and is actually made")

        -- The turtle keeps talking while its radio is off -- a miner prints its
        -- whole ascent -- so the outbox fills past the high-water mark and asks
        -- to be flushed again. That request is what the backoff has to refuse.
        -- The first version of this test printed nothing here, so urgency was
        -- never set, the next turn declined for the ordinary reason, and
        -- deleting the backoff left it green. Caught by mutation.
        for i = 1, 30 do print("still climbing " .. i) end
        assert_eq(c.ship:urgent(), true, "precondition: the outbox is asking again")

        c.advance(1000)
        assert_eq(c.ship:tick(c.now()), false,
            "a radio that just failed must not be retried on the very next turn, "
            .. "even with the outbox asking")
        assert_eq(sends, 1, "and nothing is sent")

        up = true
        c.advance(14000)
        assert_eq(c.ship:tick(c.now()), true,
            "but the interval still fires, so the backlog leaves within 15 s of "
            .. "the radio coming back")
        assert_eq(sends, 2, "and is sent")

        for i = 1, 30 do print("again " .. i) end
        c.advance(1000)
        assert_eq(c.ship:tick(c.now()), true,
            "and once a send has succeeded, urgency works again -- a backoff "
            .. "that never lifts turns every burst back into a 15-second wait")
        assert_eq(sends, 3, "and the burst goes out")
    end)
end

-- The warehouse's transport returns nothing, as did every transport written
-- before this. Treating nil as failure would resend its whole outbox for ever.
suite["a transport that returns nothing still counts as sent"] = function(assert_eq)
    withShip({}, function(c)
        c.ship:setTransport({ send = function(lines) c.sent[#c.sent + 1] = { lines = lines } end })
        print("[WH] State machine ready.")
        assert_eq(c.ship:flush(), true, "a nil return is a send")
        assert_eq(c.ship:_queueDepth(), 0,
            "and the batch must NOT be put back -- only an explicit false means "
            .. "the send failed")
        c.ship:flush()
        assert_eq(#c.sent, 1, "so it is sent exactly once")
    end)
end

return suite
