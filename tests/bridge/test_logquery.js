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
