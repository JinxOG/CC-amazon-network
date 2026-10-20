-- lua sandbox/tools/synth_world.lua <out_dir> [--seed N]
-- Writes the synthetic world to a folder. Run from the repo root (sandbox/sim does).
package.path = "sandbox/?.lua;" .. package.path
local Synth = require("world.synth")

local out, seed = nil, 1
local i = 1
while i <= #arg do
  if arg[i] == "--seed" then seed = tonumber(arg[i + 1]); i = i + 2
  else out = arg[i]; i = i + 1 end
end
if not out then io.stderr:write("usage: synth_world.lua <out_dir> [--seed N]\n"); os.exit(2) end

local world = Synth.generate(seed)
world:save(out)
print("synthetic world (seed " .. seed .. ") written, digest " .. world:digest())
