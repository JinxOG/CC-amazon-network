-- tickreport.lua — reads tick.log and reports whether chunk loading held.
--
-- The number that matters is the LARGEST GAP between consecutive ticks. The
-- program logs every 5s, so any gap much beyond that is time the chunk was not
-- loaded. Where that gap falls tells us which assumption failed:
--
--   gap starts within seconds of departure  -> never loaded at all
--   gap starts ~10 min in                   -> chunkLoadValidTime expiry
--   no gap over the whole run               -> loading held
--
-- Run on the witness turtle after returning: tickreport

local PATH = "tick.log"
local INTERVAL = 5

if not fs.exists(PATH) then
    print("[REPORT] no " .. PATH .. " — was tick.lua ever run?")
    return
end

local first, last, prev
local count, biggestGap, gapAt, gapAfter = 0, 0, nil, nil

for line in io.lines(PATH) do
    local n, ts = line:match("^(%d+)%s+(%-?%d+)$")
    if n then
        n, ts = tonumber(n), tonumber(ts)
        count = count + 1
        first = first or { n = n, ts = ts }
        if prev then
            local gap = (ts - prev.ts) / 1000
            if gap > biggestGap then
                biggestGap = gap
                gapAt      = prev
                gapAfter   = { n = n, ts = ts }
            end
        end
        prev = { n = n, ts = ts }
        last = prev
    end
end

if not first then print("[REPORT] log is empty or unparseable") return end

local elapsed = (last.ts - first.ts) / 1000
print(string.format("[REPORT] %d ticks over %.1f min of wall clock",
    count, elapsed / 60))
print(string.format("[REPORT] expected ~%d ticks if never stalled",
    math.floor(elapsed / INTERVAL) + 1))
print(string.format("[REPORT] largest gap: %.1f s", biggestGap))

if biggestGap > INTERVAL * 3 then
    local intoRun = (gapAt.ts - first.ts) / 1000
    print(string.format("[REPORT] STALLED after %.1f min (tick %d -> %d)",
        intoRun / 60, gapAt.n, gapAfter.n))
    print("[REPORT] chunk loading did NOT hold for the whole run.")
else
    print("[REPORT] no stall detected — loading held.")
end
