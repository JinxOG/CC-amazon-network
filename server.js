// server.js — CC Amazon Network bridge server
const express = require('express');
const { Rcon }  = require('rcon-client');
const path      = require('path');

// Prevent unhandled rejections from crashing the process
process.on('unhandledRejection', (err) => {
    console.error('[ERROR] Unhandled rejection:', err && err.message || err);
});
process.on('uncaughtException', (err) => {
    console.error('[ERROR] Uncaught exception:', err && err.message || err);
});

const app = express();
app.use(express.json());
app.use(express.static(path.join(__dirname, 'public')));

// ─── Config ──────────────────────────────────────────────────────────────────

const CFG = {
    port:        3000,
    rcon: {
        host:     '127.0.0.1',
        port:     25575,
        password: 'zoomer',
    },
    dynmap: {
        world:  'MODPACK',
        set:    'turtles',
    },
};

// ─── State ───────────────────────────────────────────────────────────────────

let state = {
    turtles:  {},   // { nodeId: { x, y, z, status, fuel, role, jobId, dock, online } }
    jobs:     [],   // job queue from CC server
    updatedAt: null,
};

let pendingCommands = [];   // commands queued by dashboard, picked up by CC on next poll
let markerExists    = {};   // track which turtle markers already exist on Dynmap
let turtlePaths     = {};   // { id: { jobId, points:[{x,y,z}] } } — path history per active job

// ─── RCON ────────────────────────────────────────────────────────────────────

async function rcon(cmd) {
    const client = await Rcon.connect(CFG.rcon);
    try {
        const res = await client.send(cmd);
        return res;
    } finally {
        await client.end();
    }
}

async function initMarkerSet() {
    try {
        await rcon(`dmarker addset id:${CFG.dynmap.set} label:Turtles`);
        console.log('[RCON] Marker set created');
    } catch (e) {
        console.log('[RCON] Marker set already exists (ok)');
    }
}

async function upsertMarker(id, t) {
    if (!t.x && t.x !== 0) return;   // no position yet
    const x = Math.round(t.x);
    const y = Math.round(t.y ?? 67);
    const z = Math.round(t.z);
    const label = `${id}_${t.status || 'UNKNOWN'}`;
    const icon  = t.role === 'SUPPORT' ? 'blueflag' : 'greenflag';

    try {
        if (markerExists[id]) {
            await rcon(`dmarker update id:${id} set:${CFG.dynmap.set} x:${x} y:${y} z:${z} label:${label} world:${CFG.dynmap.world}`);
        } else {
            // Try add — if it fails (already exists), delete and re-add
            try {
                await rcon(`dmarker add id:${id} label:${label} world:${CFG.dynmap.world} x:${x} y:${y} z:${z} icon:${icon} set:${CFG.dynmap.set}`);
            } catch (addErr) {
                // Marker already exists — delete and re-add
                await rcon(`dmarker delete id:${id} set:${CFG.dynmap.set}`);
                await rcon(`dmarker add id:${id} label:${label} world:${CFG.dynmap.world} x:${x} y:${y} z:${z} icon:${icon} set:${CFG.dynmap.set}`);
            }
            markerExists[id] = true;
            console.log(`[RCON] Marker created: ${id} @ ${x},${y},${z}`);
        }
    } catch (e) {
        console.error(`[RCON] Marker error for ${id}:`, e.message);
        markerExists[id] = false;   // retry next time
    }
}

// ─── Path tracking ───────────────────────────────────────────────────────────

function trackPath(id, t) {
    if (!t.jobId || t.x == null) return;

    // New job or first point — reset path
    if (!turtlePaths[id] || turtlePaths[id].jobId !== t.jobId) {
        if (turtlePaths[id]) deletePathLine(id).catch(() => {});
        turtlePaths[id] = { jobId: t.jobId, points: [], dirty: false };
    }

    const pts  = turtlePaths[id].points;
    const last = pts[pts.length - 1];
    const x = Math.round(t.x), y = Math.round(t.y ?? 67), z = Math.round(t.z);

    if (!last || Math.abs(last.x - x) > 1 || Math.abs(last.z - z) > 1) {
        pts.push({ x, y, z });
        if (pts.length > 300) pts.shift();   // cap history
        turtlePaths[id].dirty = true;
    }
}

async function flushPaths() {
    for (const [id, path] of Object.entries(turtlePaths)) {
        if (!path.dirty || path.points.length < 2) continue;
        path.dirty = false;
        const xs = path.points.map(p => p.x).join(',');
        const ys = path.points.map(p => p.y).join(',');
        const zs = path.points.map(p => p.z).join(',');
        const lineId = `path_${id}`;
        try {
            try { await rcon(`dmarker deleteline id:${lineId} set:${CFG.dynmap.set}`); } catch(e) {}
            await rcon(`dmarker addline id:${lineId} set:${CFG.dynmap.set} world:${CFG.dynmap.world} x:${xs} y:${ys} z:${zs} color:00ff88 weight:2 opacity:0.6`);
        } catch(e) {
            console.error(`[RCON] Path error ${id}:`, e.message);
        }
    }
}

async function deletePathLine(id) {
    try { await rcon(`dmarker deleteline id:path_${id} set:${CFG.dynmap.set}`); } catch(e) {}
    delete turtlePaths[id];
}

// Flush path lines every 4 seconds
setInterval(() => flushPaths().catch(() => {}), 4000);

async function removeMarker(id) {
    if (!markerExists[id]) return;
    try {
        await rcon(`dmarker delete id:${id} set:${CFG.dynmap.set}`);
        markerExists[id] = false;
    } catch (e) {
        console.error(`[RCON] Delete error for ${id}:`, e.message);
    }
}

// ─── Routes ──────────────────────────────────────────────────────────────────

// CC central_server.lua pushes state here every 2s
app.post('/update', async (req, res) => {
    const { turtles, jobs } = req.body;
    if (!turtles && !jobs) return res.status(400).json({ error: 'missing data' });

    if (turtles) {
        for (const [id, data] of Object.entries(turtles)) {
            state.turtles[id] = { ...state.turtles[id], ...data };
            const t = state.turtles[id];
            upsertMarker(id, t).catch(() => {});
            trackPath(id, t);
            // Job finished — clear path line
            if (turtlePaths[id] && !t.jobId) {
                deletePathLine(id).catch(() => {});
            }
        }
    }

    if (jobs) state.jobs = jobs;
    state.updatedAt = Date.now();

    res.json({ ok: true, commands: pendingCommands.splice(0) });
});

// Dashboard reads current state
app.get('/state', (req, res) => {
    res.json({ ...state, serverTime: Date.now() });
});

// Dashboard queues a command for CC to pick up
app.post('/command', (req, res) => {
    const { type, params } = req.body;
    if (!type) return res.status(400).json({ error: 'missing type' });
    pendingCommands.push({ type, params: params || {}, ts: Date.now() });
    console.log(`[CMD] Queued: ${type}`, params || '');
    res.json({ ok: true });
});

// Health check
app.get('/ping', (req, res) => res.json({ ok: true, uptime: process.uptime() }));

// ─── Start ───────────────────────────────────────────────────────────────────

app.listen(CFG.port, () => {
    console.log(`CC Dashboard bridge listening on http://localhost:${CFG.port}`);
    initMarkerSet();
});
