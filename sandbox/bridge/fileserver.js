// Read-only file server for a sandbox run:  node fileserver.js <run_dir> <port> [public_dir]
// Serves what the stand-in bridge wrote, over the same GET routes the analysis tools and the dashboard use:
//   /state            run_dir/state.json
//   /logs             the list of log days
//   /logs/<date>      the day's lines, with server.js's query parameters
//   /ping             liveness
//   /, /index.html    the real dashboard page (public/), plus its assets
// Binds 127.0.0.1 only. No timers, no writes, no other routes. It makes no outgoing connection.
'use strict';
const http = require('http');
const fs = require('fs');
const path = require('path');
const readline = require('readline');

const runDir = path.resolve(process.argv[2] || '');
const port = Number(process.argv[3]);
const publicDir = path.resolve(process.argv[4] || path.join(__dirname, '..', '..', 'public'));
if (!process.argv[2] || !Number.isInteger(port) || port <= 0) {
    console.error('usage: node fileserver.js <run_dir> <port> [public_dir]');
    process.exit(2);
}
const logDir = path.join(runDir, 'logs');

const LOG_QUERY_DEFAULT = 500;
const LOG_QUERY_MAX = 5000;
const AUDIT_MIN_LINES = 50;
const LOG_LINE_RE = /^(\S+)\s{2}(\S+)\s+(\S+)\s+([\s\S]*)$/;

function sendJson(res, status, obj) {
    const body = JSON.stringify(obj);
    res.writeHead(status, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' });
    res.end(body);
}

function parseLogLine(line) {
    const m = LOG_LINE_RE.exec(line);
    if (!m) return null;
    const hash = m[2].lastIndexOf('#');
    const source = hash > 0 ? m[2].slice(0, hash) : m[2];
    const seqRaw = hash > 0 ? Number(m[2].slice(hash + 1)) : NaN;
    return { ts: m[1], source, level: m[3], msg: m[4], seq: Number.isFinite(seqRaw) ? seqRaw : null };
}

function logDays() {
    try {
        return fs.readdirSync(logDir).filter(f => /^\d{4}-\d{2}-\d{2}\.txt$/.test(f)).sort();
    } catch { return []; }
}

function serveLogList(res) {
    const days = logDays().map(f => {
        let size = null;
        try { size = fs.statSync(path.join(logDir, f)).size; } catch { /* gone */ }
        return { date: f.slice(0, 10), bytes: size };
    });
    sendJson(res, 200, { dir: logDir, retentionDays: 14,
        filenames: 'simulated UTC date; use /logs/latest to avoid guessing',
        todayUtc: days.length ? days[days.length - 1].date : null, days });
}

function serveLog(res, dateParam, q) {
    const all = logDays();
    if (dateParam === 'latest' || dateParam === 'today') {
        dateParam = all.length ? all[all.length - 1].slice(0, 10) : '1970-01-01';
    }
    if (!/^\d{4}-\d{2}-\d{2}$/.test(dateParam)) return sendJson(res, 400, { error: 'date must be YYYY-MM-DD' });
    const file = path.join(logDir, dateParam + '.txt');
    if (!fs.existsSync(file)) {
        // A run has no history before it began. The analysis tools look back a day or more, so an earlier day answers
        // "nothing logged" rather than 404 (the live bridge keeps older days; a sandbox run does not). Days after the
        // run's last log stay 404.
        const first = all.length ? all[0].slice(0, 10) : null;
        if (!first || dateParam < first) {
            return sendJson(res, 200, { file: dateParam + '.txt', matched: 0, returned: 0, truncated: false,
                order: 'tail', lines: [], note: 'sandbox: this run has no log for that earlier day' });
        }
        return sendJson(res, 404, { error: 'no log for that date' });
    }

    const get = k => q.get(k);
    const source = get('node') ? String(get('node')) : null;
    const level = get('level') ? String(get('level')).toUpperCase() : null;
    const contains = get('contains') ? String(get('contains')) : null;
    const since = get('since') ? String(get('since')) : null;
    const until = get('until') ? String(get('until')) : null;
    const head = String(get('order') || 'tail') === 'head';
    const asText = String(get('format') || 'json') === 'text';
    let limit = parseInt(get('limit'), 10);
    if (!Number.isFinite(limit) || limit <= 0) limit = LOG_QUERY_DEFAULT;
    limit = Math.min(limit, LOG_QUERY_MAX);
    const audit = String(get('audit') || '') === '1';

    const out = [];
    let matched = 0;
    const seen = {};
    const rl = readline.createInterface({ input: fs.createReadStream(file, { encoding: 'utf8' }), crlfDelay: Infinity });

    rl.on('line', (line) => {
        if (!line) return;
        const e = parseLogLine(line);
        if (!e) return;
        if (source && e.source !== source) return;
        if (level && e.level !== level) return;
        if (since && e.ts < since) return;
        if (until && e.ts > until) return;
        if (contains && !e.msg.includes(contains)) return;
        matched++;
        if (audit) {
            const st = seen[e.source] || (seen[e.source] = { n: 0, unsequenced: 0, first: null, last: null, gaps: 0, missing: 0, reboots: 0, prev: null });
            st.n++;
            if (e.seq == null) { st.unsequenced++; return; }
            if (st.first === null) st.first = e.seq;
            st.last = e.seq;
            if (st.prev !== null) {
                if (e.seq < st.prev) st.reboots++;
                else if (e.seq > st.prev + 1) { st.gaps++; st.missing += e.seq - st.prev - 1; }
            }
            st.prev = e.seq;
            return;
        }
        out.push(e);
        if (head && out.length >= limit) rl.close();
        else if (!head && out.length > limit) out.shift();
    });

    rl.on('close', () => {
        if (audit) {
            const minLines = Math.max(1, parseInt(get('minLines'), 10) || AUDIT_MIN_LINES);
            const sources = {};
            let sequencedTotal = 0;
            for (const [src, st] of Object.entries(seen)) {
                const sequenced = st.n - st.unsequenced;
                sequencedTotal += sequenced;
                sources[src] = { lines: st.n, sequenced, unsequenced: st.unsequenced, first: st.first, last: st.last,
                    gaps: st.gaps, missing: st.missing, reboots: st.reboots, conclusive: sequenced >= minLines };
            }
            const insufficient = sequencedTotal < minLines;
            return sendJson(res, 200, { file: path.basename(file), scanned: matched, sequenced: sequencedTotal, minLines,
                insufficient,
                verdict: insufficient ? 'insufficient' : (Object.values(sources).some(v => v.gaps > 0) ? 'gaps' : 'clean'),
                note: insufficient ? `only ${sequencedTotal} sequenced line(s) in this window — too few to conclude anything.` : undefined,
                sources });
        }
        if (asText) {
            res.writeHead(200, { 'Content-Type': 'text/plain' });
            return res.end(out.map(e => `${e.ts}  ${e.source.padEnd(9)} ${e.level.padEnd(6)} ${e.msg}`).join('\n'));
        }
        sendJson(res, 200, { file: path.basename(file), matched, returned: out.length, truncated: matched > out.length,
            order: head ? 'head' : 'tail', lines: out });
    });
    rl.on('error', () => sendJson(res, 500, { error: 'cannot read log file' }));
}

const MIME = { '.html': 'text/html; charset=utf-8', '.js': 'text/javascript', '.css': 'text/css', '.json': 'application/json',
    '.png': 'image/png', '.svg': 'image/svg+xml', '.ico': 'image/x-icon' };

function serveStatic(res, urlPath) {
    let rel = urlPath === '/' ? '/index.html' : urlPath;
    const file = path.join(publicDir, path.normalize(rel));
    if (!file.startsWith(publicDir)) return sendJson(res, 404, { error: 'not found' });
    fs.readFile(file, (err, data) => {
        if (err) return sendJson(res, 404, { error: 'not found' });
        res.writeHead(200, { 'Content-Type': MIME[path.extname(file)] || 'application/octet-stream', 'Cache-Control': 'no-cache' });
        res.end(data);
    });
}

// The dashboard's "synced Ns ago / STALE" badge compares the state's updatedAt (simulated time) with the browser's wall
// clock, so a sandbox run would always read stale. Shift every timestamp by (file written - serverTime): a run being
// written reads fresh, and ages normally once writing stops. The file on disk is untouched.
const SHIFT_KEYS = ['updatedAt', 'storageTs', 'storageAt']; // serverTime stays simulated: gate_check and ack_loss date their windows from it
function shiftToWallClock(data, mtimeMs) {
    try {
        const s = JSON.parse(data.toString('utf8'));
        if (!s || typeof s.serverTime !== 'number' || !mtimeMs) return data;
        const delta = Math.round(mtimeMs - s.serverTime);
        for (const k of SHIFT_KEYS) if (typeof s[k] === 'number') s[k] += delta;
        for (const t of Object.values(s.turtles || {})) if (t && typeof t.lastSeen === 'number') t.lastSeen += delta;
        s.sandboxTimeShiftMs = delta;
        return JSON.stringify(s);
    } catch { return data; }
}

const server = http.createServer((req, res) => {
    if (req.method !== 'GET' && req.method !== 'HEAD') {
        return sendJson(res, 405, { error: 'the sandbox file server is read-only' });
    }
    const u = new URL(req.url, 'http://127.0.0.1');
    const p = u.pathname;
    if (p === '/state') {
        const file = path.join(runDir, 'state.json');
        fs.readFile(file, (err, data) => {
            if (err) return sendJson(res, 503, { error: 'no state yet' });
            res.writeHead(200, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' });
            let mtime = 0;
            try { mtime = fs.statSync(file).mtimeMs; } catch { /* keep raw */ }
            res.end(shiftToWallClock(data, mtime));
        });
    } else if (p === '/dynmap-frame') {
        fs.readFile(path.join(__dirname, 'map_page.html'), (err, data) => {
            if (err) return sendJson(res, 404, { error: 'not found' });
            res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8', 'Cache-Control': 'no-cache' });
            res.end(data);
        });
    } else if (p === '/dynmap-model.js') {
        fs.readFile(path.join(__dirname, 'map_model.js'), (err, data) => {
            if (err) return sendJson(res, 404, { error: 'not found' });
            res.writeHead(200, { 'Content-Type': 'text/javascript', 'Cache-Control': 'no-cache' });
            res.end(data);
        });
    } else if (p === '/ping') {
        sendJson(res, 200, { ok: true, uptime: process.uptime() });
    } else if (p === '/logs') {
        serveLogList(res);
    } else if (p.startsWith('/logs/')) {
        serveLog(res, decodeURIComponent(p.slice(6)), u.searchParams);
    } else {
        serveStatic(res, p);
    }
});

server.listen(port, '127.0.0.1', () => {
    console.log(`sandbox file server for ${runDir} on http://127.0.0.1:${port}/`);
});
