-- The Advanced Peripherals geo scanner: a block the miner places under itself, wraps as a peripheral,
-- scans with, and digs up again. scan(radius) lists every non-air block within the cube, with
-- coordinates relative to the scanner.
local CCEnv = require("cc.env")
local TIMINGS = require("timings")
local Blocks = require("periph.blocks")

local M = {}

M.MAX_RADIUS = 16
local ORE_TAGS = { ["forge:ores"] = true, ["c:ores"] = true }

Blocks.register("advancedperipherals:geo_scanner", function(comp, bx, by, bz)
  local methods = {}
  function methods.scan(radius)
    if type(radius) ~= "number" then error("bad argument #1 (number expected)", 2) end
    if radius > M.MAX_RADIUS then error("Radius is bigger than the maximum", 2) end
    local world = comp.sched.world
    return CCEnv.main_thread_call(comp, TIMINGS.scan_ms * (comp.sched.action_scale or 1), function()
      local out, n = {}, 0
      for x = -radius, radius do
        for y = -radius, radius do
          for z = -radius, radius do
            local name = world:get(bx + x, by + y, bz + z)
            if name and not (x == 0 and y == 0 and z == 0) then
              n = n + 1
              out[n] = { name = name, tags = name:find("ore", 1, true) and ORE_TAGS or {}, x = x, y = y, z = z }
            end
          end
        end
      end
      return out
    end)
  end
  function methods.getOperationCooldown() return 0 end
  return { type = "geoScanner", methods = methods }
end)

return M
