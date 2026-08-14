-- tick.lua — Task 1 Step 1: the witness turtle.
--
-- Appends a line every 5s to tick.log. If the chunk it sits in stops being
-- loaded, this program stops running and the log simply stops growing — the
-- gap between the last line before the stall and the first line after tells us
-- exactly how long chunk loading survived.
--
-- Run this turtle ~5 blocks from the placed chunky turtle, then read the log
-- back with tickreport.lua. Needs no fuel and never moves.

local INTERVAL = 5
local PATH     = "tick.log"

local n = 0

-- Resume the count across reboots so a server restart mid-test does not look
-- like a fresh run.
if fs.exists(PATH) then
    for line in io.lines(PATH) do
        local c = line:match("^(%d+)")
        if c then n = tonumber(c) end
    end
end

print("[TICK] logging every " .. INTERVAL .. "s to " .. PATH)
print("[TICK] resuming at tick " .. n)
print("[TICK] leave this running and fly away.")

while true do
    n = n + 1
    local f = fs.open(PATH, "a")
    f.writeLine(n .. " " .. tostring(os.epoch("utc")))
    f.close()
    if n % 12 == 0 then print("[TICK] " .. n) end
    sleep(INTERVAL)
end
