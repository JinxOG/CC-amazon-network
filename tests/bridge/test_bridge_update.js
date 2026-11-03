// Exercises the two functions behind W3's 2026-10-02 and 2026-10-03 mails, as
// they actually ship in server.js:
//
//   mergeTurtleSnapshot — a field the server stops sending must CLEAR, not stick
//   updateAllParams     — a deploy pins the fleet to a commit, or says it cannot
//
// Extracted from the real source text rather than copied, so this reads any
// later change to that file.
//
// Usage: node test_bridge_update.js [--mutate '<find>|||<replace>']
//        ./mutate_bridge_update.sh   — runs the whole mutant set
//
// Separator is ||| and must not become =>: a replacement containing an arrow
// function would be split mid-expression into a syntax error, which a runner
// reports as a SURVIVING mutant — the worst possible failure for this harness.

const fs   = require('fs');
const path = require('path');

const SERVER = path.join(__dirname, '..', '..', 'server.js');

let failures = 0;
function check(name, cond, detail) {
    if (cond) { console.log(`  PASS  ${name}`); }
    else      { console.log(`  FAIL  ${name}${detail ? ' — ' + detail : ''}`); failures++; }
}

function slice(src, startMarker, endMarker, what) {
    const a = src.indexOf(startMarker);
    const b = src.indexOf(endMarker, a + 1);
    if (a < 0 || b < 0 || b <= a) throw new Error(`could not locate ${what} in server.js — markers moved`);
    return src.slice(a, b);
}

function load(mutation) {
    const src = fs.readFileSync(SERVER, 'utf8');
    let block = slice(src, 'function mergeTurtleSnapshot', '// CC central_server.lua pushes', 'mergeTurtleSnapshot')
              + '\n'
              + slice(src, 'function updateAllParams', "app.post('/self-update'", 'updateAllParams');

    if (mutation) {
        const [find, replace] = mutation;
        if (!block.includes(find)) throw new Error(`mutation target not found: ${find}`);
        block = block.replace(find, replace);
    }
    return new Function(block + '\n return { mergeTurtleSnapshot, updateAllParams };')();
}

function run({ mergeTurtleSnapshot, updateAllParams }) {
    const NOW = 1_770_000_000_000;

    // ── mergeTurtleSnapshot ─────────────────────────────────────────────────
    //
    // The reported sequence, exactly: a turtle is flagged as needing hands, the
    // operator frees it, and the server stops sending the field. Before the fix
    // the dashboard showed NEEDS HANDS until the bridge restarted, while the
    // server had already dispatched the turtle.
    const flagged = mergeTurtleSnapshot({
        node_119: { role: 'MINER', online: true, needsHands: 'loader_outstanding at 1,2,3',
                    blockReason: 'loader_outstanding', jobId: 'job_0121' },
    }, NOW);
    check('a flagged turtle carries the field', flagged.node_119.needsHands !== undefined);

    const released = mergeTurtleSnapshot({
        node_119: { role: 'MINER', online: true },
    }, NOW + 1000);

    check('a field the server stops sending is CLEARED',
        !('needsHands' in released.node_119), JSON.stringify(released.node_119));
    check('every such field clears, not just the reported one',
        !('blockReason' in released.node_119) && !('jobId' in released.node_119),
        JSON.stringify(released.node_119));

    // lastSeen is the one field the bridge owns — nothing upstream sends it, so
    // if this stops being stamped nothing else will put it back.
    check('lastSeen is stamped by the bridge', released.node_119.lastSeen === NOW + 1000,
        String(released.node_119.lastSeen));

    check('incoming values are taken as-is', flagged.node_119.role === 'MINER'
        && flagged.node_119.jobId === 'job_0121');

    // A turtle the server drops (a retrieved loader) must not linger.
    const two = mergeTurtleSnapshot({ a: { online: true }, b: { online: true } }, NOW);
    const one = mergeTurtleSnapshot({ a: { online: true } }, NOW);
    check('a turtle absent from the snapshot does not appear',
        'b' in two && !('b' in one));

    // The caller still holds the request body; corrupting it would be invisible.
    const incoming = { a: { online: true } };
    mergeTurtleSnapshot(incoming, NOW);
    check('the incoming payload is not mutated', incoming.a.lastSeen === undefined);

    check('a missing payload yields no turtles',
        Object.keys(mergeTurtleSnapshot(undefined, NOW)).length === 0);

    // ── updateAllParams ─────────────────────────────────────────────────────
    const SHA = 'a1b2c3d4e5f60718293a4b5c6d7e8f9012345678';

    check('a real commit pins the deploy', updateAllParams(SHA).ref === SHA);
    // git rev-parse prints a trailing newline; without trimming, every deploy
    // would silently fall back to master.
    check('a trailing newline still pins', updateAllParams(SHA + '\n').ref === SHA);

    // Everything below must fall back rather than reach a URL.
    const rejects = {
        'empty':            '',
        'undefined':        undefined,
        'null':             null,
        'too short':        SHA.slice(0, 39),
        'too long':         SHA + 'a',
        'uppercase':        SHA.toUpperCase(),
        'non-hex':          SHA.slice(0, 39) + 'z',
        'embedded in junk': 'xx' + SHA + 'yy',
        'a path traversal': '../../etc/passwd',
        'shell characters': `${SHA}; rm -rf /`,
        'a number':         12345,
    };
    for (const [label, value] of Object.entries(rejects)) {
        const p = updateAllParams(value);
        check(`${label} does not pin`, p.ref === undefined && Object.keys(p).length === 0,
            JSON.stringify(p));
    }

    return failures;
}

const mutArg = process.argv.indexOf('--mutate');
const mutation = mutArg > -1 ? process.argv[mutArg + 1].split('|||') : null;

// Loading and running fail for different reasons and must not be collapsed: a
// mutant that makes the code THROW is killed, but reported as a harness error it
// reads as "cannot tell" — the exact failure this suite exists to catch.
let mod;
try { mod = load(mutation); }
catch (e) { console.error('HARNESS ERROR:', e.message); process.exit(2); }

try {
    const f = run(mod);
    console.log(f === 0 ? '\nALL PASS' : `\n${f} FAILURE(S)`);
    process.exit(f === 0 ? 0 : 1);
} catch (e) {
    console.log(`  FAIL  threw during the run — ${e.message}`);
    console.log('\n1 FAILURE(S)');
    process.exit(1);
}
