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

return H
