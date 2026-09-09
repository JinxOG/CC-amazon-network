// Two failures the maintainer found on 2026-09-09, both of the same species:
// something that returns a plausible wrong answer instead of failing loudly.
//
//  1. UTF-8 arriving one byte per character, so an em-dash reads as "â".
//  2. Log filenames are UTC; the documented check used LOCAL date, so for the
//     last hours of every day west of UTC it read yesterday's finished file and
//     returned real, correctly-formatted, hours-old lines. That cost a wrong
//     conclusion: seq:null on every line looked like a broken feature, and was
//     actually pre-1.9.88 lines from the previous UTC day.
//
// Usage: node test_logencoding.js [--mutate '<find>|||<replace>']

const fs   = require('fs');
const path = require('path');

const SERVER = path.join(__dirname, '..', '..', 'server.js');
const START  = 'function repairMojibake';
const END    = 'function ingestLogs';

let failures = 0;
function check(name, cond, detail) {
    if (cond) console.log(`  PASS  ${name}`);
    else { console.log(`  FAIL  ${name}${detail ? ' — ' + detail : ''}`); failures++; }
}

function load(mutation) {
    let src = fs.readFileSync(SERVER, 'utf8');
    const a = src.indexOf(START), b = src.indexOf(END, a);
    if (a < 0 || b < 0) throw new Error('could not locate the repair block — markers moved');
    let block = src.slice(a, b);
    if (mutation) {
        const [find, replace] = mutation;
        if (!block.includes(find)) {
            console.log(`  MALFORMED  mutation target not found: ${find}`);
            process.exit(2);
        }
        block = block.split(find).join(replace);
    }
    return new Function('Buffer', block + '\nreturn { repairMojibake, repairIncomingLogs };')(Buffer);
}

const mi = process.argv.indexOf('--mutate');
const M  = load(mi > -1 ? process.argv[mi + 1].split('|||') : null);

// ─── The repair ─────────────────────────────────────────────────────────────

{
    // Exactly what the live log contained: 0xe2 0x80 0x94, the em-dash's three
    // UTF-8 bytes arriving as three separate characters.
    const broken = 'Server reconnected \u00e2\u0080\u0094 resuming from 161,67,-2806';
    const fixed  = M.repairMojibake(broken);
    check('byte-expanded UTF-8 is put back together',
        fixed === 'Server reconnected — resuming from 161,67,-2806', JSON.stringify(fixed));
}

{
    // The guard that matters most: a string that is ALREADY correct must come
    // through untouched. A repair that damages good input is worse than the
    // corruption it fixes, because it would be applied to every line for ever.
    const good = 'Server reconnected — resuming';
    check('an already-correct string is not touched', M.repairMojibake(good) === good,
        JSON.stringify(M.repairMojibake(good)));
}

{
    // MIXED content, which is the case that distinguishes the two guards.
    //
    // 'é' is 0xE9 so it passes the "contains high Latin-1" test, and '—' is
    // U+2014 so it can only have come from a correctly-decoded string. Without
    // the >0xFF guard, Buffer.from(.., 'latin1') truncates U+2014 to 0x14 and
    // silently mangles a line that was already right. Neither guard alone is
    // caught by the simpler cases above -- each covers for the other there --
    // so this is the one that pins the second.
    const mixed = 'café — done';
    check('a correct string with BOTH high-Latin-1 and wide characters survives',
        M.repairMojibake(mixed) === mixed, JSON.stringify(M.repairMojibake(mixed)));
}

{
    // The case where the >0xFF guard is the ONLY thing standing between a
    // correct string and silent corruption.
    //
    // 'Ã' (U+00C3) and 'Ʃ' (U+01A9) truncate to bytes C3 A9, which is VALID
    // UTF-8 for 'é'. So the invalid-decode check waves it through and the string
    // is quietly rewritten. Contrived, and that is the point: the simpler cases
    // are all covered twice over, so only this one shows the guard doing work.
    // Found by hunting for it after its mutant survived, rather than by
    // assuming a surviving mutant meant a redundant guard.
    const wide = 'ÃƩ';
    check('a wide character is never truncated into a plausible byte pair',
        M.repairMojibake(wide) === wide, JSON.stringify(M.repairMojibake(wide)));
}

{
    check('plain ASCII is not touched',
        M.repairMojibake('Bridge push timed out (>4s)') === 'Bridge push timed out (>4s)');
    // Latin-1 that is NOT byte-expanded UTF-8: 0xE9 alone is an invalid UTF-8
    // start byte, so the decode fails and the original must survive.
    check('a lone high byte that is not valid UTF-8 is left alone',
        M.repairMojibake('caf\u00e9') === 'caf\u00e9',
        JSON.stringify(M.repairMojibake('caf\u00e9')));
    check('non-string input does not throw', M.repairMojibake(null) === null);
    // NOTE for a future mutation run: the leading
    // `!/[-ÿ]/.test(str)` early-return is an OPTIMISATION, not a
    // guard. Removing it changes no result -- pure ASCII round-trips through
    // latin1 unchanged, and anything wider is caught by the >0xFF test. Its
    // mutant surviving is the correct outcome, not a hole.
}

// ─── Applied to the whole payload, once, before both consumers ──────────────

{
    const body = {
        serverLog:  [{ msg: 'a \u00e2\u0080\u0094 b' }],
        turtleLogs: { node_1: [{ msg: 'c \u00e2\u0080\u0094 d' }] },
    };
    M.repairIncomingLogs(body);
    check('server lines are repaired', body.serverLog[0].msg === 'a — b',
        body.serverLog[0].msg);
    // The file writer and the /state display buffers read from the same payload.
    // Repairing in only one of them leaves the other showing mojibake.
    check('turtle lines are repaired too', body.turtleLogs.node_1[0].msg === 'c — d',
        body.turtleLogs.node_1[0].msg);
}

{
    // Shapes that arrive from a misbehaving or older server must not throw --
    // this runs on the /update path, and an exception here costs the response.
    for (const body of [{}, { serverLog: 'nope' }, { turtleLogs: [1, 2] },
                        { turtleLogs: { n: 'nope' } }, { serverLog: [null, 5] }]) {
        let threw = false;
        try { M.repairIncomingLogs(body); } catch { threw = true; }
        check(`malformed payload ${JSON.stringify(body).slice(0, 28)} does not throw`, !threw);
    }
}

// ─── SOURCE-ONLY, weaker: the date trap ─────────────────────────────────────

{
    const src = fs.readFileSync(SERVER, 'utf8');

    check('the repair runs before both consumers, not inside one of them',
        src.includes('repairIncomingLogs(req.body || {})'),
        'repairing in the writer alone leaves the dashboard showing mojibake');

    check('the log day is UTC',
        src.includes("const day  = new Date().toISOString().slice(0, 10);"));

    check('a date-free path into the current file exists',
        src.includes("path.join(LOG_DIR, 'current.txt')"),
        'someone will always type `date +%F`, and it is local');

    check('a filesystem without symlinks degrades instead of failing the write',
        src.includes('logSymlinkWarned'));

    check("the API resolves 'latest' so no caller computes a date",
        src.includes("dateParam === 'latest' || dateParam === 'today'"));

    check('the index states the filename convention',
        src.includes('filenames:') && src.includes('todayUtc:'),
        'it was found by working it out from a timestamp mismatch');
}

console.log(failures === 0 ? '\nALL PASS' : `\n${failures} FAILED`);
process.exit(failures === 0 ? 0 : 1);
