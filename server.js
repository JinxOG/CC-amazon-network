// server.js — CC Amazon Network bridge server
const express = require('express');
const { Rcon }  = require('rcon-client');
const path      = require('path');
const http      = require('http');
const fs        = require('fs');
const crypto    = require('crypto');
const { exec }  = require('child_process');
const readline  = require('readline');

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
// Errors that mean this process can never do its job must exit, not be logged
// and ignored. A swallowed EADDRINUSE leaves a process that failed to bind but
// keeps running -- a silent zombie holding no port and serving nothing. Two
// orphans (PIDs 3077167, 2423081) came from exactly that, and it recurs on every
// accidental double-start. P7: degraded with no way to say so.
const FATAL_ERRNO = new Set(['EADDRINUSE', 'EACCES', 'EADDRNOTAVAIL']);
process.on('uncaughtException', (err) => {
    if (err && FATAL_ERRNO.has(err.code)) {
        console.error(`[FATAL] ${err.code}: ${err.message}`);
        console.error('[FATAL] cannot serve — exiting rather than lingering as a zombie.');
        process.exit(1);
    }
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

    if (a === 127) return true;                        // 127.0.0.0/8
    if (a === 10) return true;                         // 10.0.0.0/8
    if (a === 192 && b === 168) return true;           // 192.168.0.0/16
    if (a === 172 && b >= 16 && b <= 31) return true;  // 172.16.0.0/12

    // 100.64.0.0/10 — the Tailscale tailnet. Devices here are already
    // authenticated by Tailscale itself before a packet reaches us. Note this
    // range is CGNAT: it is only safe to trust because nothing routes to this
    // host from a carrier network, and it must be dropped if that ever changes.
    if (a === 100 && b >= 64 && b <= 127) return true;

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

// The RCON password is read from the environment and has no default. It used to
// be a literal in this file, in a public repository. Rotation makes the old value
// worthless; only removing it stops the next one being committed the same way.
// Set RCON_PASSWORD in the environment (the host loads it from .env).
//
// Unset is not fatal: RCON only drives Dynmap markers, so the bridge runs without
// it. But it says so once, loudly, rather than retrying a bad login forever --
// a marker that silently stops updating looks identical to a turtle not moving.
const RCON_PASSWORD = process.env.RCON_PASSWORD || null;
if (!RCON_PASSWORD) {
    console.warn('[WARN] RCON_PASSWORD is not set — Dynmap marker updates are disabled.');
    console.warn('[WARN] Everything else (dashboard, /state, /command) works normally.');
}

const CFG = {
    port:        Number(process.env.PORT) || 3000,
    rcon: {
        host:     process.env.RCON_HOST || '127.0.0.1',
        port:     Number(process.env.RCON_PORT) || 25575,
        password: RCON_PASSWORD,
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
    serverLog: [],   // rolling display buffer, appended from each push's delta
    turtleLogs: {},  // [nodeId] = rolling display buffer, same shape
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
    'turtleLogs',
]);

// This bridge's boot identity, sent with every /update reply.
//
// The display buffers below live in memory and die with the process, but the CC
// server's logAck survives in ITS memory -- so after a bridge restart it would
// keep sending only what is new, and the panel would stay blank until the fleet
// happened to say something. Seeing this change is how it knows to replay.
//
// A timestamp rather than a counter, for the same reason the log bootIds are:
// comparable, no state on disk, and two boots cannot collide.
const BRIDGE_BOOT_ID = Date.now();

let pendingCommands = [];   // commands queued by dashboard, picked up by CC on next poll
let markerExists    = {};   // track which turtle markers already exist on Dynmap

// ─── Continuous log to disk (Phase 1 of W3's 2026-09-07 memo) ────────────────
//
// The CC server already captures its own log and every turtle's print() output,
// and already ships a slice of both in the /update payload. Nothing wrote it
// down. This does, on the only disk in the system with room for it — the CC
// computer has 1 MB, and this is order of 10 MB/day.
//
// The hard constraint is that none of it may delay the /update response. The CC
// server is synchronous: time spent answering is time it is deaf to the radio,
// which is what loses heartbeats. So this queues formatted lines in memory and
// returns; a single writer drains the queue behind the response.

const LOG_DIR             = path.join(__dirname, 'logs');
const LOG_RETENTION_DAYS  = 14;
// Display buffers for /state. Separate from the file on disk: the file is the
// record, these are what the dashboard's log panel renders.
const LOG_DISPLAY_MAX     = 200;    // server lines kept for the panel
const TURTLE_DISPLAY_MAX  = 30;     // per node
const LOG_DEDUPE_MAX      = 5000;   // ~75 min at two-miner volume. Only needs to
                                    // outlast the re-send window, which is seconds.
const LOG_PRUNE_INTERVAL  = 6 * 60 * 60 * 1000;

try { fs.mkdirSync(LOG_DIR, { recursive: true }); }
catch (e) { console.error('[LOG] Cannot create log directory:', e.message); }

let logQueue   = [];
let logCurrentDay  = null;   // drives the current.txt symlink
let logSymlinkWarned = false;
let logWriting = false;

// ─── Bridge busy periods (W1's proposals 1 and 2, 2026-09-09) ────────────────
//
// W1 measured 561 fleet-wide disconnects that cluster: 30 clusters hitting eight
// or more nodes within five seconds. Everyone loses the dispatch server at the
// same instant, which rules out anything per-turtle. The mechanism on the table
// is the one W3 documented -- bridge busy => CC server waiting => CC server deaf
// -- and it predicts that clusters land INSIDE bridge-busy windows.
//
// That prediction is worth nothing until the busy windows are written down, so
// this writes them down. Two rules shape it:
//
// 1. A LINE PER PUSH WOULD BE 28,800 LINES A DAY on a system already suspected
//    of being hurt by log volume, so only slow pushes get their own line.
// 2. BUT SILENCE MUST NOT BE AMBIGUOUS. If slow pushes were the only output,
//    "no slow lines" would mean either "the bridge was never busy" or "the
//    instrumentation is broken", and those must never look alike -- that shape
//    is now three-for-three in this project. So a rollup is emitted every
//    interval unconditionally, carrying its own denominator. Its ABSENCE means
//    the instrumentation is down; a rollup of zeros is a real measurement.
//
// The rollup separates total handler time from time spent inside the log system.
// That is proposal 2 answered with a number instead of a code reading: W3
// believes the log writer costs the push handler nothing, and `log_share` either
// agrees or does not.

const BUSY_SLOW_PUSH_MS = 100;      // a push at least this slow gets its own line
const BUSY_ROLLUP_MS    = 60 * 1000;

function freshBusy() {
    return {
        pushes: 0, slowPushes: 0, pushMsTotal: 0, pushMsMax: 0,
        logMsTotal: 0, logMsMax: 0,
        writes: 0, writeMsTotal: 0, writeMsMax: 0, writeBytes: 0,
        queueMax: 0,
    };
}
let busy = freshBusy();

// Bridge-authored lines carry their own source and sequence. A separate source
// from `server` so they never mix into the CC server's continuity audit, and
// sequenced so the instrumentation is itself auditable -- the one thing worse
// than no busy data is busy data with silent holes in it.
let bridgeSeq = 0;

function logLocal(level, msg) {
    bridgeSeq++;
    logQueue.push(logFormatLine('bridge', { ts: Date.now(), level, msg, seq: bridgeSeq }));
    flushLogQueue();
}

function recordPush(totalMs, logMs) {
    busy.pushes++;
    busy.pushMsTotal += totalMs;
    busy.logMsTotal  += logMs;
    if (totalMs > busy.pushMsMax) busy.pushMsMax = totalMs;
    if (logMs   > busy.logMsMax)  busy.logMsMax  = logMs;
    if (logQueue.length > busy.queueMax) busy.queueMax = logQueue.length;

    if (totalMs >= BUSY_SLOW_PUSH_MS) {
        busy.slowPushes++;
        // Timestamped by the log itself, so `?node=bridge&contains=slow push`
        // gives W1 the busy windows to correlate disconnect clusters against.
        logLocal('WARN', `slow push: ${totalMs.toFixed(1)}ms total, `
            + `${logMs.toFixed(1)}ms of it in the log system, queue=${logQueue.length}`);
    }
}

// Kept for /state so the dashboard can show the current picture without parsing
// the log back. Null until the first rollup: "not measured yet" is not "zero".
let lastBusyRollup = null;

function emitBusyRollup() {
    const b = busy;
    busy = freshBusy();

    const avg = (total, n) => (n > 0 ? total / n : 0);
    const pushAvg = avg(b.pushMsTotal, b.pushes);
    const logAvg  = avg(b.logMsTotal,  b.pushes);
    // What share of the bridge's own busy time the log system accounts for.
    const logShare = b.pushMsTotal > 0 ? (b.logMsTotal / b.pushMsTotal) * 100 : null;

    lastBusyRollup = {
        at: Date.now(),
        windowMs: BUSY_ROLLUP_MS,
        pushes: b.pushes, slowPushes: b.slowPushes,
        pushMsAvg: +pushAvg.toFixed(2), pushMsMax: +b.pushMsMax.toFixed(2),
        logMsAvg: +logAvg.toFixed(2),   logMsMax: +b.logMsMax.toFixed(2),
        logSharePct: logShare === null ? null : +logShare.toFixed(1),
        writes: b.writes,
        writeMsAvg: +avg(b.writeMsTotal, b.writes).toFixed(2),
        writeMsMax: +b.writeMsMax.toFixed(2),
        writeKb: +(b.writeBytes / 1024).toFixed(1),
        queueMax: b.queueMax,
    };

    if (b.pushes === 0 && b.writes === 0) {
        // Emitted anyway, and this is the whole point: it distinguishes "the
        // bridge was idle" from "the instrumentation stopped".
        logLocal('INFO', 'busy rollup: pushes=0 writes=0 — bridge received nothing this interval');
        return;
    }

    logLocal('INFO', 'busy rollup: '
        + `pushes=${b.pushes} slow=${b.slowPushes} `
        + `push_ms_avg=${pushAvg.toFixed(1)} push_ms_max=${b.pushMsMax.toFixed(1)} `
        + `log_ms_avg=${logAvg.toFixed(1)} log_ms_max=${b.logMsMax.toFixed(1)} `
        + `log_share=${logShare === null ? 'n/a' : logShare.toFixed(1) + '%'} `
        + `writes=${b.writes} write_ms_max=${b.writeMsMax.toFixed(1)} `
        + `write_kb=${(b.writeBytes / 1024).toFixed(1)} queue_max=${b.queueMax}`);
}

// One append in flight at a time. fs.appendFile does not order concurrent
// callers, so two pushes landing during a disk stall could interleave and
// corrupt the one-entry-per-line property the whole file exists for. Draining
// through a single writer also means a slow disk grows this queue instead of
// ever reaching the response path.
function flushLogQueue() {
    if (logWriting || logQueue.length === 0) return;
    logWriting = true;

    const batch = logQueue.join('');
    logQueue = [];

    // UTC, deliberately and permanently: the timestamps INSIDE the file are
    // ISO-8601 UTC, and a file whose name and contents disagree about which day
    // it is would be a worse trap than the one this convention caused.
    const day  = new Date().toISOString().slice(0, 10);
    const file = path.join(LOG_DIR, `${day}.txt`);
    // ...but nobody should have to know that to read the log.
    //
    // The documented check was `tail ~/cc-dashboard/logs/$(date +%F).txt`, and
    // `date +%F` is LOCAL. West of UTC those disagree for the last hours of every
    // day, so the command silently read yesterday's finished file and returned
    // real, correctly-formatted, hours-old lines. The maintainer hit it on
    // 2026-09-09 checking the new sequence field, saw seq:null on every line
    // (they were pre-1.9.88 lines from the previous UTC day), and was about to
    // report a working feature broken.
    //
    // A check that can return success as failure is worse than no check. So the
    // date comes out of the human path entirely: current.txt always points at
    // the file being written.
    if (day !== logCurrentDay) {
        logCurrentDay = day;
        // ASYNC, and the callbacks are the point rather than tidiness.
        //
        // This was existsSync/unlinkSync/symlinkSync. W5 caught it on 2026-09-09
        // while answering whether the log system blocks the push handler: it is
        // guarded to fire once per UTC day, so it is not a per-push cost, but on
        // a day boundary it blocked the one thread that answers /update -- and
        // that thread going quiet is the exact failure this whole investigation
        // is about. A few milliseconds once a day is not a stall; putting a
        // synchronous filesystem call on that path while hunting one is still
        // indefensible.
        //
        // Nothing waits on the result: current.txt is a convenience for humans,
        // so it can land whenever it lands.
        const link = path.join(LOG_DIR, 'current.txt');
        fs.unlink(link, () => {
            fs.symlink(`${day}.txt`, link, (err) => {
                if (err && !logSymlinkWarned) {
                    // Degrade quietly rather than failing the write: a filesystem
                    // without symlinks still gets a correct dated log.
                    logSymlinkWarned = true;
                    console.error('[LOG] could not maintain current.txt:', err.message);
                }
            });
        });
    }

    // Timed so W1 can see whether the disk itself ever stalls. This callback runs
    // on the main thread, but the write behind it does not: fs.appendFile hands
    // the I/O to libuv's threadpool, which is the distinction proposal 2 turns on.
    const writeStart = process.hrtime.bigint();
    fs.appendFile(file, batch, (err) => {
        const writeMs = Number(process.hrtime.bigint() - writeStart) / 1e6;
        busy.writes++;
        busy.writeMsTotal += writeMs;
        busy.writeBytes   += batch.length;
        if (writeMs > busy.writeMsMax) busy.writeMsMax = writeMs;

        logWriting = false;
        if (err) console.error('[LOG] append failed:', err.message);
        if (logQueue.length) flushLogQueue();
    });
}

// Overlapping windows arrive every 3s, so the same line is delivered many times.
// Keyed on (source, ts, msg) today; on (source, bootId, seq) the moment W3's
// Phase 2 adds them, which is the one forward-compatibility they asked for.
const logSeen      = new Set();
const logSeenOrder = [];

function logDedupeKey(source, entry) {
    if (entry.seq != null) return `${source}|${entry.bootId ?? ''}|${entry.seq}`;
    return `${source}|${entry.ts}|${entry.msg}`;
}

function logAlreadyWritten(key) {
    if (logSeen.has(key)) return true;
    logSeen.add(key);
    logSeenOrder.push(key);
    if (logSeenOrder.length > LOG_DEDUPE_MAX) {
        for (const k of logSeenOrder.splice(0, logSeenOrder.length - LOG_DEDUPE_MAX)) {
            logSeen.delete(k);
        }
    }
    return false;
}

// Highest sequence seen per source, for the Phase 2 ack. Populated only once W3
// ships `seq`; until then it stays empty and no ack is sent.
const logSeqHigh = {};

function logNoteSeq(source, entry) {
    if (entry.seq == null) return;
    const cur = logSeqHigh[source];
    // A reboot restarts seq at 1 under a new bootId, so a changed bootId adopts
    // the new boot's numbering rather than treating 1 as "older".
    if (!cur || cur.bootId !== (entry.bootId ?? null)) {
        logSeqHigh[source] = { bootId: entry.bootId ?? null, seq: entry.seq };
    } else if (entry.seq > cur.seq) {
        cur.seq = entry.seq;
    }
}

// ─── Live loss accounting (W1's proposal 5) ──────────────────────────────────
//
// W1 found 19% of lines missing by running ?audit=1, and observed that a figure
// nobody sees is how it went unnoticed until someone audited for an unrelated
// reason. So the loss rate becomes a live number the dashboard can render.
//
// Counted here rather than by re-running the file audit on a timer, because that
// audit streams the whole day file -- 10 MB and growing -- on the one thread
// that must also answer /update every three seconds. Paying that repeatedly to
// display a number would risk causing the very stall W1 is asking us to measure.
// These counters are free: the sequences are already in hand.
//
// MIN/MAX/COUNT, not a running previous-value. Missing is
// (max - min + 1) - count, which does not care what order lines arrive in. That
// matters because W3's 1.9.89 retry deliberately re-sends a withheld batch, and
// a running-prev counter would book those as loss and never un-book them when
// they landed. This self-corrects when a hole is filled later.
const logContinuity = {};

function logNoteContinuity(source, entry) {
    if (entry.seq == null) return;
    const boot = entry.bootId ?? null;
    let c = logContinuity[source];
    // A reboot restarts the sequence, so each boot is accounted separately and
    // the restart is never mistaken for a 40,000-line gap.
    if (!c || c.bootId !== boot) {
        c = logContinuity[source] = {
            bootId: boot, min: entry.seq, max: entry.seq, count: 0,
            reboots: c ? c.reboots + 1 : 0,
        };
    }
    if (entry.seq < c.min) c.min = entry.seq;
    if (entry.seq > c.max) c.max = entry.seq;
    c.count++;
}

function logLossSummary() {
    let received = 0, expected = 0;
    const sources = {};
    for (const [src, c] of Object.entries(logContinuity)) {
        const span = c.max - c.min + 1;
        const missing = Math.max(0, span - c.count);
        received += c.count;
        expected += span;
        sources[src] = {
            received: c.count, missing, reboots: c.reboots,
            lossPct: span > 0 ? +((missing / span) * 100).toFixed(1) : null,
        };
    }
    const missing = Math.max(0, expected - received);
    return {
        since: BRIDGE_BOOT_ID,
        received, expected, missing,
        // NULL, NOT ZERO, when nothing sequenced has arrived. A dashboard
        // rendering 0% for "no data" is the same trap W1 walked into: a pass
        // state indistinguishable from a no-data state.
        lossPct: expected > 0 ? +((missing / expected) * 100).toFixed(1) : null,
        sources,
    };
}

// Turtle entries carry no `level` field — the level is inside the message, which
// turtles capture from print() verbatim as `[node_118][INFO] ...`. Lifting it
// into its own column is what makes `grep WARN` find turtle warnings and not
// just server ones; without it the column would be server-only and requirement 1
// would be half met.
const LOG_LEVEL_RE = /^\[[^\]]*\]\[([A-Z]+)\]/;

function logLevelOf(entry) {
    if (typeof entry.level === 'string' && entry.level) return entry.level;
    const m = LOG_LEVEL_RE.exec(String(entry.msg ?? ''));
    return m ? m[1] : '-';
}

function logFormatLine(source, entry) {
    const ts = Number.isFinite(entry.ts)
        ? new Date(entry.ts).toISOString()
        : new Date().toISOString();
    // Newlines collapsed: one entry must be exactly one line, or grep reports a
    // match at a line that does not show the node it came from.
    const msg = String(entry.msg ?? '').replace(/\r?\n/g, ' ');
    // The sequence is written into the line, joined to the source with '#'.
    //
    // Without it the file cannot be AUDITED. Delivery was provable live -- send
    // a probe and watch it land -- but nobody could open yesterday's log and
    // show that nothing went missing, which is the question you actually want to
    // ask of a log. The number already existed; it was used for de-duplication
    // and then thrown away at formatting time.
    //
    // Joined to the source rather than given its own column, so `grep node_118`
    // and `grep WARN` both keep working unchanged.
    //
    // No bootId in the line: a reboot restarts seq at 1, so a DECREASE is a
    // reboot and a FORWARD SKIP is a gap. That inference needs no extra field
    // and no marker line.
    const src = entry.seq != null ? `${source}#${entry.seq}` : source;
    return `${ts}  ${src.padEnd(14)} ${logLevelOf(entry).padEnd(6)} ${msg}\n`;
}

// Repair UTF-8 that arrived one byte per character.
//
// NOT a bridge bug. CC's textutils.serialiseJSON escapes a Lua string BYTE by
// byte -- Lua strings are byte strings and it treats each byte as a codepoint --
// so an em-dash leaves Minecraft as â and arrives here as three
// perfectly legitimate characters. This writer was recording exactly what it was
// given. Verified from the live log on 2026-09-09: 0xe2 0x80 0x94, which is the
// em-dash's UTF-8 encoding expanded into three Latin-1 codepoints.
//
// The expansion is exactly reversible, so this reverses it rather than papering
// over it: map the codepoints back to bytes, decode as UTF-8.
//
// GUARDED BOTH WAYS. Untouched unless the string actually contains a character
// in the 0x80-0xFF range, and the result is discarded unless it decodes as valid
// UTF-8. A string that is already correct cannot be damaged by this.
function repairMojibake(str) {
    if (typeof str !== 'string' || !/[\u0080-\u00ff]/.test(str)) return str;
    // Anything above 0xFF means this was never byte-expanded Latin-1.
    if (/[^\u0000-\u00ff]/.test(str)) return str;
    const decoded = Buffer.from(str, 'latin1').toString('utf8');
    return decoded.includes('\uFFFD') ? str : decoded;
}

// Applied ONCE to the incoming payload, before either consumer reads it: the
// file writer and the /state display buffers both take their text from here, and
// repairing in one of them would leave the other showing mojibake.
function repairIncomingLogs(body) {
    for (const e of (Array.isArray(body?.serverLog) ? body.serverLog : [])) {
        if (e && typeof e === 'object') e.msg = repairMojibake(e.msg);
    }
    const tl = body?.turtleLogs;
    if (tl && typeof tl === 'object') {
        for (const entries of Object.values(tl)) {
            for (const e of (Array.isArray(entries) ? entries : [])) {
                if (e && typeof e === 'object') e.msg = repairMojibake(e.msg);
            }
        }
    }
}

function ingestLogs(body) {
    const lines = [];

    const take = (source, entries) => {
        if (!Array.isArray(entries)) return;
        for (const e of entries) {
            if (!e || typeof e !== 'object') continue;
            logNoteSeq(source, e);
            if (logAlreadyWritten(logDedupeKey(source, e))) continue;
            // AFTER the dedupe check, unlike logNoteSeq above. A re-sent delta
            // (an ack that did not reach the server) delivers the same line
            // twice; counting it twice would inflate `count` past the sequence
            // span and report negative loss. The ack high-water mark above is
            // idempotent and can safely see duplicates; this cannot.
            logNoteContinuity(source, e);
            lines.push(logFormatLine(source, e));
        }
    };

    take('server', body.serverLog);

    if (body.turtleLogs && typeof body.turtleLogs === 'object') {
        for (const [nodeId, entries] of Object.entries(body.turtleLogs)) take(nodeId, entries);
    }

    if (lines.length === 0) return;

    // Every line starts with an ISO-8601 timestamp, which sorts lexicographically
    // in chronological order — so this reads as a timeline rather than as
    // server-then-turtles.
    lines.sort();
    logQueue.push(...lines);
    flushLogQueue();
}

// Deletes only files this module creates: an exact YYYY-MM-DD.txt name. Anything
// else an operator leaves in the directory is left alone.
function pruneOldLogs() {
    fs.readdir(LOG_DIR, (err, files) => {
        if (err) return;
        const cutoff = Date.now() - LOG_RETENTION_DAYS * 86400000;
        for (const f of files) {
            const m = /^(\d{4}-\d{2}-\d{2})\.txt$/.exec(f);
            if (!m) continue;
            if (new Date(`${m[1]}T00:00:00Z`).getTime() < cutoff) {
                fs.unlink(path.join(LOG_DIR, f), () => {});
            }
        }
    });
}

// ─── RCON ────────────────────────────────────────────────────────────────────
// PERF #58: Persistent singleton connection — reuse across calls instead of
// creating a new TCP connection for every marker write.

let rconClient = null;

async function getRcon() {
    // Short-circuit when no password is configured, so we don't attempt (and log)
    // a failed login on every marker update.
    if (!CFG.rcon.password) throw new Error('RCON disabled: RCON_PASSWORD not set');
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
    // Wall-clock from handler entry to response sent. Express has already parsed
    // the body by this point, so this does not capture JSON parsing -- worth
    // knowing when reading the number, since a ~190 KB payload is not free.
    const pushStart = process.hrtime.bigint();
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
    // ACCUMULATE, do not replace. W3's Phase 2 (1.9.85) changed what these two
    // fields mean: they were "the last N lines", a window safe to overwrite with,
    // and they are now "what the bridge has not acknowledged writing" -- a delta.
    // Once the ack loop closes that is normally empty, so replacing the display
    // copy with it blanked the dashboard's log panel: observed live at 1.9.85
    // with serverLog down to one entry and turtleLogs to none at all.
    //
    // The file on disk is unaffected either way -- ingestLogs() has already taken
    // these lines and it is the durable record. These buffers exist only so
    // /state can still render a recent view without reading the file back.
    //
    // A re-sent delta (an ack that did not reach the server) can duplicate a line
    // here. That is cosmetic in a scrolling panel and not worth carrying seq
    // state for; the file's own dedupe is where correctness lives.
    if (Array.isArray(req.body?.serverLog) && req.body.serverLog.length) {
        state.serverLog = state.serverLog
            .concat(req.body.serverLog)
            .slice(-LOG_DISPLAY_MAX);
    }
    if (req.body?.turtleLogs && typeof req.body.turtleLogs === 'object') {
        if (!state.turtleLogs || typeof state.turtleLogs !== 'object') state.turtleLogs = {};
        for (const [id, entries] of Object.entries(req.body.turtleLogs)) {
            if (!Array.isArray(entries) || entries.length === 0) continue;
            const cur = Array.isArray(state.turtleLogs[id]) ? state.turtleLogs[id] : [];
            state.turtleLogs[id] = cur.concat(entries).slice(-TURTLE_DISPLAY_MAX);
        }
    }

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

    // Bracketed so the log system's share of this handler is measurable rather
    // than argued about — proposal 2. Both calls are CPU on this thread; only
    // the disk write they queue happens elsewhere.
    const logStart = process.hrtime.bigint();

    // Before both consumers: the file writer and the display buffers below.
    try { repairIncomingLogs(req.body || {}); }
    catch (e) { console.error('[LOG] repair failed:', e.message); }

    // Queues formatted lines and returns immediately — the disk write happens
    // behind the response. Never await this: see the note on LOG_DIR above.
    try { ingestLogs(req.body || {}); }
    catch (e) { console.error('[LOG] ingest failed:', e.message); }

    const logMs = Number(process.hrtime.bigint() - logStart) / 1e6;

    // `logAck` rides as a sibling of `commands`, not inside it: `commands` is a
    // list the CC server iterates and dispatches, so a non-command entry there
    // would have to be filtered by every consumer. Sent only once W3's Phase 2
    // starts attaching `seq`, so today it is absent rather than an empty object.
    const reply = { ok: true, commands: pendingCommands.splice(0),
                    bridgeBootId: BRIDGE_BOOT_ID };
    if (Object.keys(logSeqHigh).length > 0) reply.logAck = logSeqHigh;
    res.json(reply);

    // After the response, deliberately: recording must never be on the path the
    // CC server waits on. res.json() has already handed the bytes to the socket,
    // so the timing includes serialisation but the accounting costs the server
    // nothing.
    recordPush(Number(process.hrtime.bigint() - pushStart) / 1e6, logMs);
});

// Dashboard reads current state
// ─── Log query API ───────────────────────────────────────────────────────────
//
// The file is the record, but an agent diagnosing something cannot read a file
// on this host -- it can only speak HTTP to this bridge, which is how every
// other question about the fleet already gets answered.
//
// STREAMED, NEVER READ WHOLE. A day's file is 129 KB today and the measured
// volume is ~10 MB/day with two miners working. readFileSync on that would block
// the event loop, and this process also answers POST /update every 3 seconds --
// time spent blocked there is time the CC server waits, and a CC server waiting
// is a CC server deaf to its own radio. That is the mechanism behind every
// dropped heartbeat this system has had. So: readline over a stream, filtering
// as it goes, holding only the result window in memory.

const LOG_QUERY_DEFAULT = 500;
const LOG_QUERY_MAX     = 5000;
// Below this many SEQUENCED lines, an audit's "no gaps" carries no
// information. Chosen to be larger than any single turtle's push window
// so a clean answer has actually seen continuity, not one lucky line.
const AUDIT_MIN_LINES   = 50;

// "2026-09-08T08:02:49.923Z  server    WARN   message text"
const LOG_LINE_RE = /^(\S+)\s{2}(\S+)\s+(\S+)\s+([\s\S]*)$/;

function parseLogLine(line) {
    const m = LOG_LINE_RE.exec(line);
    if (!m) return null;
    // `source#seq` since 1.9.88; a bare source is a line written before that,
    // or one from a node too old to send a sequence. Both must still parse -- a
    // log you cannot read the old half of is not much of a log.
    const hash = m[2].lastIndexOf('#');
    const source = hash > 0 ? m[2].slice(0, hash) : m[2];
    const seqRaw = hash > 0 ? Number(m[2].slice(hash + 1)) : NaN;
    return {
        ts: m[1], source, level: m[3], msg: m[4],
        seq: Number.isFinite(seqRaw) ? seqRaw : null,
    };
}

// Only ever a date this module could have produced. Without this, `date` is a
// path fragment and ../../etc/passwd is a valid one.
function logFileFor(date) {
    if (!/^\d{4}-\d{2}-\d{2}$/.test(date)) return null;
    return path.join(LOG_DIR, `${date}.txt`);
}

app.get('/logs', (req, res) => {
    fs.readdir(LOG_DIR, (err, files) => {
        if (err) return res.status(500).json({ error: 'cannot read log directory' });
        const days = files
            .filter(f => /^\d{4}-\d{2}-\d{2}\.txt$/.test(f))
            .sort()
            .map(f => {
                let size = null;
                try { size = fs.statSync(path.join(LOG_DIR, f)).size; } catch { /* raced a prune */ }
                return { date: f.slice(0, 10), bytes: size };
            });
        res.json({ dir: LOG_DIR, retentionDays: LOG_RETENTION_DAYS,
                   // Stated rather than left to be worked out from a
                   // timestamp mismatch, which is how it was found.
                   filenames: 'UTC date; use /logs/latest or logs/current.txt to avoid guessing',
                   todayUtc: new Date().toISOString().slice(0, 10),
                   days });
    });
});

app.get('/logs/:date', (req, res) => {
    // `latest` and `today` resolve here rather than in the caller. Every client
    // that computes a date itself can compute the WRONG one -- see the note in
    // flushLogQueue -- and the failure is silent because the wrong file is a
    // real file full of real lines.
    //
    // `latest` is the newest file that exists; `today` is the current UTC day.
    // They differ only just after a rollover, when today's file has no lines
    // yet, and `latest` is the more useful answer there.
    let dateParam = req.params.date;
    if (dateParam === 'latest' || dateParam === 'today') {
        let days = [];
        try {
            days = fs.readdirSync(LOG_DIR)
                .filter(f => /^\d{4}-\d{2}-\d{2}\.txt$/.test(f)).sort();
        } catch { /* handled below */ }
        const todayUtc = new Date().toISOString().slice(0, 10);
        if (dateParam === 'today') dateParam = todayUtc;
        else if (days.length) dateParam = days[days.length - 1].slice(0, 10);
        else dateParam = todayUtc;
    }
    const file = logFileFor(dateParam);
    if (!file) return res.status(400).json({ error: 'date must be YYYY-MM-DD' });
    if (!fs.existsSync(file)) return res.status(404).json({ error: 'no log for that date' });

    const q        = req.query;
    const source   = q.node   ? String(q.node)               : null;
    const level    = q.level  ? String(q.level).toUpperCase(): null;
    const contains = q.contains ? String(q.contains)         : null;
    const since    = q.since  ? String(q.since)              : null;
    const until    = q.until  ? String(q.until)              : null;
    const head     = String(q.order || 'tail') === 'head';
    const asText   = String(q.format || 'json') === 'text';
    let limit = parseInt(q.limit, 10);
    if (!Number.isFinite(limit) || limit <= 0) limit = LOG_QUERY_DEFAULT;
    limit = Math.min(limit, LOG_QUERY_MAX);

    // Timestamps are ISO-8601 in the file, which sorts lexicographically in
    // chronological order -- so a string compare IS a time compare, and callers
    // can pass a bare date, a whole timestamp, or anything in between.
    const out = [];
    let matched = 0;
    const audit = String(q.audit || '') === '1';
    const seen = {};   // source -> continuity state, only for audit

    const rl = readline.createInterface({
        input: fs.createReadStream(file, { encoding: 'utf8' }),
        crlfDelay: Infinity,
    });

    rl.on('line', (line) => {
        if (!line) return;
        const e = parseLogLine(line);
        if (!e) return;
        if (source   && e.source !== source)            return;
        if (level    && e.level  !== level)             return;
        if (since    && e.ts < since)                   return;
        if (until    && e.ts > until)                   return;
        if (contains && !e.msg.includes(contains))      return;
        matched++;
        if (audit) {
            // Only lines that carry a sequence can be audited. Lines written
            // before 1.9.88, or by a node too old to send one, are counted but
            // contribute no continuity claim -- saying "no gaps" about lines
            // that cannot show one would be worse than saying nothing.
            const st = seen[e.source] || (seen[e.source] =
                { n: 0, unsequenced: 0, first: null, last: null,
                  gaps: 0, missing: 0, reboots: 0, prev: null });
            st.n++;
            if (e.seq == null) { st.unsequenced++; return; }
            if (st.first === null) st.first = e.seq;
            st.last = e.seq;
            if (st.prev !== null) {
                if (e.seq < st.prev) st.reboots++;
                else if (e.seq > st.prev + 1) {
                    st.gaps++;
                    st.missing += e.seq - st.prev - 1;
                }
            }
            st.prev = e.seq;
            return;   // audit counts lines; it does not collect them
        }
        out.push(e);
        // Head stops early; tail keeps a sliding window so memory stays bounded
        // however large the file is.
        if (head && out.length >= limit) rl.close();
        else if (!head && out.length > limit) out.shift();
    });

    rl.on('close', () => {
        if (audit) {
            // Per-source continuity. Computed HERE rather than by the caller,
            // because the alternative is pulling every line of a 10 MB file
            // across the network to count them -- which is exactly the work
            // this endpoint exists to avoid, and which this bridge does instead
            // of answering the dispatch server.
            // AN AUDIT MUST REPORT ITS OWN SUFFICIENCY.
            //
            // Without this, a window containing one line returns `gaps: 0` and
            // reads exactly like a window containing ten thousand clean ones.
            // The endpoint could not distinguish "delivery is working" from
            // "nothing was delivered because nothing happened", and the caller
            // had to know to check `scanned` by hand -- which is the manual
            // re-proving this endpoint exists to end.
            //
            // Named by the server maintainer on 2026-09-09 as the THIRD
            // instance of one shape: a check whose pass state is
            // indistinguishable from its no-data state. The other two were an
            // empty display buffer read as a broken feature, and a local-date
            // filename reading yesterday's finished file.
            const minLines = Math.max(1, parseInt(q.minLines, 10) || AUDIT_MIN_LINES);
            const out2 = {};
            let sequencedTotal = 0;
            for (const [src, st] of Object.entries(seen)) {
                const sequenced = st.n - st.unsequenced;
                sequencedTotal += sequenced;
                out2[src] = {
                    lines: st.n,
                    // Reported, not just counted. A source whose lines all
                    // predate 1.9.88 shows gaps:0 -- and that zero is a
                    // statement about nothing.
                    sequenced,
                    unsequenced: st.unsequenced,
                    first: st.first,
                    last: st.last,
                    // A FORWARD skip is loss. A DECREASE is a reboot -- seq
                    // restarts at 1 -- and is reported separately so it is never
                    // mistaken for a gap.
                    gaps: st.gaps,
                    missing: st.missing,
                    reboots: st.reboots,
                    // Does THIS source's zero mean anything?
                    conclusive: sequenced >= minLines,
                };
            }
            const insufficient = sequencedTotal < minLines;
            return res.json({
                file: path.basename(file),
                scanned: matched,
                sequenced: sequencedTotal,
                minLines,
                insufficient,
                verdict: insufficient ? 'insufficient'
                       : (Object.values(out2).some(v => v.gaps > 0) ? 'gaps' : 'clean'),
                note: insufficient
                    ? `only ${sequencedTotal} sequenced line(s) in this window — `
                      + 'too few to conclude anything. Widen the window, or give '
                      + 'the fleet something to do and audit with ?since= the '
                      + 'moment it started.'
                    : undefined,
                sources: out2,
            });
        }
        if (asText) {
            res.type('text/plain').send(out.map(e =>
                `${e.ts}  ${e.source.padEnd(9)} ${e.level.padEnd(6)} ${e.msg}`).join('\n'));
        } else {
            res.json({
                file: path.basename(file),
                matched,                       // before the limit was applied
                returned: out.length,
                truncated: matched > out.length,
                order: head ? 'head' : 'tail',
                lines: out,
            });
        }
    });

    rl.on('error', () => res.status(500).json({ error: 'cannot read log file' }));
});

app.get('/state', (req, res) => {
    // Computed per request rather than stored: both are small derivations over
    // ~15 sources, and a stale copy of a health number is worse than none.
    res.json({
        ...state,
        serverTime: Date.now(),
        logLoss:    logLossSummary(),
        bridgeBusy: lastBusyRollup,   // null until the first rollup lands
    });
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
    console.log(`[LOG] Fleet log -> ${path.join(LOG_DIR, 'YYYY-MM-DD.txt')} (${LOG_RETENTION_DAYS}-day retention)`);
    initMarkerSet();
    pruneOldLogs();
    setInterval(pruneOldLogs, LOG_PRUNE_INTERVAL);

    // Unconditional, so that a missing rollup means the instrumentation stopped
    // rather than the bridge being quiet. unref() left off deliberately: this
    // timer should keep the process honest for as long as it is running.
    logLocal('INFO', `bridge up — busy rollups every ${BUSY_ROLLUP_MS / 1000}s, `
        + `slow-push threshold ${BUSY_SLOW_PUSH_MS}ms`);
    setInterval(emitBusyRollup, BUSY_ROLLUP_MS);
});
