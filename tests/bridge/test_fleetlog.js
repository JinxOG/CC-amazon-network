// Exercises the continuous-log block as it actually ships in server.js.
//
// Express is not installed on the dev machine, so the whole bridge cannot boot
// here. But the log block touches only fs/path/console, so it is extracted from
// the real source text (not a copy) and run against synthetic /update payloads.
// If server.js changes, this reads the change.
//
// Usage: node test_fleetlog.js [--mutate '<find>|||<replace>']
//        ./mutate_fleetlog.sh   — runs the whole mutant set
//
// The mutation separator is ||| and must not become =>: a replacement
// containing an arrow function would be split mid-expression and produce a
// syntax error, which the runner reports as a SURVIVING mutant. That is the
// worst possible failure for a mutation harness -- it reads as 'your test
// cannot detect this defect' when in fact the mutant never compiled.

const fs   = require('fs');
const path = require('path');
const os   = require('os');

const SERVER = path.join(__dirname, '..', '..', 'server.js');

let failures = 0;
function check(name, cond, detail) {
    if (cond) { console.log(`  PASS  ${name}`); }
    else      { console.log(`  FAIL  ${name}${detail ? ' — ' + detail : ''}`); failures++; }
}

function loadLogModule(mutation) {
    let src = fs.readFileSync(SERVER, 'utf8');

    const start = src.indexOf('const LOG_DIR');
    const end   = src.indexOf('// ─── RCON');
    if (start < 0 || end < 0 || end <= start) {
        throw new Error('could not locate the log block in server.js — markers moved');
    }
    let block = src.slice(start, end);

    if (mutation) {
        const [find, replace] = mutation;
        if (!block.includes(find)) throw new Error(`mutation target not found: ${find}`);
        block = block.replace(find, replace);
    }

    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'fleetlog-'));
    block = block.replace("path.join(__dirname, 'logs')", 'TEST_LOG_DIR');

    const factory = new Function('fs', 'path', 'console', 'TEST_LOG_DIR', block + `
        return { ingestLogs, logSeqHigh, pruneOldLogs,
                 queueLen: () => logQueue.length, LOG_DIR };
    `);
    return { mod: factory(fs, path, console, dir), dir };
}

// The writer drains behind the response, so tests wait for it rather than
// assuming the append already landed.
function settle(mod) {
    return new Promise((resolve) => {
        const tick = () => (mod.queueLen() === 0 ? setTimeout(resolve, 60) : setTimeout(tick, 10));
        tick();
    });
}

function readLog(dir) {
    const f = fs.readdirSync(dir).filter((n) => /^\d{4}-\d{2}-\d{2}\.txt$/.test(n));
    if (f.length === 0) return '';
    return fs.readFileSync(path.join(dir, f[0]), 'utf8');
}

async function run(mutation) {
    const { mod, dir } = loadLogModule(mutation);

    const T0 = Date.parse('2026-09-07T14:26:09.412Z');

    // ── 1. basic capture, both sources ──────────────────────────────────────
    mod.ingestLogs({
        serverLog: [{ ts: T0, level: 'WARN', msg: 'Bridge push timed out (>4s)' }],
        turtleLogs: {
            node_118: [{ ts: T0 + 1000, msg: '[node_118][INFO] phase: SCANNING' }],
        },
    });
    await settle(mod);

    let text = readLog(dir);
    let lines = text.trim().split('\n');

    check('writes one line per entry', lines.length === 2, `got ${lines.length}`);
    check('server line carries ISO ts, source and level',
        /^2026-09-07T14:26:09\.412Z\s+server\s+WARN\s+Bridge push timed out/.test(lines[0]),
        JSON.stringify(lines[0]));

    // The whole point of the level column: grep WARN must find turtle warnings
    // too, and the level for a turtle lives inside its message prefix.
    check('turtle level lifted out of the msg prefix',
        /\s+node_118\s+INFO\s+\[node_118\]\[INFO\] phase: SCANNING$/.test(lines[1]),
        JSON.stringify(lines[1]));

    // ── 2. dedupe across overlapping windows ────────────────────────────────
    mod.ingestLogs({
        serverLog: [{ ts: T0, level: 'WARN', msg: 'Bridge push timed out (>4s)' }],
        turtleLogs: {
            node_118: [{ ts: T0 + 1000, msg: '[node_118][INFO] phase: SCANNING' }],
        },
    });
    await settle(mod);
    check('re-sent window writes nothing new',
        readLog(dir).trim().split('\n').length === 2,
        `got ${readLog(dir).trim().split('\n').length}`);

    // ── 3. one entry is always exactly one line ─────────────────────────────
    mod.ingestLogs({
        serverLog: [{ ts: T0 + 2000, level: 'ERROR', msg: 'line one\nline two\r\nline three' }],
    });
    await settle(mod);
    lines = readLog(dir).trim().split('\n');
    check('embedded newlines collapsed', lines.length === 3, `got ${lines.length}`);
    check('collapsed line keeps its content',
        /ERROR\s+line one line two line three$/.test(lines[2]), JSON.stringify(lines[2]));

    // ── 4. chronological ordering within a batch ────────────────────────────
    mod.ingestLogs({
        serverLog:  [{ ts: T0 + 9000, level: 'INFO', msg: 'later-server' }],
        turtleLogs: { node_9: [{ ts: T0 + 5000, msg: 'earlier-turtle' }] },
    });
    await settle(mod);
    lines = readLog(dir).trim().split('\n');
    const iEarly = lines.findIndex((l) => l.includes('earlier-turtle'));
    const iLate  = lines.findIndex((l) => l.includes('later-server'));
    check('batch sorted chronologically, not by source',
        iEarly !== -1 && iLate !== -1 && iEarly < iLate, `early=${iEarly} late=${iLate}`);

    // ── 5. Phase 2 forward-compat: seq preferred, ack tracked ───────────────
    // Same (ts,msg) as an earlier line but a distinct seq: keying on seq must
    // let it through, proving seq is genuinely preferred over (source,ts,msg).
    mod.ingestLogs({
        serverLog: [
            { ts: T0, level: 'WARN', msg: 'Bridge push timed out (>4s)', seq: 41, bootId: 'b1' },
            { ts: T0, level: 'WARN', msg: 'Bridge push timed out (>4s)', seq: 42, bootId: 'b1' },
        ],
    });
    await settle(mod);
    check('seq-keyed entries are not collapsed by (ts,msg)',
        readLog(dir).split('Bridge push timed out').length - 1 === 3,
        `occurrences=${readLog(dir).split('Bridge push timed out').length - 1}`);
    check('logAck tracks highest seq per source',
        mod.logSeqHigh.server && mod.logSeqHigh.server.seq === 42
            && mod.logSeqHigh.server.bootId === 'b1',
        JSON.stringify(mod.logSeqHigh.server));

    // A reboot restarts seq at 1 under a new bootId — that must adopt the new
    // numbering, not be discarded as "older than 42".
    mod.ingestLogs({ serverLog: [{ ts: T0 + 20000, level: 'INFO', msg: 'rebooted', seq: 1, bootId: 'b2' }] });
    await settle(mod);
    check('new bootId adopts the new sequence',
        mod.logSeqHigh.server.bootId === 'b2' && mod.logSeqHigh.server.seq === 1,
        JSON.stringify(mod.logSeqHigh.server));

    // ── 6. retention prunes only this module's own files ────────────────────
    const old = path.join(dir, '2020-01-01.txt');
    const keep = path.join(dir, 'operator-notes.txt');
    fs.writeFileSync(old, 'ancient\n');
    fs.writeFileSync(keep, 'do not delete\n');
    mod.pruneOldLogs();
    await new Promise((r) => setTimeout(r, 120));
    check('prunes a log file past retention', !fs.existsSync(old));
    check('leaves unrelated files alone', fs.existsSync(keep));

    fs.rmSync(dir, { recursive: true, force: true });
    return failures;
}

const mutArg = process.argv.indexOf('--mutate');
const mutation = mutArg > -1 ? process.argv[mutArg + 1].split('|||') : null;

run(mutation).then((f) => {
    console.log(f === 0 ? '\nALL PASS' : `\n${f} FAILURE(S)`);
    process.exit(f === 0 ? 0 : 1);
}).catch((e) => { console.error('HARNESS ERROR:', e.message); process.exit(2); });
