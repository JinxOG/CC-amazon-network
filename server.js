// server.js — CC Amazon Network bridge server
const express = require('express');
const { Rcon }  = require('rcon-client');
const path      = require('path');
const http      = require('http');

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
        await rcon(`dmarker addset id:${CFG.dynmap.set} label:Turtles hidebydefault:false`);
        console.log('[RCON] Marker set created');
    } catch (e) {
        // Already exists — update it to ensure it's visible
        try {
            await rcon(`dmarker updateset id:${CFG.dynmap.set} label:Turtles hidebydefault:false`);
            console.log('[RCON] Marker set updated (hidebydefault:false)');
        } catch (e2) {
            console.log('[RCON] Marker set already exists (ok)');
        }
    }
}

async function upsertMarker(id, t) {
    if (!t.x && t.x !== 0) return;
    const x = Math.round(t.x);
    const y = Math.round(t.y ?? 67);
    const z = Math.round(t.z);
    const label = `${id}_${t.status || 'UNKNOWN'}`;
    const icon  = t.role === 'SUPPORT' ? 'blueflag' : 'greenflag';

    try {
        if (markerExists[id]) {
            await rcon(`dmarker update id:${id} set:${CFG.dynmap.set} x:${x} y:${y} z:${z} label:${label} world:${CFG.dynmap.world}`);
        } else {
            try {
                await rcon(`dmarker add id:${id} label:${label} world:${CFG.dynmap.world} x:${x} y:${y} z:${z} icon:${icon} set:${CFG.dynmap.set}`);
            } catch (addErr) {
                await rcon(`dmarker delete id:${id} set:${CFG.dynmap.set}`);
                await rcon(`dmarker add id:${id} label:${label} world:${CFG.dynmap.world} x:${x} y:${y} z:${z} icon:${icon} set:${CFG.dynmap.set}`);
            }
            markerExists[id] = true;
            console.log(`[RCON] Marker created: ${id} @ ${x},${y},${z}`);
        }
    } catch (e) {
        console.error(`[RCON] Marker error for ${id}:`, e.message);
        markerExists[id] = false;
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

// ─── Dynmap proxy helpers ─────────────────────────────────────────────────────

function proxyDynmap(req, res, basePath) {
    const url = `http://127.0.0.1:8123${basePath}${req.path}`;
    http.get(url, (upstream) => {
        res.setHeader('Content-Type', upstream.headers['content-type'] || 'application/octet-stream');
        res.setHeader('Cache-Control', 'public, max-age=10');
        upstream.pipe(res);
    }).on('error', () => res.status(404).end());
}

// ─── Dynmap static asset proxies (makes iframe same-origin) ──────────────────
// These must come BEFORE the /update, /state, /command routes.

app.use('/tiles',      (req, res) => proxyDynmap(req, res, '/tiles'));
app.use('/up',         (req, res) => proxyDynmap(req, res, '/up'));
app.use('/js',         (req, res) => proxyDynmap(req, res, '/js'));
app.use('/css',        (req, res) => proxyDynmap(req, res, '/css'));
app.use('/images',     (req, res) => proxyDynmap(req, res, '/images'));
app.use('/standalone', (req, res) => proxyDynmap(req, res, '/standalone'));
app.use('/webstart',   (req, res) => proxyDynmap(req, res, '/webstart'));
app.get('/favicon.ico',  (req, res) => proxyDynmap(req, res, '/favicon.ico'));
// Root-level Dynmap files (version.js etc.) — req.path is the full path here
app.get('/version.js', (req, res) => proxyDynmap(req, res, ''));

// Serve Dynmap's main page for iframe embedding (same-origin = can inject JS)
app.get('/dynmap-frame', (req, res) => {
    http.get('http://127.0.0.1:8123/', (upstream) => {
        res.setHeader('Content-Type', 'text/html');
        upstream.pipe(res);
    }).on('error', () => res.status(502).send('<h3>Dynmap unavailable (port 8123)</h3>'));
});

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

// Health check
app.get('/ping', (req, res) => res.json({ ok: true, uptime: process.uptime() }));

// ─── Start ───────────────────────────────────────────────────────────────────

app.listen(CFG.port, () => {
    console.log(`CC Dashboard bridge listening on http://localhost:${CFG.port}`);
    initMarkerSet();
});
