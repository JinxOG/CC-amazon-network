-- Binary min-heap of (time, item). Ties go to the earlier push, so order is deterministic.
-- Written for speed: this is the scheduler's inner loop (hundreds of thousands of pops per run), so the
-- comparisons are inlined and items move into a "hole" instead of being swapped.
local Heap = {}
Heap.__index = Heap

function Heap.new() return setmetatable({ n = 0, seq = 0, t = {}, s = {}, v = {} }, Heap) end

function Heap:push(t_ms, item)
  local n = self.n + 1
  local seq = self.seq + 1
  self.n, self.seq = n, seq
  local ts, ss, vs = self.t, self.s, self.v
  local i = n
  while i > 1 do
    local p = (i - i % 2) / 2
    local pt = ts[p]
    if t_ms < pt or (t_ms == pt and seq < ss[p]) then
      ts[i], ss[i], vs[i] = pt, ss[p], vs[p]
      i = p
    else
      break
    end
  end
  ts[i], ss[i], vs[i] = t_ms, seq, item
end

function Heap:peek_time() return self.t[1] end

function Heap:pop()
  local n = self.n
  if n == 0 then return nil end
  local ts, ss, vs = self.t, self.s, self.v
  local top_t, top_v = ts[1], vs[1]
  local last_t, last_s, last_v = ts[n], ss[n], vs[n]
  ts[n], ss[n], vs[n] = nil, nil, nil
  n = n - 1
  self.n = n
  if n > 0 then
    local i = 1
    while true do
      local c = i * 2
      if c > n then break end
      local ct, cs = ts[c], ss[c]
      local c2 = c + 1
      if c2 <= n then
        local t2 = ts[c2]
        if t2 < ct or (t2 == ct and ss[c2] < cs) then c, ct, cs = c2, t2, ss[c2] end
      end
      if ct < last_t or (ct == last_t and cs < last_s) then
        ts[i], ss[i], vs[i] = ct, cs, vs[c]
        i = c
      else
        break
      end
    end
    ts[i], ss[i], vs[i] = last_t, last_s, last_v
  end
  return top_t, top_v
end

return Heap
