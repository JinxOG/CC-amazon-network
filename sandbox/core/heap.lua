-- Binary min-heap of (time, item). Ties go to the earlier push, so order is deterministic.
local Heap = {}
Heap.__index = Heap

function Heap.new() return setmetatable({ n = 0, seq = 0, t = {}, s = {}, v = {} }, Heap) end

local function less(h, i, j)
  if h.t[i] ~= h.t[j] then return h.t[i] < h.t[j] end
  return h.s[i] < h.s[j]
end

local function swap(h, i, j)
  h.t[i], h.t[j] = h.t[j], h.t[i]
  h.s[i], h.s[j] = h.s[j], h.s[i]
  h.v[i], h.v[j] = h.v[j], h.v[i]
end

function Heap:push(t_ms, item)
  self.n = self.n + 1; self.seq = self.seq + 1
  local i = self.n
  self.t[i], self.s[i], self.v[i] = t_ms, self.seq, item
  while i > 1 do
    local p = math.floor(i / 2)
    if less(self, i, p) then swap(self, i, p); i = p else break end
  end
end

function Heap:peek_time() return self.t[1] end

function Heap:pop()
  if self.n == 0 then return nil end
  local t, v = self.t[1], self.v[1]
  local n = self.n
  self.t[1], self.s[1], self.v[1] = self.t[n], self.s[n], self.v[n]
  self.t[n], self.s[n], self.v[n] = nil, nil, nil
  self.n = n - 1
  local i = 1
  while true do
    local l, r, m = i * 2, i * 2 + 1, i
    if l <= self.n and less(self, l, m) then m = l end
    if r <= self.n and less(self, r, m) then m = r end
    if m == i then break end
    swap(self, i, m); i = m
  end
  return t, v
end

return Heap
