-- T2 mechanics probe (sandbox code, not a fleet file): checks, in real CC:Tweaked, three things the simulator models but
-- could not verify: digging with a full inventory, falling blocks, and liquids. The controller (probe_mechanics.py) sets the
-- scene for each step, writes go_<step> into this computer's folder when ready, and reads mech.json and the world afterwards.
local out = {}

local function save()
  local f = fs.open("mech.json", "w")
  f.write(textutils.serialiseJSON(out))
  f.close()
end

local function wait_for(step)
  while not fs.exists("go_" .. step) do sleep(0.5) end
end

local function pack(...) return { n = select("#", ...), ... } end

-- A: the inventory is full of cobblestone, the block in front is stone
wait_for("A")
local r = pack(turtle.dig())
out.A_dig = { ok = r[1], err = r[2] }
local slots_full = 0
for i = 1, 16 do if turtle.getItemCount(i) == 64 then slots_full = slots_full + 1 end end
out.A_full_slots_after = slots_full
save()
wait_for("A2")
-- drop one stack into the cell in front (nothing there: it lies on the ground), then pick it up again
turtle.select(1)
local d = pack(turtle.drop(10))
out.A_drop_front = { ok = d[1], err = d[2] }
save()
sleep(1)
local s1 = pack(turtle.suck(4))
out.A_suck_front = { ok = s1[1], err = s1[2], count_slot1 = turtle.getItemCount(1) }
save()

-- B: stone in front with gravel stacked on top of it
wait_for("B")
turtle.select(1)
local g = pack(turtle.dig())
out.B_dig = { ok = g[1], err = g[2] }
save()
sleep(6)
local ok, info = turtle.inspect()
out.B_front_after = ok and info.name or tostring(info)
local oku, infou = turtle.inspectUp()
out.B_above_after = oku and infou.name or tostring(infou)
save()

-- C: a water source block in front
wait_for("C")
local det = turtle.detect()
local ins, iinfo = turtle.inspect()
out.C_detect = det
out.C_inspect = ins and iinfo.name or tostring(iinfo)
local dw = pack(turtle.dig())
out.C_dig = { ok = dw[1], err = dw[2] }
local mv = pack(turtle.forward())
out.C_forward = { ok = mv[1], err = mv[2] }
save()

out.done = os.epoch("utc")
save()
