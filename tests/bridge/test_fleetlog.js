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

    // BRIDGE_BOOT_ID is declared above the extracted block, so it is injected
    // rather than sliced in — logLossSummary reports it as the window start.
    const factory = new Function('fs', 'path', 'console', 'TEST_LOG_DIR', 'BRIDGE_BOOT_ID', block + `
        return { ingestLogs, logSeqHigh, pruneOldLogs, logLossSummary,
                 recordPush, emitBusyRollup, logLocal,
                 busy: () => busy, lastBusyRollup: () => lastBusyRollup,
                 queueLen: () => logQueue.length, LOG_DIR };
    `);
    return { mod: factory(fs, path, console, dir, 1), dir };
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

    // ── 6. live loss accounting (W1 proposal 5) ─────────────────────────────
    {
        const { mod: m } = loadLogModule(mutation);

        // Nothing sequenced yet: this must be "no data", never "0% loss".
        check('loss is null before any sequenced line arrives',
            m.logLossSummary().lossPct === null,
            JSON.stringify(m.logLossSummary().lossPct));

        // seq 1,2,3,5 — one hole at 4.
        m.ingestLogs({ turtleLogs: { node_7: [1, 2, 3, 5].map((s) => (
            { ts: T0 + s * 10, msg: `line ${s}`, seq: s, bootId: 'b1' })) } });
        await settle(m);
        let sum = m.logLossSummary();
        check('counts a hole in the sequence',
            sum.missing === 1 && sum.lossPct === 20, JSON.stringify(sum));

        // The retry W3 ships at 1.9.89 delivers seq 4 late. A running-prev
        // counter would have booked it as permanent loss; min/max/count heals.
        m.ingestLogs({ turtleLogs: { node_7: [
            { ts: T0 + 45, msg: 'line 4', seq: 4, bootId: 'b1' }] } });
        await settle(m);
        sum = m.logLossSummary();
        check('a late-arriving line heals the hole',
            sum.missing === 0 && sum.lossPct === 0, JSON.stringify(sum));

        // A duplicate must not push count past the span and invent negative loss.
        m.ingestLogs({ turtleLogs: { node_7: [
            { ts: T0 + 30, msg: 'line 3', seq: 3, bootId: 'b1' }] } });
        await settle(m);
        sum = m.logLossSummary();
        check('a re-sent duplicate does not distort the count',
            sum.missing === 0 && sum.sources.node_7.received === 5, JSON.stringify(sum.sources.node_7));

        // A source whose FIRST delivered line is not its lowest: the window must
        // extend downwards, or the span is measured from the wrong floor and the
        // loss rate is wrong for every source that starts mid-flight.
        const { mod: m2 } = loadLogModule(mutation);
        m2.ingestLogs({ turtleLogs: { node_8: [
            { ts: T0 + 50, msg: 'five', seq: 5, bootId: 'b1' }] } });
        await settle(m2);
        m2.ingestLogs({ turtleLogs: { node_8: [2, 3, 4].map((s) => (
            { ts: T0 + s * 10, msg: `line ${s}`, seq: s, bootId: 'b1' })) } });
        await settle(m2);
        // Asserted on `expected` (the span), not on `missing`. missing is
        // clamped with Math.max(0, …), so a span measured from the wrong floor
        // still reports 0 missing and the bug hides behind the clamp — the
        // first version of this check was blind for exactly that reason.
        const late = m2.logLossSummary();
        check('the window extends down when an earlier line arrives later',
            late.expected === 4 && late.received === 4 && late.missing === 0,
            JSON.stringify(late));

        // A reboot restarts seq at 1; that must not read as a huge backwards gap.
        m.ingestLogs({ turtleLogs: { node_7: [
            { ts: T0 + 900, msg: 'after reboot', seq: 1, bootId: 'b2' }] } });
        await settle(m);
        sum = m.logLossSummary();
        check('a reboot is counted as a reboot, not as loss',
            sum.sources.node_7.reboots === 1 && sum.sources.node_7.missing === 0,
            JSON.stringify(sum.sources.node_7));
    }

    // ── 7. busy instrumentation (W1 proposals 1 and 2) ──────────────────────
    {
        const { mod: m } = loadLogModule(mutation);

        // The rollup must be emitted even when nothing happened — that is what
        // makes its absence mean "instrumentation down" rather than "quiet".
        m.emitBusyRollup();
        await settle(m);
        check('a zero-activity rollup is still emitted',
            /bridge#\d+\s+INFO\s+busy rollup: pushes=0 writes=0/.test(readLog(m.LOG_DIR)),
            JSON.stringify(readLog(m.LOG_DIR).trim().split('\n').pop()));

        // A fast push produces no line of its own.
        m.recordPush(5, 1);
        await settle(m);
        check('a fast push writes no slow-push line',
            !readLog(m.LOG_DIR).includes('slow push'));

        // A slow one does, and carries the log system's share of it.
        m.recordPush(250, 200);
        await settle(m);
        check('a slow push is recorded with its log-system share',
            /WARN\s+slow push: 250\.0ms total, 200\.0ms of it in the log system/
                .test(readLog(m.LOG_DIR)),
            JSON.stringify(readLog(m.LOG_DIR).trim().split('\n').pop()));

        // log_share is the number that answers proposal 2. 201/255 ≈ 78.8%.
        m.emitBusyRollup();
        await settle(m);
        const roll = m.lastBusyRollup();
        check('rollup reports pushes, slow count and log share',
            roll.pushes === 2 && roll.slowPushes === 1 && roll.logSharePct === 78.8,
            JSON.stringify(roll));
        check('rollup line names the log share',
            /log_share=78\.8%/.test(readLog(m.LOG_DIR)),
            JSON.stringify(readLog(m.LOG_DIR).trim().split('\n').pop()));

        // Bridge lines are sequenced, so the instrumentation is itself auditable.
        check('bridge lines carry their own sequence',
            /bridge#1\s/.test(readLog(m.LOG_DIR)) && /bridge#2\s/.test(readLog(m.LOG_DIR)));
    }

    // ── 8. retention prunes only this module's own files ────────────────────
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
