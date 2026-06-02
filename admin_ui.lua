-- admin_ui.lua
-- Live dashboard for the CC autonomous network.
-- Runs on a dedicated computer connected to a DirectGPU monitor + ender modem.

local proto = require("protocol")

-- ─── State ───────────────────────────────────────────────────────────────────

local state = {
    turtles  = {},
    jobs     = {},
    logs     = {},
    modem    = nil,
    gpu      = nil,
    display  = nil,
    lastPoll = 0,
    W        = 1968,   -- updated after display creation
    H        = 648,
}

local MAX_LOGS  = 60
local PAD       = 10
local TITLE_H   = 18    -- height of the top title strip
local FONT      = "minecraft:font/default.ttf"

-- Layout panels — recalculated after we know W, H
local TURTLE_PANEL, JOB_PANEL, LOG_PANEL

local function recalcLayout()
    local W, H  = state.W, state.H
    local top   = TITLE_H + PAD          -- content starts below title strip
    local topH  = math.floor(H * 0.55)  -- top panels end here
    local halfW = math.floor(W * 0.5)
    TURTLE_PANEL = { x=PAD,       y=top,       w=halfW-PAD*2,       h=topH-top-PAD   }
    JOB_PANEL    = { x=halfW+PAD, y=top,       w=W-halfW-PAD*2,     h=topH-top-PAD   }
    LOG_PANEL    = { x=PAD,       y=topH+PAD,  w=W-PAD*2,           h=H-topH-PAD*2   }
end

-- ─── Colour palette ──────────────────────────────────────────────────────────

local C = {
    BG       = { 8,   10,  20  },
    PANEL_BG = { 20,  25,  45  },
    BORDER   = { 70,  90,  140 },   -- brighter so panels visible when empty
    HDR_BG   = { 35,  50,  95  },   -- more contrast against BG
    WHITE    = { 240, 240, 240 },
    DIM      = { 130, 130, 150 },
    GREEN    = {  55, 195,  80 },
    YELLOW   = { 220, 185,  45 },
    RED      = { 215,  55,  55 },
    BLUE     = {  75, 155, 225 },
    CYAN     = {  55, 195, 195 },
    ORANGE   = { 215, 125,  45 },
    INFO     = {  75, 155, 225 },
    WARN     = { 220, 185,  45 },
    ERR      = { 215,  55,  55 },
}

-- ─── GPU helpers ─────────────────────────────────────────────────────────────

local function fill(x, y, w, h, col)
    if w <= 0 or h <= 0 then return end
    state.gpu.fillRect(state.display, x, y, w, h, col[1], col[2], col[3])
end

local function txt(str, x, y, col, size, bold)
    state.gpu.drawText(state.display, str, x, y,
        col[1], col[2], col[3],
        FONT, size or 13, bold and "bold" or "regular")
end

local function hline(x1, x2, y, col)
    state.gpu.drawLine(state.display, x1, y, x2, y, col[1], col[2], col[3])
end

local function flush()
    state.gpu.updateDisplay(state.display)
end

local function lh(size) return math.floor((size or 13) * 1.45) end

-- ─── Panel chrome ────────────────────────────────────────────────────────────

local function panel(p, title)
    fill(p.x, p.y, p.w, p.h, C.PANEL_BG)
    -- border lines
    hline(p.x, p.x+p.w, p.y,       C.BORDER)
    hline(p.x, p.x+p.w, p.y+p.h-1, C.BORDER)
    state.gpu.drawLine(state.display, p.x,       p.y, p.x,       p.y+p.h, C.BORDER[1], C.BORDER[2], C.BORDER[3])
    state.gpu.drawLine(state.display, p.x+p.w-1, p.y, p.x+p.w-1, p.y+p.h, C.BORDER[1], C.BORDER[2], C.BORDER[3])
    -- header
    local hh = 26
    fill(p.x+1, p.y+1, p.w-2, hh, C.HDR_BG)
    txt(title, p.x+8, p.y+6, C.WHITE, 13, true)
    return p.y + hh + 8
end

-- ─── Status colours ──────────────────────────────────────────────────────────

local function tCol(status, online)
    if not online                                         then return C.RED    end
    if status == "IDLE"                                   then return C.GREEN  end
    if status == "TRAVELLING" or status == "LOADING"
       or status == "WORKING"                             then return C.YELLOW end
    if status == "RETURNING"                              then return C.BLUE   end
    if status == "ERROR"                                  then return C.RED    end
    return C.DIM
end

local function jCol(status)
    if status == "COMPLETE"    then return C.GREEN  end
    if status == "IN_PROGRESS" then return C.CYAN   end
    if status == "ASSIGNED"    then return C.YELLOW end
    if status == "PENDING"     then return C.ORANGE end
    if status == "FAILED"      then return C.RED    end
    return C.DIM
end

-- ─── Render sections ─────────────────────────────────────────────────────────

local FS = 12   -- content font size

local function renderTurtles()
    local p  = TURTLE_PANEL
    local cy = panel(p, "TURTLES")
    local lh_ = lh(FS)

    local list = {}
    for _, t in pairs(state.turtles) do table.insert(list, t) end
    table.sort(list, function(a,b)
        if (a.role or "") ~= (b.role or "") then return (a.role or "") < (b.role or "") end
        return (a.id or "") < (b.id or "")
    end)

    if #list == 0 then
        txt("No turtles registered yet", p.x+8, cy, C.DIM, FS)
        return
    end

    for _, t in ipairs(list) do
        if cy + lh_ > p.y + p.h - 6 then break end

        local sc     = tCol(t.status, t.online)
        local dot    = t.online and ">" or "x"   -- ASCII status indicator
        local status = t.online and (t.status or "?") or "OFFLINE"
        local role   = t.role or "?"

        -- dot
        txt(dot, p.x+8, cy, sc, FS, true)
        -- id [role]
        txt(string.format("%-12s [%-8s]", t.id or "?", role), p.x+24, cy, C.WHITE, FS)
        -- status
        txt(status, p.x+230, cy, sc, FS)

        -- fuel bar
        local fuel = t.fuel or 0
        local fmax = math.max(t.fuelMax or 100000, 1)
        local pct  = math.min(1, fuel / fmax)
        local bx   = p.x + 330
        local bw   = math.max(60, p.w - 330 - 55 - 8)
        local bh   = 9
        local by   = cy + 3
        fill(bx, by, bw, bh, C.BORDER)
        local fc = pct > 0.5 and C.GREEN or (pct > 0.2 and C.YELLOW or C.RED)
        fill(bx, by, math.max(1, math.floor(bw * pct)), bh, fc)
        txt(string.format("%dk", math.floor(fuel/1000)), bx+bw+4, cy, C.DIM, FS)

        cy = cy + lh_ + 2
        hline(p.x+4, p.x+p.w-4, cy-2, C.BORDER)
    end
end

local function renderJobs()
    local p  = JOB_PANEL
    local cy = panel(p, "JOBS")
    local lh_ = lh(FS)

    local list = {}
    for _, j in pairs(state.jobs) do table.insert(list, j) end
    table.sort(list, function(a, b)
        local function rank(s)
            if s == "IN_PROGRESS" then return 0
            elseif s == "ASSIGNED" then return 1
            elseif s == "PENDING"  then return 2
            else                        return 3
            end
        end
        local ra, rb = rank(a.status), rank(b.status)
        if ra ~= rb then return ra < rb end
        return (a.id or "") > (b.id or "")
    end)

    if #list == 0 then
        txt("Queue empty", p.x+8, cy, C.DIM, FS)
        return
    end

    for _, j in ipairs(list) do
        if cy + lh_ > p.y + p.h - 6 then break end

        local sc  = jCol(j.status)
        local typ = j.type == "SUPPORT_FOLLOW" and "SUPPORT" or (j.type or "?")

        txt(j.id or "?",   p.x+8,  cy, C.WHITE, FS, true)
        txt(typ,           p.x+100, cy, C.DIM,   FS)
        txt(j.status or "?", p.x+200, cy, sc,    FS)
        if j.assignedTo then
            txt(j.assignedTo, p.x+310, cy, C.DIM, FS)
        end

        cy = cy + lh_ + 2
    end
end

local function renderLog()
    local p   = LOG_PANEL
    local cy  = panel(p, "LOG")
    local lh_ = lh(11)
    local max = math.floor((p.y + p.h - cy - 4) / lh_)
    local col = p.x + 8

    local start = math.max(1, #state.logs - max + 1)
    for i = start, #state.logs do
        local e = state.logs[i]
        if cy + lh_ > p.y + p.h - 4 then break end
        local lc = e.level == "WARN" and C.WARN or (e.level == "ERROR" and C.ERR or C.INFO)
        txt(string.format("[%5s]", e.level), col,    cy, lc,    11, true)
        txt(e.msg or "",                     col+60, cy, C.DIM, 11)
        cy = cy + lh_
    end
end

local function renderAll()
    local W, H = state.W, state.H
    fill(0, 0, W, H, C.BG)

    -- title strip
    fill(0, 0, W, TITLE_H, C.HDR_BG)
    txt("CC AMAZON NETWORK  -  ADMIN DASHBOARD", 8, 3, C.WHITE, 10, true)
    local age = math.floor((os.epoch("utc") - state.lastPoll) / 1000)
    local ts  = age == 0 and "live" or (age .. "s ago")
    txt("last update: " .. ts, W - 130, 3, C.DIM, 10)

    renderTurtles()
    renderJobs()
    renderLog()
    flush()
end

-- ─── Message handling ────────────────────────────────────────────────────────

local function addLog(level, msg)
    table.insert(state.logs, { level=level, msg=msg })
    if #state.logs > MAX_LOGS then table.remove(state.logs, 1) end
end

local function handleMsg(msg)
    if msg.type == proto.MSG.REGISTER then
        local id = msg.from
        local p  = msg.payload
        state.turtles[id] = {
            id      = id,
            role    = p.role,
            status  = "IDLE",
            fuel    = p.fuel,
            fuelMax = p.fuelMax,
            online  = true,
            jobId   = nil,
        }
        addLog("INFO", "Registered: " .. id .. " [" .. (p.role or "?") .. "]")

    elseif msg.type == proto.MSG.HEARTBEAT then
        local id = msg.from
        local p  = msg.payload
        if not state.turtles[id] then
            state.turtles[id] = { id=id, online=true }
        end
        local t = state.turtles[id]
        t.online  = true
        t.status  = p.status  or t.status
        t.fuel    = p.fuel    or t.fuel
        t.jobId   = p.jobId

    elseif msg.type == proto.MSG.STATUS_UPDATE then
        local id = msg.from
        local p  = msg.payload
        if not state.turtles[id] then state.turtles[id] = { id=id, online=true } end
        local t = state.turtles[id]
        t.status = p.status or t.status
        t.jobId  = p.jobId  or t.jobId
        if p.jobId and state.jobs[p.jobId] then
            state.jobs[p.jobId].status = "IN_PROGRESS"
        end

    elseif msg.type == proto.MSG.JOB_ASSIGN then
        local p = msg.payload
        if not state.jobs[p.jobId] then
            state.jobs[p.jobId] = { id=p.jobId, type=p.jobType }
        end
        local j      = state.jobs[p.jobId]
        j.status     = "ASSIGNED"
        j.assignedTo = msg.to
        j.type       = p.jobType or j.type

    elseif msg.type == proto.MSG.JOB_COMPLETE then
        local jid = msg.payload.jobId
        if state.jobs[jid] then
            state.jobs[jid].status     = "COMPLETE"
            state.jobs[jid].assignedTo = nil
        end
        local t = state.turtles[msg.from]
        if t then t.status = "IDLE"; t.jobId = nil end
        addLog("INFO", "Complete: " .. jid .. " (" .. msg.from .. ")")

    elseif msg.type == proto.MSG.JOB_FAILED then
        local p   = msg.payload
        local jid = p.jobId
        if state.jobs[jid] then
            state.jobs[jid].status = p.recoverable and "PENDING" or "FAILED"
        end
        local t = state.turtles[msg.from]
        if t then t.status = "IDLE"; t.jobId = nil end
        addLog("WARN", "Failed: " .. (jid or "?") .. " - " .. (p.reason or "?"))
    end
end

-- ─── Main ────────────────────────────────────────────────────────────────────

local function main()
    -- GPU
    state.gpu = peripheral.find("directgpu")
    if not state.gpu then error("No DirectGPU peripheral found.") end
    state.display = state.gpu.autoDetectAndCreateDisplay()
    if not state.display then error("Could not create display — is a monitor attached?") end

    -- Detect actual pixel dimensions.
    -- 1) Try DirectGPU API methods (Blitz may or may not expose these)
    local ok, dw = pcall(function() return state.gpu.getDisplayWidth(state.display)  end)
    local ok2,dh = pcall(function() return state.gpu.getDisplayHeight(state.display) end)
    if ok  and type(dw) == "number" and dw > 0 then state.W = dw end
    if ok2 and type(dh) == "number" and dh > 0 then state.H = dh end

    -- 2) Fallback: find the monitor directly attached to THIS computer by checking
    --    each side. peripheral.find("monitor") can grab a different computer's
    --    monitor over a wired network, giving wrong dimensions.
    if state.W == 1968 and state.H == 648 then
        local mon = nil
        for _, side in ipairs({"top","bottom","left","right","front","back"}) do
            if peripheral.getType(side) == "monitor" then
                mon = peripheral.wrap(side)
                print("Found monitor on side: " .. side)
                break
            end
        end
        if mon then
            local cw, ch = mon.getSize()
            print(string.format("Monitor chars: %dx%d", cw, ch))
            -- Blitz DirectGPU: 656x324 px per monitor block.
            -- Default CC Advanced Monitor scale = 8 chars wide x 6 chars tall per block.
            -- So 1 char ≈ 82x54 px.
            state.W = math.max(400, cw * 82)
            state.H = math.max(200, ch * 54)
        else
            -- No directly-attached monitor found — single-block safe default
            state.W = 656
            state.H = 324
            print("No adjacent monitor found — using default 656x324")
        end
    end
    print(string.format("Display: %dx%d px", state.W, state.H))

    recalcLayout()

    -- Modem
    state.modem = peripheral.find("modem")
    if not state.modem then error("No modem found. Attach an ender modem.") end
    state.modem.open(proto.CH_SERVER)
    state.modem.open(proto.CH_BROADCAST)
    state.modem.open(proto.CH_PRIVATE)

    addLog("INFO", string.format("Dashboard online (%dx%d)", state.W, state.H))
    renderAll()

    local redrawTimer = os.startTimer(2)

    while true do
        local event, p1, p2, p3, p4 = os.pullEvent()

        if event == "modem_message" then
            local parsed = type(p4) == "table" and p4 or textutils.unserialise(p4)
            if parsed then
                local valid, msg = proto.decode(parsed)
                if valid then
                    state.lastPoll = os.epoch("utc")
                    pcall(handleMsg, msg)
                    renderAll()
                end
            end

        elseif event == "timer" and p1 == redrawTimer then
            renderAll()
            redrawTimer = os.startTimer(2)
        end
    end
end

-- ─── Run ─────────────────────────────────────────────────────────────────────

local ok, err = pcall(main)
if not ok then
    print("ADMIN UI CRASH: " .. tostring(err))
    if state.gpu and state.display then
        state.gpu.clear(state.display, 10, 10, 18)
        state.gpu.drawText(state.display,
            "CRASH: " .. tostring(err),
            10, 10, 220, 60, 60,
            FONT, 14, "bold")
        state.gpu.updateDisplay(state.display)
    end
    error(err)
end
