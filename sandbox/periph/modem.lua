-- The wireless modem peripheral. Every modem here behaves as the advanced wireless modem the fleet uses:
-- unlimited range, the distance between the two computers is reported with each message.
local M = {}

local MAX_CHANNELS = 128

local function check_channel(n, who)
  if type(n) ~= "number" or n ~= math.floor(n) or n < 0 or n > 65535 then
    error("Expected number in range 0-65535", 3)
  end
  return n
end

-- Attaches a modem to `comp` on `side`.
function M.place(comp, side)
  local open, count = {}, 0
  local methods = {}
  function methods.open(ch)
    check_channel(ch)
    if open[ch] then return end
    if count >= MAX_CHANNELS then error("Too many open channels", 2) end
    open[ch] = true; count = count + 1
  end
  function methods.close(ch) check_channel(ch); if open[ch] then open[ch] = nil; count = count - 1 end end
  function methods.isOpen(ch) check_channel(ch); return open[ch] == true end
  function methods.closeAll() open, count = {}, 0 end
  function methods.isWireless() return true end
  function methods.transmit(ch, reply, msg)
    check_channel(ch)
    check_channel(reply)
    local radio = comp.sched.radio
    if not radio then error("sandbox: no radio in this run (computer " .. comp.id .. ")", 2) end
    radio:transmit(comp, side, ch, reply, msg)
  end
  comp:attach(side, "modem", methods, function() methods.closeAll() end)
  comp.peripherals[side].is_open = function(ch) return open[ch] == true end
  comp.peripherals[side].channels = function()
    local out = {}
    for ch in pairs(open) do out[#out + 1] = ch end
    table.sort(out)
    return out
  end
end

local MODEM_ITEMS = {
  ["computercraft:wireless_modem_advanced"] = true,
  ["computercraft:wireless_modem_normal"] = true,
}

-- A turtle has a modem on each side that carries a modem upgrade.
function M.track_equipment(comp)
  local function sync(c)
    local st = c.tstate
    if not st then return end
    for _, side in ipairs({ "left", "right" }) do
      local has = MODEM_ITEMS[st.equipped[side] or ""] == true
      local there = c.peripherals[side] ~= nil
      if has and not there then M.place(c, side)
      elseif not has and there and c.peripherals[side].type == "modem" then c:detach(side) end
    end
  end
  comp.on_equipment_changed = sync
  sync(comp)
  return sync
end

return M
