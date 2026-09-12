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

# This integration path proves server reuse without invoking Ghostty.
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/unity-neovim-launcher.XXXXXX")
server_pid=''
delayed_pid=''
cleanup() {
  if [ -n "$delayed_pid" ]; then
    kill "$delayed_pid" 2>/dev/null || true
    wait "$delayed_pid" 2>/dev/null || true
  fi
  if [ -n "$server_pid" ]; then
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
  fi
  [ -z "${delayed_socket:-}" ] || rm -f "$delayed_socket"
  [ -z "${integration_socket:-}" ] || rm -f "$integration_socket"
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
delayed_pid_file="$test_dir/delayed-nvim.pid"
printf '%s\n' '#!/bin/sh' 'sleep "${UNITY_NVIM_LAUNCHER_TEST_DELAY:-0}"' 'printf "%s\n" "$$" > "$UNITY_NVIM_LAUNCHER_TEST_PID_FILE"' 'exec "$UNITY_NVIM_LAUNCHER_REAL_NVIM" --clean --headless "$@"' >"$delayed_nvim"
printf '%s\n' '#!/bin/sh' '/bin/sh -c "$3" >/dev/null 2>&1 &' >"$delayed_osascript"
chmod +x "$delayed_nvim" "$delayed_osascript"
UNITY_NVIM_LAUNCHER_NVIM="$delayed_nvim" UNITY_NVIM_LAUNCHER_OSASCRIPT="$delayed_osascript" UNITY_NVIM_LAUNCHER_REAL_NVIM="$nvim" UNITY_NVIM_LAUNCHER_TEST_DELAY=0.3 UNITY_NVIM_LAUNCHER_TEST_PID_FILE="$delayed_pid_file" "$launcher" "$delayed_project" "$delayed_file" 3 2 || fail "launcher did not wait for delayed Neovim"
delayed_cursor=$("$nvim" --server "$delayed_socket" --remote-expr "luaeval(\"vim.api.nvim_win_get_cursor(0)\")[0] . ':' . (luaeval(\"vim.api.nvim_win_get_cursor(0)\")[1] + 1)")
[ "$delayed_cursor" = '3:2' ] || fail "delayed first-launch cursor was not positioned (got $delayed_cursor)"
IFS= read -r delayed_pid <"$delayed_pid_file"
kill "$delayed_pid" 2>/dev/null || true
wait "$delayed_pid" 2>/dev/null || true
delayed_pid=''
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

printf 'PASS: UnityNeovimLauncher staging checks and server reuse integration\n'
