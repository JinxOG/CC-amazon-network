-- Assertion helpers handed to every test as `t`.
local H = {}

local function show(v) return type(v) == "string" and string.format("%q", v) or tostring(v) end

function H.eq(actual, expected, msg)
  if actual ~= expected then
    error((msg or "values differ") .. ": expected " .. show(expected) .. ", got " .. show(actual), 2)
  end
end

function H.ok(v, msg)
  if not v then error(msg or "expected a true value", 2) end
end

function H.near(a, b, tol, msg)
  if math.abs(a - b) > tol then
    error((msg or "not near") .. ": " .. tostring(a) .. " vs " .. tostring(b) .. " (tol " .. tostring(tol) .. ")", 2)
  end
end

function H.raises(fn, pattern)
  local ok, err = pcall(fn)
  if ok then error("expected an error, but none was raised", 2) end
  if pattern and not tostring(err):find(pattern) then
    error("error did not match " .. show(pattern) .. ": " .. tostring(err), 2)
  end
end

local tmp_n = 0
-- A fresh empty directory for one test (under the system temp folder).
function H.tmpdir()
  tmp_n = tmp_n + 1
  local base = (os.getenv("TEMP") or "/tmp"):gsub("\\", "/")
  local dir = string.format("%s/sbx_%d_%d_%d", base, os.time(), math.floor(os.clock() * 1000000), tmp_n)
  if package.config:sub(1, 1) == "\\" then
    os.execute('mkdir "' .. dir:gsub("/", "\\") .. '" >nul 2>nul')
  else
    os.execute('mkdir -p "' .. dir .. '"')
  end
  return dir
end

function H.write(path, text)
  local f = assert(io.open(path, "wb")); f:write(text); f:close()
end

function H.read(path)
  local f = io.open(path, "rb"); if not f then return nil end
  local s = f:read("*a"); f:close(); return s
end

return H
