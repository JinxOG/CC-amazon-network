// server.js — CC Amazon Network bridge server
const express = require('express');
const { Rcon }  = require('rcon-client');
const path      = require('path');
const http      = require('http');
const { exec }  = require('child_process');

// Prevent unhandled rejections from crashing the process
process.on('unhandledRejection', (err) => {
    console.error('[ERROR] Unhandled rejection:', err && err.message || err);
});
process.on('uncaughtException', (err) => {
    console.error('[ERROR] Uncaught exception:', err && err.message || err);
});

const app = express();
app.use(express.json({ limit: '1mb' }));

// Serve index.html with no-cache so the browser always fetches the latest version
app.get('/', (req, res) => {
    res.setHeader('Cache-Control', 'no-cache, no-store, must-revalidate');
    res.setHeader('Pragma', 'no-cache');
    res.setHeader('Expires', '0');
    res.sendFile(path.join(__dirname, 'public', 'index.html'));
});

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
    turtles:   {},   // { nodeId: { x, y, z, status, fuel, role, jobId, dock, online } }
    jobs:      [],   // job queue from CC server
    version:   null,
    storage:   [],   // RS storage snapshot [{name, displayName, amount, craftable}]
    mineZones: {},   // { [jobId]: { bounds, total, done, pct, eta, oreFound, oreMined } }
    updatedAt: null,
};

let pendingCommands = [];   // commands queued by dashboard, picked up by CC on next poll
let markerExists    = {};   // track which turtle markers already exist on Dynmap

// ─── RCON ────────────────────────────────────────────────────────────────────
// PERF #58: Persistent singleton connection — reuse across calls instead of
// creating a new TCP connection for every marker write.

let rconClient = null;

async function getRcon() {
    if (rconClient) {
        try {
            await rconClient.send('');   // ping to verify connection is alive
            return rconClient;
        } catch (e) {
            rconClient = null;           // stale — fall through to reconnect
        }
    }
    rconClient = await Rcon.connect(CFG.rcon);
    return rconClient;
}

async function rcon(cmd) {
    try {
        const client = await getRcon();
        return await client.send(cmd);
    } catch (e) {
        rconClient = null;   // reset so next call reconnects
        throw e;
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
            // Always delete first — prevents stale marker at old position if the
            // turtle was pruned offline and came back at a new position.
            await rcon(`dmarker delete id:${id} set:${CFG.dynmap.set}`).catch(() => {});
            await rcon(`dmarker add id:${id} label:${label} world:${CFG.dynmap.world} x:${x} y:${y} z:${z} icon:${icon} set:${CFG.dynmap.set}`);
            markerExists[id] = true;
            console.log(`[RCON] Marker created: ${id} @ ${x},${y},${z}`);
        }
    } catch (e) {
        if (!markerExists[`_err_${id}`]) {
            console.error(`[RCON] Marker error for ${id}:`, e.message);
        }
        markerExists[`_err_${id}`] = true;
        markerExists[id] = false;
        // Clear error flag after 30s so we retry
        setTimeout(() => { delete markerExists[`_err_${id}`]; }, 30000);
    }
}

// ─── Dynmap proxy helpers ─────────────────────────────────────────────────────

// PERF #59: 5s timeout on upstream Dynmap requests — prevents browser hangs
// if Dynmap is slow or unreachable.
function proxyDynmap(req, res, basePath) {
    const url = `http://127.0.0.1:8123${basePath}${req.path}`;
    let settled = false;
    const timeout = setTimeout(() => {
        if (!settled) { settled = true; res.status(504).end(); }
    }, 5000);
    http.get(url, (upstream) => {
        if (settled) { upstream.resume(); return; }   // already timed out — drain and discard
        settled = true;
        clearTimeout(timeout);
        res.setHeader('Content-Type', upstream.headers['content-type'] || 'application/octet-stream');
        res.setHeader('Cache-Control', 'public, max-age=10');
        upstream.pipe(res);
    }).on('error', () => {
        clearTimeout(timeout);
        if (!settled) { settled = true; res.status(404).end(); }
    });
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
// PERF #59: same 5s timeout as proxyDynmap to prevent indefinite hangs.
app.get('/dynmap-frame', (req, res) => {
    let settled = false;
    const timeout = setTimeout(() => {
        if (!settled) { settled = true; res.status(504).send('<h3>Dynmap timeout</h3>'); }
    }, 5000);
    http.get('http://127.0.0.1:8123/', (upstream) => {
        if (settled) { upstream.resume(); return; }
        settled = true;
        clearTimeout(timeout);
        res.setHeader('Content-Type', 'text/html');
        upstream.pipe(res);
    }).on('error', () => {
        clearTimeout(timeout);
        if (!settled) { settled = true; res.status(502).send('<h3>Dynmap unavailable (port 8123)</h3>'); }
    });
});

// ─── Routes ──────────────────────────────────────────────────────────────────

// CC central_server.lua pushes state here every 2s
app.post('/update', async (req, res) => {
    const { turtles, jobs, version, storage, mineZones } = req.body || {};
    console.log(`[UPDATE] v=${version} turtles=${Object.keys(turtles||{}).length} storage=${Array.isArray(storage)?storage.length:'?'}`);
    if (!turtles && !jobs && !version) return res.status(400).json({ error: 'missing data' });

    const now = Date.now();

    if (turtles) {
        for (const [id, data] of Object.entries(turtles)) {
            state.turtles[id] = { ...state.turtles[id], ...data, lastSeen: now };
            if (data.online === false) {
                if (markerExists[id]) {
                    rcon(`dmarker delete id:${id} set:${CFG.dynmap.set}`).catch(() => {});
                    markerExists[id] = false;
                }
            } else {
                upsertMarker(id, state.turtles[id]).catch((e) => console.error('[RCON] upsertMarker uncaught:', e.message));
            }
        }

        for (const [id, t] of Object.entries(state.turtles)) {
            if (t.lastSeen && now - t.lastSeen > 10 * 60 * 1000) {
                delete state.turtles[id];
                delete markerExists[id];
                rcon(`dmarker delete id:${id} set:${CFG.dynmap.set}`).catch(() => {});
                console.log(`[STATE] Pruned stale turtle: ${id}`);
            }
        }
    }

    if (jobs)                   state.jobs      = jobs;
    if (version)                state.version   = version;
    if (Array.isArray(storage)) state.storage   = storage;
    if (mineZones)              state.mineZones = mineZones;
    state.updatedAt = now;

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

    // REMOVE_TURTLE: immediately evict from bridge state so the turtle vanishes
    // from the dashboard and map without waiting for central_server to process it.
    if (type === 'REMOVE_TURTLE' && params && params.turtleId) {
        const id = params.turtleId;
        delete state.turtles[id];
        if (markerExists[id]) {
            rcon(`dmarker delete id:${id} set:${CFG.dynmap.set}`).catch(() => {});
            delete markerExists[id];
        }
        console.log(`[CMD] Evicted turtle from bridge state: ${id}`);
    }

    pendingCommands.push({ type, params: params || {}, ts: Date.now() });
    console.log(`[CMD] Queued: ${type}`, params || '');
    res.json({ ok: true });
});

// Health check
app.get('/ping', (req, res) => res.json({ ok: true, uptime: process.uptime() }));

// Self-update: git pull + queue UPDATE_ALL for CC computers + restart dashboard
app.post('/self-update', (req, res) => {
    exec('git pull origin master', { cwd: __dirname }, (err, stdout, stderr) => {
        const output = (stdout + stderr).trim();
        console.log('[SELF-UPDATE] git pull:\n' + output);

        // Queue UPDATE_ALL so CC computers update on the next bridge push
        pendingCommands.push({ type: 'UPDATE_ALL', params: {}, ts: Date.now() });
        console.log('[SELF-UPDATE] UPDATE_ALL queued for CC computers');

        res.json({ ok: true, output });

        // Wait for CC to pick up the command (bridge polls every 2s, use 5s buffer)
        // then exit — pm2 / nodemon / the start script will restart automatically.
        setTimeout(() => {
            console.log('[SELF-UPDATE] Exiting for restart...');
            process.exit(0);
        }, 5000);
    });
});

// Catch JSON parse errors from express.json()
app.use((err, req, res, next) => {
    console.log('[ERROR] middleware:', err.type, err.message?.slice(0, 80));
    res.status(400).json({ error: 'bad request' });
});

// ─── Start ───────────────────────────────────────────────────────────────────

app.listen(CFG.port, () => {
    console.log(`CC Dashboard bridge listening on http://localhost:${CFG.port}`);
    initMarkerSet();
});
