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

-- Map page: right info panel click zone (cycles selected turtle)
local MAP_BTN = { x=320, y=38, w=175, h=220 }

local PAGES    = { "TURTLES", "JOBS", "LOG", "MAP" }
local MAX_LOGS = 80
local FONT     = "minecraft:font/default.ttf"
local FS       = 12   -- body font size
local FT       = 13   -- title font size

-- ─── State ───────────────────────────────────────────────────────────────────

local state = {
    turtles       = {},
    jobs          = {},
    logs          = {},
    selectedTurtle = nil,   -- ID of currently focused turtle on map page
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

local MAP = {
    -- Canvas area (left portion of the monitor)
    px=6, py=42, pw=308, ph=212,
    -- Viewport half-extents in world-blocks (zoom level — keep these fixed)
    hwx = 190,   -- half-width  in world X
    hwz = 70,    -- half-height in world Z
    -- Default view center (depot midpoint)
    defX = 164, defZ = -2797,
}

-- worldToMap: converts world coords to canvas pixels using the current viewport.
-- Pass x1/x2/z1/z2 from the dynamic viewport computed each frame.
local function worldToMap(wx, wz, x1, x2, z1, z2)
    local sx = MAP.px + (wx-x1)/(x2-x1) * MAP.pw
    local sy = MAP.py + (wz-z1)/(z2-z1) * MAP.ph
    return math.floor(sx), math.floor(sy)
end

-- Sorted turtle list (stable order for cycling)
local function turtleList()
    local list = {}
    for _,v in pairs(state.turtles) do table.insert(list,v) end
    table.sort(list, function(a,b) return (a.id or"") < (b.id or"") end)
    return list
end

local function cycleTurtle()
    local list = turtleList()
    if #list == 0 then state.selectedTurtle = nil; return end
    if not state.selectedTurtle then
        state.selectedTurtle = list[1].id; return
    end
    for i,v in ipairs(list) do
        if v.id == state.selectedTurtle then
            state.selectedTurtle = list[(i % #list)+1].id
            return
        end
    end
    state.selectedTurtle = list[1].id
end

local TCOLS = {{55,195,80},{80,155,225},{220,185,45},{215,55,55},{195,55,195}}

local function turtleCol(idx) return TCOLS[(idx-1) % #TCOLS + 1] end

local function pgMap()
    -- ── Compute dynamic viewport centered on selected turtle ─────────────────
    local selTurtle = state.selectedTurtle and state.turtles[state.selectedTurtle]
    local vcx = MAP.defX
    local vcz = MAP.defZ
    if selTurtle and selTurtle.pos then
        vcx = selTurtle.pos.x
        vcz = selTurtle.pos.z
    end
    local vx1 = vcx - MAP.hwx
    local vx2 = vcx + MAP.hwx
    local vz1 = vcz - MAP.hwz
    local vz2 = vcz + MAP.hwz

    -- Shorthand: convert using this frame's viewport
    local function wm(wx, wz) return worldToMap(wx, wz, vx1, vx2, vz1, vz2) end

    -- Map background
    fill(MAP.px, MAP.py, MAP.pw, MAP.ph, {10,14,28})
    -- Border
    state.gpu.drawLine(state.display,MAP.px,MAP.py,MAP.px+MAP.pw,MAP.py,50,65,110)
    state.gpu.drawLine(state.display,MAP.px,MAP.py+MAP.ph,MAP.px+MAP.pw,MAP.py+MAP.ph,50,65,110)
    state.gpu.drawLine(state.display,MAP.px,MAP.py,MAP.px,MAP.py+MAP.ph,50,65,110)
    state.gpu.drawLine(state.display,MAP.px+MAP.pw,MAP.py,MAP.px+MAP.pw,MAP.py+MAP.ph,50,65,110)

    -- Grid every 40 blocks (snap start to nearest multiple of 40)
    local gxStart = math.ceil(vx1 / 40) * 40
    for wx = gxStart, vx2, 40 do
        local sx,_ = wm(wx, vz1)
        if sx >= MAP.px and sx <= MAP.px+MAP.pw then
            state.gpu.drawLine(state.display,sx,MAP.py,sx,MAP.py+MAP.ph,20,25,50)
            t(wx, sx+1, MAP.py+MAP.ph-10, {35,45,75}, 8)
        end
    end
    local gzStart = math.ceil(vz1 / 40) * 40
    for wz = gzStart, vz2, 40 do
        local _,sy = wm(vx1, wz)
        if sy >= MAP.py and sy <= MAP.py+MAP.ph then
            state.gpu.drawLine(state.display,MAP.px,sy,MAP.px+MAP.pw,sy,20,25,50)
            t(wz, MAP.px+2, sy-8, {35,45,75}, 8)
        end
    end

    -- Crosshair at view center (shows where the camera is locked)
    do
        local csx,csy = wm(vcx, vcz)
        state.gpu.drawLine(state.display,csx-6,csy,csx+6,csy,40,50,80)
        state.gpu.drawLine(state.display,csx,csy-6,csx,csy+6,40,50,80)
    end

    -- Depot outline (only draw if any corner is near the viewport)
    local dx1c,dy1c = wm(143,-2813)
    local dx2c,dy2c = wm(228,-2782)
    state.gpu.drawLine(state.display,dx1c,dy1c,dx2c,dy1c,60,80,140)
    state.gpu.drawLine(state.display,dx2c,dy1c,dx2c,dy2c,60,80,140)
    state.gpu.drawLine(state.display,dx2c,dy2c,dx1c,dy2c,60,80,140)
    state.gpu.drawLine(state.display,dx1c,dy2c,dx1c,dy1c,60,80,140)
    t("DEPOT",dx1c+2,dy1c+2,{60,80,140},8)

    -- Hole markers
    local hx,hy = wm(143,-2813); fill(hx-2,hy-2,5,5,{220,120,30})
    local ax,ay = wm(228,-2782); fill(ax-2,ay-2,5,5,{30,180,220})

    -- Draw all turtles
    local list = turtleList()
    for i,v in ipairs(list) do
        local col = turtleCol(i)
        local isSel = v.id == state.selectedTurtle
        if v.pos then
            local tx,tz = wm(v.pos.x, v.pos.z)
            -- Selected: bigger ring
            if isSel then
                state.gpu.drawLine(state.display,tx-5,tz-5,tx+5,tz-5,col[1],col[2],col[3])
                state.gpu.drawLine(state.display,tx+5,tz-5,tx+5,tz+5,col[1],col[2],col[3])
                state.gpu.drawLine(state.display,tx+5,tz+5,tx-5,tz+5,col[1],col[2],col[3])
                state.gpu.drawLine(state.display,tx-5,tz+5,tx-5,tz-5,col[1],col[2],col[3])
            end
            fill(tx-2, tz-2, 5, 5, col)
            t(v.id or"?", tx+5, tz-4, col, 8, isSel)
        end
    end

    -- ── Right info panel ─────────────────────────────────────────────────────
    local rx = MAP.px + MAP.pw + 6
    local ry = MAP.py

    -- Panel bg + border
    fill(rx, ry, W-rx-4, MAP.ph, {16,20,38})
    state.gpu.drawLine(state.display,rx,ry,W-4,ry,50,65,110)

    -- Title + click hint
    t("TURTLES", rx+4, ry+2, C.WHITE, 10, true)
    fill(rx, ry+14, W-rx-4, 14, {30,50,100})
    t("click to focus", rx+4, ry+16, {180,200,255}, 9)

    -- Turtle list
    local ly = ry + 32
    for i,v in ipairs(list) do
        local col  = turtleCol(i)
        local isSel = v.id == state.selectedTurtle
        if isSel then fill(rx, ly-1, W-rx-4, 12, {25,40,70}) end
        local marker = isSel and ">" or " "
        t(marker .. (v.id or"?"), rx+4, ly, col, 9, isSel)
        ly = ly + 13
    end

    -- Selected turtle detail box
    local sel = state.selectedTurtle and state.turtles[state.selectedTurtle]
    if sel then
        local dy = ry + 32 + #list*13 + 6
        -- Divider
        state.gpu.drawLine(state.display,rx,dy,W-4,dy,50,65,110)
        dy = dy + 4

        t(sel.id or"?", rx+4, dy, C.WHITE, 10, true)
        dy = dy + 13

        local st = sel.online and (sel.status or"IDLE") or "OFFLINE"
        local sc = (not sel.online) and C.RED
                or (sel.status=="IDLE" and C.GREEN)
                or (sel.status=="RETURNING" and C.BLUE)
                or (sel.status=="ERROR" and C.RED)
                or C.YELLOW
        t("Status: "..st, rx+4, dy, sc, 9); dy=dy+11

        if sel.pos then
            t(string.format("%d %d %d", sel.pos.x, sel.pos.y, sel.pos.z), rx+4, dy, C.DIM, 9); dy=dy+11
            local age = math.floor((os.epoch("utc")-(sel.posAge or 0))/1000)
            t(age.."s ago", rx+4, dy, {80,80,100}, 9); dy=dy+11
        else
            t("No position yet", rx+4, dy, C.DIM, 9); dy=dy+11
        end

        local fuel = sel.fuel or 0
        local pct  = math.floor(math.min(100, fuel/math.max(sel.fuelMax or 1,1)*100))
        t(string.format("Fuel: %d%%", pct), rx+4, dy, pct>50 and C.GREEN or (pct>20 and C.YELLOW or C.RED), 9)
        dy=dy+11

        if sel.jobId then
            t("Job: "..sel.jobId, rx+4, dy, C.CYAN, 9)
        end
    else
        t("No turtle", rx+4, ry+80, C.DIM, 9)
        t("selected", rx+4, ry+91, C.DIM, 9)
    end
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
                    local now = os.clock()
                    if not isMove and ex and ey then
                        -- NEXT bar: cycle pages
                        if ex >= BTN.x and ex <= BTN.x+BTN.w
                        and ey >= BTN.y and ey <= BTN.y+BTN.h
                        and (now - lastPageFlip) > 0.5 then
                            lastPageFlip = now
                            state.page = (state.page % #PAGES) + 1
                            render(); break

                        -- MAP right panel: cycle selected turtle
                        elseif state.page == 4
                        and ex >= MAP_BTN.x and ex <= MAP_BTN.x+MAP_BTN.w
                        and ey >= MAP_BTN.y and ey <= MAP_BTN.y+MAP_BTN.h
                        and (now - lastPageFlip) > 0.3 then
                            lastPageFlip = now
                            cycleTurtle()
                            render(); break
                        end
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
