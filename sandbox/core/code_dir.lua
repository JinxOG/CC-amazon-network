-- Which fleet code a run installs from.
--   worktree:<path>   the files exactly as they are in that folder
--   rev:<git-rev>     the files of a commit, unpacked into the run folder (HEAD and the work tree are untouched)
local Disk = require("core.disk")

local CodeDir = {}

local function sh_quote(s) return '"' .. s:gsub('"', '\\"') .. '"' end

-- run_dir: where a rev is unpacked (under run_dir/code). repo: the git folder to read revs from.
function CodeDir.prepare(spec, run_dir, repo)
  local kind, value = spec:match("^(%a+):(.+)$")
  if kind == "worktree" then
    local path = value:gsub("\\", "/"):gsub("/+$", "")
    local probe = io.open(path .. "/install.lua", "rb")
    if not probe then error("code dir " .. path .. " has no install.lua", 0) end
    probe:close()
    return path
  elseif kind == "rev" then
    if not value:match("^[%w%^~._/-]+$") then error("bad git revision: " .. value, 0) end
    local dest = run_dir .. "/code"
    Disk.new(dest)
    -- the revision is quoted: ^ means "parent" to git but "escape" to the Windows shell
    local cmd = string.format("git -C %s archive %s | tar -x -C %s", sh_quote(repo or "."), sh_quote(value), sh_quote(dest))
    local ok = os.execute(cmd)
    if ok ~= 0 and ok ~= true then error("git archive failed for " .. value, 0) end
    local probe = io.open(dest .. "/install.lua", "rb")
    if not probe then error("revision " .. value .. " has no install.lua", 0) end
    probe:close()
    return dest
  end
  error("code spec must be worktree:<path> or rev:<git-rev>, got " .. tostring(spec), 0)
end

return CodeDir
