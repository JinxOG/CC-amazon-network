-- The virtual clock, in whole milliseconds. It only moves forward.
local Clock = {}
Clock.__index = Clock

Clock.DEFAULT_START_MS = 1790000000000 -- a fixed instant; scenarios may override

function Clock.new(start_ms) return setmetatable({ ms = start_ms or Clock.DEFAULT_START_MS }, Clock) end
function Clock:now() return self.ms end
-- Only for restoring a snapshot: time may move backwards then.
function Clock:reset(ms) self.ms = ms end

function Clock:set(ms)
  if ms < self.ms then error("clock cannot go backwards: " .. ms .. " < " .. self.ms, 2) end
  self.ms = ms
end

return Clock
