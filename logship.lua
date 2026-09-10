-- logship.lua
-- The fleet log's outbox, for any computer that has a radio.
--
-- WHY THIS IS A MODULE AND NOT A COPY
--
-- Every hard-won property below was paid for by an outage:
--
--   * the batch is retried once after a stall, because a fire-and-forget send
--     into a deaf server loses exactly the lines that describe the outage
--     (W1, 2026-09-09: every gap in the audit was a multiple of five, and a
--     disconnect cycle prints five lines);
--   * one message is capped, because a large payload is what makes the RECEIVER
--     deaf while it deserialises, and that is the fault this whole month was
--     about (2026-08-30: 96 KB of a 190 KB push);
--   * a filling outbox asks to be flushed NOW, because a node in trouble talks
--     more, so the queue overflows exactly when its contents are worth having
--     (node_119 lost 38 lines in one gap, and the next line was a geofence
--     refusal);
--   * lines lost to a full outbox are ANNOUNCED, because an unexplained hole in
--     the audit costs someone an afternoon and an explained one costs nothing;
--   * seq is monotonic per boot and bootId is a comparable wall-clock stamp, so
--     the server ships only what is new and the bridge de-duplicates on
--     (source, bootId, seq). That is what makes the retry above free.
--
-- The warehouse computer forwards no logs at all today, and neither does the
-- admin computer. Both need this behaviour and neither is a turtle. Re-typing
-- five outage-shaped rules into a second file is how one copy quietly loses one
-- of them, so the rules live here once and turtle_base.lua consumes them like
-- everybody else.
--
-- WIRE NAME. The message stays proto.MSG.TURTLE_LOG even when the sender is a
-- computer. The server's handler keys on msg.from and never asks what a source
-- is, so a warehouse batch already flows to the file with no server change --
-- and renaming a wire constant would strand every node mid-rollout for a
-- cosmetic gain.

local logship = {}

-- Sized and paced against a BURST, because that is when the log matters.
-- QUEUE_MAX is what an ordinary burst has to fit in; FLUSH_AT is where the
-- outbox stops waiting for the interval; BATCH_MAX caps ONE message so a
-- backlog drains over consecutive flushes instead of arriving as one lump.
local DEFAULTS = {
    QUEUE_MAX   = 96,
    FLUSH_AT    = 24,
    BATCH_MAX   = 48,
    INTERVAL_MS = 15000,
}
logship.DEFAULTS = DEFAULTS

-- The real print, stashed on a GLOBAL rather than a module local.
--
-- Tests clear package.loaded between cases, which re-runs this file. A module
-- local would be nil again on every reload, so each reload would wrap whatever
-- print it found -- i.e. the previous instance's wrapper -- and twenty tests
-- would leave twenty layers of capture chained together, every one of them
-- still appending to a dead queue. Keyed on _G so the original survives the
-- reload and each capture replaces the last instead of stacking on it.
local RAW_KEY = "__LOGSHIP_RAW_PRINT"

local Ship = {}
Ship.__index = Ship

-- opts:
--   source     string, for diagnostics only -- the sender stamps msg.from
--   send       function(lines, bootId); fire-and-forget, may be set later
--   ready      function() -> boolean; false makes flush a complete no-op
--   capture    replace the global print (default true)
--   queueMax / flushAt / batchMax / intervalMs override DEFAULTS
function logship.new(opts)
    opts = opts or {}
    local self = setmetatable({
        source       = opts.source,
        -- Set for the duration of one print() so a line's level is a real FIELD
        -- rather than something the bridge recovers with a regex. A parsed
        -- level and a known one must not be the same thing, or `grep WARN`
        -- quietly answers for only half the fleet.
        pendingLevel = nil,
        _bootId      = os.epoch("utc"),
        _seq         = 0,
        _queue       = {},
        _retry       = nil,
        _suspect     = false,
        _urgent      = false,
        _dropped     = 0,
        _send        = opts.send,
        _ready       = opts.ready,
        QUEUE_MAX    = opts.queueMax   or DEFAULTS.QUEUE_MAX,
        FLUSH_AT     = opts.flushAt    or DEFAULTS.FLUSH_AT,
        BATCH_MAX    = opts.batchMax   or DEFAULTS.BATCH_MAX,
        INTERVAL_MS  = opts.intervalMs or DEFAULTS.INTERVAL_MS,
    }, Ship)
    self._lastFlush = self._bootId
    if opts.capture ~= false then self:capturePrint() end
    return self
end

-- The transport is not always available when print must already be captured.
-- On a turtle the queue is armed at module load and comms.toServer does not
-- exist for another four hundred lines; on the warehouse both exist at once.
-- Splitting them means the turtle keeps the lines it prints during boot instead
-- of choosing between capturing early and having somewhere to send.
function Ship:setTransport(t)
    self._send  = t.send
    self._ready = t.ready
end

function Ship:capturePrint()
    if _G[RAW_KEY] == nil then _G[RAW_KEY] = print end
    local raw  = _G[RAW_KEY]
    local inst = self
    print = function(...)
        raw(...)
        -- The outbox must never be able to break the thing it is wrapping.
        --
        -- This capture replaces the GLOBAL print, so anything that can throw in
        -- here throws out of every print() on the computer -- including the ones
        -- a crash handler makes on its way down. A logger that takes stdout with
        -- it costs far more than every line it was ever going to ship.
        --
        -- Found on 2026-09-10, when a test released a fake clock while the
        -- capture was still installed: os.epoch went away, add() raised, and the
        -- TEST RUNNER died in the middle of reporting. In CC os.epoch is always
        -- there, so this guards the class rather than that instance.
        --
        -- A failure is counted as a dropped line, so it leaves through the
        -- notice that already exists instead of becoming a silent hole.
        -- Flattened out here rather than inside the pcall because a closure
        -- cannot see its enclosing function's `...`. Safe in this order: raw()
        -- above has already stringified every argument without throwing, so by
        -- the time this runs tostring is proven not to raise on them.
        local parts = {}
        for i = 1, select("#", ...) do parts[i] = tostring((select(i, ...))) end
        local ok = pcall(function()
            inst:add(table.concat(parts, "\t"), inst.pendingLevel)
        end)
        if not ok then inst._dropped = inst._dropped + 1 end
    end
end

-- Queue one line. Public because a node with no console -- or one whose print
-- is already owned by something else -- can feed the outbox directly.
function Ship:add(line, level)
    if #self._queue >= self.QUEUE_MAX then
        table.remove(self._queue, 1)
        self._dropped = self._dropped + 1
    end
    if #self._queue >= self.FLUSH_AT then self._urgent = true end
    self._seq = self._seq + 1
    table.insert(self._queue, {
        ts    = os.epoch("utc"),
        msg   = line,
        seq   = self._seq,
        level = level,
    })
end

-- Something happened that makes the NEXT batch untrustworthy -- a stall, a
-- declared-unreachable server. One retry only: two consecutive stalls mean the
-- node has worse problems than its logging, and an unbounded retry grows a
-- queue on a computer with 1 MB of disk.
function Ship:markSuspect() self._suspect = true end

function Ship:urgent() return self._urgent end

-- Realign the interval with the caller's clock. The control loop that owns the
-- pacing usually starts well after this module was required, and on a fake
-- clock it starts on a different one entirely.
function Ship:resetInterval(now) self._lastFlush = now or os.epoch("utc") end

function Ship:flush()
    if self._ready and not self._ready() then return false end
    -- Typed rather than truthy: an outbox with no transport yet is the normal
    -- state during a turtle's boot, and "no transport" must be a no-op that
    -- KEEPS the queue, never a call into whatever was passed in its place.
    if type(self._send) ~= "function" then return false end
    self._urgent = false

    -- Say so BEFORE taking the batch, so the notice travels with the lines that
    -- survived rather than a flush later. This is what turns an unexplained
    -- hole in the audit into a recorded one. Appended to the BACK deliberately:
    -- moving it to the front would put its sequence number out of order, and
    -- the audit reads a backwards sequence as a reboot.
    if self._dropped > 0 then
        local n = self._dropped
        self._dropped = 0
        print(string.format(
            "[LOG] %d line(s) dropped — the outbox filled faster than it drains", n))
    end

    -- Anything withheld from the previous flush goes back to the FRONT, so the
    -- retry keeps the original order rather than reporting the outage after the
    -- recovery it preceded.
    if self._retry then
        for i = #self._retry, 1, -1 do table.insert(self._queue, 1, self._retry[i]) end
        self._retry = nil
        while #self._queue > self.QUEUE_MAX do table.remove(self._queue, 1) end
    end

    if #self._queue == 0 then return false end

    local batch = {}
    for i = 1, math.min(#self._queue, self.BATCH_MAX) do
        batch[i] = table.remove(self._queue, 1)
    end
    -- The remainder must keep asking, or it waits out the whole interval --
    -- which is the delay the urgent flag exists to remove.
    if #self._queue > 0 then self._urgent = true end
    if self._suspect then
        self._retry   = batch
        self._suspect = false
    end
    -- bootId rides once per BATCH, not per line: it is the same 13 digits for
    -- every entry and this payload crosses the radio every 15 seconds.
    self._send(batch, self._bootId)
    return true
end

-- One call for an event loop: flushes on the interval, or immediately when the
-- outbox has asked. Returns true if a flush was attempted.
function Ship:tick(now)
    now = now or os.epoch("utc")
    if self._urgent or now - self._lastFlush >= self.INTERVAL_MS then
        self:flush()
        self._lastFlush = now
        return true
    end
    return false
end

-- Test seams.
function Ship:_queueDepth() return #self._queue end
function Ship:_bootStamp()  return self._bootId end

return logship
