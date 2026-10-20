-- parallel: runs functions as coroutines; every event is offered to every coroutine,
-- each applying its own filter (the mechanism behind the doubled first order, 1.9.108).
local CCEnv = require("cc.env")

local M = {}

function M.install(comp, E)
  local P = {}

  local function run(fns, stop_on_first)
    local n = #fns
    local cos, filters, alive = {}, {}, n
    for i, fn in ipairs(fns) do
      if type(fn) ~= "function" then error("bad argument #" .. i .. " (function expected, got " .. type(fn) .. ")", 3) end
      cos[i] = comp:new_co(fn)
    end
    local ev = {}
    local first = true
    while true do
      for i = 1, n do
        local co = cos[i]
        if co then
          local ev_name = ev[1]
          if first or filters[i] == nil or filters[i] == ev_name or ev_name == "terminate" then
            local r = { coroutine.resume(co, (table.unpack or unpack)(ev, 1, ev.n or #ev)) }
            if not r[1] then error(r[2], 0) end
            if coroutine.status(co) == "dead" then
              cos[i] = false; alive = alive - 1
              if stop_on_first or alive == 0 then return i end
            else
              filters[i] = r[2]
            end
          end
        end
      end
      first = false
      -- pull the next event unfiltered: the parallel manager itself discards nothing
      ev = table.pack(coroutine.yield())
    end
  end

  function P.waitForAny(...) return run({ ... }, true) end
  function P.waitForAll(...) return run({ ... }, false) end

  E.parallel = CCEnv.api(comp, "parallel", P)
end

return M
