-- Safety tests that never go away (spec section 10).
local function slurp(path)
  local f = assert(io.open(path, "rb"), "cannot open " .. path)
  local s = f:read("*a"); f:close(); return s
end

return {
  ["gitignore lists sandbox/worlds and sandbox/run"] = function(t)
    local lines = {}
    for l in slurp(".gitignore"):gmatch("[^\r\n]+") do lines[l] = true end
    t.ok(lines["sandbox/worlds/"], "sandbox/worlds/ missing from .gitignore")
    t.ok(lines["sandbox/run/"], "sandbox/run/ missing from .gitignore")
  end,

  ["nothing under sandbox ships to the fleet"] = function(t)
    for _, f in ipairs({ "install.lua", "updater.lua" }) do
      t.ok(not slurp(f):find("sandbox/", 1, true), f .. " mentions sandbox/")
    end
  end,

  ["no file under sandbox names a forbidden host"] = function(t)
    local hits = {}
    local p = io.popen("find sandbox -type f -not -path 'sandbox/tests/*'")
    for path in p:lines() do
      local s = slurp(path)
      for _, host in ipairs({ "192.168.86.35", "100.103.179.74" }) do
        if s:find(host, 1, true) then hits[#hits + 1] = path .. " names " .. host end
      end
    end
    p:close()
    t.eq(#hits, 0, table.concat(hits, "; "))
  end,
}
