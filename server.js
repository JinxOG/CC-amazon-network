// server.js — CC Amazon Network bridge server
const express = require('express');
const { Rcon }  = require('rcon-client');
const path      = require('path');
const http      = require('http');
const fs        = require('fs');
const crypto    = require('crypto');
const { exec }  = require('child_process');

// Minimal .env loader — avoids pulling in dotenv for three values.
(function loadEnv() {
    const envPath = path.join(__dirname, '.env');
    if (!fs.existsSync(envPath)) return;
    for (const line of fs.readFileSync(envPath, 'utf8').split('\n')) {
        const m = line.match(/^\s*([A-Z0-9_]+)\s*=\s*(.*)\s*$/);
        if (m && !(m[1] in process.env)) process.env[m[1]] = m[2];
    }
})();

// Prevent unhandled rejections from crashing the process
process.on('unhandledRejection', (err) => {
    console.error('[ERROR] Unhandled rejection:', err && err.message || err);
});
process.on('uncaughtException', (err) => {
    console.error('[ERROR] Uncaught exception:', err && err.message || err);
});

const app = express();
app.use(express.json({ limit: '1mb' }));

// ─── Access control ──────────────────────────────────────────────────────────
// Trusted = loopback (in-game CC computers) and the local LAN (browsers on the
// home network). Anything arriving through the ngrok tunnel carries
// X-Forwarded-For — even though it reaches us from 127.0.0.1 — so it is treated
// as remote and must present Basic Auth credentials.

function isTrustedNetwork(req) {
    if (req.headers['x-forwarded-for'] || req.headers['x-real-ip']) return false;

    // Strip the IPv4-mapped IPv6 prefix (::ffff:192.168.1.5 -> 192.168.1.5)
    const addr = (req.socket.remoteAddress || '').replace(/^::ffff:/, '');

    if (addr === '127.0.0.1' || addr === '::1') return true;

    const m = addr.match(/^(\d+)\.(\d+)\.(\d+)\.(\d+)$/);
    if (!m) return false;
    const [a, b] = [Number(m[1]), Number(m[2])];

    if (a === 127) return true;                       // 127.0.0.0/8
    if (a === 10) return true;                        // 10.0.0.0/8
    if (a === 192 && b === 168) return true;          // 192.168.0.0/16
    if (a === 172 && b >= 16 && b <= 31) return true; // 172.16.0.0/12
    return false;
}

function safeEqual(a, b) {
    const ba = Buffer.from(String(a));
    const bb = Buffer.from(String(b));
    return ba.length === bb.length && crypto.timingSafeEqual(ba, bb);
}

app.use((req, res, next) => {
    if (req.path === '/ping') return next();
    if (isTrustedNetwork(req)) return next();

    const user = process.env.DASH_USER;
    const pass = process.env.DASH_PASS;
    if (!user || !pass) {
        console.error('[AUTH] DASH_USER/DASH_PASS unset — refusing remote request');
        return res.status(503).json({ error: 'auth not configured' });
    }

    const header = req.headers.authorization || '';
    if (header.startsWith('Basic ')) {
        const decoded = Buffer.from(header.slice(6), 'base64').toString('utf8');
        const idx = decoded.indexOf(':');
        if (idx !== -1 &&
            safeEqual(decoded.slice(0, idx), user) &&
            safeEqual(decoded.slice(idx + 1), pass)) {
            return next();
        }
    }

    console.warn(`[AUTH] Rejected ${req.method} ${req.path} from ${req.headers['x-forwarded-for'] || req.socket.remoteAddress}`);
    res.setHeader('WWW-Authenticate', 'Basic realm="cc-dashboard", charset="UTF-8"');
    res.status(401).json({ error: 'authentication required' });
});

// Serve index.html with no-cache so the browser always fetches the latest version
app.get('/', (req, res) => {
    res.setHeader('Cache-Control', 'no-cache, no-store, must-revalidate');
    res.setHeader('Pragma', 'no-cache');
    res.setHeader('Expires', '0');
    res.sendFile(path.join(__dirname, 'public', 'index.html'));
});

app.use(express.static(path.join(__dirname, 'public')));

// ─── Lua file server (used by turtles and androids for wget installs) ─────────
const LUA_WHITELIST = new Set([
    'protocol.lua', 'turtle_base.lua', 'waypoints.lua',
    'ore_turtle.lua', 'support_turtle.lua', 'delivery_turtle.lua',
    'android_base.lua', 'android_main.lua',
]);
app.get('/lua/:file', (req, res) => {
    const name = req.params.file;
    if (!LUA_WHITELIST.has(name)) return res.status(404).json({ error: 'not found' });
    const filePath = path.join(__dirname, name);
    if (!fs.existsSync(filePath)) return res.status(404).json({ error: 'file missing' });
    res.setHeader('Content-Type', 'text/plain');
    res.sendFile(filePath);
});

// ─── Config ──────────────────────────────────────────────────────────────────

const CFG = {
    port:        3000,
    rcon: {
        host:     '127.0.0.1',
        port:     25575,
        password: process.env.RCON_PASSWORD,
    },
    dynmap: {
        world:  'MODPACK',
        set:    'turtles',
    },
};

// ─── State ───────────────────────────────────────────────────────────────────

// ─── Named Locations ─────────────────────────────────────────────────────────

const LOCATIONS_FILE = path.join(__dirname, 'locations.json');
let locations = {};
try {
    if (fs.existsSync(LOCATIONS_FILE)) {
        locations = JSON.parse(fs.readFileSync(LOCATIONS_FILE, 'utf8'));
        console.log(`[LOCATIONS] Loaded ${Object.keys(locations).length} saved locations`);
    }
} catch (e) {
    console.error('[LOCATIONS] Failed to load:', e.message);
}

function saveLocations() {
    try { fs.writeFileSync(LOCATIONS_FILE, JSON.stringify(locations, null, 2)); }
    catch (e) { console.error('[LOCATIONS] Failed to save:', e.message); }
}

// ─── State ───────────────────────────────────────────────────────────────────

let state = {
    turtles:   {},   // { nodeId: { x, y, z, status, fuel, role, jobId, dock, online } }
    jobs:      [],   // job queue from CC server
    version:   null,
    storage:   [],   // RS storage snapshot [{name, displayName, amount, craftable}]
    storageTs: 0,    // unix ms when CC last successfully polled rsBridge.listItems()
    mineZones: {},   // { [jobId]: { bounds, total, done, pct, eta, oreFound, oreMined } }
    serverLog: [],   // last 100 log lines from CC server: [{ ts, level, msg }]
    players:   [],   // online players from Dynmap: [{ name, x, y, z, health, world }]
    locations,       // named delivery locations { [name]: { name, x, y, z } }
    updatedAt: null,

    // Seeded so /state has a stable shape before the first CC push lands.
    // The two health booleans start null, not true: on a cold bridge we have
    // not heard from the server yet, and "unknown" must not read as "healthy" —
    // that is the exact confusion Invariant K exists to prevent.
    oreThresholds:      {},
    turtleLogs:         {},
    recentFailures:     [],
    storageHealth:      {},
    zoneStoreHealthy:   null,
    persistenceHealthy: null,
    diskFree:           -1,
};

// Keys the CC server may never overwrite, whatever it sends.
//   locations — bridge-owned and persisted to disk here; no server-side counterpart
//   players   — sourced from Dynmap, not from CC
//   updatedAt — stamped by this handler
const BRIDGE_OWNED = new Set(['locations', 'players', 'updatedAt']);

// Keys with their own handling in /update below (marker diffing, type checks).
// Listed so the generic merge skips them rather than assigning twice.
const EXPLICITLY_MERGED = new Set([
    'turtles', 'jobs', 'version', 'storage', 'storageTs', 'mineZones', 'serverLog',
]);

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

// ─── Player position polling ─────────────────────────────────────────────────
// Dynmap's /up/world/<world>/0 returns player list with positions.

function refreshPlayers() {
    const url = `http://127.0.0.1:8123/up/world/${CFG.dynmap.world}/0`;
    http.get(url, (res) => {
        let raw = '';
        res.on('data', d => raw += d);
        res.on('end', () => {
            try {
                const data = JSON.parse(raw);
                state.players = (data.players || []).map(p => ({
                    name:   p.account,
                    x:      Math.round(p.x),
                    y:      Math.round(p.y),
                    z:      Math.round(p.z),
                    health: p.health,
                    world:  p.world,
                }));
            } catch (e) { /* dynmap unavailable — keep last known */ }
        });
    }).on('error', () => { /* dynmap unavailable — keep last known */ });
}

setInterval(refreshPlayers, 5000);
refreshPlayers();

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
const CC_RESTART_GAP_MS = 20 * 1000;  // >20s between updates → CC server restarted

app.post('/update', async (req, res) => {
    const { turtles, jobs, version, storage, storageTs, mineZones } = req.body || {};
    console.log(`[UPDATE] v=${version} turtles=${Object.keys(turtles||{}).length} storage=${Array.isArray(storage)?storage.length:'?'}`);
    if (!turtles && !jobs && !version) return res.status(400).json({ error: 'missing data' });

    const now = Date.now();

    // If the CC server was silent for >20s it almost certainly crashed and restarted.
    // Clear all stale bridge state so the dashboard doesn't show ghost turtles/jobs
    // from before the crash. The CC server will repopulate within a few seconds as
    // turtles re-register.
    if (state.updatedAt && (now - state.updatedAt) > CC_RESTART_GAP_MS) {
        const gapSec = Math.round((now - state.updatedAt) / 1000);
        console.log(`[UPDATE] CC server gap detected (${gapSec}s) — clearing stale state`);
        state.turtles   = {};
        state.jobs      = [];
        state.mineZones = {};
        markerExists    = {};
    }

    if (turtles) {
        // Incoming snapshot is authoritative — replace entirely so turtles absent
        // from the payload (e.g. after a CC server reboot) vanish immediately
        // rather than lingering until a 10-minute prune.
        const newTurtles = {};
        for (const [id, data] of Object.entries(turtles)) {
            newTurtles[id] = { ...state.turtles[id], ...data, lastSeen: now };
            if (data.online === false) {
                if (markerExists[id]) {
                    rcon(`dmarker delete id:${id} set:${CFG.dynmap.set}`).catch(() => {});
                    markerExists[id] = false;
                }
            } else {
                upsertMarker(id, newTurtles[id]).catch((e) => console.error('[RCON] upsertMarker uncaught:', e.message));
            }
        }
        // Remove dynmap markers for turtles that dropped off the snapshot
        for (const id of Object.keys(state.turtles)) {
            if (!newTurtles[id] && markerExists[id]) {
                rcon(`dmarker delete id:${id} set:${CFG.dynmap.set}`).catch(() => {});
                markerExists[id] = false;
            }
        }
        state.turtles = newTurtles;
    }

    if (jobs)                        state.jobs      = jobs;
    if (version)                     state.version   = version;
    if (Array.isArray(storage))      state.storage   = storage;
    if (typeof storageTs === 'number' && storageTs > 0) state.storageTs = storageTs;
    if (mineZones)                   state.mineZones = mineZones;
    if (Array.isArray(req.body?.serverLog)) state.serverLog = req.body.serverLog;

    // Everything else the server sends passes straight through.
    //
    // This used to be a whitelist, which meant a new server-side field reached an
    // operator only if someone remembered to add a line here. Seven did not get
    // one — including every Invariant K health signal — so the system could be
    // degraded and unable to say so while each component upstream believed it had
    // reported. Merging by default inverts the failure mode: a new field arrives
    // unstyled rather than not at all, which is the right direction for a signal
    // nobody goes looking for until something is already wrong.
    //
    // Bridge-owned keys stay protected: a stray `locations` in a payload would
    // otherwise wipe the operator's saved delivery points, which live only here.
    for (const [key, value] of Object.entries(req.body || {})) {
        if (BRIDGE_OWNED.has(key) || EXPLICITLY_MERGED.has(key)) continue;
        state[key] = value;
    }

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

    // ADD_LOCATION / REMOVE_LOCATION: handled entirely in the bridge — not forwarded to CC.
    if (type === 'ADD_LOCATION') {
        const { name, x, y, z } = params || {};
        if (!name || x == null || z == null) return res.status(400).json({ error: 'missing fields' });
        locations[name] = { name, x: parseInt(x), y: parseInt(y) || 67, z: parseInt(z) };
        saveLocations();
        console.log(`[LOCATION] Saved: ${name} @ ${x},${y||67},${z}`);
        return res.json({ ok: true });
    }
    if (type === 'REMOVE_LOCATION') {
        const { name } = params || {};
        if (name) { delete locations[name]; saveLocations(); console.log(`[LOCATION] Removed: ${name}`); }
        return res.json({ ok: true });
    }

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
