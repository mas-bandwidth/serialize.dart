#!/bin/sh
# The fuzz differential's negative controls (fuzz/differential_test.go):
#
#   tool/fuzz_negative_control.sh
#
# 1. Runs the differential with -sabotage-widen-int, which makes the Go writer
#    write every non-degenerate int range one bit wider than the Dart port does.
# 2. Runs the differential with -sabotage-hostile-read, which reports touched
#    destinations on refused mutant reads.
# Both must go red by a disagreement (not by a build or driver failure).
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
log="$root/fuzz/negative-control.log"
cd "$root/fuzz"
if go test -count=1 -timeout 300s -run 'TestDifferentialAgainstSerializeGo' -v . -sabotage-widen-int > "$log" 2>&1; then
    cat "$log"
    echo "FAIL fuzz negative control: the differential stayed green with the int range widened by one bit"
    exit 1
fi
if ! grep -q 'disagreement:' "$log"; then
    cat "$log"
    echo "FAIL fuzz negative control: red, but not by a disagreement"
    exit 1
fi
grep -m 3 -A 4 'disagreement:' "$log" || true
grep 'disagreements$' "$log" || true
echo "ok fuzz negative control: the widened int range went red"

hostile_log="$root/fuzz/hostile-negative-control.log"
if go test -count=1 -timeout 300s -run 'TestDifferentialAgainstSerializeGo' -v . -sabotage-hostile-read > "$hostile_log" 2>&1; then
    cat "$hostile_log"
    echo "FAIL fuzz hostile-read negative control: the differential stayed green with touched destinations"
    exit 1
fi
if ! grep -q 'disagreement:' "$hostile_log"; then
    cat "$hostile_log"
    echo "FAIL fuzz hostile-read negative control: red, but not by a disagreement"
    exit 1
fi
grep -m 3 -A 4 'disagreement:' "$hostile_log" || true
grep 'disagreements$' "$hostile_log" || true
echo "ok fuzz hostile-read negative control: touched refused destinations went red"
