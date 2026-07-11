#!/usr/bin/env bash
# tests/fm-stat-lib.test.sh - the shared portable-stat helper (bin/fm-stat-lib.sh),
# the ONE fleet-wide owner every mtime/signature read delegates to.
#
# The load-bearing contract (upstream #464, the macOS mirror of the closed Linux
# crash #26): the stat flavor is chosen by a one-time CAPABILITY probe, never by
# OS. On macOS with GNU coreutils' stat first on PATH, `uname` is still Darwin yet
# the BSD `-f %m` form makes GNU stat read `-f` as *filesystem* mode and dump
# "File: ..." text to stdout. That text then flows into arithmetic like
# `age=$(( now - m ))` and, under `set -u`, aborts with `File: unbound variable`,
# silently killing the caller mid-cycle. These tests shim a fake GNU-style stat
# (dumps on `-f %m`, numeric on `-c %Y`) and a fake BSD-style stat (errors on
# `-c %Y`, numeric on `-f %m`) and assert the helper returns a numeric mtime and
# a well-formed size:mtime signature on either flavor, and that the arithmetic
# path stays safe under `set -u`.
#
# Each scenario sources the lib in a fresh `bash -c` process so its one-time
# probe re-runs under that scenario's shimmed PATH.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

STATLIB="$ROOT/bin/fm-stat-lib.sh"
TMP=$(fm_test_tmproot fm-stat-lib-tests)

# --- fake stat shims --------------------------------------------------------

# A fake GNU-style stat: `-c <fmt>` returns the canned value, `-f <fmt>` behaves
# like GNU coreutils' --file-system and dumps a "File: ..." block to stdout with
# exit 0 - never a plain mtime. This is the exact trap #464 describes.
GNU_BIN="$TMP/gnu"; mkdir -p "$GNU_BIN"
cat > "$GNU_BIN/stat" <<'SH'
#!/usr/bin/env bash
case "$1" in
  -c)
    case "$2" in
      %Y) echo 1700000000 ;;
      '%s:%Y') echo '42:1700000000' ;;
      *) echo "gnu-fake: unhandled -c fmt '$2'" >&2; exit 1 ;;
    esac
    ;;
  -f)
    # GNU reads -f as --file-system; it dumps filesystem info, not an mtime.
    printf '  File: "%s"\n    ID: 0 Namelen: 255 Type: apfs\n' "$3"
    ;;
  *) echo "gnu-fake: unhandled arg '$1'" >&2; exit 1 ;;
esac
SH
chmod +x "$GNU_BIN/stat"

# A fake BSD-style stat: `-f <fmt>` returns the canned value, `-c <fmt>` is an
# illegal option that errors to stderr with exit 1 and no stdout side effect.
BSD_BIN="$TMP/bsd"; mkdir -p "$BSD_BIN"
cat > "$BSD_BIN/stat" <<'SH'
#!/usr/bin/env bash
case "$1" in
  -f)
    case "$2" in
      %m) echo 1700000000 ;;
      '%z:%Fm') echo '42:1700000000' ;;
      *) echo "bsd-fake: unhandled -f fmt '$2'" >&2; exit 1 ;;
    esac
    ;;
  -c) echo 'stat: illegal option -- c' >&2; exit 1 ;;
  *) echo "bsd-fake: unhandled arg '$1'" >&2; exit 1 ;;
esac
SH
chmod +x "$BSD_BIN/stat"

TARGET="$TMP/target"; : > "$TARGET"

# call_helper <fakebin-or-empty> <fn> <arg>: source the lib fresh under the given
# fakebin PATH (empty = the real host stat) and echo the helper's output.
call_helper() {
  local bin=$1 fn=$2 arg=$3 path=$PATH
  [ -n "$bin" ] && path="$bin:$PATH"
  PATH="$path" bash -c '. "$1"; "$2" "$3"' _ "$STATLIB" "$fn" "$arg"
}

# age_under_set_u <fakebin>: reproduce the crash path - feed the helper's mtime
# into `set -u` arithmetic and echo `1700000001 - mtime` (stderr merged in).
age_under_set_u() {
  local bin=$1 path=$PATH
  [ -n "$bin" ] && path="$bin:$PATH"
  PATH="$path" bash -c 'set -u; . "$1"; m=$(fm_stat_mtime "$2"); echo $(( 1700000001 - m ))' \
    _ "$STATLIB" "$TARGET" 2>&1
}

# assert_numeric <value> <label>
assert_numeric() {
  case "$1" in
    ''|*[!0-9]*) fail "$2: expected a numeric value, got '$1'" ;;
  esac
}

# --- fake GNU stat first on PATH: capability probe must pick `-c` -----------

test_gnu_flavor_returns_numeric_not_file_dump() {
  local dump mtime sig
  # Confirm the shim really reproduces the trap: the OLD BSD `-f %m` form dumps.
  dump=$(PATH="$GNU_BIN:$PATH" stat -f %m "$TARGET")
  assert_contains "$dump" 'File:' 'fake GNU stat must dump File: text on -f %m (reproduces the trap)'

  mtime=$(call_helper "$GNU_BIN" fm_stat_mtime "$TARGET")
  assert_numeric "$mtime" 'GNU flavor fm_stat_mtime'
  [ "$mtime" = 1700000000 ] || fail "GNU flavor fm_stat_mtime should read the -c %Y value, got '$mtime'"
  assert_not_contains "$mtime" 'File:' 'GNU flavor fm_stat_mtime must not return a File: dump'

  sig=$(call_helper "$GNU_BIN" fm_stat_sig "$TARGET")
  [ "$sig" = '42:1700000000' ] || fail "GNU flavor fm_stat_sig should read '%s:%Y', got '$sig'"
  pass "fm-stat-lib: GNU coreutils stat first on PATH selects -c and returns a numeric mtime"
}

# The exact crash mode #464 reports: the mtime flows into `set -u` arithmetic.
test_gnu_arithmetic_safe_under_set_u() {
  local out
  out=$(age_under_set_u "$GNU_BIN")
  assert_not_contains "$out" 'unbound variable' 'GNU flavor must not crash with File: unbound variable'
  [ "$out" = 1 ] || fail "GNU flavor age arithmetic should be 1, got '$out'"
  pass "fm-stat-lib: GNU flavor mtime is safe in set -u arithmetic (no 'File: unbound variable')"
}

# --- fake BSD stat first on PATH: capability probe must pick `-f` -----------

test_bsd_flavor_returns_numeric() {
  local mtime sig
  mtime=$(call_helper "$BSD_BIN" fm_stat_mtime "$TARGET")
  assert_numeric "$mtime" 'BSD flavor fm_stat_mtime'
  [ "$mtime" = 1700000000 ] || fail "BSD flavor fm_stat_mtime should read the -f %m value, got '$mtime'"

  sig=$(call_helper "$BSD_BIN" fm_stat_sig "$TARGET")
  [ "$sig" = '42:1700000000' ] || fail "BSD flavor fm_stat_sig should read '%z:%Fm', got '$sig'"
  pass "fm-stat-lib: BSD stat first on PATH selects -f and returns a numeric mtime"
}

test_bsd_arithmetic_safe_under_set_u() {
  local out
  out=$(age_under_set_u "$BSD_BIN")
  [ "$out" = 1 ] || fail "BSD flavor age arithmetic should be 1, got '$out'"
  pass "fm-stat-lib: BSD flavor mtime is safe in set -u arithmetic"
}

# --- real stat sanity -------------------------------------------------------

test_real_stat_returns_numeric() {
  local mtime sig
  mtime=$(call_helper '' fm_stat_mtime "$TARGET")
  assert_numeric "$mtime" 'real stat fm_stat_mtime'
  sig=$(call_helper '' fm_stat_sig "$TARGET")
  case "$sig" in
    *:*) assert_numeric "${sig%%:*}" 'real stat sig size'; mtime="${sig##*:}"; assert_numeric "${mtime%%.*}" 'real stat sig mtime' ;;
    *) fail "real stat fm_stat_sig should be 'size:mtime', got '$sig'" ;;
  esac
  pass "fm-stat-lib: real host stat returns a numeric mtime and a size:mtime signature"
}

test_gnu_flavor_returns_numeric_not_file_dump
test_gnu_arithmetic_safe_under_set_u
test_bsd_flavor_returns_numeric
test_bsd_arithmetic_safe_under_set_u
test_real_stat_returns_numeric
