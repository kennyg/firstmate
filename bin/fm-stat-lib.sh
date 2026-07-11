# shellcheck shell=bash
# ONE owner for portable `stat` mtime/signature reads across the toolbelt.
# Usage: . "$SCRIPT_DIR/fm-stat-lib.sh"  (leaf lib, no other dependencies)
#
# GNU/coreutils stat spells format `-c <fmt>`; BSD/macOS stat spells it `-f <fmt>`.
# The flavor is NOT determined by the OS: on macOS with GNU coreutils' `stat`
# ahead of /usr/bin/stat on PATH, `uname` is still Darwin yet the GNU form is what
# runs, and the BSD `-f %m` form makes GNU stat read `-f` as *filesystem* mode and
# dump "File: ..."/"Blocks: ..." text to stdout. That text then flows into
# arithmetic like `age=$(( now - m ))` and, under `set -u`, aborts on the stray
# token (e.g. `File: unbound variable`), silently killing the caller mid-cycle.
# So detect the capability, never the OS: try the GNU form once and select it when
# it works. `stat -c %Y` succeeds on GNU and errors cleanly on BSD with no
# filesystem-dump side effect, so the probe itself is safe on either flavor.
[ -n "${FM_STAT_LIB_LOADED:-}" ] && return 0
FM_STAT_LIB_LOADED=1

if stat -c %Y . >/dev/null 2>&1; then
  # GNU/coreutils stat.
  fm_stat_mtime() { stat -c %Y "$1" 2>/dev/null; }        # epoch seconds of mtime
  fm_stat_sig()   { stat -c '%s:%Y' "$1" 2>/dev/null; }   # size:mtime signature
else
  # BSD/macOS stat.
  fm_stat_mtime() { stat -f %m "$1" 2>/dev/null; }
  fm_stat_sig()   { stat -f '%z:%Fm' "$1" 2>/dev/null; }
fi
