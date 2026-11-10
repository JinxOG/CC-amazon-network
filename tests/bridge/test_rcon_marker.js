// initMarkerSet, as it ships in server.js.
//
// WHY THIS SUITE EXISTS. On 2026-11-10 a cold bridge was started with nothing
// listening on the RCON port, and it logged:
//
//     [RCON] Marker set already exists (ok)
//
// RCON was not merely absent, it was unreachable — and the bridge said "(ok)".
// Dynmap markers are how turtle positions reach the map, so rotated
// credentials or a moved port would have stopped the map updating and the log
// would never have said so. The pass state and the no-data state were the same
// line. That is the shape behind most of this project's silent failures, so
// the branch is now pinned by tests rather than by a comment.
//
// The function is extracted from the real server.js source text and RUN, with
// rcon() injected, so these are behavioural assertions and not string matches.
// express is not installed here, which is exactly why the function is lifted
// out instead of the module being required.
//
// Usage: node test_rcon_marker.js [--mutate '<find>|||<replace>']
//
// Separator is ||| and not '=>' — an arrow function in a replacement string
// got split on '=>' and silently truncated into a syntax error, which the
// runner then reported as a SURVIVING mutant. Do not change it back.

const fs   = require('fs');
const path = require('path');

const SERVER = path.join(__dirname, '..', '..', 'server.js');
const START  = '// Whether the Dynmap marker set is usable.';
const END    = 'async function upsertMarker(';

let failures = 0;
function check(name, cond, detail) {
    if (cond) console.log(`  PASS  ${name}`);
    else { console.log(`  FAIL  ${name}${detail ? ' — ' + detail : ''}`); failures++; }
}

// Load-time and run-time failures are kept apart deliberately. A mutant that
// makes the code THROW is a mutant the suite killed; reporting that as
// "HARNESS ERROR" is how four real kills were once thrown away as errors.
function loadBlock(mutation) {
    const src   = fs.readFileSync(SERVER, 'utf8');
    const start = src.indexOf(START);
    const end   = src.indexOf(END, start);
    if (start < 0 || end < 0) throw new Error('could not locate initMarkerSet — markers moved');
    let block = src.slice(start, end);
    if (mutation) {
        const [find, replace] = mutation;
        if (!block.includes(find)) {
            console.log(`  MALFORMED  mutation target not found: ${find}`);
            process.exit(2);
        }
        block = block.split(find).join(replace);
    }
    return new Function('rcon', 'CFG', 'console',
        block + '\nreturn { initMarkerSet, ready: () => markerSetReady };');
}

const mutIdx  = process.argv.indexOf('--mutate');
const factory = loadBlock(mutIdx > -1 ? process.argv[mutIdx + 1].split('|||') : null);

const CFG = { dynmap: { set: 'turtles', world: 'world' } };

// A console that records instead of printing, so the suite can assert on what
// an operator would actually see.
function recorder() {
    const lines = [];
    const push = (level) => (...a) => lines.push(level + ' ' + a.join(' '));
    return { lines, log: push('log'), warn: push('warn'), error: push('error') };
}

// Builds an initMarkerSet whose rcon() behaves as told: 'ok' replies, 'throw'
// fails at the transport level the way an unreachable RCON does.
function scenario(behaviour) {
    const sent = [];
    const con  = recorder();
    const rcon = async (cmd) => {
        sent.push(cmd);
        const verb = cmd.split(' ')[0].replace('dmarker ', '');
        const mode = cmd.includes('addset') ? behaviour.addset : behaviour.updateset;
        if (mode === 'throw') throw new Error(behaviour.message || 'connect ECONNREFUSED 127.0.0.1:25575');
        return 'ok';
    };
    const mod = factory(rcon, CFG, con);
    return { mod, sent, con };
}

// ─── The branch that was wrong ──────────────────────────────────────────────

(async () => {
    {
        // Both commands fail at the transport level: RCON is unreachable. This
        // is the exact condition measured on 2026-11-10.
        const s = scenario({ addset: 'throw', updateset: 'throw' });
        await s.mod.initMarkerSet();
        const all = s.con.lines.join('\n');

        check('an unreachable RCON is NOT reported as ok',
            !/\(ok\)/.test(all) && !/already exists/i.test(all),
            'operator saw: ' + JSON.stringify(all));
        check('it says the markers are not being updated',
            /not being updated|NOT being updated/i.test(all),
            'operator saw: ' + JSON.stringify(all));
        check('it carries the underlying error, so the cause is diagnosable',
            /ECONNREFUSED/.test(all), 'operator saw: ' + JSON.stringify(all));
        check('it is logged at warn, not buried in log',
            s.con.lines.some(l => l.startsWith('warn')),
            s.con.lines.map(l => l.split(' ')[0]).join(','));
        check('the marker set is recorded as NOT ready',
            s.mod.ready() === false, String(s.mod.ready()));
        check('both commands were actually attempted before giving up',
            s.sent.length === 2, JSON.stringify(s.sent));
    }

    // ─── The two healthy paths must stay healthy ────────────────────────────

    {
        // A fresh set: addset succeeds. Dynmap answers a pre-existing set with
        // a normal reply rather than an error, so this path covers that too —
        // which is why the catch below is not an "already exists" branch.
        const s = scenario({ addset: 'ok', updateset: 'ok' });
        await s.mod.initMarkerSet();
        const all = s.con.lines.join('\n');
        check('a working RCON reports the set created', /created/i.test(all), all);
        check('and records the set ready', s.mod.ready() === true, String(s.mod.ready()));
        check('and does not warn', !s.con.lines.some(l => l.startsWith('warn')), all);
        check('updateset is not sent when addset worked',
            s.sent.length === 1, JSON.stringify(s.sent));
    }

    {
        // addset rejected but the connection is live: the update path.
        const s = scenario({ addset: 'throw', updateset: 'ok' });
        await s.mod.initMarkerSet();
        const all = s.con.lines.join('\n');
        check('a rejected addset falls through to updateset', /updated/i.test(all), all);
        check('and records the set ready', s.mod.ready() === true, String(s.mod.ready()));
        check('and does not warn', !s.con.lines.some(l => l.startsWith('warn')), all);
    }

    {
        // Before anything is attempted the state must be UNKNOWN, never
        // healthy. A default of true would make "no attempt yet" and "working"
        // the same value — the same conflation this suite exists to prevent.
        const s = scenario({ addset: 'ok', updateset: 'ok' });
        check('the ready flag starts unknown rather than healthy',
            s.mod.ready() === null, String(s.mod.ready()));
    }

    {
        // initMarkerSet is called from the listen callback without await. If it
        // rejected, that would be an unhandled rejection at boot.
        const s = scenario({ addset: 'throw', updateset: 'throw' });
        let threw = false;
        try { await s.mod.initMarkerSet(); } catch { threw = true; }
        check('it never rejects, so the unawaited boot call is safe', !threw);
    }

    console.log(failures === 0 ? '\nALL PASS' : `\n${failures} FAILED`);
    process.exit(failures === 0 ? 0 : 1);
})();
