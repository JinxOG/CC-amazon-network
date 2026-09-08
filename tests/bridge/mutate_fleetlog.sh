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
run "prune deletes non-log files" 'if (!m) continue;|||if (!m) { fs.unlink(path.join(LOG_DIR, f), function(){}); continue; }'

echo ""
if [ "$fails" -eq 0 ]; then echo "ALL MUTANTS KILLED"; else echo "$fails MUTANT(S) NOT KILLED"; fi
exit "$fails"
