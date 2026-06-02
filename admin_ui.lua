-- admin_ui.lua
-- Live dashboard for the CC autonomous network.
-- Runs on a dedicated computer connected to a 3x2 DirectGPU monitor.
-- Polls the central server via ender modem for state updates.
--
-- Setup: place this computer next to (or wired to) the server computer,
-- attach an ender modem, run this file.

local proto = require("protocol")

-- ─── Display config ──────────────────────────────────────────────────────────

local W, H = 1968, 648          -- 3×2 monitor in pixels (656×324 per block)
local PAD  = 12                  -- outer padding

-- Colour palette
local C = {
    BG          = { 10,  10,  18  },  -- near-black background
    PANEL_BG    = { 18,  22,  35  },  -- panel fill
    BORDER      = { 40,  50,  80  },  -- panel border
    HEADER_BG   = { 25,  35,  65  },  -- panel header bar
    WHITE       = { 235, 235, 235 },
    DIM         = { 120, 120, 140 },
    GREEN       = {  60, 200,  90 },  -- IDLE / COMPLETE
    YELLOW      = { 220, 190,  50 },  -- TRAVELLING / LOADING / WORKING
    RED         = { 220,  60,  60 },  -- ERROR / FAILED / OFFLINE
    BLUE        = {  80, 160, 230 },  -- RETURNING
    CYAN        = {  60, 200, 200 },  -- IN_PROGRESS
    ORANGE      = { 220, 130,  50 },  -- PENDING / retry
    INFO_COL    = {  80, 160, 230 },
    WARN_COL    = { 220, 190,  50 },
    ERROR_COL   = { 220,  60,  60 },
}

-- Layout (calculated once)
local TURTLE_PANEL = { x=PAD,           y=PAD,          w=900,          h=380 }
local JOB_PANEL    = { x=PAD+900+PAD,   y=PAD,          w=W-PAD*3-900,  h=380 }
local LOG_PANEL    = { x=PAD,           y=PAD+380+PAD,  w=W-PAD*2,      h=H-PAD*3-380 }

-- ─── State ───────────────────────────────────────────────────────────────────

local state = {
    turtles  = {},   -- mirrored registry
    jobs     = {},   -- mirrored job queue
    logs     = {},   -- recent log lines
    modem    = nil,
    gpu      = nil,
    display  = nil,
    lastPoll = 0,
}

local MAX_LOGS = 60

-- ─── GPU helpers ─────────────────────────────────────────────────────────────

local function fill(x, y, w, h, col)
    state.gpu.fillRect(state.display, x, y, w, h, col[1], col[2], col[3])
end

local function text(str, x, y, col, font, size, style)
    state.gpu.drawText(state.display, str, x, y,
        col[1], col[2], col[3],
        font  or "minecraft:font/default.ttf",
        size  or 14,
        style or "regular")
end

local function line(x1, y1, x2, y2, col)
    state.gpu.drawLine(state.display, x1, y1, x2, y2, col[1], col[2], col[3])
end

local function flush()
    state.gpu.updateDisplay(state.display)
end

-- Measure text height for the given font size (approximation: size * 1.25)
local function lineH(size) return math.floor((size or 14) * 1.4) end

-- ─── Panel drawing ───────────────────────────────────────────────────────────

local function drawPanel(p, title)
    -- Background
    fill(p.x, p.y, p.w, p.h, C.PANEL_BG)
    -- Border
    line(p.x,       p.y,       p.x+p.w-1, p.y,       C.BORDER)
    line(p.x,       p.y+p.h-1, p.x+p.w-1, p.y+p.h-1, C.BORDER)
    line(p.x,       p.y,       p.x,       p.y+p.h-1, C.BORDER)
    line(p.x+p.w-1, p.y,       p.x+p.w-1, p.y+p.h-1, C.BORDER)
    -- Header bar
    local hh = 28
    fill(p.x+1, p.y+1, p.w-2, hh, C.HEADER_BG)
    text(title, p.x+10, p.y+7, C.WHITE, nil, 14, "bold")
    return p.y + hh + 8   -- y for first content row
end

-- ─── Status colours ──────────────────────────────────────────────────────────

local function turtleStatusCol(status, online)
    if not online                         then return C.RED    end
    if status == "IDLE"                   then return C.GREEN  end
    if status == "TRAVELLING"
    or status == "LOADING"
    or status == "WORKING"                then return C.YELLOW end
    if status == "RETURNING"              then return C.BLUE   end
    if status == "ERROR"                  then return C.RED    end
    return C.DIM
end

local function jobStatusCol(status)
    if status == "COMPLETE"               then return C.GREEN  end
    if status == "IN_PROGRESS"            then return C.CYAN   end
    if status == "ASSIGNED"               then return C.YELLOW end
    if status == "PENDING"                then return C.ORANGE end
    if status == "FAILED"                 then return C.RED    end
    if status == "CANCELLED"              then return C.DIM    end
    return C.DIM
end

local function logLevelCol(level)
    if level == "WARN"  then return C.WARN_COL  end
    if level == "ERROR" then return C.ERROR_COL end
    return C.INFO_COL
end

-- ─── Render sections ─────────────────────────────────────────────────────────

local function renderTurtles()
    local p   = TURTLE_PANEL
    local cy  = drawPanel(p, "TURTLES")
    local fs  = 13
    local lh  = lineH(fs)
    local col = p.x + 10

    -- Sort by role then id
    local list = {}
    for id, t in pairs(state.turtles) do table.insert(list, t) end
    table.sort(list, function(a, b)
        if a.role ~= b.role then return (a.role or "") < (b.role or "") end
        return (a.id or "") < (b.id or "")
    end)

    for _, t in ipairs(list) do
        if cy + lh > p.y + p.h - 8 then break end

        local scol   = turtleStatusCol(t.status, t.online)
        local online = t.online and "●" or "○"

        -- Dot indicator
        text(online, col, cy, scol, nil, fs)
        -- ID + role
        local label = string.format("%-14s [%s]", t.id or "?", t.role or "?")
        text(label, col + 18, cy, C.WHITE, nil, fs, "bold")
        -- Status
        local statusStr = t.online and (t.status or "?") or "OFFLINE"
        text(statusStr, col + 220, cy, scol, nil, fs)
        -- Fuel bar
        local fuel    = t.fuel    or 0
        local fuelMax = t.fuelMax or 1
        local pct     = math.min(1, fuel / math.max(fuelMax, 1))
        local barW    = 160
        local barH    = 10
        local barX    = col + 340
        local barY    = cy + 2
        fill(barX, barY, barW, barH, C.BORDER)
        local fuelCol = pct > 0.5 and C.GREEN or (pct > 0.2 and C.YELLOW or C.RED)
        fill(barX, barY, math.floor(barW * pct), barH, fuelCol)
        text(string.format("%dk", math.floor(fuel/1000)), barX + barW + 6, cy, C.DIM, nil, fs)

        -- Job if active
        if t.jobId then
            text("→ " .. t.jobId, col + 530, cy, C.CYAN, nil, fs)
        end

        cy = cy + lh + 4

        -- Separator
        if cy < p.y + p.h - 8 then
            line(p.x+6, cy-2, p.x+p.w-6, cy-2, C.BORDER)
        end
    end

    if #list == 0 then
        text("No turtles registered", col, cy, C.DIM, nil, fs)
    end
end

local function renderJobs()
    local p  = JOB_PANEL
    local cy = drawPanel(p, "JOBS")
    local fs = 12
    local lh = lineH(fs)

    -- Sort: active first, then by id descending (most recent at top)
    local list = {}
    for id, j in pairs(state.jobs) do table.insert(list, j) end
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

    local col = p.x + 10
    for _, j in ipairs(list) do
        if cy + lh > p.y + p.h - 8 then break end

        local scol = jobStatusCol(j.status)
        -- Job ID
        text(j.id or "?", col, cy, C.WHITE, nil, fs, "bold")
        -- Type (short)
        local typ = j.type == "SUPPORT_FOLLOW" and "SUPPORT" or (j.type or "?")
        text(typ, col + 120, cy, C.DIM, nil, fs)
        -- Status
        text(j.status or "?", col + 230, cy, scol, nil, fs)
        -- Assigned to
        if j.assignedTo then
            text("→ " .. j.assignedTo, col + 370, cy, C.DIM, nil, fs)
        end

        cy = cy + lh + 3
    end

    if #list == 0 then
        text("Queue empty", col, cy, C.DIM, nil, fs)
    end
end

local function renderLog()
    local p  = LOG_PANEL
    local cy = drawPanel(p, "LOG")
    local fs = 11
    local lh = lineH(fs)
    local col = p.x + 10
    local maxRows = math.floor((p.y + p.h - cy - 6) / lh)

    -- Show most recent lines that fit
    local start = math.max(1, #state.logs - maxRows + 1)
    for i = start, #state.logs do
        local entry = state.logs[i]
        if cy + lh > p.y + p.h - 4 then break end

        -- Level tag
        local lcol = logLevelCol(entry.level)
        text(string.format("[%s]", entry.level), col, cy, lcol, nil, fs, "bold")
        -- Message
        text(entry.msg or "", col + 60, cy, C.DIM, nil, fs)
        cy = cy + lh
    end
end

local function renderAll()
    -- Background
    fill(0, 0, W, H, C.BG)
    -- Title bar
    fill(0, 0, W, PAD - 2, C.HEADER_BG)
    text("CC AMAZON NETWORK  —  ADMIN DASHBOARD", 12, 0, C.WHITE, nil, 11, "bold")
    local ts = string.format("last update: %ds ago",
        math.floor((os.epoch("utc") - state.lastPoll) / 1000))
    text(ts, W - 200, 0, C.DIM, nil, 10)

    renderTurtles()
    renderJobs()
    renderLog()
    flush()
end

-- ─── Polling (server query via modem) ────────────────────────────────────────
-- The UI computer sends a STATE_REQUEST and the server responds.
-- For now we use a simpler approach: the UI subscribes to the broadcast
-- channel and mirrors STATUS_UPDATE / JOB_COMPLETE / REGISTER messages.
-- This gives near-real-time updates without adding a query round-trip.

local function handleMessage(msg)
    if msg.type == proto.MSG.REGISTER or msg.type == proto.MSG.HEARTBEAT then
        -- Update turtle entry
        local id = msg.from
        if not state.turtles[id] then
            state.turtles[id] = { id = id }
        end
        local t   = state.turtles[id]
        local p   = msg.payload
        t.online  = true
        t.role    = p.role    or t.role
        t.status  = p.status  or t.status  or "IDLE"
        t.fuel    = p.fuel    or t.fuel
        t.fuelMax = p.fuelMax or t.fuelMax
        t.jobId   = p.jobId
        if msg.type == proto.MSG.REGISTER then
            t.status = "IDLE"
            t.jobId  = nil
        end

    elseif msg.type == proto.MSG.STATUS_UPDATE then
        local id = msg.from
        if not state.turtles[id] then state.turtles[id] = { id = id } end
        local t  = state.turtles[id]
        local p  = msg.payload
        t.status = p.status or t.status
        t.jobId  = p.jobId  or t.jobId
        -- Mirror job status
        if p.jobId and state.jobs[p.jobId] then
            state.jobs[p.jobId].status = "IN_PROGRESS"
        end

    elseif msg.type == proto.MSG.JOB_ASSIGN then
        local p = msg.payload
        state.jobs[p.jobId] = state.jobs[p.jobId] or {
            id   = p.jobId,
            type = p.jobType,
        }
        local j       = state.jobs[p.jobId]
        j.status      = "ASSIGNED"
        j.assignedTo  = msg.to
        j.type        = p.jobType or j.type

    elseif msg.type == proto.MSG.JOB_COMPLETE then
        local jid = msg.payload.jobId
        if state.jobs[jid] then
            state.jobs[jid].status = "COMPLETE"
            state.jobs[jid].assignedTo = nil
        end
        local t = state.turtles[msg.from]
        if t then t.status = "IDLE"; t.jobId = nil end

    elseif msg.type == proto.MSG.JOB_FAILED then
        local jid = msg.payload.jobId
        if state.jobs[jid] then
            local recoverable = msg.payload.recoverable
            state.jobs[jid].status = recoverable and "PENDING" or "FAILED"
        end
        local t = state.turtles[msg.from]
        if t then t.status = "IDLE"; t.jobId = nil end
    end
end

local function handleLog(raw)
    -- Sniff log-style STATUS_UPDATE detail as log entry
    -- Real log lines come from server print() — we can't intercept those,
    -- but we synthesise useful events from the messages we do see.
end

local function addLog(level, msg)
    table.insert(state.logs, { level = level, msg = msg, ts = os.epoch("utc") })
    if #state.logs > MAX_LOGS then table.remove(state.logs, 1) end
end

-- ─── Main ────────────────────────────────────────────────────────────────────

local function main()
    -- GPU setup
    state.gpu = peripheral.find("directgpu")
    if not state.gpu then error("No DirectGPU peripheral found.") end
    state.display = state.gpu.autoDetectAndCreateDisplay()
    if not state.display then error("Could not create display.") end

    -- Modem setup — listen on all channels to sniff traffic
    state.modem = peripheral.find("modem")
    if not state.modem then error("No modem found.") end
    state.modem.open(proto.CH_SERVER)
    state.modem.open(proto.CH_BROADCAST)
    state.modem.open(proto.CH_PRIVATE)

    addLog("INFO", "Admin UI started — listening for network traffic")
    renderAll()

    local redrawTimer = os.startTimer(2)   -- redraw every 2s minimum

    while true do
        local event, p1, p2, p3, p4 = os.pullEvent()

        if event == "modem_message" then
            local parsed = type(p4) == "table" and p4 or textutils.unserialise(p4)
            if parsed then
                local valid, msg = proto.decode(parsed)
                if valid then
                    state.lastPoll = os.epoch("utc")
                    local ok, err = pcall(handleMessage, msg)
                    if not ok then addLog("ERROR", "UI handler: " .. tostring(err)) end

                    -- Synthesise log entries for notable events
                    if msg.type == proto.MSG.JOB_COMPLETE then
                        addLog("INFO", string.format("Job complete: %s (%s)", msg.payload.jobId, msg.from))
                    elseif msg.type == proto.MSG.JOB_FAILED then
                        addLog("WARN", string.format("Job failed: %s — %s", msg.payload.jobId, msg.payload.reason or "?"))
                    elseif msg.type == proto.MSG.REGISTER then
                        addLog("INFO", string.format("Turtle registered: %s [%s]", msg.from, msg.payload.role or "?"))
                    end

                    renderAll()
                end
            end

        elseif event == "timer" and p1 == redrawTimer then
            -- Periodic redraw to update timestamps even when no messages arrive
            renderAll()
            redrawTimer = os.startTimer(2)
        end
    end
end

-- Graceful error display
local ok, err = pcall(main)
if not ok then
    if state.gpu and state.display then
        state.gpu.clear(state.display, 10, 10, 18)
        state.gpu.drawText(state.display, "CRASH: " .. tostring(err), 10, 10, 220, 60, 60, nil, 14, "bold")
        state.gpu.updateDisplay(state.display)
    end
    error(err)
end
