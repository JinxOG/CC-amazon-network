-- A screen the fleet can draw on without effect. Output through print/write is what is recorded.
local CCEnv = require("cc.env")
local M = {}

function M.install(comp, E)
  local T = {}
  local function noop() end
  for _, n in ipairs({ "clear", "clearLine", "setCursorPos", "setCursorBlink", "setTextColor", "setTextColour",
      "setBackgroundColor", "setBackgroundColour", "scroll" }) do T[n] = noop end
  T.write = function(s) E.write(s) end
  T.getSize = function() return 51, 19 end
  T.getCursorPos = function() return 1, 1 end
  T.isColor = function() return true end
  T.isColour = T.isColor
  E.term = CCEnv.api(comp, "term", T)
end

return M
