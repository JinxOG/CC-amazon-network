-- admin_ui.lua
-- Admin dashboard. Right-click monitor to cycle pages.

local proto = require("protocol")

-- ─── Fixed canvas size ────────────────────────────────────────────────────────
-- Deliberately undersized so content always fits in the top-left of any monitor.
-- Change these if you want a larger layout.
local W = 360
local H = 240

local PAGES    = { "TURTLES", "JOBS", "LOG" }
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

local TH = 22   -- title height

local function drawTitle()
    fill(0,0,W,TH,C.HDR)
    local label = string.format("CC AMAZON | %s (%d/%d) right-click=next",
        PAGES[state.page], state.page, #PAGES)
    t(label, 6, 5, C.WHITE, 11, true)
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
        t("[".. (v.role or "?") .."]", 115, y, C.DIM, FS)
        t(st, 205, y, sc, FS)
        -- compact fuel bar
        local pct = math.min(1,(v.fuel or 0)/math.max(v.fuelMax or 1,1))
        local bx,bw,bh = 260,70,8
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

-- ─── Render ──────────────────────────────────────────────────────────────────

local function render()
    fill(0,0,W,H,C.BG)
    drawTitle()
    if     state.page==1 then pgTurtles()
    elseif state.page==2 then pgJobs()
    elseif state.page==3 then pgLog()
    end
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
            fuel=p.fuel,fuelMax=p.fuelMax,online=true}
        addLog("INFO","Reg: "..id.." [".. (p.role or"?") .."]")

    elseif msg.type==proto.MSG.HEARTBEAT then
        local p=msg.payload; local id=msg.from
        if not state.turtles[id] then state.turtles[id]={id=id,online=true} end
        local v=state.turtles[id]
        v.online=true; v.status=p.status or v.status
        v.fuel=p.fuel or v.fuel; v.jobId=p.jobId

    elseif msg.type==proto.MSG.STATUS_UPDATE then
        local p=msg.payload; local id=msg.from
        if not state.turtles[id] then state.turtles[id]={id=id,online=true} end
        local v=state.turtles[id]
        v.status=p.status or v.status; v.jobId=p.jobId or v.jobId
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

    local timer = os.startTimer(2)
    while true do
        local ev,p1,p2,p3,p4 = os.pullEvent()
        if ev=="monitor_touch" then
            state.page = (state.page % #PAGES) + 1
            render()
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
