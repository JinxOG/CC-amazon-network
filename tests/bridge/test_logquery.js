// The /logs query API, as it ships in server.js.
//
// Express is not installed here so the routes cannot be mounted, but the two
// pieces that decide correctness -- the line parser and the path guard -- are
// pure functions, and they are extracted from the real source text and run.
// The route body is asserted at source level, and labelled as the weaker thing
// it is.
//
// Usage: node test_logquery.js [--mutate '<find>|||<replace>']

const fs   = require('fs');
const path = require('path');

const SERVER = path.join(__dirname, '..', '..', 'server.js');
const START  = '// ─── Log query API';
const END    = "app.get('/logs', (req, res) => {";

let failures = 0;
function check(name, cond, detail) {
    if (cond) console.log(`  PASS  ${name}`);
    else { console.log(`  FAIL  ${name}${detail ? ' — ' + detail : ''}`); failures++; }
}

function loadPure(mutation) {
    let src = fs.readFileSync(SERVER, 'utf8');
    const start = src.indexOf(START);
    const end   = src.indexOf(END, start);
    if (start < 0 || end < 0) throw new Error('could not locate the log query block — markers moved');
    let block = src.slice(start, end);
    if (mutation) {
        const [find, replace] = mutation;
        if (!block.includes(find)) {
            console.log(`  MALFORMED  mutation target not found: ${find}`);
            process.exit(2);
        }
        block = block.split(find).join(replace);
    }
    // path is referenced by logFileFor; LOG_DIR stands in for the real one.
    return new Function('path', 'LOG_DIR',
        block + '\nreturn { parseLogLine, logFileFor, LOG_QUERY_MAX, LOG_QUERY_DEFAULT };');
}

const mutIdx = process.argv.indexOf('--mutate');
const M = loadPure(mutIdx > -1 ? process.argv[mutIdx + 1].split('|||') : null)(path, '/logs');

// ─── Parsing the format the writer actually produces ─────────────────────────

{
    // Byte-for-byte the shape logFormatLine emits: ISO ts, TWO spaces, source
    // padded to 9, level padded to 6, then the message.
    const line = '2026-09-08T08:02:49.923Z  server    WARN   Bridge push timed out (>4s)';
    const e = M.parseLogLine(line);
    check('parses a server line', e && e.source === 'server' && e.level === 'WARN', JSON.stringify(e));
    check('keeps the whole message including spaces',
        e && e.msg === 'Bridge push timed out (>4s)', e && e.msg);
}

{
    // A turtle line: longer source name, and a message that already carries its
    // own [node][LEVEL] prefix because turtles capture print() verbatim.
    const line = '2026-09-08T00:43:11.002Z  node_118  INFO   [node_118][INFO] phase: SCANNING';
    const e = M.parseLogLine(line);
    check('parses a turtle line', e && e.source === 'node_118' && e.level === 'INFO', JSON.stringify(e));
    check('does not eat the message\'s own prefix',
        e && e.msg.startsWith('[node_118][INFO]'), e && e.msg);
}

{
    check('a blank line yields nothing', M.parseLogLine('') === null);
    check('a garbage line yields nothing rather than a half-entry',
        M.parseLogLine('not a log line') === null,
        JSON.stringify(M.parseLogLine('not a log line')));
}

// ─── Sequence numbers in the line (1.9.88) ──────────────────────────────────
//
// Delivery was already provable LIVE -- send a probe, watch it land. What was
// impossible was opening yesterday's file and showing that nothing went
// missing, which is the question you actually want to ask of a log.

{
    const line = '2026-09-08T16:07:21.791Z  server#27      INFO   Bridge cmd: LOGPROBE';
    const e = M.parseLogLine(line);
    check('a sequenced line splits source from seq',
        e && e.source === 'server' && e.seq === 27, JSON.stringify(e));
    check('and keeps the message intact',
        e && e.msg === 'Bridge cmd: LOGPROBE', e && e.msg);
}

{
    const line = '2026-09-08T00:43:11.002Z  node_118#1043  INFO   [node_118][INFO] phase: SCANNING';
    const e = M.parseLogLine(line);
    check('a node id survives the split unchanged',
        e && e.source === 'node_118' && e.seq === 1043, JSON.stringify(e));
}

{
    // Lines written before 1.9.88, and lines from any node too old to send a
    // sequence, must still parse. A log you cannot read the older half of is
    // not much of a log.
    const line = '2026-09-08T08:02:49.923Z  server    WARN   Bridge push timed out (>4s)';
    const e = M.parseLogLine(line);
    check('an unsequenced line still parses, with seq null',
        e && e.source === 'server' && e.seq === null, JSON.stringify(e));
}

{
    // A '#' inside the MESSAGE must not be mistaken for the sequence join. The
    // split is on the source token only, which never contains a space.
    //
    // NOTE, so a future mutation run is not misread: the parser uses
    // lastIndexOf rather than indexOf, and NO test distinguishes them. Source
    // names are 'server' and 'node_NNN' -- none contains a '#' -- so the two are
    // identical in every reachable case. That choice is defensive, not
    // load-bearing, and its mutant surviving is the correct result rather than a
    // hole in the suite.
    const line = '2026-09-08T16:07:21.791Z  server#27      INFO   chest #4 is full';
    const e = M.parseLogLine(line);
    check('a hash in the message is not treated as a sequence',
        e && e.seq === 27 && e.msg === 'chest #4 is full', JSON.stringify(e));
}

// SOURCE-ONLY, weaker: the writer and the auditor both live outside this
// extracted block -- the writer in the fleetlog block, the auditor inside the
// route handler.
{
    const src = fs.readFileSync(SERVER, 'utf8');

    check('the writer actually puts the sequence in the line',
        src.includes('entry.seq != null ? `${source}#${entry.seq}` : source'),
        'without this the parser above has nothing to parse');

    const start = src.indexOf(START);
    const route = src.slice(start, src.indexOf("app.get('/state'", start));

    // The distinction that makes the audit trustworthy rather than alarming: a
    // reboot restarts seq at 1, and counting that as 1042 missing lines would
    // report a catastrophe every time a turtle reboots.
    check('the audit counts a DECREASE as a reboot, not as a gap',
        route.includes('if (e.seq < st.prev) st.reboots++;'));
    check('and only counts a FORWARD skip as missing lines',
        route.includes('st.missing += e.seq - st.prev - 1;'));
    check('unsequenced lines make no continuity claim',
        route.includes('if (e.seq == null) { st.unsequenced++; return; }'),
        'claiming "no gaps" about lines that cannot show one is worse than silence');
    // Anchored on the PROPERTY, not on a formatting-sensitive literal: the
    // previous version pinned an exact one-line `return res.json({...})` and
    // went red when that call was reformatted across lines, which told us
    // nothing about the code.
    check('the audit is computed on the bridge, not by shipping every line',
        route.includes('sources: out2') &&
        route.includes('// audit counts lines; it does not collect them'));

    // An audit must report its own sufficiency. Without this a one-line window
    // returns gaps:0 and reads exactly like ten thousand clean ones -- the
    // third instance of one shape, after an empty display buffer read as a
    // broken feature and a local-date filename reading yesterday's file.
    // Anchored on the COMPARISON, not the word. `insufficient` appears in the
    // response field, the verdict and the note, so matching the identifier
    // passed with the value hardcoded to false -- caught by mutation, and the
    // third assertion this session that matched prose instead of logic.
    check('the audit says when it has too little data to conclude anything',
        route.includes('sequencedTotal < minLines'),
        'a clean window and an empty one must not produce identical JSON');
    check('and says so per source as well as overall',
        route.includes('conclusive: sequenced >= minLines'));
    check('unsequenced lines are REPORTED, not merely skipped',
        route.includes('unsequenced: st.unsequenced'),
        'a source whose lines all predate the sequence shows gaps:0, and that '
        + 'zero is a statement about nothing');
}

// ─── The path guard, which is the one with teeth ────────────────────────────

{
    check('accepts a real date', M.logFileFor('2026-09-08') !== null);
    for (const bad of ['../../etc/passwd', '2026-09-08/../../x', '..', '', 'latest',
                       '2026-9-8', '2026-09-08.txt']) {
        check(`refuses ${JSON.stringify(bad)}`, M.logFileFor(bad) === null,
            String(M.logFileFor(bad)));
    }
}

// ─── Bounds ─────────────────────────────────────────────────────────────────

{
    check('a limit ceiling exists', M.LOG_QUERY_MAX > 0 && M.LOG_QUERY_MAX <= 20000,
        String(M.LOG_QUERY_MAX));
    check('and a default below it', M.LOG_QUERY_DEFAULT < M.LOG_QUERY_MAX,
        `${M.LOG_QUERY_DEFAULT}/${M.LOG_QUERY_MAX}`);
}

// ─── SOURCE-ONLY, and weaker: the property that protects the fleet ──────────
//
// This process also answers POST /update every 3 seconds. Reading a 10 MB file
// synchronously would block the event loop, and a CC server waiting on this
// bridge is a CC server deaf to its own radio -- the mechanism behind every
// dropped heartbeat this system has had. The route must stream.
{
    const src = fs.readFileSync(SERVER, 'utf8');
    const start = src.indexOf(START);
    const end   = src.indexOf("app.get('/state'", start);
    const route = src.slice(start, end);
    check('the query route streams rather than buffering the file',
        route.includes('createReadStream') && route.includes('readline.createInterface'));
    // Anchored on the CALL form (`fs.readFileSync(`), not the bare identifier:
    // the comment above this route warns against readFileSync by name, so the
    // bare form matched the prose and failed against correct code. A test that
    // reads its own warning label is no test at all.
    check('and never reads a log file whole',
        !route.includes('fs.readFileSync(') && !route.includes('fs.readFile('),
        'a synchronous read here blocks /update');
    check('the tail path keeps a bounded window, not the whole match set',
        route.includes('out.shift()'));
}

console.log(failures === 0 ? '\nALL PASS' : `\n${failures} FAILED`);
process.exit(failures === 0 ? 0 : 1);
