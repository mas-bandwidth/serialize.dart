#!/bin/sh
# The fuzz differential's negative control (fuzz/differential_test.go):
#
#   tool/fuzz_negative_control.sh
#
# Runs the differential with -sabotage-widen-int, which makes the Go writer
# write every non-degenerate int range one bit wider than the Dart port does.
# A differential that stayed green on that would be measuring nothing, so this
# passes only when the test goes red, and red by a disagreement (not by a
# build or driver failure). The log is left at fuzz/negative-control.log.
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
