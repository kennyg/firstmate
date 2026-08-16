#!/usr/bin/env bash
# fm-send post-submit settle wait (FM_SEND_SETTLE).
#
# fm-send's success only proves the composer cleared - the Enter landed and the
# text was submitted. The harness then takes a beat to spin up the turn before its
# busy state appears, so an immediate peek after fm-send returns would see the
# stale idle pane. fm-send therefore waits after a successful text submit, so the
# receiving turn has time to visibly start. FM_SEND_SETTLE (default 1, 0 disables)
# is the CAP on that wait, not a fixed duration: a target with recorded metadata is
# polled against the semantic busy-state contract (bin/fm-busy-lib.sh) and the wait
# ends as soon as it reads busy. These tests pin that behavior hermetically
# (stubbed tmux + sleep, no real agent):
#   1. An explicit session:window target has no recorded harness to classify, so it
#      still pauses the fixed FM_SEND_SETTLE value (default 1).
#   2. FM_SEND_SETTLE=0 produces no wait at all (sleep is never invoked for it).
#   3. That fixed pause is tunable (FM_SEND_SETTLE=7 pauses 7).
#   4. The --key path never waits (it bypasses the submit/settle path entirely).
#   5. A metadata-bearing target that already reads busy returns with no settle
#      wait at all - the bounded poll's whole point.
#   6. A metadata-bearing target with no busy record at all never reads busy, so it
#      waits the full cap: unknown is never promoted to busy, so the wait can end
#      early but never late.
#   7. A metadata-bearing target whose busy record is UNREADABLE also waits the full
#      cap - the other half of case 6, and the reason this change cannot regress a
#      target it cannot classify.
#   8. The cap keeps its meaning for the poll (FM_SEND_SETTLE=0.5 halves the
#      unresolved wait).
#
# The poll's step size is fm-send's own implementation detail, so cases 5-8 never
# pin it. They run the same send twice - once with FM_SEND_SETTLE=0 to record what
# the submit core sleeps on its own, once at the real cap - and drop that baseline
# from the head of the second log, leaving only the settle wait. The unresolved
# cases then assert that the wait opens exactly one sleep for the whole cap (the
# deadline the poll runs inside, and the reason an unresolved wait costs no more
# than it did before) and that every poll step is shorter than it. Both are
# recorded, and their order is a race between the deadline and the first step, so
# the assertions are on the set of sleeps, never on their sequence.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-busy-lib.sh"

SEND="$ROOT/bin/fm-send.sh"

TMP_ROOT=$(fm_test_tmproot fm-send-settle)

# A fake tmux that lets fm-send's submit path reach a clean "empty" verdict, plus a
# fake sleep that records every requested duration (one per line) instead of
# sleeping. send-keys always succeeds; display-message yields a numeric cursor_y;
# capture-pane returns an empty bordered composer so fm_tmux_composer_state reads
# "empty" (submit landed) on the first Enter. The sleep log path comes from
# FM_SLEEP_LOG.
make_stubs() {  # <dir> -> echoes fakebin dir
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  send-keys) exit 0 ;;
  display-message)
    for a in "$@"; do case "$a" in *cursor_y*) printf '1\n'; exit 0 ;; esac; done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane) printf '╭────╮\n│    │\n╰────╯\n'; exit 0 ;;
  list-windows) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  cat > "$fb/sleep" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${1:-}" >> "$FM_SLEEP_LOG"
exit 0
SH
  chmod +x "$fb/sleep"
  printf '%s\n' "$fb"
}

# run_send <fakebin> <sleep-log> [env-assignments...] -- <fm-send args...>
# Runs fm-send.sh with the stubs on PATH. FM_ROOT_OVERRIDE points at a non-repo
# temp dir so fm-guard's tangle check stays silent, and FM_HOME at an empty home so
# no in-flight task is seen; guard noise goes to stderr (discarded). Echoes nothing;
# returns fm-send's exit code.
run_send() {
  local fb=$1 log=$2 home; shift 2
  home="$TMP_ROOT/home-$RANDOM"; mkdir -p "$home/state"
  : > "$log"
  env "$@" PATH="$fb:$PATH" \
    FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_SLEEP_LOG="$log" \
    "$SEND" "sess:win" "hello captain" 2>/dev/null
}

# settle_sleeps <fakebin> <dir> <task-id> <cap>: echo the sleeps fm-send makes
# AFTER the submit, one per line. The same send is run twice - once with
# FM_SEND_SETTLE=0 to record the submit core's own waits, once at the real cap -
# and the baseline's line count is dropped from the head of the second log, so
# what is left is the settle wait and nothing else.
settle_sleeps() {
  local fb=$1 dir=$2 id=$3 cap=$4 log="$2/sleep.log" base
  : > "$log"
  env PATH="$fb:$PATH" FM_HOME="$dir/home" FM_SLEEP_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" "$id" "hello captain" 2>/dev/null || return 1
  base=$(wc -l < "$log")
  : > "$log"
  env PATH="$fb:$PATH" FM_HOME="$dir/home" FM_SLEEP_LOG="$log" FM_SEND_SETTLE="$cap" \
    "$SEND" "$id" "hello captain" 2>/dev/null || return 1
  tail -n "+$((base + 1))" "$log"
}

# assert_capped_settle <settle-sleeps> <cap> <what>: the unresolved wait must open
# on the cap itself - one sleep for the whole cap, which is also the deadline the
# poll runs inside - and every later poll step must be shorter than it, so the
# wait ends at the cap whatever the poll does.
assert_capped_settle() {
  local settle=$1 cap=$2 what=$3 deadlines
  deadlines=$(printf '%s\n' "$settle" | grep -c -x -- "$cap" || true)
  [ "$deadlines" = 1 ] \
    || fail "$what must wait on exactly one full ${cap}s cap, saw $deadlines"$'\n'"--- settle sleeps ---"$'\n'"$settle"
  printf '%s\n' "$settle" | grep -v -x -- "$cap" | awk -v cap="$cap" '$1 >= cap { exit 1 }' \
    || fail "$what polled in steps that are not shorter than the ${cap}s cap"$'\n'"--- settle sleeps ---"$'\n'"$settle"
}

# make_meta_target <dir> <id> <busy|unknown|unreadable>: build a home with one
# recorded task whose endpoint is the stub tmux pane, and shape its busy state.
# "unknown" leaves the task with no busy record at all; "unreadable" arms the
# contract and then corrupts the record, so the classifier can read the file but
# cannot trust it. Both must still wait the full cap - the second is the case that
# proves an unclassifiable target is never promoted to busy.
make_meta_target() {
  local dir=$1 id=$2 want=$3 home="$1/home" gen
  mkdir -p "$home/state"
  fm_write_meta "$home/state/$id.meta" \
    "window=sess:win" "worktree=$home/wt" "project=$home/project" \
    "harness=claude" "kind=ship" "mode=no-mistakes" "yolo=off"
  case $want in
    busy|unreadable)
      gen=$("$ROOT/bin/fm-busy-event.sh" arm "$home/state" "$id")
      printf 'busy_gen=%s\n' "$gen" >> "$home/state/$id.meta"
      ;;
  esac
  if [ "$want" = unreadable ]; then
    printf 'not-a-busy-record\n' > "$(fm_busy_record_path "$home/state" "$id")"
  fi
}

test_default_send_pauses_one_second() {
  local dir fb log rc last
  dir="$TMP_ROOT/default"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/sleep.log"
  run_send "$fb" "$log"; rc=$?
  expect_code 0 "$rc" "default send should succeed"
  last=$(tail -1 "$log")
  [ "$last" = 1 ] || fail "default send: expected a trailing 1s settle pause, got '$last'"$'\n'"--- sleeps ---"$'\n'"$(cat "$log")"
  pass "fm-send: a successful text send pauses the default 1s after submit"
}

test_zero_disables_pause() {
  local dir fb log rc
  dir="$TMP_ROOT/zero"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/sleep.log"
  run_send "$fb" "$log" FM_SEND_SETTLE=0; rc=$?
  expect_code 0 "$rc" "FM_SEND_SETTLE=0 send should succeed"
  # The disable path must not invoke sleep with 0 at all - the only sleeps left are
  # the submit core's own settle/enter waits, none of which is "0".
  if grep -qx '0' "$log"; then
    fail "FM_SEND_SETTLE=0 still paused (a sleep 0 was recorded)"$'\n'"--- sleeps ---"$'\n'"$(cat "$log")"
  fi
  pass "fm-send: FM_SEND_SETTLE=0 produces no settle pause"
}

test_pause_is_tunable() {
  local dir fb log rc last
  dir="$TMP_ROOT/tunable"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/sleep.log"
  run_send "$fb" "$log" FM_SEND_SETTLE=7; rc=$?
  expect_code 0 "$rc" "FM_SEND_SETTLE=7 send should succeed"
  last=$(tail -1 "$log")
  [ "$last" = 7 ] || fail "FM_SEND_SETTLE=7: expected a trailing 7s settle pause, got '$last'"$'\n'"--- sleeps ---"$'\n'"$(cat "$log")"
  pass "fm-send: the settle pause is tunable via FM_SEND_SETTLE"
}

test_key_path_never_pauses() {
  local dir fb log rc home
  dir="$TMP_ROOT/key"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/sleep.log"
  home="$dir/home"; mkdir -p "$home/state"
  : > "$log"
  env PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_SLEEP_LOG="$log" \
    "$SEND" "sess:win" --key Escape 2>/dev/null; rc=$?
  expect_code 0 "$rc" "--key send should succeed"
  [ ! -s "$log" ] || fail "--key path paused but must not"$'\n'"--- sleeps ---"$'\n'"$(cat "$log")"
  pass "fm-send: the --key path never pauses (settle scoped to text submit)"
}

test_claude_escape_records_interrupt_idle() {
  local dir fb log rc home gen out
  dir="$TMP_ROOT/claude-interrupt"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/sleep.log"
  home="$dir/home"; mkdir -p "$home/state"
  fm_write_meta "$home/state/task.meta" \
    "window=sess:win" "worktree=$home/wt" "project=$home/project" \
    "harness=claude" "kind=ship" "mode=no-mistakes" "yolo=off"
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$home/state" task)
  printf 'busy_gen=%s\n' "$gen" >> "$home/state/task.meta"
  : > "$log"

  env PATH="$fb:$PATH" FM_HOME="$home" FM_SLEEP_LOG="$log" \
    "$SEND" task --key Escape 2>/dev/null; rc=$?
  expect_code 0 "$rc" "Claude Escape send should succeed"
  out=$(fm_busy_classify tmux sess:win claude task "$home/state")
  [ "$out" = "idle fm-interrupt" ] \
    || fail "Claude Escape must classify idle/fm-interrupt, got '$out'"
  pass "fm-send: a successful Claude Escape records the interrupt lifecycle edge"
}

test_busy_target_returns_immediately() {
  local dir fb settle
  dir="$TMP_ROOT/poll-busy"; mkdir -p "$dir"
  fb=$(make_stubs "$dir")
  make_meta_target "$dir" task busy
  settle=$(settle_sleeps "$fb" "$dir" task 1) \
    || fail "busy-target send should succeed"
  [ -z "$settle" ] \
    || fail "a target that already reads busy must not settle at all"$'\n'"--- settle sleeps ---"$'\n'"$settle"
  pass "fm-send: a target that already reads busy returns with no settle wait"
}

test_unknown_target_waits_the_full_cap() {
  local dir fb settle
  dir="$TMP_ROOT/poll-unknown"; mkdir -p "$dir"
  fb=$(make_stubs "$dir")
  make_meta_target "$dir" task unknown
  settle=$(settle_sleeps "$fb" "$dir" task 1) \
    || fail "unknown-target send should succeed"
  assert_capped_settle "$settle" 1 "a target that never reads busy"
  pass "fm-send: a target that never reads busy still waits the full cap"
}

test_unreadable_target_waits_the_full_cap() {
  local dir fb settle verdict
  dir="$TMP_ROOT/poll-unreadable"; mkdir -p "$dir"
  fb=$(make_stubs "$dir")
  make_meta_target "$dir" task unreadable
  # Prove the case is the one it claims to be before pinning the wait: a
  # corrupted record must classify unknown, never busy and never idle.
  verdict=$(fm_busy_classify tmux sess:win claude task "$dir/home/state")
  [ "${verdict%% *}" = unknown ] \
    || fail "the unreadable fixture must classify unknown, got '$verdict'"
  settle=$(settle_sleeps "$fb" "$dir" task 1) \
    || fail "unreadable-target send should succeed"
  assert_capped_settle "$settle" 1 "a target whose busy record is unreadable"
  pass "fm-send: a target whose busy state is unreadable still waits the full cap"
}

test_poll_cap_is_tunable() {
  local dir fb settle
  dir="$TMP_ROOT/poll-cap"; mkdir -p "$dir"
  fb=$(make_stubs "$dir")
  make_meta_target "$dir" task unknown
  settle=$(settle_sleeps "$fb" "$dir" task 0.5) \
    || fail "FM_SEND_SETTLE=0.5 send should succeed"
  assert_capped_settle "$settle" 0.5 "FM_SEND_SETTLE=0.5"
  pass "fm-send: FM_SEND_SETTLE still caps the bounded poll"
}

test_default_send_pauses_one_second
test_zero_disables_pause
test_pause_is_tunable
test_key_path_never_pauses
test_claude_escape_records_interrupt_idle
test_busy_target_returns_immediately
test_unknown_target_waits_the_full_cap
test_unreadable_target_waits_the_full_cap
test_poll_cap_is_tunable
