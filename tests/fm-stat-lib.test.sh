#!/usr/bin/env bash
# tests/fm-stat-lib.test.sh - unit tests for the portable, capability-probed
# file-mtime helper (bin/fm-stat-lib.sh). Pure functions, no backend required.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=bin/fm-stat-lib.sh
. "$ROOT/bin/fm-stat-lib.sh"

# --- flavor detection --------------------------------------------------------

fm_stat_detect_flavor
case "$FM_STAT_FLAVOR" in
  gnu|bsd) : ;;
  *) fail "fm_stat_detect_flavor must cache gnu or bsd, got '$FM_STAT_FLAVOR'" ;;
esac
pass "fm_stat_detect_flavor resolves to a known stat flavor ($FM_STAT_FLAVOR)"

# --- mtime on a real file returns a bare epoch second ------------------------

TMP=$(fm_test_tmproot fm-stat)
mkdir -p "$TMP"
F="$TMP/probe"
: > "$F"

M=$(fm_stat_mtime "$F")
case "$M" in
  ''|*[!0-9]*) fail "fm_stat_mtime must return bare epoch seconds, got '$M'" ;;
  *) : ;;
esac
pass "fm_stat_mtime returns a bare epoch second on this platform"

# The reported mtime is within a sane window of the wall clock (a real read, not
# a stray "File: ..." dump from the wrong stat flavor).
NOW=$(date +%s)
DELTA=$(( NOW - M ))
[ "$DELTA" -ge -5 ] && [ "$DELTA" -le 300 ] || fail "mtime $M implausible vs now $NOW (delta ${DELTA}s)"
pass "fm_stat_mtime tracks the actual file mtime, not a foreign stat dump"

# --- missing path fails quietly ---------------------------------------------

MISSING=$(fm_stat_mtime "$TMP/does-not-exist")
[ -z "$MISSING" ] || fail "fm_stat_mtime must print nothing for a missing path, got '$MISSING'"
pass "fm_stat_mtime prints nothing for a path it cannot stat"

echo "# fm-stat-lib.test.sh: all assertions passed"
