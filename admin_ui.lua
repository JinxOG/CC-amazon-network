-- admin_ui.lua
-- Admin dashboard. Right-click monitor to cycle pages.

local proto = require("protocol")

-- ─── Fixed canvas size ────────────────────────────────────────────────────────
-- Deliberately undersized so content always fits in the top-left of any monitor.
-- Change these if you want a larger layout.
local W = 500
local H = 260

-- NEXT button = the second row of the title bar
local BTN = { x=0, y=20, w=W, h=18 }

local PAGES    = { "TURTLES", "JOBS", "LOG", "MAP" }
local MAX_LOGS = 80
local FONT     = "minecraft:font/default.ttf"
local FS       = 12   -- body font size
local FT       = 13   -- title font size

-- ─── State ───────────────────────────────────────────────────────────────────

local state = {
    turtles  = {},
    jobs     = {},
    logs     = {},
    modem    = nil,
    gpu      = nil,
    display  = nil,
    lastPoll = 0,
    page     = 1,
}

-- ─── Colours ─────────────────────────────────────────────────────────────────

local C = {
    BG     = { 8,  10,  20 },
    HDR    = { 30, 45,  90 },
    PANEL  = { 18, 22,  40 },
    BORDER = { 60, 80, 130 },
    WHITE  = {240,240, 240 },
    DIM    = {120,120, 140 },
    GREEN  = { 50,190,  70 },
    YELLOW = {220,185,  45 },
    RED    = {210, 50,  50 },
    BLUE   = { 70,150, 220 },
    CYAN   = { 50,190, 190 },
    ORANGE = {210,120,  40 },
    INFO   = { 70,150, 220 },
    WARN   = {220,185,  45 },
    ERR    = {210, 50,  50 },
}

-- ─── GPU helpers ─────────────────────────────────────────────────────────────

local function fill(x,y,w,h,c)
    if w>0 and h>0 then
        state.gpu.fillRect(state.display,x,y,w,h,c[1],c[2],c[3])
    end
end
local function t(s,x,y,c,sz,bold)
    state.gpu.drawText(state.display,tostring(s),x,y,
        c[1],c[2],c[3],FONT,sz or FS,bold and "bold" or "regular")
end
local function ln(x1,y1,x2,y2,c)
    state.gpu.drawLine(state.display,x1,y1,x2,y2,c[1],c[2],c[3])
end
local function flush() state.gpu.updateDisplay(state.display) end
local LH = math.floor(FS * 1.5)

-- ─── Title bar ───────────────────────────────────────────────────────────────

local TH = 38   -- title height (two rows)

local function drawTitle()
    fill(0, 0, W, TH, C.HDR)

    -- Row 1: app name + current page
    t(string.format("CC AMAZON  |  %s", PAGES[state.page]), 6, 3, C.WHITE, 12, true)

    -- Row 2: clickable NEXT button bar
    fill(BTN.x, BTN.y, BTN.w, BTN.h, {40, 160, 60})
    t(">>>  CLICK HERE TO CHANGE PAGE  >>>", 8, 22, {255, 255, 255}, 11, true)
end

-- ─── Page: Turtles ───────────────────────────────────────────────────────────

local function pgTurtles()
    local y = TH + 8
    -- Header
    fill(4, TH+2, W-8, 20, C.PANEL)
    ln(4,TH+2,W-4,TH+2,C.BORDER)
    t("TURTLES", 8, TH+4, C.WHITE, FT, true)
    y = TH + 26

    local list = {}
    for _,v in pairs(state.turtles) do table.insert(list,v) end
    table.sort(list,function(a,b) return (a.id or"") < (b.id or"") end)

    if #list == 0 then
        t("No turtles registered", 8, y, C.DIM, FS)
        return
    end

    for _,v in ipairs(list) do
        if y + LH > H - 4 then break end
        local sc  = (not v.online) and C.RED
                 or (v.status=="IDLE" and C.GREEN)
                 or (v.status=="RETURNING" and C.BLUE)
                 or (v.status=="ERROR" and C.RED)
                 or C.YELLOW
        local dot = v.online and ">" or "x"
        local st  = v.online and (v.status or "IDLE") or "OFFLINE"
        t(dot,  8,   y, sc, FS, true)
        t(v.id or "?", 22, y, C.WHITE, FS)
        t("[".. (v.role or "?") .."]", 130, y, C.DIM, FS)
        t(st, 240, y, sc, FS)
        -- compact fuel bar
        local pct = math.min(1,(v.fuel or 0)/math.max(v.fuelMax or 1,1))
        local bx,bw,bh = 330,140,8
        fill(bx, y+2, bw, bh, C.BORDER)
        local fc = pct>0.5 and C.GREEN or (pct>0.2 and C.YELLOW or C.RED)
        fill(bx, y+2, math.max(1,math.floor(bw*pct)), bh, fc)
        t(math.floor((v.fuel or 0)/1000).."k", bx+bw+4, y, C.DIM, 10)
        y = y + LH + 2
        ln(4,y-1,W-4,y-1,C.BORDER)
    end
end

-- ─── Page: Jobs ──────────────────────────────────────────────────────────────

local function pgJobs()
    local y = TH + 8
    fill(4,TH+2,W-8,20,C.PANEL)
    ln(4,TH+2,W-4,TH+2,C.BORDER)
    t("JOBS", 8, TH+4, C.WHITE, FT, true)
    y = TH + 26

    local list = {}
    for _,j in pairs(state.jobs) do table.insert(list,j) end
    table.sort(list,function(a,b)
        local function r(s)
            return s=="IN_PROGRESS" and 0 or s=="ASSIGNED" and 1
                or s=="PENDING" and 2 or 3
        end
        local ra,rb = r(a.status),r(b.status)
        return ra~=rb and ra<rb or (a.id or"")>(b.id or"")
    end)

    if #list == 0 then t("Queue empty",8,y,C.DIM,FS); return end

    -- column headers
    t("ID",      8,   y, C.DIM, 10, true)
    t("TYPE",   110,  y, C.DIM, 10, true)
    t("STATUS", 210,  y, C.DIM, 10, true)
    t("TURTLE", 330,  y, C.DIM, 10, true)
    y = y + 16
    ln(4,y,W-4,y,C.BORDER)
    y = y + 4

    for _,j in ipairs(list) do
        if y + LH > H - 4 then break end
        local sc  = j.status=="COMPLETE" and C.GREEN
                 or j.status=="IN_PROGRESS" and C.CYAN
                 or j.status=="ASSIGNED" and C.YELLOW
                 or j.status=="PENDING" and C.ORANGE
                 or j.status=="FAILED" and C.RED or C.DIM
        local typ = j.type=="SUPPORT_FOLLOW" and "SUPPORT" or (j.type or "?")
        t(j.id or "?",  8,   y, C.WHITE, FS, true)
        t(typ,         110,  y, C.DIM,   FS)
        t(j.status or"?", 210, y, sc,    FS)
        if j.assignedTo then t(j.assignedTo, 330, y, C.DIM, FS) end
        y = y + LH + 2
        ln(4,y-1,W-4,y-1,C.BORDER)
    end
end

-- ─── Page: Log ───────────────────────────────────────────────────────────────

local function pgLog()
    local y = TH + 8
    fill(4,TH+2,W-8,20,C.PANEL)
    ln(4,TH+2,W-4,TH+2,C.BORDER)
    t("LOG", 8, TH+4, C.WHITE, FT, true)
    y = TH + 26

    if #state.logs == 0 then
        t("No events yet", 8, y, C.DIM, FS)
        return
    end

    local lh2  = math.floor(FS * 1.35)
    local rows = math.floor((H - y - 4) / lh2)
    local from = math.max(1, #state.logs - rows + 1)
    for i = from, #state.logs do
        if y + lh2 > H - 4 then break end
        local e  = state.logs[i]
        local lc = e.level=="WARN" and C.WARN or e.level=="ERROR" and C.ERR or C.INFO
        t("["..e.level.."]", 8,  y, lc,    10, true)
        t(e.msg or "",       70, y, C.DIM, 10)
        y = y + lh2
    end
end

-- ─── Page: Map ───────────────────────────────────────────────────────────────
-- Top-down view. World X → screen X, World Z → screen Y.
-- Viewport centred on the depot area with enough margin for delivery routes.

local MAP = {
    -- World bounds shown on map
    x1 = 100,    x2 = 280,   -- world X range (180 blocks)
    z1 = -2850,  z2 = -2720, -- world Z range (130 blocks)
    -- Canvas area for the map (inside the page)
    px = 8, py = 46, pw = 440, ph = 195,
}

-- Convert world coords to canvas pixels
local function worldToMap(wx, wz)
    local sx = MAP.px + (wx - MAP.x1) / (MAP.x2 - MAP.x1) * MAP.pw
    local sy = MAP.py + (wz - MAP.z1) / (MAP.z2 - MAP.z1) * MAP.ph
    return math.floor(sx), math.floor(sy)
end

local function pgMap()
    -- Header
    fill(4, TH+2, W-8, 20, C.PANEL)
    t("MAP  (last known positions)", 8, TH+4, C.WHITE, FT, true)

    -- Map background
    fill(MAP.px, MAP.py, MAP.pw, MAP.ph, {12, 16, 30})

    -- Grid lines every 20 blocks
    for wx = MAP.x1, MAP.x2, 20 do
        local sx, _ = worldToMap(wx, MAP.z1)
        local _,  ey = worldToMap(wx, MAP.z2)
        state.gpu.drawLine(state.display, sx, MAP.py, sx, MAP.py+MAP.ph, 25,30,55)
        t(tostring(wx), sx+1, MAP.py+MAP.ph-10, {40,50,80}, 9)
    end
    for wz = MAP.z1, MAP.z2, 20 do
        local _, sy = worldToMap(MAP.x1, wz)
        state.gpu.drawLine(state.display, MAP.px, sy, MAP.px+MAP.pw, sy, 25,30,55)
        t(tostring(wz), MAP.px+2, sy-9, {40,50,80}, 9)
    end

    -- Depot outline (x=143→228, z=-2813→-2782)
    local dx1,dz1 = worldToMap(143, -2813)
    local dx2,dz2 = worldToMap(228, -2782)
    state.gpu.drawLine(state.display, dx1,dz1, dx2,dz1, 60,80,130)
    state.gpu.drawLine(state.display, dx2,dz1, dx2,dz2, 60,80,130)
    state.gpu.drawLine(state.display, dx2,dz2, dx1,dz2, 60,80,130)
    state.gpu.drawLine(state.display, dx1,dz2, dx1,dz1, 60,80,130)
    t("DEPOT", dx1+2, dz1+2, {60,80,130}, 9)

    -- Dispatch hole marker
    local hx,hz = worldToMap(143, -2813)
    fill(hx-2, hz-2, 5, 5, {220,120,30})

    -- Arrivals hole marker
    local ax,az = worldToMap(228, -2782)
    fill(ax-2, az-2, 5, 5, {30,180,220})

    -- Turtle dots
    local tColors = { {55,195,80}, {80,155,225}, {220,185,45}, {215,55,55}, {195,55,195} }
    local ti = 0
    for _, v in pairs(state.turtles) do
        ti = ti + 1
        local col = tColors[(ti-1) % #tColors + 1]
        if v.pos then
            local tx, tz = worldToMap(v.pos.x, v.pos.z)
            -- Dot (5x5)
            fill(tx-3, tz-3, 7, 7, col)
            -- Label above dot
            local label = (v.id or "?") .. " Y" .. tostring(v.pos.y)
            t(label, tx+5, tz-8, col, 9, true)
            -- Age indicator
            local age = math.floor((os.epoch("utc") - (v.posAge or 0)) / 1000)
            t(age.."s", tx+5, tz+1, C.DIM, 9)
        else
            -- No position known yet
            t((v.id or "?") .. " (no pos)", MAP.px+4, MAP.py+14*(ti), C.DIM, 9)
        end
    end

    -- Legend
    local lx = MAP.px + MAP.pw + 4
    t("LEGEND", lx, MAP.py, C.DIM, 9, true)
    fill(lx, MAP.py+12, 5, 5, {220,120,30})
    t("Dispatch", lx+7, MAP.py+11, C.DIM, 9)
    fill(lx, MAP.py+22, 5, 5, {30,180,220})
    t("Arrivals", lx+7, MAP.py+21, C.DIM, 9)
end

-- ─── Render ──────────────────────────────────────────────────────────────────

local function drawNextBtn()
    -- Button is drawn as part of the title bar in drawTitle()
end

local function render()
    fill(0,0,W,H,C.BG)
    drawTitle()
    if     state.page==1 then pgTurtles()
    elseif state.page==2 then pgJobs()
    elseif state.page==3 then pgLog()
    elseif state.page==4 then pgMap()
    end
    drawNextBtn()
    flush()
end

-- ─── Messages ────────────────────────────────────────────────────────────────

local function addLog(lv,msg)
    table.insert(state.logs,{level=lv,msg=msg})
    if #state.logs>MAX_LOGS then table.remove(state.logs,1) end
end

local function onMsg(msg)
    if msg.type==proto.MSG.REGISTER then
        local p=msg.payload; local id=msg.from
        state.turtles[id]={id=id,role=p.role,status="IDLE",
            fuel=p.fuel,fuelMax=p.fuelMax,online=true,
            pos=p.position,posAge=os.epoch("utc")}
        addLog("INFO","Reg: "..id.." [".. (p.role or"?") .."]")

    elseif msg.type==proto.MSG.HEARTBEAT then
        local p=msg.payload; local id=msg.from
        if not state.turtles[id] then state.turtles[id]={id=id,online=true} end
        local v=state.turtles[id]
        v.online=true; v.status=p.status or v.status
        v.fuel=p.fuel or v.fuel; v.jobId=p.jobId
        if p.position then v.pos=p.position; v.posAge=os.epoch("utc") end

    elseif msg.type==proto.MSG.STATUS_UPDATE then
        local p=msg.payload; local id=msg.from
        if not state.turtles[id] then state.turtles[id]={id=id,online=true} end
        local v=state.turtles[id]
        v.status=p.status or v.status; v.jobId=p.jobId or v.jobId
        if p.position then v.pos=p.position; v.posAge=os.epoch("utc") end
        if p.jobId and state.jobs[p.jobId] then
            state.jobs[p.jobId].status="IN_PROGRESS"
        end

    elseif msg.type==proto.MSG.JOB_ASSIGN then
        local p=msg.payload
        state.jobs[p.jobId]=state.jobs[p.jobId] or {id=p.jobId,type=p.jobType}
        local j=state.jobs[p.jobId]
        j.status="ASSIGNED"; j.assignedTo=msg.to; j.type=p.jobType or j.type

    elseif msg.type==proto.MSG.JOB_COMPLETE then
        local jid=msg.payload.jobId
        if state.jobs[jid] then state.jobs[jid].status="COMPLETE"; state.jobs[jid].assignedTo=nil end
        local v=state.turtles[msg.from]; if v then v.status="IDLE"; v.jobId=nil end
        addLog("INFO","Done: "..(jid or"?").." ("..msg.from..")")

    elseif msg.type==proto.MSG.JOB_FAILED then
        local p=msg.payload; local jid=p.jobId
        if state.jobs[jid] then
            state.jobs[jid].status=p.recoverable and "PENDING" or "FAILED"
        end
        local v=state.turtles[msg.from]; if v then v.status="IDLE"; v.jobId=nil end
        addLog("WARN","Fail: "..(jid or"?").." "..(p.reason or"?"))
    end
end

-- ─── Main ────────────────────────────────────────────────────────────────────

local function main()
    state.gpu = peripheral.find("directgpu")
    if not state.gpu then error("No DirectGPU found") end
    state.display = state.gpu.autoDetectAndCreateDisplay()
    if not state.display then error("No display created") end

    state.modem = peripheral.find("modem")
    if not state.modem then error("No modem found") end
    state.modem.open(proto.CH_SERVER)
    state.modem.open(proto.CH_BROADCAST)
    state.modem.open(proto.CH_PRIVATE)

    addLog("INFO","Dashboard online")
    render()

    local timer         = os.startTimer(2)
    local pollTimer     = os.startTimer(0.1)
    local lastPageFlip  = 0   -- debounce: ignore clicks within 0.5s of last flip

    while true do
        local ev,p1,p2,p3,p4 = os.pullEvent()

        -- DirectGPU input polling
        if ev=="timer" and p1==pollTimer then
            local ok, hasEv = pcall(function() return state.gpu.hasEvents(state.display) end)
            if ok and hasEv then
                while true do
                    local ok2, gpuEv = pcall(function() return state.gpu.pollEvent(state.display) end)
                    if not ok2 or not gpuEv then break end
                    -- Extract type and x,y from event
                    local ex, ey, evType
                    if type(gpuEv) == "table" then
                        evType = tostring(gpuEv[1] or gpuEv.type or "")
                        ex = gpuEv.x or gpuEv[2]
                        ey = gpuEv.y or gpuEv[3]
                    end
                    -- Skip hover/move/drag events — only act on press/click
                    local evLow = evType and evType:lower() or ""
                    local isMove = evLow:find("mov") or evLow:find("hover")
                                or evLow:find("drag") or evLow:find("enter")
                                or evLow:find("exit") or evLow == "3"
                    -- Hit-test against NEXT button
                    local now = os.clock()
                    if not isMove and ex and ey
                    and ex >= BTN.x and ex <= BTN.x + BTN.w
                    and ey >= BTN.y and ey <= BTN.y + BTN.h
                    and (now - lastPageFlip) > 0.5 then
                        lastPageFlip = now
                        state.page = (state.page % #PAGES) + 1
                        render()
                        break
                    end
                end
            end
            pollTimer = os.startTimer(0.1)

        elseif ev=="monitor_touch" then
            -- CC fallback: p2,p3 are char-grid x,y — convert roughly to pixels
            local cx = (p2 or 0) * 6
            local cy = (p3 or 0) * 9
            local now = os.clock()
            if cx >= BTN.x and cx <= BTN.x + BTN.w
            and cy >= BTN.y and cy <= BTN.y + BTN.h
            and (now - lastPageFlip) > 0.5 then
                lastPageFlip = now
                state.page = (state.page % #PAGES) + 1
                render()
            end
        elseif ev=="modem_message" then
            local raw = type(p4)=="table" and p4 or textutils.unserialise(p4)
            if raw then
                local ok,msg = proto.decode(raw)
                if ok then
                    state.lastPoll = os.epoch("utc")
                    pcall(onMsg,msg)
                    render()
                end
            end
        elseif ev=="timer" and p1==timer then
            render()
            timer = os.startTimer(2)
        end
    end
end

local ok,err = pcall(main)
if not ok then
    print("CRASH: "..tostring(err))
    if state.gpu and state.display then
        state.gpu.clear(state.display,10,10,18)
        state.gpu.drawText(state.display,"CRASH: "..tostring(err),
            6,6,210,50,50,FONT,12,"bold")
        state.gpu.updateDisplay(state.display)
    end
    error(err)
end
