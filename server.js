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
let markerExists    = {};   // track which turtle markers already exist on Dynmap (for direct Dynmap access)

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
            upsertMarker(id, state.turtles[id]).catch(() => {});
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

// Proxy Dynmap tiles through our server (avoids cross-origin image issues)
app.get('/tiles/*', (req, res) => {
    const url = `http://127.0.0.1:8123${req.path}`;
    const http = require('http');
    http.get(url, (upstream) => {
        res.setHeader('Content-Type', upstream.headers['content-type'] || 'image/png');
        res.setHeader('Cache-Control', 'public, max-age=10');
        upstream.pipe(res);
    }).on('error', () => res.status(404).end());
});

// Health check
app.get('/ping', (req, res) => res.json({ ok: true, uptime: process.uptime() }));

// ─── Start ───────────────────────────────────────────────────────────────────

app.listen(CFG.port, () => {
    console.log(`CC Dashboard bridge listening on http://localhost:${CFG.port}`);
    initMarkerSet();
});
