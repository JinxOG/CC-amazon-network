// Exercises acceptStorage as it actually ships in server.js.
//
// The function is the arbiter both storage paths go through — the warehouse's
// POST /storage and the dispatch server's /update push — so the rules it
// enforces are the whole no-flag-day property. Extracted from the real source
// text rather than copied, so it reads any later change to that file.
//
// Usage: node test_storage.js [--mutate '<find>|||<replace>']
//        ./mutate_storage.sh   — runs the whole mutant set
//
// Separator is ||| and must not become =>: a replacement containing an arrow
// function would be split mid-expression and produce a syntax error, which a
// runner reports as a SURVIVING mutant — the worst possible failure for a
// mutation harness.

const fs   = require('fs');
const path = require('path');

const SERVER = path.join(__dirname, '..', '..', 'server.js');

let failures = 0;
function check(name, cond, detail) {
    if (cond) { console.log(`  PASS  ${name}`); }
    else      { console.log(`  FAIL  ${name}${detail ? ' — ' + detail : ''}`); failures++; }
}

function loadAcceptStorage(mutation) {
    const src = fs.readFileSync(SERVER, 'utf8');

    const start = src.indexOf('function acceptStorage');
    const end   = src.indexOf("// The warehouse's own route");
    if (start < 0 || end < 0 || end <= start) {
        throw new Error('could not locate acceptStorage in server.js — markers moved');
    }
    let block = src.slice(start, end);

    if (mutation) {
        const [find, replace] = mutation;
        if (!block.includes(find)) throw new Error(`mutation target not found: ${find}`);
        block = block.replace(find, replace);
    }

    const factory = new Function('console', block + '\n return { acceptStorage };');
    return factory(console).acceptStorage;
}

function run(acceptStorage) {
    const T = 1_759_000_000_000;   // a plausible epoch-ms reading

    // ── 1. a first good snapshot ────────────────────────────────────────────
    let s = {};
    let r = acceptStorage(s, { storage: [{ name: 'minecraft:stone', amount: 64 }], storageTs: T }, 'warehouse');
    check('accepts a first snapshot', r.ok && r.items === 1, JSON.stringify(r));
    check('records list, timestamp and source',
        s.storage.length === 1 && s.storageTs === T && s.storageSource === 'warehouse',
        JSON.stringify({ ts: s.storageTs, src: s.storageSource }));

    // ── 2. shape guards ─────────────────────────────────────────────────────
    s = {};
    check('rejects a non-array list', !acceptStorage(s, { storage: 'nope', storageTs: T }, 'warehouse').ok);
    check('rejects a missing list',   !acceptStorage(s, { storageTs: T }, 'warehouse').ok);

    // ── 3. rule 2: never invent a timestamp ─────────────────────────────────
    // The dangerous failure is not rejecting these; it is accepting them with a
    // Date.now() stamp, which makes a dead RS network read as freshly polled.
    for (const [label, ts] of [['a missing', undefined], ['a zero', 0], ['a negative', -5],
                               ['a NaN', NaN], ['a string', String(T)]]) {
        s = {};
        const res = acceptStorage(s, { storage: [], storageTs: ts }, 'warehouse');
        check(`rejects ${label} timestamp`, !res.ok, JSON.stringify(res));
        check(`does not stamp ${label} timestamp`,
            s.storageTs === undefined && s.storage === undefined,
            JSON.stringify({ ts: s.storageTs, stored: s.storage !== undefined }));
    }

    // ── 4. rule 1: newest wins, in both directions ──────────────────────────
    s = {};
    acceptStorage(s, { storage: [1, 2, 3], storageTs: T }, 'warehouse');

    r = acceptStorage(s, { storage: [9], storageTs: T - 60_000 }, 'dispatch');
    check('a staler dispatch push cannot overwrite a fresher warehouse post',
        !r.ok && s.storage.length === 3 && s.storageSource === 'warehouse', JSON.stringify(r));

    r = acceptStorage(s, { storage: [9, 9], storageTs: T + 60_000 }, 'dispatch');
    check('a fresher dispatch push does win',
        r.ok && s.storage.length === 2 && s.storageSource === 'dispatch', JSON.stringify(r));

    // The reverse direction matters just as much: neither sender is privileged,
    // which is what lets the two run concurrently during the cutover.
    r = acceptStorage(s, { storage: [7], storageTs: T }, 'warehouse');
    check('a staler warehouse post cannot overwrite a fresher dispatch push',
        !r.ok && s.storageSource === 'dispatch', JSON.stringify(r));

    // Equal timestamps are the same reading arriving twice — accepting is a
    // harmless no-op, and refusing would make a duplicate look like an error.
    r = acceptStorage(s, { storage: [5, 5], storageTs: s.storageTs }, 'warehouse');
    check('a re-post of the same reading is accepted', r.ok, JSON.stringify(r));

    // ── 5. an empty list is data, not an error ──────────────────────────────
    s = {};
    r = acceptStorage(s, { storage: [], storageTs: T }, 'warehouse');
    check('accepts an empty list with a good timestamp',
        r.ok && r.items === 0 && Array.isArray(s.storage) && s.storage.length === 0,
        JSON.stringify(r));

    return failures;
}

const mutArg = process.argv.indexOf('--mutate');
const mutation = mutArg > -1 ? process.argv[mutArg + 1].split('|||') : null;

// Loading and running fail for completely different reasons, and collapsing them
// was itself a defect: a mutant that makes the code THROW is killed, but it came
// out as "HARNESS ERROR", which the runner reads as a malformed mutation string.
// That is the same trap the mutation suite exists to expose — a result whose
// failure state is indistinguishable from its can't-tell state.
let acceptStorage;
try {
    acceptStorage = loadAcceptStorage(mutation);
} catch (e) {
    console.error('HARNESS ERROR:', e.message);   // markers moved, or a bad mutation
    process.exit(2);
}

try {
    const f = run(acceptStorage);
    console.log(f === 0 ? '\nALL PASS' : `\n${f} FAILURE(S)`);
    process.exit(f === 0 ? 0 : 1);
} catch (e) {
    // An exception from the code under test is a failure, not a harness problem.
    console.log(`  FAIL  threw during the run — ${e.message}`);
    console.log('\n1 FAILURE(S)');
    process.exit(1);
}
