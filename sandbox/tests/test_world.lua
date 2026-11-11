package.path = "sandbox/?.lua;" .. package.path
local World = require("world.world")
local Synth = require("world.synth")
local H = dofile("sandbox/tests/helpers.lua")

return {
  ["unset blocks are air"] = function(t)
    local w = World.new_empty()
    t.eq(w:get(5, 70, -3), nil)
    t.eq(w:get(-1000, -64, 1000), nil)
  end,

  ["set then get"] = function(t)
    local w = World.new_empty()
    w:set(-1, 64, -17, "minecraft:stone")
    t.eq(w:get(-1, 64, -17), "minecraft:stone")
    t.eq(w:get(0, 64, -17), nil)
    w:set(-1, 64, -17, nil)
    t.eq(w:get(-1, 64, -17), nil)
  end,

  ["chunk_of floors negatives"] = function(t)
    local w = World.new_empty()
    local cx, cz = w:chunk_of(-1, -17)
    t.eq(cx, -1); t.eq(cz, -2)
    cx, cz = w:chunk_of(15, 16)
    t.eq(cx, 0); t.eq(cz, 1)
  end,

  ["terrain default fills until a block is dug"] = function(t)
    local w = World.new_empty({ terrain = { bottom = -64, stone_top = 60, soil_top = 63 } })
    t.eq(w:get(3, -64, 3), "minecraft:bedrock")
    t.eq(w:get(3, 10, 3), "minecraft:stone")
    t.eq(w:get(3, 63, 3), "minecraft:grass_block")
    t.eq(w:get(3, 64, 3), nil)
    w:set(3, 10, 3, nil)
    t.eq(w:get(3, 10, 3), nil, "dug block should be air")
    t.eq(w:get(3, 11, 3), "minecraft:stone")
  end,

  ["save then open round-trips"] = function(t)
    local dir = H.tmpdir()
    local w = World.new_empty({ terrain = { bottom = -64, stone_top = 60, soil_top = 63 }, dock = { x = 1, y = 64, z = 2 } })
    w:set(-20, 5, 40, "minecraft:diamond_ore")
    w:set(7, 12, 7, nil)
    w:save(dir)
    local back = World.open(dir)
    t.eq(back:get(-20, 5, 40), "minecraft:diamond_ore")
    t.eq(back:get(7, 12, 7), nil)
    t.eq(back:get(7, 13, 7), "minecraft:stone")
    t.eq(back:meta().dock.z, 2)
    t.eq(back:digest(), w:digest())
  end,

  -- final review I2 (2026-11-11): the preset dock file is written as per-bay code's own saver writes it (legacy lists
  -- by side index, no MINER list), so that code reads it BY POSITION, silently, with every turtle on its own cell
  ["synth preset dock file is read by position on per-bay code"] = function(t)
    local saved = { fs = rawget(_G, "fs"), textutils = rawget(_G, "textutils") }
    local text
    _G.textutils = { unserialise = function(s)
      local fn = load("return " .. s, "unserialise", "t", {}); if not fn then return nil end
      local ok, v = pcall(fn); if ok then return v end; return nil end }
    _G.fs = { exists = function() return text ~= nil end,
              open = function(_, m) return { readAll = function() return text end, write = function(s) text = s end, close = function() end } end }
    local ok, err = pcall(function()
      local W = dofile("waypoints.lua")
      local L = Synth.layout(W, { miners = 70, workers = 90, delivery = 10, support = 10, preset_docks = true, miners_on_delivery = 2 })
      for _, spec in ipairs(L) do if spec.role == "server" then text = spec.files["dock_assignments.dat"] end end
      t.ok(text ~= nil, "the server is given a dock file")
      t.ok(not text:find("MINER =", 1, true), "no MINER list")
      local W2 = dofile("waypoints.lua")
      local said = {}
      W2.loadDockAssignments(function(m) said[#said + 1] = m end, function(m) said[#said + 1] = m end)
      t.eq(#said, 0, "read silently by position: " .. tostring(said[1]))
      local n, wrong = 0, ""
      for _, spec in ipairs(L) do
        if spec.kind == "turtle" and spec.pos and not spec.carried then
          local _, d = W2.dockOf("node_" .. spec.id)
          n = n + 1
          if not d or d.x ~= spec.pos.x or d.z ~= spec.pos.z then wrong = wrong .. "node_" .. spec.id .. "; " end
        end
      end
      t.eq(n, 90, "turtles checked")
      t.eq(wrong, "", "turtles whose dock is not the cell they stand on")
    end)
    _G.fs, _G.textutils = saved.fs, saved.textutils
    if not ok then error(err, 0) end
  end,

  ["synth world is identical for the same seed"] = function(t)
    t.eq(Synth.generate(11):digest(), Synth.generate(11):digest())
    t.ok(Synth.generate(11):digest() ~= Synth.generate(12):digest(), "different seeds gave the same world")
  end,

  ["synth world has ore in each mining area"] = function(t)
    local w = Synth.generate(1)
    local m = w:meta()
    t.eq(#m.areas, 3)
    for _, a in ipairs(m.areas) do
      local ores = 0
      for x = a.x1, a.x2 do for z = a.z1, a.z2 do for y = a.ymin, a.ymax do
        local b = w:get(x, y, z)
        if b and b:find("_ore") then ores = ores + 1 end
      end end end
      t.ok(ores > 20, a.name .. " has only " .. ores .. " ore blocks")
    end
    t.eq(#m.gps_hosts, 4)
    t.eq(m.base_loaded[1][1], 110)
  end,
}
