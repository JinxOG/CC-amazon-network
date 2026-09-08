// The /state display buffers must ACCUMULATE the delta, not be replaced by it.
//
// W3's Phase 2 (1.9.85) changed what `serverLog` and `turtleLogs` mean in the
// /update payload. They used to be "the last N lines" -- a window, safe to
// overwrite the display copy with. They are now "what the bridge has not
// acknowledged writing" -- a delta, which is normally EMPTY once the ack loop
// closes.
//
// Replacing with that blanked the dashboard's log panel. Observed live at
// 1.9.85: serverLog down to a single entry, turtleLogs to no nodes at all,
// while the file on disk was complete and correct. A contract changed under a
// consumer that had no reason to expect it.
//
// Express is not installed here, so the handler cannot be booted. The merge
// statements touch nothing but `req` and `state`, so they are extracted from
// the real source text and run directly -- the same technique, and the same
// limitation, as test_fleetlog.js.
//
// Usage: node test_statemerge.js [--mutate '<find>|||<replace>']

const fs   = require('fs');
const path = require('path');

const SERVER = path.join(__dirname, '..', '..', 'server.js');
const START  = '// ACCUMULATE, do not replace.';
const END    = '// Everything else the server sends passes straight through.';

let failures = 0;
function check(name, cond, detail) {
    if (cond) console.log(`  PASS  ${name}`);
    else { console.log(`  FAIL  ${name}${detail ? ' — ' + detail : ''}`); failures++; }
}

function loadMerge(mutation) {
    let src = fs.readFileSync(SERVER, 'utf8');
    const start = src.indexOf(START);
    const end   = src.indexOf(END, start);
    if (start < 0 || end < 0) {
        throw new Error('could not locate the merge block in server.js — markers moved');
    }
    let block = src.slice(start, end);

    if (mutation) {
        const [find, replace] = mutation;
        if (!block.includes(find)) {
            // A mutation that does not apply is indistinguishable from a test
            // that cannot detect the defect. Both report green. Say which.
            console.log(`  MALFORMED  mutation target not found: ${find}`);
            process.exit(2);
        }
        block = block.split(find).join(replace);
    }
    return new Function('req', 'state', 'LOG_DISPLAY_MAX', 'TURTLE_DISPLAY_MAX', block);
}

const mutIdx = process.argv.indexOf('--mutate');
const merge  = loadMerge(mutIdx > -1 ? process.argv[mutIdx + 1].split('|||') : null);

function freshState() { return { serverLog: [], turtleLogs: {} }; }
function run(state, body) { merge({ body }, state, 200, 30); }

// ─── The regression itself ───────────────────────────────────────────────────

{
    const state = freshState();
    run(state, { serverLog: [{ seq: 1, msg: 'a' }, { seq: 2, msg: 'b' }] });
    run(state, { serverLog: [{ seq: 3, msg: 'c' }] });
    check('server lines accumulate across pushes',
        state.serverLog.length === 3 && state.serverLog[2].msg === 'c',
        `got ${state.serverLog.length}`);
}

{
    const state = freshState();
    run(state, { serverLog: [{ seq: 1, msg: 'a' }] });
    // The steady state once the bridge has acknowledged everything: the server
    // has nothing new to say and sends an empty delta. This is the push that
    // used to wipe the panel.
    run(state, { serverLog: [] });
    run(state, {});
    check('an empty delta does not wipe what is already displayed',
        state.serverLog.length === 1 && state.serverLog[0].msg === 'a',
        `got ${state.serverLog.length}`);
}

{
    const state = freshState();
    run(state, { turtleLogs: { node_1: [{ seq: 1, msg: 'x' }] } });
    run(state, { turtleLogs: { node_2: [{ seq: 1, msg: 'y' }] } });
    check('a push naming one node does not erase the others',
        state.turtleLogs.node_1 && state.turtleLogs.node_1.length === 1 &&
        state.turtleLogs.node_2 && state.turtleLogs.node_2.length === 1,
        JSON.stringify(Object.keys(state.turtleLogs)));
}

// ─── Bounds, because a display buffer that grows for ever is a leak ──────────

{
    const state = freshState();
    for (let i = 0; i < 300; i++) run(state, { serverLog: [{ seq: i, msg: 'line ' + i }] });
    check('the server buffer is bounded',
        state.serverLog.length === 200, `got ${state.serverLog.length}`);
    check('and keeps the NEWEST lines, not the oldest',
        state.serverLog[state.serverLog.length - 1].msg === 'line 299',
        state.serverLog[state.serverLog.length - 1].msg);
}

{
    const state = freshState();
    for (let i = 0; i < 100; i++) run(state, { turtleLogs: { node_1: [{ seq: i, msg: 'l' + i }] } });
    check('the per-node buffer is bounded',
        state.turtleLogs.node_1.length === 30, `got ${state.turtleLogs.node_1.length}`);
}

// ─── Shapes that must not throw ─────────────────────────────────────────────

{
    const state = freshState();
    run(state, { serverLog: 'not an array', turtleLogs: [1, 2, 3] });
    run(state, { turtleLogs: { node_1: 'nope' } });
    check('malformed payloads are ignored rather than thrown on',
        state.serverLog.length === 0 && !state.turtleLogs.node_1);
}

console.log(failures === 0 ? '\nALL PASS' : `\n${failures} FAILED`);
process.exit(failures === 0 ? 0 : 1);
