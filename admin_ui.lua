-- admin_ui.lua
-- Live dashboard for the CC autonomous network.
-- Runs on a dedicated computer connected to a DirectGPU monitor + ender modem.
-- Tap the monitor to cycle between pages: Turtles → Jobs → Log

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
    W        = 656,
    H        = 324,
    page     = 1,    -- 1=Turtles  2=Jobs  3=Log
}

local PAGES     = { "TURTLES", "JOBS", "LOG" }
local MAX_LOGS  = 100
local PAD       = 10
local TITLE_H   = 20
local FONT      = "minecraft:font/default.ttf"

-- ─── Colour palette ──────────────────────────────────────────────────────────

local C = {
    BG       = { 8,   10,  20  },
    PANEL_BG = { 20,  25,  45  },
    BORDER   = { 70,  90,  140 },
    HDR_BG   = { 35,  50,  95  },
    BTN_BG   = { 55,  75,  130 },
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
    state.gpu.drawText(state.display, tostring(str), x, y,
        col[1], col[2], col[3],
        FONT, size or 13, bold and "bold" or "regular")
end

local function hline(x1, x2, y, col)
    state.gpu.drawLine(state.display, x1, y, x2, y, col[1], col[2], col[3])
end

local function flush() state.gpu.updateDisplay(state.display) end
local function lh(s)   return math.floor((s or 13) * 1.45)    end

-- ─── Title bar (shared across all pages) ─────────────────────────────────────

local function drawTitle()
    local W = state.W
    fill(0, 0, W, TITLE_H, C.HDR_BG)

    -- Page name
    local pageLabel = PAGES[state.page]
    txt("CC AMAZON  |  " .. pageLabel, 8, 4, C.WHITE, 11, true)

    -- "NEXT >" button on the right
    local btnW, btnH = 70, TITLE_H - 2
    local btnX = W - btnW - 2
    fill(btnX, 1, btnW, btnH, C.BTN_BG)
    txt("NEXT >", btnX + 8, 4, C.WHITE, 11, true)

    -- Page dots  e.g.  * . .
    local dotX = W - btnW - 55
    for i = 1, #PAGES do
        local dot = (i == state.page) and "*" or "."
        local dc  = (i == state.page) and C.WHITE or C.DIM
        txt(dot, dotX + (i-1)*14, 4, dc, 11, true)
    end

    -- Last-update age
    local age = math.floor((os.epoch("utc") - state.lastPoll) / 1000)
    local ts  = (state.lastPoll == 0) and "waiting..." or (age .. "s ago")
    txt(ts, W - btnW - 130, 4, C.DIM, 10)
end

-- ─── Content area ────────────────────────────────────────────────────────────

local function contentArea()
    -- Full-width panel below title bar
    local W, H = state.W, state.H
    local y    = TITLE_H + PAD
    local h    = H - TITLE_H - PAD * 2
    return { x=PAD, y=y, w=W-PAD*2, h=h }
end

local function panelHeader(p, title)
    fill(p.x, p.y, p.w, p.h, C.PANEL_BG)
    hline(p.x, p.x+p.w, p.y,       C.BORDER)
    hline(p.x, p.x+p.w, p.y+p.h-1, C.BORDER)
    state.gpu.drawLine(state.display, p.x,       p.y, p.x,       p.y+p.h, C.BORDER[1], C.BORDER[2], C.BORDER[3])
    state.gpu.drawLine(state.display, p.x+p.w-1, p.y, p.x+p.w-1, p.y+p.h, C.BORDER[1], C.BORDER[2], C.BORDER[3])
    local hh = 24
    fill(p.x+1, p.y+1, p.w-2, hh, C.HDR_BG)
    txt(title, p.x+8, p.y+5, C.WHITE, 13, true)
    return p.y + hh + 8
end

-- ─── Status colours ──────────────────────────────────────────────────────────

local function tCol(status, online)
    if not online                                      then return C.RED    end
    if status == "IDLE"                                then return C.GREEN  end
    if status == "TRAVELLING" or status == "LOADING"
       or status == "WORKING"                          then return C.YELLOW end
    if status == "RETURNING"                           then return C.BLUE   end
    if status == "ERROR"                               then return C.RED    end
    return C.DIM
end

local function jCol(s)
    if s == "COMPLETE"    then return C.GREEN  end
    if s == "IN_PROGRESS" then return C.CYAN   end
    if s == "ASSIGNED"    then return C.YELLOW end
    if s == "PENDING"     then return C.ORANGE end
    if s == "FAILED"      then return C.RED    end
    return C.DIM
end

-- ─── Page renderers ──────────────────────────────────────────────────────────

local FS = 13

local function renderTurtles()
    local p  = contentArea()
    local cy = panelHeader(p, "TURTLES")
    local lh_ = lh(FS)

    local list = {}
    for _, t in pairs(state.turtles) do table.insert(list, t) end
    table.sort(list, function(a,b) return (a.id or "") < (b.id or "") end)

    if #list == 0 then
        txt("No turtles registered yet", p.x+8, cy, C.DIM, FS)
        return
    end

    for _, t in ipairs(list) do
        if cy + lh_ > p.y + p.h - 6 then break end

        local sc     = tCol(t.status, t.online)
        local dot    = t.online and ">" or "x"
        local status = t.online and (t.status or "IDLE") or "OFFLINE"
        local role   = t.role or "?"

        txt(dot, p.x+8, cy, sc, FS, true)
        txt(string.format("%-14s", t.id or "?"), p.x+26, cy, C.WHITE, FS, true)
        txt(string.format("[%-8s]", role), p.x+170, cy, C.DIM, FS)
        txt(status, p.x+290, cy, sc, FS)

        -- Fuel bar
        local fuel = t.fuel or 0
        local fmax = math.max(t.fuelMax or 100000, 1)
        local pct  = math.min(1, fuel / fmax)
        local bx   = p.x + 420
        local bw   = math.max(60, p.w - 420 - 70 - 8)
        local bh   = 10
        local by   = cy + 2
        fill(bx, by, bw, bh, C.BORDER)
        local fc = pct > 0.5 and C.GREEN or (pct > 0.2 and C.YELLOW or C.RED)
        fill(bx, by, math.max(1, math.floor(bw * pct)), bh, fc)
        txt(string.format("%dk", math.floor(fuel/1000)), bx+bw+5, cy, C.DIM, FS)

        -- Active job
        if t.jobId then
            txt("job: " .. t.jobId, p.x+8, cy+lh_-2, C.CYAN, 10)
        end

        local rowH = t.jobId and lh_+14 or lh_+4
        cy = cy + rowH
        hline(p.x+4, p.x+p.w-4, cy-4, C.BORDER)
    end
end

local function renderJobs()
    local p   = contentArea()
    local cy  = panelHeader(p, "JOBS")
    local lh_ = lh(FS)

    local list = {}
    for _, j in pairs(state.jobs) do table.insert(list, j) end
    table.sort(list, function(a, b)
        local function rank(s)
            if s == "IN_PROGRESS" then return 0
            elseif s == "ASSIGNED" then return 1
            elseif s == "PENDING"  then return 2
            else                        return 3 end
        end
        local ra, rb = rank(a.status), rank(b.status)
        if ra ~= rb then return ra < rb end
        return (a.id or "") > (b.id or "")
    end)

    if #list == 0 then
        txt("Queue empty", p.x+8, cy, C.DIM, FS)
        return
    end

    -- Column headers
    txt("ID",         p.x+8,   cy, C.DIM, 10, true)
    txt("TYPE",       p.x+130, cy, C.DIM, 10, true)
    txt("STATUS",     p.x+280, cy, C.DIM, 10, true)
    txt("ASSIGNED TO",p.x+430, cy, C.DIM, 10, true)
    cy = cy + lh(10) + 4
    hline(p.x+4, p.x+p.w-4, cy-2, C.BORDER)

    for _, j in ipairs(list) do
        if cy + lh_ > p.y + p.h - 6 then break end

        local sc  = jCol(j.status)
        local typ = j.type == "SUPPORT_FOLLOW" and "SUPPORT" or (j.type or "?")

        txt(j.id or "?",      p.x+8,   cy, C.WHITE,  FS, true)
        txt(typ,              p.x+130,  cy, C.DIM,    FS)
        txt(j.status or "?",  p.x+280,  cy, sc,       FS)
        if j.assignedTo then
            txt(j.assignedTo, p.x+430,  cy, C.DIM,    FS)
        end

        cy = cy + lh_ + 3
        hline(p.x+4, p.x+p.w-4, cy-1, C.BORDER)
    end
end

local function renderLog()
    local p   = contentArea()
    local cy  = panelHeader(p, "LOG")
    local lh_ = lh(11)
    local max = math.floor((p.y + p.h - cy - 4) / lh_)

    if #state.logs == 0 then
        txt("No events yet — waiting for network traffic", p.x+8, cy, C.DIM, 11)
        return
    end

    local start = math.max(1, #state.logs - max + 1)
    for i = start, #state.logs do
        local e = state.logs[i]
        if cy + lh_ > p.y + p.h - 4 then break end
        local lc = e.level == "WARN" and C.WARN or (e.level == "ERROR" and C.ERR or C.INFO)
        txt(string.format("[%5s]", e.level), p.x+8,    cy, lc,    11, true)
        txt(e.msg or "",                     p.x+68,   cy, C.DIM, 11)
        cy = cy + lh_
    end
end

-- ─── Main render ─────────────────────────────────────────────────────────────

local function renderAll()
    fill(0, 0, state.W, state.H, C.BG)
    drawTitle()
    if     state.page == 1 then renderTurtles()
    elseif state.page == 2 then renderJobs()
    elseif state.page == 3 then renderLog()
    end
    flush()
end

-- ─── Message handling ────────────────────────────────────────────────────────

local function addLog(level, msg)
    table.insert(state.logs, { level=level, msg=msg })
    if #state.logs > MAX_LOGS then table.remove(state.logs, 1) end
end

local function handleMsg(msg)
    if msg.type == proto.MSG.REGISTER then
        local p = msg.payload
        local id = msg.from
        if not state.turtles[id] then state.turtles[id] = { id=id } end
        local t = state.turtles[id]
        t.role    = p.role
        t.status  = "IDLE"
        t.fuel    = p.fuel
        t.fuelMax = p.fuelMax
        t.online  = true
        t.jobId   = nil
        addLog("INFO", "Registered: " .. id .. " [" .. (p.role or "?") .. "]")

    elseif msg.type == proto.MSG.HEARTBEAT then
        local p  = msg.payload
        local id = msg.from
        if not state.turtles[id] then state.turtles[id] = { id=id, online=true } end
        local t = state.turtles[id]
        t.online  = true
        t.status  = p.status or t.status
        t.fuel    = p.fuel   or t.fuel
        t.jobId   = p.jobId

    elseif msg.type == proto.MSG.STATUS_UPDATE then
        local p  = msg.payload
        local id = msg.from
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
        addLog("INFO", "Complete: " .. (jid or "?") .. " (" .. msg.from .. ")")

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

    -- Try DirectGPU dimension API first
    local ok,  dw = pcall(function() return state.gpu.getDisplayWidth(state.display)  end)
    local ok2, dh = pcall(function() return state.gpu.getDisplayHeight(state.display) end)
    if ok  and type(dw) == "number" and dw > 0 then state.W = dw end
    if ok2 and type(dh) == "number" and dh > 0 then state.H = dh end

    -- Fallback: scan sides for a directly-attached monitor
    if state.W == 656 and state.H == 324 then
        for _, side in ipairs({"top","bottom","left","right","front","back"}) do
            if peripheral.getType(side) == "monitor" then
                local mon    = peripheral.wrap(side)
                local cw, ch = mon.getSize()
                state.W = math.max(300, cw * 82)
                state.H = math.max(150, ch * 54)
                print(string.format("Monitor on %s: %dx%d chars → %dx%d px", side, cw, ch, state.W, state.H))
                break
            end
        end
    end
    print(string.format("Display: %dx%d px  (page UI, tap to cycle)", state.W, state.H))

    -- Modem
    state.modem = peripheral.find("modem")
    if not state.modem then error("No modem found. Attach an ender modem.") end
    state.modem.open(proto.CH_SERVER)
    state.modem.open(proto.CH_BROADCAST)
    state.modem.open(proto.CH_PRIVATE)

    addLog("INFO", string.format("Dashboard online — %dx%d px", state.W, state.H))
    renderAll()

    local redrawTimer = os.startTimer(2)

    while true do
        local event, p1, p2, p3, p4 = os.pullEvent()

        if event == "monitor_touch" then
            -- Any tap cycles to next page
            state.page = (state.page % #PAGES) + 1
            renderAll()

        elseif event == "modem_message" then
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
        state.gpu.drawText(state.display, "CRASH: " .. tostring(err),
            10, 10, 220, 60, 60, FONT, 13, "bold")
        state.gpu.updateDisplay(state.display)
    end
    error(err)
end
