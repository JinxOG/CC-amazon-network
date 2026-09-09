#!/bin/bash
# Mutation suite for the continuous-log block in server.js (§13.2).
#
# A test that cannot fail is worse than no test: it reports safety it never
# checked. Each entry here breaks one behaviour the suite claims to guard. Every
# one must be KILLED. A SURVIVED line means that assertion is decorative.
#
# Separator is ||| — see the note in test_fleetlog.js before changing it.

cd "$(dirname "$0")" || exit 1
fails=0

run() {
  desc="$1"; mut="$2"
  outp=$(node test_fleetlog.js --mutate "$mut" 2>&1)
  if echo "$outp" | grep -q "HARNESS ERROR"; then
    echo "  ERROR    $desc   <-- mutant did not compile; the mutation is malformed"
    echo "$outp" | grep "HARNESS ERROR" | sed 's/^/             /'
    fails=$((fails+1))
  elif echo "$outp" | grep -q "FAILURE(S)"; then
    echo "  KILLED   $desc"
  else
    echo "  SURVIVED $desc   <-- assertion cannot detect this defect"
    fails=$((fails+1))
  fi
}

run "dedupe disabled"             'if (logSeen.has(key)) return true;|||if (false) return true;'
run "newline collapsing removed"  ".replace(/\r?\n/g, ' ')|||"
run "batch sort removed"          'lines.sort();|||;'
run "level extraction removed"    "return m ? m[1] : '-';|||return '-';"
run "seq no longer preferred"     'if (entry.seq != null) return|||if (false) return'
run "bootId reset removed"        'cur.bootId !== (entry.bootId ?? null)|||false'
run "retention cutoff neutered"   'Date.now() - LOG_RETENTION_DAYS * 86400000|||0'
run "loss ignores the gap"          'Math.max(0, span - c.count)|||span'
run "no-data loss reported as 0%"   'expected > 0 ? +((missing / expected) * 100).toFixed(1) : null|||0'
run "reboots not counted"           'reboots: c ? c.reboots + 1 : 0|||reboots: 0'
run "window never extends down"     'if (entry.seq < c.min) c.min = entry.seq;|||;'
run "slow-push line suppressed"     'if (totalMs >= BUSY_SLOW_PUSH_MS) {|||if (false) {'
run "zero-activity rollup dropped"  'if (b.pushes === 0 && b.writes === 0) {|||if (false) {'
run "log share not computed"        'b.pushMsTotal > 0 ? (b.logMsTotal / b.pushMsTotal) * 100 : null|||null'
run "bridge lines unsequenced"      'bridgeSeq++;|||;'
run "prune deletes non-log files" 'if (!m) continue;|||if (!m) { fs.unlink(path.join(LOG_DIR, f), function(){}); continue; }'

echo ""
if [ "$fails" -eq 0 ]; then echo "ALL MUTANTS KILLED"; else echo "$fails MUTANT(S) NOT KILLED"; fi
exit "$fails"
