# shellcheck shell=bash
# bin/fm-stat-lib.sh - the single owner of firstmate's portable file-mtime read.
#
# Usage: . bin/fm-stat-lib.sh ; fm_stat_mtime <path>
#
# WHY THIS EXISTS (upstream issue #464): the supervision and guard path needs a
# file's modification time as a bare epoch second, but the two stat flavors
# disagree on the flag - GNU coreutils stat uses `-c %Y`, BSD/macOS stat uses
# `-f %m`. The historical helpers branched on `uname`, choosing the BSD `-f`
# form on Darwin. That misfires when GNU coreutils' stat is ahead of
# /usr/bin/stat on PATH (a common Homebrew layout): GNU stat reads `-f` as its
# filesystem-mode flag and prints a multi-line "File: ..." dump instead of an
# epoch, and under `set -u` that stray string crashed the watcher with
# "File: unbound variable" and took supervision down.
#
# THE FIX: detect the stat flavor by CAPABILITY, never by OS. Probe `stat -c %Y`
# once against a path guaranteed to be statable (`/`); if that yields a bare
# number this stat speaks GNU and we keep `-c %Y`, otherwise we use the BSD
# `-f %m` form. The probe is a single cheap stat. The FM_STAT_FLAVOR cache avoids
# re-probing only within the same shell scope, so a caller that invokes
# fm_stat_mtime through command substitution re-probes once per call, which is
# negligible.
#
# fm_stat_mtime prints the mtime as epoch seconds on success and nothing (with a
# non-zero exit) when the path cannot be stat'd, matching the old per-helper form
# so callers keep their existing empty-string checks.

FM_STAT_FLAVOR=${FM_STAT_FLAVOR:-}

# fm_stat_detect_flavor: probe the on-PATH stat once and cache gnu/bsd in
# FM_STAT_FLAVOR. GNU stat answers `-c %Y /` with a bare epoch; BSD stat rejects
# `-c` and prints nothing to stdout, so a non-numeric probe means BSD.
fm_stat_detect_flavor() {
  local probe
  probe=$(stat -c %Y / 2>/dev/null)
  case "$probe" in
    ''|*[!0-9]*) FM_STAT_FLAVOR=bsd ;;
    *) FM_STAT_FLAVOR=gnu ;;
  esac
}

# fm_stat_mtime <path>: echo the file's mtime as epoch seconds, nothing on error.
fm_stat_mtime() {
  [ -n "$FM_STAT_FLAVOR" ] || fm_stat_detect_flavor
  if [ "$FM_STAT_FLAVOR" = gnu ]; then
    stat -c %Y "$1" 2>/dev/null
  else
    stat -f %m "$1" 2>/dev/null
  fi
}
