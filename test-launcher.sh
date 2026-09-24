#!/bin/sh

set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
app="$root/UnityNeovimLauncher.app"
launcher="$app/Contents/MacOS/UnityNeovimLauncher"
plist="$app/Contents/Info.plist"

if [ -x /opt/homebrew/bin/nvim ]; then
  nvim=/opt/homebrew/bin/nvim
else
  nvim=$(command -v nvim 2>/dev/null || true)
fi

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

[ -x "$launcher" ] || fail "launcher is not executable"
[ -n "$nvim" ] || fail "nvim is required for server reuse integration"
plutil -lint "$plist" >/dev/null || fail "Info.plist is invalid"

# Isolation: tests must never touch a live Herdr server or a live Ghostty
# session's Herdr state. Every launcher invocation below therefore sees an
# explicitly missing Herdr binary; only stub cases override this variable.
UNITY_NVIM_LAUNCHER_HERDR="$root/.absent-herdr"
export UNITY_NVIM_LAUNCHER_HERDR
[ -x "$root/.absent-herdr" ] && fail "Herdr isolation sentinel is executable; tests could contact a live Herdr"
[ -n "${UNITY_NVIM_LAUNCHER_TEST_HERDR_LOG:-}" ] && fail "UNITY_NVIM_LAUNCHER_TEST_HERDR_LOG leaked into the environment"

run_dry() {
  UNITY_NVIM_LAUNCHER_DRY_RUN=1 "$launcher" "$@"
}

project="/tmp/Unity Project's; safe"
file="/tmp/Unity Project's; safe/Assets/Player Controller.cs"
first=$(run_dry "$project" "$file" invalid 0)
second=$(run_dry "$project" "$file" 12 7)

line=$(printf '%s\n' "$first" | awk -F= '/^line=/{print $2}')
column=$(printf '%s\n' "$first" | awk -F= '/^column=/{print $2}')
first_socket=$(printf '%s\n' "$first" | awk -F= '/^socket=/{print $2}')
second_socket=$(printf '%s\n' "$second" | awk -F= '/^socket=/{print $2}')
command=$(printf '%s\n' "$second" | awk -F= '/^command=/{sub(/^[^=]*=/, ""); print}')

[ "$line" = 1 ] || fail "invalid line did not normalize to 1"
[ "$column" = 1 ] || fail "invalid column did not normalize to 1"
[ "$first_socket" = "$second_socket" ] || fail "socket is not stable per project"
printf '%s\n' "$first_socket" | grep -Eq '^/tmp/unl-[0-9a-f]{32}\.sock$' || fail "socket hash format is invalid"
[ "${#first_socket}" -le 100 ] || fail "socket path exceeds conservative Darwin limit"
printf '%s\n' "$command" | grep -F -- '/bin/sh -lc ' >/dev/null || fail "Ghostty command does not invoke an explicit shell"
[ "$(printf '%s\n' "$first" | awk -F= '/^herdr=/{print $2}')" = '-' ] || fail "dry run did not see the absent-Herdr isolation sentinel"

# This integration path proves server reuse without invoking Ghostty.
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/unity-neovim-launcher.XXXXXX")
server_pid=''
# Every test-spawned headless Neovim server registers its pid here as soon as
# it is spawned (before any delay or exec), so cleanup reaps them all even if
# a test step fails midway; no pid is ever overwritten by later probe calls.
nvim_pids_file="$test_dir/nvim-pids"
: >"$nvim_pids_file"
cleanup() {
  if [ -n "$server_pid" ]; then
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
  fi
  for tracked_pids_file in "$nvim_pids_file" "${herdr_pids_file:-}"; do
    if [ -n "$tracked_pids_file" ] && [ -f "$tracked_pids_file" ]; then
      while IFS= read -r stray_pid; do
        kill "$stray_pid" 2>/dev/null || true
      done <"$tracked_pids_file"
    fi
  done
  if [ -n "${delayed_socket:-}" ]; then rm -f "$delayed_socket"; fi
  if [ -n "${integration_socket:-}" ]; then rm -f "$integration_socket"; fi
  if [ -n "${herdr_socket:-}" ]; then rm -f "$herdr_socket"; fi
  rm -rf "$test_dir"
}
trap cleanup EXIT HUP INT TERM

integration_project="$test_dir/Unity Project"
integration_file="$integration_project/Assets/hostile name's; \$dollar.cs"
newline_file="$integration_project/Assets/rejected
file.cs"
carriage_return_file=$(printf '%s\r%s' "$integration_project/Assets/rejected" 'file.cs')
rejection_message='UnityNeovimLauncher: project and file paths must not contain newline or carriage return characters'
mkdir -p "$integration_project/Assets"
printf 'one\ntwo\nthree\n' >"$integration_file"
canonical_integration_file=$(CDPATH= cd -P -- "$(dirname -- "$integration_file")" && printf '%s/%s\n' "$PWD" "$(basename -- "$integration_file")")
if newline_output=$(UNITY_NVIM_LAUNCHER_DRY_RUN=1 "$launcher" "$integration_project" "$newline_file" 3 2 2>&1); then
  fail "newline path was accepted"
fi
[ "$newline_output" = "$rejection_message" ] || fail "newline rejection produced dry-run output or an unclear message"
if carriage_return_output=$(UNITY_NVIM_LAUNCHER_DRY_RUN=1 "$launcher" "$integration_project" "$carriage_return_file" 3 2 2>&1); then
  fail "carriage-return path was accepted"
else
  carriage_return_status=$?
fi
[ "$carriage_return_status" -eq 2 ] || fail "carriage-return rejection did not exit 2"
[ "$carriage_return_output" = "$rejection_message" ] || fail "carriage-return rejection produced dry-run output or an unclear message"
integration_socket=$(run_dry "$integration_project" "$integration_file" 3 2 | awk -F= '/^socket=/{print $2}')
stub="$test_dir/nvim-stub"
stub_args="$test_dir/nvim-stub-args"
printf '%s\n' '#!/bin/sh' "printf '%s\\n' \"\$@\" > \"\$UNITY_NVIM_LAUNCHER_TEST_ARGS\"" >"$stub"
chmod +x "$stub"
stub_dry=$(UNITY_NVIM_LAUNCHER_DRY_RUN=1 UNITY_NVIM_LAUNCHER_NVIM="$stub" "$launcher" "$integration_project" "$integration_file" 3 2)
stub_command=$(printf '%s\n' "$stub_dry" | awk -F= '/^command=/{sub(/^[^=]*=/, ""); print}')
UNITY_NVIM_LAUNCHER_TEST_ARGS="$stub_args" /bin/sh -c "$stub_command"
expected_stub_args="$test_dir/expected-nvim-stub-args"
printf '%s\n' --listen "$integration_socket" '+call cursor(3, 2)' "$canonical_integration_file" >"$expected_stub_args"
cmp -s "$stub_args" "$expected_stub_args" || fail "nested Ghostty command did not preserve nvim arguments"

# Simulate Ghostty returning before its shell starts Neovim, then verify the
# launcher waits for the socket and applies the first-launch cursor position.
delayed_project="$test_dir/Delayed Unity Project"
delayed_file="$delayed_project/Assets/first launch.cs"
mkdir -p "$delayed_project/Assets"
printf 'one\ntwo\nthree\nfour\n' >"$delayed_file"
delayed_socket=$(run_dry "$delayed_project" "$delayed_file" 3 2 | awk -F= '/^socket=/{print $2}')
delayed_nvim="$test_dir/delayed-nvim"
delayed_osascript="$test_dir/delayed-osascript"
# Only the actual listening server (args containing --listen) registers its
# pid; the launcher's later probe and remote calls reuse this wrapper with
# --server arguments and must never overwrite the tracked server pid.
cat >"$delayed_nvim" <<'DELAYED_NVIM'
#!/bin/sh
case "$*" in
  *--listen*)
    printf '%s\n' "$$" >>"$UNITY_NVIM_LAUNCHER_TEST_NVIM_PIDS"
    ;;
esac
sleep "${UNITY_NVIM_LAUNCHER_TEST_DELAY:-0}"
exec "$UNITY_NVIM_LAUNCHER_REAL_NVIM" --clean --headless "$@"
DELAYED_NVIM
printf '%s\n' '#!/bin/sh' '/bin/sh -c "$3" >/dev/null 2>&1 &' >"$delayed_osascript"
chmod +x "$delayed_nvim" "$delayed_osascript"
UNITY_NVIM_LAUNCHER_NVIM="$delayed_nvim" UNITY_NVIM_LAUNCHER_OSASCRIPT="$delayed_osascript" UNITY_NVIM_LAUNCHER_REAL_NVIM="$nvim" UNITY_NVIM_LAUNCHER_TEST_DELAY=0.3 UNITY_NVIM_LAUNCHER_TEST_NVIM_PIDS="$nvim_pids_file" "$launcher" "$delayed_project" "$delayed_file" 3 2 || fail "launcher did not wait for delayed Neovim"
# Regression: the tracked pid list must hold exactly one entry, and that entry
# must still be the live headless server, proving probe calls never overwrote it.
[ "$(grep -c . "$nvim_pids_file")" -eq 1 ] || fail "delayed launch did not track exactly one server pid"
IFS= read -r delayed_pid <"$nvim_pids_file"
kill -0 "$delayed_pid" 2>/dev/null || fail "delayed headless server pid was not alive when tracked"
delayed_cursor=$("$nvim" --server "$delayed_socket" --remote-expr "luaeval(\"vim.api.nvim_win_get_cursor(0)\")[0] . ':' . (luaeval(\"vim.api.nvim_win_get_cursor(0)\")[1] + 1)")
[ "$delayed_cursor" = '3:2' ] || fail "delayed first-launch cursor was not positioned (got $delayed_cursor)"
kill "$delayed_pid" 2>/dev/null || true
death_wait=0
while kill -0 "$delayed_pid" 2>/dev/null; do
  death_wait=$((death_wait + 1))
  [ "$death_wait" -lt 20 ] || fail "delayed headless server ignored SIGTERM"
  sleep 0.1
done
# Regression: no process may still be listening on the test-only socket after
# cleanup, i.e. the delayed launch must not leak a headless Neovim server.
if pgrep -f "$delayed_socket" >/dev/null 2>&1; then
  fail "delayed headless Neovim server leaked a process on $delayed_socket"
fi
"$nvim" --clean --headless --listen "$integration_socket" >/dev/null 2>&1 &
server_pid=$!

attempt=0
while ! "$nvim" --server "$integration_socket" --remote-expr '1' >/dev/null 2>&1; do
  attempt=$((attempt + 1))
  [ "$attempt" -lt 50 ] || fail "headless Neovim server did not start"
  sleep 0.1
done

"$launcher" "$integration_project" "$integration_file" 3 2 || fail "launcher did not reuse headless server"
expected_file_hash=$(printf '%s' "$canonical_integration_file" | openssl dgst -sha256 | awk '{print $NF}')
opened_file_hashes=$("$nvim" --server "$integration_socket" --remote-expr "join(map(getbufinfo({'bufloaded': 1}), 'sha256(v:val.name)'), nr2char(10))")
printf '%s\n' "$opened_file_hashes" | grep -Fx -- "$expected_file_hash" >/dev/null || fail "server did not open exact hostile filename"
cursor_position=$("$nvim" --server "$integration_socket" --remote-expr "luaeval(\"vim.api.nvim_win_get_cursor(0)\")[0] . ':' . (luaeval(\"vim.api.nvim_win_get_cursor(0)\")[1] + 1)")
[ "$cursor_position" = '3:2' ] || fail "server cursor was not positioned (got $cursor_position)"

# Herdr-first routing: the launcher must prefer a running compatible Herdr
# server, write commands only into panes freshly created by the same
# invocation, fail visibly on ambiguous host errors, and fall back to Ghostty
# only when Herdr is absent, not running, or incompatible.
herdr_project="$test_dir/Herdr Unity Project"
herdr_file="$herdr_project/Assets/hostile name's; \$dollar.cs"
mkdir -p "$herdr_project/Assets"
printf 'one\ntwo\nthree\nfour\n' >"$herdr_file"
herdr_dry=$(run_dry "$herdr_project" "$herdr_file" 3 2)
herdr_socket=$(printf '%s\n' "$herdr_dry" | awk -F= '/^socket=/{print $2}')
herdr_label=$(printf '%s\n' "$herdr_dry" | awk -F= '/^workspace_label=/{print $2}')
herdr_project_c=$(printf '%s\n' "$herdr_dry" | awk -F= '/^project=/{print $2}')
herdr_file_c=$(printf '%s\n' "$herdr_dry" | awk -F= '/^file=/{print $2}')
printf '%s\n' "$herdr_label" | grep -Eq '^unl-[0-9a-f]{32}$' || fail "herdr workspace label format is invalid"

herdr_log="$test_dir/herdr.log"
herdr_pids_file="$test_dir/herdr-pids"
: >"$herdr_pids_file"

no_osascript="$test_dir/no-osascript"
printf '%s\n' '#!/bin/sh' 'printf "unexpected osascript invocation\n" >&2' 'exit 90' >"$no_osascript"
chmod +x "$no_osascript"

herdr_stub="$test_dir/herdr-stub"
cat >"$herdr_stub" <<'HERDR_STUB'
#!/bin/sh
printf '%s\n' "$*" >>"$UNITY_NVIM_LAUNCHER_TEST_HERDR_LOG"
case $1 in
  status)
    if [ -n "${UNITY_NVIM_LAUNCHER_TEST_STATUS_JSON:-}" ]; then
      printf '%s\n' "$UNITY_NVIM_LAUNCHER_TEST_STATUS_JSON"
    fi
    ;;
  workspace)
    case $2 in
      list)
        [ -n "${UNITY_NVIM_LAUNCHER_TEST_LIST_JSON:-}" ] && printf '%s\n' "$UNITY_NVIM_LAUNCHER_TEST_LIST_JSON"
        ;;
      create)
        [ -n "${UNITY_NVIM_LAUNCHER_TEST_CREATE_JSON:-}" ] && printf '%s\n' "$UNITY_NVIM_LAUNCHER_TEST_CREATE_JSON"
        ;;
      focus)
        printf '%s\n' '{"result":{}}'
        ;;
    esac
    ;;
  tab)
    if [ "$2" = create ]; then
      if [ -n "${UNITY_NVIM_LAUNCHER_TEST_TAB_FAIL:-}" ]; then
        printf 'herdr tab create: simulated tab create failure\n' >&2
        exit 9
      fi
      [ -n "${UNITY_NVIM_LAUNCHER_TEST_TAB_JSON:-}" ] && printf '%s\n' "$UNITY_NVIM_LAUNCHER_TEST_TAB_JSON"
    fi
    ;;
  pane)
    if [ "$2" = run ]; then
      if [ -n "${UNITY_NVIM_LAUNCHER_TEST_PANE_RUN_FAIL:-}" ]; then
        printf 'herdr pane run: simulated dispatch failure\n' >&2
        exit 7
      fi
      "$4" --clean --headless --listen "$6" "$7" >/dev/null 2>&1 &
      printf '%s\n' "$!" >>"$UNITY_NVIM_LAUNCHER_TEST_HERDR_PIDS"
    fi
    ;;
esac
exit 0
HERDR_STUB
chmod +x "$herdr_stub"

herdr_status_json=''
herdr_list_json=''
herdr_tab_json=''
herdr_create_json=''
herdr_bin_choice="$herdr_stub"
herdr_osascript_choice="$no_osascript"
herdr_nvim_choice="$nvim"

# Probe stub contract: the launcher must probe the lowercase live process
# name (pgrep -x ghostty, matching the installed app bundle's process name),
# so the stub records its arguments and fails loudly on anything else. The
# exit code then models pgrep: yes -> 0 (Ghostty running), no -> 1 (not
# running), unset -> 127 so the launcher conservatively treats the probe as
# "Ghostty running". Tests never contact live Ghostty.
ghostty_probe_stub="$test_dir/ghostty-probe-stub"
cat >"$ghostty_probe_stub" <<'GHOSTTY_PROBE_STUB'
#!/bin/sh
case "$*" in
  "-x ghostty") ;;
  *)
    printf 'pgrep stub: expected exactly "-x ghostty", got: %s\n' "$*" >&2
    exit 64
    ;;
esac
if [ -n "${UNITY_NVIM_LAUNCHER_TEST_PROBE_LOG:-}" ]; then
  printf '%s\n' "$*" >>"$UNITY_NVIM_LAUNCHER_TEST_PROBE_LOG"
fi
case ${UNITY_NVIM_LAUNCHER_TEST_GHOSTTY_RUNNING:-} in
  yes) exit 0 ;;
  no) exit 1 ;;
  *) exit 127 ;;
esac
GHOSTTY_PROBE_STUB
chmod +x "$ghostty_probe_stub"

# Attach-surface osascript stub: records argc, argv, and the full stdin (the
# AppleScript source the launcher must provide), and can simulate a failed
# surface launch via UNITY_NVIM_LAUNCHER_TEST_OSASCRIPT_FAIL.
attach_osascript_stub="$test_dir/attach-osascript-stub"
cat >"$attach_osascript_stub" <<'ATTACH_OSASCRIPT_STUB'
#!/bin/sh
if [ -n "${UNITY_NVIM_LAUNCHER_TEST_OSASCRIPT_LOG:-}" ]; then
  {
    printf 'argc=%s\n' "$#"
    printf 'args=%s\n' "$*"
    printf 'source-start\n'
    cat
    printf 'stdin-end\n'
  } >>"$UNITY_NVIM_LAUNCHER_TEST_OSASCRIPT_LOG"
fi
if [ -n "${UNITY_NVIM_LAUNCHER_TEST_OSASCRIPT_FAIL:-}" ]; then
  printf 'osascript: simulated Ghostty surface launch failure\n' >&2
  exit 1
fi
exit 0
ATTACH_OSASCRIPT_STUB
chmod +x "$attach_osascript_stub"

herdr_probe_log="$test_dir/ghostty-probe.log"
herdr_osascript_log="$test_dir/attach-osascript.log"
herdr_osascript_fail=''

herdr_run() {
  : >"$herdr_log"
  : >"$herdr_probe_log"
  : >"$herdr_osascript_log"
  UNITY_NVIM_LAUNCHER_HERDR="$herdr_bin_choice" \
  UNITY_NVIM_LAUNCHER_TEST_GHOSTTY_PROBE="$ghostty_probe_stub" \
  UNITY_NVIM_LAUNCHER_TEST_GHOSTTY_RUNNING="${herdr_ghostty_running:-}" \
  UNITY_NVIM_LAUNCHER_TEST_PROBE_LOG="$herdr_probe_log" \
  UNITY_NVIM_LAUNCHER_TEST_HERDR_LOG="$herdr_log" \
  UNITY_NVIM_LAUNCHER_TEST_OSASCRIPT_LOG="$herdr_osascript_log" \
  UNITY_NVIM_LAUNCHER_TEST_OSASCRIPT_FAIL="${herdr_osascript_fail:-}" \
  UNITY_NVIM_LAUNCHER_TEST_PANE_RUN_FAIL="${herdr_pane_run_fail:-}" \
  UNITY_NVIM_LAUNCHER_TEST_TAB_FAIL="${herdr_tab_fail:-}" \
  UNITY_NVIM_LAUNCHER_TEST_HERDR_PIDS="$herdr_pids_file" \
  UNITY_NVIM_LAUNCHER_TEST_STATUS_JSON="$herdr_status_json" \
  UNITY_NVIM_LAUNCHER_TEST_LIST_JSON="$herdr_list_json" \
  UNITY_NVIM_LAUNCHER_TEST_TAB_JSON="$herdr_tab_json" \
  UNITY_NVIM_LAUNCHER_TEST_CREATE_JSON="$herdr_create_json" \
  UNITY_NVIM_LAUNCHER_TEST_DELAY="${herdr_test_delay:-0}" \
  UNITY_NVIM_LAUNCHER_REAL_NVIM="$nvim" \
  UNITY_NVIM_LAUNCHER_OSASCRIPT="$herdr_osascript_choice" \
  UNITY_NVIM_LAUNCHER_NVIM="$herdr_nvim_choice" \
  "$launcher" "$herdr_project" "$herdr_file" 3 2
}

herdr_wait_server() {
  attempt=0
  while ! "$nvim" --server "$herdr_socket" --remote-expr '1' >/dev/null 2>&1; do
    attempt=$((attempt + 1))
    [ "$attempt" -lt 50 ] || return 1
    sleep 0.1
  done
}

herdr_kill_tracked() {
  while IFS= read -r tracked_pid; do
    kill "$tracked_pid" 2>/dev/null || true
  done <"$herdr_pids_file"
  : >"$herdr_pids_file"
}

herdr_wait_socket_dead() {
  attempt=0
  while "$nvim" --server "$herdr_socket" --remote-expr '1' >/dev/null 2>&1; do
    attempt=$((attempt + 1))
    [ "$attempt" -lt 50 ] || fail "Herdr test socket stayed alive after cleanup"
    sleep 0.1
  done
}

# Ghostty-fallback stubs: the nvim wrapper registers only the listening
# server (the one whose args contain --listen), so cleanup never races with
# probe calls that reuse the same wrapper binary.
herdr_fallback_nvim="$test_dir/herdr-fallback-nvim"
cat >"$herdr_fallback_nvim" <<'HERDR_FALLBACK_NVIM'
#!/bin/sh
case "$*" in
  *--listen*)
    printf '%s\n' "$$" >>"$UNITY_NVIM_LAUNCHER_TEST_HERDR_PIDS"
    ;;
esac
exec "$UNITY_NVIM_LAUNCHER_REAL_NVIM" --clean --headless "$@"
HERDR_FALLBACK_NVIM
chmod +x "$herdr_fallback_nvim"

printf '%s\n' '#!/bin/sh' '/bin/sh -c "$3" >/dev/null 2>&1 &' >"$test_dir/herdr-fallback-osascript"
chmod +x "$test_dir/herdr-fallback-osascript"

herdr_cursor_is() {
  herdr_cursor=$("$nvim" --server "$herdr_socket" --remote-expr "luaeval(\"vim.api.nvim_win_get_cursor(0)\")[0] . ':' . (luaeval(\"vim.api.nvim_win_get_cursor(0)\")[1] + 1)")
  [ "$herdr_cursor" = "$1" ] || fail "Herdr cursor was not positioned at $1 (got $herdr_cursor)"
}

# 1. Herdr reports not running -> the whole launch must use the Ghostty host.
herdr_status_json='{"server":{"running":false,"compatible":true}}'
herdr_list_json='{"result":{"workspaces":[]}}'
herdr_osascript_choice="$test_dir/herdr-fallback-osascript"
herdr_nvim_choice="$herdr_fallback_nvim"
if ! herdr_fallback_out=$(herdr_run 2>&1); then
  fail "Herdr-not-running fallback failed: $herdr_fallback_out"
fi
case "$herdr_fallback_out" in *'unexpected osascript'*) fail "fallback unexpectedly invoked the osascript guard stub" ;; esac
printf '%s\n' 'status --json' >"$test_dir/expected-herdr-not-running"
cmp -s "$herdr_log" "$test_dir/expected-herdr-not-running" || fail "Herdr-not-running case touched host commands beyond status"
herdr_wait_server
herdr_cursor_is '3:2'
herdr_kill_tracked

# 2. Fresh project: Herdr running -> dedicated workspace create, pane run only
# on the fresh root pane of this invocation, herdr focus, never osascript.
herdr_status_json='{"server":{"running":true,"compatible":true}}'
herdr_list_json='{"result":{"workspaces":[]}}'
herdr_tab_json=''
herdr_create_json='{"result":{"workspace":{"workspace_id":"WS-NEW"},"root_pane":{"pane_id":"PANE-NEW"}}}'
herdr_osascript_choice="$no_osascript"
herdr_nvim_choice="$nvim"
if ! herdr_fresh_out=$(herdr_run 2>&1); then
  fail "Herdr fresh-workspace launch failed: $herdr_fresh_out"
fi
case "$herdr_fresh_out" in *'unexpected osascript'*) fail "Herdr launch fell back to osascript" ;; esac
herdr_expected_fresh="$test_dir/expected-herdr-fresh"
{
  printf '%s\n' 'status --json' 'workspace list'
  printf 'workspace create --cwd %s --label %s --no-focus\n' "$herdr_project_c" "$herdr_label"
  printf 'pane run PANE-NEW %s --listen %s %s\n' "$nvim" "$herdr_socket" "$herdr_file_c"
  printf '%s\n' 'workspace focus WS-NEW'
} >"$herdr_expected_fresh"
cmp -s "$herdr_log" "$herdr_expected_fresh" || fail "fresh-workspace Herdr route mismatch; got: $(cat "$herdr_log")"
herdr_wait_server
herdr_cursor_is '3:2'
expected_herdr_hash=$(printf '%s' "$herdr_file_c" | openssl dgst -sha256 | awk '{print $NF}')
"$nvim" --server "$herdr_socket" --remote-expr "join(map(getbufinfo({'bufloaded': 1}), 'sha256(v:val.name)'), nr2char(10))" | grep -Fx -- "$expected_herdr_hash" >/dev/null || fail "Herdr pane did not open the exact hostile filename"
herdr_kill_tracked

# 3. Live socket plus a verified launcher-owned workspace: reuse remotely,
# focus the Herdr workspace by id, never create panes or run commands.
"$nvim" --clean --headless --listen "$herdr_socket" >/dev/null 2>&1 &
printf '%s\n' "$!" >>"$herdr_pids_file"
herdr_wait_server
herdr_list_json='{"result":{"workspaces":[{"label":"other","workspace_id":"WS-OTHER"},{"label":"'"$herdr_label"'","workspace_id":"WS-EXIST"}]}}'
if ! herdr_reuse_out=$(herdr_run 2>&1); then
  fail "Herdr socket reuse failed: $herdr_reuse_out"
fi
herdr_expected_reuse="$test_dir/expected-herdr-reuse"
printf '%s\n' 'status --json' 'workspace list' 'workspace focus WS-EXIST' >"$herdr_expected_reuse"
cmp -s "$herdr_log" "$herdr_expected_reuse" || fail "reuse route ran Herdr mutations or fell back to osascript; got: $(cat "$herdr_log")"
herdr_cursor_is '3:2'
herdr_kill_tracked

# 3a. Live socket, verified launcher-owned workspace, Ghostty NOT running:
# a successful attach stub proves the route - one Ghostty surface whose
# AppleScript source creates, configures, and activates a new surface with the
# Herdr attach command, probed with the lowercase process name, followed by
# the usual workspace focus. No pane run, no tab create, no workspace create,
# and exit 0: navigation already succeeded.
herdr_ghostty_running='no'
herdr_osascript_choice="$attach_osascript_stub"
"$nvim" --clean --headless --listen "$herdr_socket" >/dev/null 2>&1 &
printf '%s\n' "$!" >>"$herdr_pids_file"
herdr_wait_server
if ! herdr_attach_out=$(herdr_run 2>&1); then
  fail "Ghostty-attach reuse failed even though navigation succeeded: $herdr_attach_out"
fi
case "$herdr_attach_out" in *'could not launch a Ghostty surface'*) fail "Ghostty attach reported a failure that did not happen" ;; esac
case "$herdr_attach_out" in *'osascript:'*) fail "Ghostty attach stub failed on the success case: $herdr_attach_out" ;; esac
herdr_expected_attach="$test_dir/expected-herdr-ghostty-attach"
printf '%s\n' 'status --json' 'workspace list' 'workspace focus WS-EXIST' >"$herdr_expected_attach"
cmp -s "$herdr_log" "$herdr_expected_attach" || fail "Ghostty-attach case ran Herdr mutations; got: $(cat "$herdr_log")"
grep -Fx -- '-x ghostty' "$herdr_probe_log" >/dev/null || fail "Ghostty probe did not use the lowercase process name argument; got: $(cat "$herdr_probe_log")"
attach_log_text=$(cat "$herdr_osascript_log")
printf '%s\n' "$attach_log_text" | grep -F 'argc=3' >/dev/null || fail "attach surface invocation did not pass three argv items; got: $attach_log_text"
printf '%s\n' "$attach_log_text" | grep -F -- "$herdr_project_c" >/dev/null || fail "attach surface did not receive the canonical project path"
printf '%s\n' "$attach_log_text" | grep -F -- "$herdr_stub" >/dev/null || fail "attach surface command did not run the Herdr CLI"
printf '%s\n' "$attach_log_text" | grep -F -- '/bin/sh -lc' >/dev/null || fail "attach surface command did not use an explicit shell"
printf '%s\n' "$attach_log_text" | grep -F 'exec' >/dev/null || fail "attach surface command did not exec the Herdr TUI"
printf '%s\n' "$attach_log_text" | grep -F 'new surface configuration' >/dev/null || fail "attach AppleScript source lacks new surface configuration"
printf '%s\n' "$attach_log_text" | grep -F 'initial working directory of surfaceConfig to projectPath' >/dev/null || fail "attach AppleScript source lacks the working-directory assignment"
printf '%s\n' "$attach_log_text" | grep -F 'command of surfaceConfig to attachCommand' >/dev/null || fail "attach AppleScript source lacks the command assignment"
printf '%s\n' "$attach_log_text" | grep -F 'new window with configuration surfaceConfig' >/dev/null || fail "attach AppleScript source lacks the new-window creation"
printf '%s\n' "$attach_log_text" | grep -F 'activate window newWindow' >/dev/null || fail "attach AppleScript source lacks window activation"
herdr_cursor_is '3:2'

# 3b. Same state but Ghostty already running: routing must be preserved
# exactly as before the Ghostty-attach feature - remote reuse plus focus,
# and no osascript invocation.
herdr_ghostty_running='yes'
if ! herdr_keep_out=$(herdr_run 2>&1); then
  fail "Ghostty-already-running reuse failed: $herdr_keep_out"
fi
case "$herdr_keep_out" in *'could not launch a Ghostty surface'*) fail "Ghostty-attach ran while Ghostty was already running" ;; esac
case "$herdr_keep_out" in *'osascript:'*) fail "Ghostty-already-running case invoked osascript" ;; esac
cmp -s "$herdr_log" "$herdr_expected_attach" || fail "Ghostty-already-running case changed the Herdr route; got: $(cat "$herdr_log")"
[ -s "$herdr_osascript_log" ] && fail "Ghostty-already-running case invoked the attach osascript stub"
herdr_cursor_is '3:2'
herdr_kill_tracked
herdr_ghostty_running=''

# 3c. Ghostty not running and the surface launch itself fails: the warning
# must be visible on stderr, the Herdr focus must still run, and the
# successful navigation must still exit 0.
herdr_ghostty_running='no'
herdr_osascript_fail=1
"$nvim" --clean --headless --listen "$herdr_socket" >/dev/null 2>&1 &
printf '%s\n' "$!" >>"$herdr_pids_file"
herdr_wait_server
if ! herdr_attach_fail_out=$(herdr_run 2>&1); then
  fail "failed Ghostty attach turned a successful navigation into an error: $herdr_attach_fail_out"
fi
printf '%s\n' "$herdr_attach_fail_out" | grep -F 'could not launch a Ghostty surface' >/dev/null || fail "failed Ghostty attach was not reported visibly"
printf '%s\n' "$herdr_attach_fail_out" | grep -F 'simulated Ghostty surface launch failure' >/dev/null || fail "failed Ghostty attach did not capture the osascript stub output"
cmp -s "$herdr_log" "$herdr_expected_attach" || fail "failed-attach case skipped or mutated Herdr commands; got: $(cat "$herdr_log")"
herdr_cursor_is '3:2'
herdr_kill_tracked
herdr_ghostty_running=''
herdr_osascript_fail=''
herdr_osascript_choice="$no_osascript"

# 4. Ambiguous workspace list -> visible failure, no duplicate mutations.
: >"$herdr_pids_file"
herdr_wait_socket_dead
herdr_list_json='not-json-at-all'
if herdr_amb_out=$(herdr_run 2>&1); then
  fail "ambiguous workspace list did not fail visibly"
fi
printf '%s\n' "$herdr_amb_out" | grep -F 'refusing to create a duplicate workspace' >/dev/null || fail "ambiguous workspace list error was not visible"
herdr_expected_amb="$test_dir/expected-herdr-ambiguous"
printf '%s\n' 'status --json' 'workspace list' >"$herdr_expected_amb"
cmp -s "$herdr_log" "$herdr_expected_amb" || fail "ambiguous list case mutated the host; got: $(cat "$herdr_log")"

# 5. Tab create without a fresh pane id -> visible failure, no pane run.
herdr_list_json='{"result":{"workspaces":[{"label":"'"$herdr_label"'","workspace_id":"WS-EXIST"}]}}'
herdr_tab_json='{"result":{}}'
if herdr_tab_out=$(herdr_run 2>&1); then
  fail "tab create without pane id did not fail visibly"
fi
printf '%s\n' "$herdr_tab_out" | grep -F 'refusing to run in an unknown pane' >/dev/null || fail "missing pane id error was not visible"
herdr_expected_tab="$test_dir/expected-herdr-tab"
{
  printf '%s\n' 'status --json' 'workspace list'
  printf 'tab create --workspace WS-EXIST --cwd %s --label %s --no-focus\n' "$herdr_project_c" "$(basename -- "$herdr_file_c")"
} >"$herdr_expected_tab"
cmp -s "$herdr_log" "$herdr_expected_tab" || fail "tab-create failure case ran a command; got: $(cat "$herdr_log")"

# 6. Workspace create without ids -> visible failure, no pane run.
herdr_list_json='{"result":{"workspaces":[]}}'
herdr_tab_json=''
herdr_create_json='{"result":{"workspace":{"workspace_id":"WS-NEW"}}}'
if herdr_create_out=$(herdr_run 2>&1); then
  fail "workspace create without pane id did not fail visibly"
fi
printf '%s\n' "$herdr_create_out" | grep -F 'no fresh root pane id' >/dev/null || fail "create missing pane id error was not visible"
herdr_expected_create="$test_dir/expected-herdr-create"
{
  printf '%s\n' 'status --json' 'workspace list'
  printf 'workspace create --cwd %s --label %s --no-focus\n' "$herdr_project_c" "$herdr_label"
} >"$herdr_expected_create"
cmp -s "$herdr_log" "$herdr_expected_create" || fail "create failure case ran a command; got: $(cat "$herdr_log")"

# 7. Herdr binary missing -> Ghostty fallback, Herdr never invoked.
herdr_bin_choice="$test_dir/definitely-missing-herdr"
herdr_osascript_choice="$test_dir/herdr-fallback-osascript"
herdr_nvim_choice="$herdr_fallback_nvim"
if ! herdr_missing_out=$(herdr_run 2>&1); then
  fail "missing-Herdr fallback failed: $herdr_missing_out"
fi
[ -s "$herdr_log" ] && fail "missing Herdr binary still invoked the stub"
herdr_wait_server
herdr_cursor_is '3:2'
herdr_kill_tracked

# Back to the Herdr stub for the ambiguous-list and pane-run failure cases.
herdr_bin_choice="$herdr_stub"
herdr_osascript_choice="$no_osascript"
herdr_nvim_choice="$nvim"
herdr_pane_run_fail=''

# 8. Duplicate launcher-owned labels -> ambiguous, refuse to create a duplicate.
herdr_status_json='{"server":{"running":true,"compatible":true}}'
herdr_list_json='{"result":{"workspaces":[{"label":"other","workspace_id":"WS-X"},{"label":"'"$herdr_label"'","workspace_id":"WS-A"},{"label":"'"$herdr_label"'","workspace_id":"WS-B"}]}}'
herdr_tab_json=''
herdr_create_json=''
herdr_wait_socket_dead
if herdr_dup_out=$(herdr_run 2>&1); then
  fail "duplicate workspace labels did not fail visibly"
fi
printf '%s\n' "$herdr_dup_out" | grep -F 'refusing to create a duplicate workspace' >/dev/null || fail "duplicate label error was not visible"
printf '%s\n' 'status --json' 'workspace list' >"$test_dir/expected-herdr-duplicate"
cmp -s "$herdr_log" "$test_dir/expected-herdr-duplicate" || fail "duplicate label case mutated the host; got: $(cat "$herdr_log")"

# 9. Matching workspace object without a usable id -> ambiguous, never create a
# duplicate workspace by treating the malformed entry as absent.
herdr_list_json='{"result":{"workspaces":[{"label":"'"$herdr_label"'"}]}}'
if herdr_mal_out=$(herdr_run 2>&1); then
  fail "malformed matching workspace object did not fail visibly"
fi
printf '%s\n' "$herdr_mal_out" | grep -F 'refusing to create a duplicate workspace' >/dev/null || fail "malformed workspace object error was not visible"
printf '%s\n' 'status --json' 'workspace list' >"$test_dir/expected-herdr-malformed"
cmp -s "$herdr_log" "$test_dir/expected-herdr-malformed" || fail "malformed workspace case created a duplicate; got: $(cat "$herdr_log")"

# 10. herdr pane run failure -> prompt visible failure with the captured herdr
# output, no fallback, no workspace focus.
herdr_list_json='{"result":{"workspaces":[]}}'
herdr_create_json='{"result":{"workspace":{"workspace_id":"WS-NEW2"},"root_pane":{"pane_id":"PANE-NEW2"}}}'
herdr_pane_run_fail=1
pane_fail_start=$(date +%s)
if herdr_pane_out=$(herdr_run 2>&1); then
  fail "herdr pane run failure did not fail visibly"
fi
pane_fail_elapsed=$(( $(date +%s) - pane_fail_start ))
[ "$pane_fail_elapsed" -lt 4 ] || fail "herdr pane run failure was not detected promptly (took ${pane_fail_elapsed}s)"
printf '%s\n' "$herdr_pane_out" | grep -F 'herdr pane run failed' >/dev/null || fail "pane run failure error was not visible"
printf '%s\n' "$herdr_pane_out" | grep -F 'simulated dispatch failure' >/dev/null || fail "pane run output was not reported"
{
  printf '%s\n' 'status --json' 'workspace list'
  printf 'workspace create --cwd %s --label %s --no-focus\n' "$herdr_project_c" "$herdr_label"
  printf 'pane run PANE-NEW2 %s --listen %s %s\n' "$nvim" "$herdr_socket" "$herdr_file_c"
} >"$test_dir/expected-herdr-pane-fail"
cmp -s "$herdr_log" "$test_dir/expected-herdr-pane-fail" || fail "pane run failure case log mismatch; got: $(cat "$herdr_log")"

# 11. Positive regression: dead socket plus an existing launcher-owned
# workspace -> tab create returns a fresh pane, the Neovim command runs only
# in that pane, and the workspace is focused by id. Stubs only; never touches
# a live Herdr server.
herdr_wait_socket_dead
herdr_pane_run_fail=''
herdr_tab_fail=''
herdr_list_json='{"result":{"workspaces":[{"label":"other","workspace_id":"WS-OTHER2"},{"label":"'"$herdr_label"'","workspace_id":"WS-REUSE"}]}}'
herdr_create_json=''
herdr_tab_json='{"result":{"workspace":{"workspace_id":"WS-REUSE"},"root_pane":{"pane_id":"PANE-REUSE"}}}'
if ! herdr_reuse_fresh_out=$(herdr_run 2>&1); then
  fail "Herdr dead-socket workspace reuse failed: $herdr_reuse_fresh_out"
fi
case "$herdr_reuse_fresh_out" in *'unexpected osascript'*) fail "dead-socket workspace reuse fell back to Ghostty" ;; esac
herdr_expected_reuse_fresh="$test_dir/expected-herdr-reuse-fresh"
{
  printf '%s\n' 'status --json' 'workspace list'
  printf 'tab create --workspace WS-REUSE --cwd %s --label %s --no-focus\n' "$herdr_project_c" "$(basename -- "$herdr_file_c")"
  printf 'pane run PANE-REUSE %s --listen %s %s\n' "$nvim" "$herdr_socket" "$herdr_file_c"
  printf '%s\n' 'workspace focus WS-REUSE'
} >"$herdr_expected_reuse_fresh"
cmp -s "$herdr_log" "$herdr_expected_reuse_fresh" || fail "dead-socket reuse route mismatch; got: $(cat "$herdr_log")"
herdr_wait_server
herdr_cursor_is '3:2'
expected_reuse_fresh_hash=$(printf '%s' "$herdr_file_c" | openssl dgst -sha256 | awk '{print $NF}')
"$nvim" --server "$herdr_socket" --remote-expr "join(map(getbufinfo({'bufloaded': 1}), 'sha256(v:val.name)'), nr2char(10))" | grep -Fx -- "$expected_reuse_fresh_hash" >/dev/null || fail "reused workspace pane did not open the exact hostile filename"
herdr_kill_tracked

# 12. tab create command failure on a dead socket -> visible failure with the
# workspace id, no pane run, no workspace create, no workspace focus, and no
# Ghostty fallback that could start a duplicate session.
herdr_wait_socket_dead
herdr_tab_json=''
herdr_tab_fail=1
if herdr_tab_fail_out=$(herdr_run 2>&1); then
  fail "tab create command failure did not fail visibly"
fi
case "$herdr_tab_fail_out" in *'unexpected osascript'*) fail "tab create failure fell back to Ghostty" ;; esac
printf '%s\n' "$herdr_tab_fail_out" | grep -F 'herdr tab create failed for workspace WS-REUSE' >/dev/null || fail "tab create failure error was not visible"
{
  printf '%s\n' 'status --json' 'workspace list'
  printf 'tab create --workspace WS-REUSE --cwd %s --label %s --no-focus\n' "$herdr_project_c" "$(basename -- "$herdr_file_c")"
} >"$test_dir/expected-herdr-tab-fail"
cmp -s "$herdr_log" "$test_dir/expected-herdr-tab-fail" || fail "tab create failure case ran extra host commands; got: $(cat "$herdr_log")"

# Herdr host resolution regressions: the installed app runs with a GUI-like
# PATH, so without an explicit override the launcher must still find Homebrew
# Herdr (resolution order: explicit override, /opt/homebrew/bin, PATH,
# /usr/local/bin). Dry runs are read-only, so these cases never touch a live
# Herdr server; a dedicated project keeps them independent of the fast checks
# and of the integration sockets below.
herdr_resolution_project="$test_dir/Herdr Resolution Project"
herdr_resolution_file="$herdr_resolution_project/Assets/resolution.cs"
mkdir -p "$herdr_resolution_project/Assets"
printf 'one\n' >"$herdr_resolution_file"

# No explicit override and a GUI-like PATH that contains no herdr: the
# launcher must discover Herdr at the Homebrew absolute locations. When no
# Homebrew copy exists on this machine, the dry run must still degrade safely
# to no Herdr.
resolution_dry=$(env -i HOME="$HOME" PATH=/usr/bin:/bin:/usr/sbin:/sbin \
  UNITY_NVIM_LAUNCHER_DRY_RUN=1 "$launcher" \
  "$herdr_resolution_project" "$herdr_resolution_file" 1 1)
resolution_herdr=$(printf '%s\n' "$resolution_dry" | awk -F= '/^herdr=/{print $2}')
if [ -x /opt/homebrew/bin/herdr ]; then
  [ "$resolution_herdr" = /opt/homebrew/bin/herdr ] ||
    fail "GUI-like PATH did not discover /opt/homebrew/bin/herdr (got $resolution_herdr)"
elif [ -x /usr/local/bin/herdr ]; then
  [ "$resolution_herdr" = /usr/local/bin/herdr ] ||
    fail "GUI-like PATH did not discover /usr/local/bin/herdr (got $resolution_herdr)"
else
  [ "$resolution_herdr" = '-' ] ||
    fail "GUI-like PATH without a Homebrew herdr did not stay Herdr-unavailable (got $resolution_herdr)"
fi

# PATH discovery regression: a stub herdr on PATH must be discovered the same
# way when no absolute Homebrew copy exists. This branch can only run on
# machines without either absolute binary; elsewhere the stub is shadowed by
# the absolute locations and the case is skipped rather than asserting a
# result the launcher cannot reach.
herdr_path_stub="$test_dir/fake-herdr-bin/herdr"
mkdir -p "$(dirname -- "$herdr_path_stub")"
printf '%s\n' '#!/bin/sh' 'exit 0' >"$herdr_path_stub"
chmod +x "$herdr_path_stub"
if [ ! -x /opt/homebrew/bin/herdr ] && [ ! -x /usr/local/bin/herdr ]; then
  path_result=$(PATH="/usr/bin:/bin:$test_dir/fake-herdr-bin" \
    UNITY_NVIM_LAUNCHER_DRY_RUN=1 "$launcher" \
    "$herdr_resolution_project" "$herdr_resolution_file" 1 1 | \
    awk -F= '/^herdr=/{print $2}')
  [ "$path_result" = "$herdr_path_stub" ] ||
    fail "PATH discovery did not find the stub herdr (got $path_result)"
fi

# Explicit-override regressions: an executable override wins over every
# fallback location, and an explicitly named but non-executable binary keeps
# Herdr unavailable even though a Homebrew herdr exists — the test suite relies
# on this authority for its isolation contract.
override_result=$(env -i HOME="$HOME" PATH=/usr/bin:/bin:/usr/sbin:/sbin \
  UNITY_NVIM_LAUNCHER_HERDR="$herdr_path_stub" \
  UNITY_NVIM_LAUNCHER_DRY_RUN=1 "$launcher" \
  "$herdr_resolution_project" "$herdr_resolution_file" 1 1 | \
  awk -F= '/^herdr=/{print $2}')
[ "$override_result" = "$herdr_path_stub" ] ||
  fail "executable override did not win over the Homebrew discovery (got $override_result)"

override_absent=$(env -i HOME="$HOME" PATH=/usr/bin:/bin:/usr/sbin:/sbin \
  UNITY_NVIM_LAUNCHER_HERDR="$root/.absent-herdr" \
  UNITY_NVIM_LAUNCHER_DRY_RUN=1 "$launcher" \
  "$herdr_resolution_project" "$herdr_resolution_file" 1 1 | \
  awk -F= '/^herdr=/{print $2}')
[ "$override_absent" = '-' ] ||
  fail "explicit absent override was not honored over an existing Homebrew herdr (got $override_absent)"

printf 'PASS: UnityNeovimLauncher staging checks, server reuse integration, and Herdr-first routing\n'
printf 'PASS: Herdr dry-run resolution stayed isolated: no live Herdr state touched\n'
