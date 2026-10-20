package.path = "sandbox/?.lua;" .. package.path
local Clock = require("core.clock")
local Rng = require("core.rng")
local Scheduler = require("core.scheduler")
local Computer = require("core.computer")
local H = dofile("sandbox/tests/helpers.lua")

-- Boots a CC environment running `startup`; `quota` sets the disk size.
local function rig(startup, quota, files)
  local dir = H.tmpdir()
  H.write(dir .. "/startup.lua", startup)
  for name, text in pairs(files or {}) do H.write(dir .. "/" .. name, text) end
  local sched = Scheduler.new{ clock = Clock.new(0), rng = Rng.new(5) }
  local comp = Computer.new{ id = 3, kind = "computer", disk = dir, sched = sched }
  comp.quota = quota
  sched:add(comp)
  comp:boot()
  sched:run{ until_ms = 1000 }
  return comp, dir
end

local function out(comp) local o = {} for i, l in ipairs(comp.output) do o[i] = l.text end return table.concat(o, "|") end

return {
  ["fs cannot escape the computer's disk"] = function(t)
    local comp, dir = rig([[
      local h = fs.open("../../escape.txt", "w"); h.write("x"); h.close()
      print(fs.exists("escape.txt"), fs.exists("../../escape.txt"), fs.combine("a/..", "../b"))
    ]])
    t.eq(out(comp), "true\ttrue\tb")
    t.ok(H.read(dir .. "/escape.txt"), "clamped file should land inside the disk")
  end,

  ["writes past the quota fail and leave the old file intact"] = function(t)
    local comp, dir = rig([[
      local h = fs.open("big.txt", "w"); h.write("old"); h.close()
      local h2 = fs.open("big.txt", "w")
      local ok, err = pcall(function() h2.write(string.rep("x", 2000)); h2.close() end)
      print(ok, tostring(err):find("Out of space") ~= nil)
    ]], 1000)
    t.eq(out(comp), "false\ttrue")
    t.eq(H.read(dir .. "/big.txt"), "old")
  end,

  ["getFreeSpace reflects quota minus usage"] = function(t)
    local comp = rig([[
      local before = fs.getFreeSpace("")
      local h = fs.open("f.txt", "w"); h.write(string.rep("a", 40)); h.close()
      print(before, fs.getFreeSpace(""))
    ]], 10000, {})
    local before, after = out(comp):match("(%d+)\t(%d+)")
    t.eq(tonumber(before) - tonumber(after), 40)
  end,

  ["fs handles read lines and everything"] = function(t)
    local comp = rig([[
      local h = fs.open("t.txt", "r")
      print(h.readLine(), h.readLine(), h.readAll(), h.readLine())
      h.close()
      print(fs.open("missing.txt", "r"))
      local a = fs.open("log.txt", "a"); a.writeLine("one"); a.close()
      local b = fs.open("log.txt", "a"); b.writeLine("two"); b.close()
      print(fs.open("log.txt", "r").readAll())
      print(table.concat(fs.list(""), ","))
    ]], nil, { ["t.txt"] = "first\r\nsecond\nrest" })
    t.eq(out(comp), "first\tsecond\trest\tnil|nil\t/missing.txt: No such file|one\ntwo\n|log.txt,startup.lua,t.txt")
  end,

  ["fs move copy delete"] = function(t)
    local comp = rig([[
      local h = fs.open("d/a.txt", "w"); h.write("A"); h.close()
      fs.copy("d/a.txt", "d/b.txt"); fs.move("d/a.txt", "e/c.txt")
      print(fs.exists("d/a.txt"), fs.exists("d/b.txt"), fs.exists("e/c.txt"), fs.isDir("d"), fs.getSize("e/c.txt"))
      fs.delete("d"); print(fs.exists("d"), fs.exists("d/b.txt"))
    ]])
    t.eq(out(comp), "false\ttrue\ttrue\ttrue\t1|false\tfalse")
  end,

  ["serialise round-trips nested tables"] = function(t)
    local comp = rig([[
      local v = { 1, 2, "three", name = "x", nested = { a = true, b = { 4, 5 } }, ["odd key"] = 7 }
      local back = textutils.unserialise(textutils.serialise(v))
      print(back[3], back.name, back.nested.a, back.nested.b[2], back["odd key"], #back)
    ]])
    t.eq(out(comp), "three\tx\ttrue\t5\t7\t3")
  end,

  ["serialise matches the format CC writes"] = function(t)
    local comp = rig([[ print(textutils.serialise({ "a", "b", sector = { cz = -176 }, ["mc:ore"] = 10 })) ]])
    local text = comp.output[1].text
    -- array items first, then keys; identifier keys bare, others bracketed with spaces
    t.ok(text:find('^{\n  "a",\n  "b",\n'), text)
    t.ok(text:find('  sector = {\n    cz = %-176,\n  },\n'), text)
    t.ok(text:find('  %[ "mc:ore" %] = 10,\n'), text)
    t.ok(text:find('\n}$'), text)
    local comp2 = rig([[ print(textutils.serialise({})) ]])
    t.eq(comp2.output[1].text, "{}")
  end,

  ["serialise refuses functions and recursion"] = function(t)
    local comp = rig([[
      print(pcall(textutils.serialise, { f = print }))
      local r = {}; r.self = r; print(pcall(textutils.serialise, r))
    ]])
    t.ok(out(comp):find("Cannot serialize type function"), out(comp))
    t.ok(out(comp):find("recursive"), out(comp))
  end,

  ["serialiseJSON writes integers without .0"] = function(t)
    local comp = rig([[
      print(textutils.serialiseJSON({ n = 3, big = 1791166211173, f = 2.5, s = "a\"b", list = { 1, 2 }, e = {} }))
    ]])
    local text = comp.output[1].text
    t.ok(text:find('"n":3[,}]'), text)
    t.ok(text:find('"big":1791166211173'), text)
    t.ok(text:find('"f":2.5'), text)
    t.ok(text:find('"s":"a\\"b"', 1, true), text)
    t.ok(text:find('"list":[1,2]', 1, true), text)
    t.ok(text:find('"e":[]', 1, true), text)
  end,

  ["unserialiseJSON handles nested arrays and null"] = function(t)
    local comp = rig([[
      local v = textutils.unserialiseJSON([=[{"a":[1,[2,3],{"b":null}],"s":"x\u00e9\n","t":true,"n":-1.5e2}]=])
      print(#v.a, v.a[2][2], v.a[3].b, #v.s, v.t, v.n)
      print(textutils.unserialiseJSON("{bad"))
    ]])
    t.eq(#comp.output, 2, out(comp))
    local l1, l2 = comp.output[1].text, comp.output[2].text
    t.eq(l1, "3\t3\tnil\t4\ttrue\t-150")
    t.ok(l2:find("^nil\t"), l2)
  end,

  ["shell.run runs a program from the disk and require loads modules"] = function(t)
    local comp = rig([[
      local m = require("mod")
      print(m.value, require("mod") == m)
      print(shell.run("prog", "x", "y"))
      print(shell.run("nothere"))
    ]], nil, { ["mod.lua"] = "return { value = 42 }", ["prog.lua"] = "print(...)" })
    t.eq(out(comp), "42\ttrue|x\ty|true|No such program|false")
  end,
}
