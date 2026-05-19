#!/usr/bin/env bash
set -euo pipefail
umask 077

APP_NAME="${TERMITE_CMD_NAME:-${0##*/}}"
SCRIPT_PATH="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
LAUNCH_LABEL="${TERMITE_LAUNCH_LABEL:-sh.termite.daemon}"
CAFFEINATE_LABEL="${TERMITE_CAFFEINATE_LABEL:-sh.termite.caffeinate}"
DEFAULT_PREFIX="!"
LINK_PHRASE="${TERMITE_LINK_PHRASE:-!link termite}"
PREFIX="${TERMITE_PREFIX:-$DEFAULT_PREFIX}"
REQUIRE_PREFIX="${TERMITE_REQUIRE_PREFIX:-0}"
STATE_DIR="${TERMITE_STATE_DIR:-$HOME/.termite}"
STORE="${TERMITE_WACLI_STORE:-${WACLI_STORE_DIR:-$STATE_DIR/wacli}}"
COMMAND_SHELL="${TERMITE_SHELL:-${SHELL:-/bin/sh}}"
COMMAND_HOME="${TERMITE_COMMAND_HOME:-$HOME}"
DB="${TERMITE_DB:-$STORE/wacli.db}"
STORE_LOCK="$STORE/LOCK"
WORKDIR_FILE="$STATE_DIR/workdir"
CHAT_FILE="$STATE_DIR/allowed_chat"
CURSOR_FILE="$STATE_DIR/cursor"
SENT_FILE="$STATE_DIR/sent"
SYNC_PID_FILE="$STATE_DIR/wacli-sync.pid"
DAEMON_PID_FILE="$STATE_DIR/daemon.pid"
DAEMON_SCRIPT="$STATE_DIR/termite-daemon.sh"
SCREEN_SESSION="${TERMITE_SCREEN_SESSION:-termite}"
CAFFEINATE_PID_FILE="$STATE_DIR/caffeinate.pid"
LAUNCH_PLIST="$HOME/Library/LaunchAgents/$LAUNCH_LABEL.plist"
CAFFEINATE_PLIST="$HOME/Library/LaunchAgents/$CAFFEINATE_LABEL.plist"
SHELL_STARTUP_LOG="$STATE_DIR/shell-startup.log"
WEBHOOK_SCRIPT="$STATE_DIR/webhook-server.mjs"
WEBHOOK_EVENTS="$STATE_DIR/webhook-events"
WEBHOOK_PORT_FILE="$STATE_DIR/webhook-port"
POLL_INTERVAL="${TERMITE_POLL_INTERVAL:-0.2}"
MAX_MESSAGE_CHARS="${TERMITE_MAX_MESSAGE_CHARS:-3500}"
FLUSH_LINES="${TERMITE_FLUSH_LINES:-24}"
SEND_EXIT="${TERMITE_SEND_EXIT:-errors}" # errors | always | never
AUTH_IDLE_EXIT="${TERMITE_AUTH_IDLE_EXIT:-3s}"
AUTH_MAX_MESSAGES="${TERMITE_AUTH_MAX_MESSAGES:-1}"
SYNC_MAX_MESSAGES="${TERMITE_SYNC_MAX_MESSAGES:-0}"
SYNC_MAX_DB_SIZE="${TERMITE_SYNC_MAX_DB_SIZE:-0}"
ALLOW_GROUPS="${TERMITE_ALLOW_GROUPS:-0}"
IGNORE_SLASH_COMMANDS="${TERMITE_IGNORE_SLASH_COMMANDS:-1}"
SEND_CONNECTED="${TERMITE_SEND_CONNECTED:-1}"
TYPING_INDICATOR="${TERMITE_TYPING_INDICATOR:-1}"
BACKGROUND_MODE="${TERMITE_BACKGROUND_MODE:-terminal}" # terminal | launchd
SYNC_STARTED=0
SYNC_PAUSED_FOR_SEND=0
WEBHOOK_PID=""
RUN_STARTED_TS=0

usage() {
  cat <<EOF
$APP_NAME - WhatsApp your terminal, powered by wacli

Usage:
  ./$APP_NAME
  ./$APP_NAME start
  ./$APP_NAME daemon
  ./$APP_NAME auth
  ./$APP_NAME link
  ./$APP_NAME run [--replay]
  ./$APP_NAME quit
  ./$APP_NAME caffeinate
  ./$APP_NAME uncaffeinate
  ./$APP_NAME send "message"
  ./$APP_NAME status
  ./$APP_NAME reset

Environment:
  TERMITE_PREFIX           command prefix (default: !)
  TERMITE_REQUIRE_PREFIX   require prefix for commands, 0 or 1 (default: 0)
  TERMITE_LINK_PHRASE      link phrase (default: !link termite)
  TERMITE_SHELL            command shell (default: \$SHELL)
  TERMITE_COMMAND_HOME     default command directory (default: \$HOME)
  TERMITE_WACLI_STORE      isolated wacli store (default: ~/.termite/wacli)
  TERMITE_STATE_DIR        termite state directory (default: ~/.termite)
  TERMITE_POLL_INTERVAL    polling interval in seconds (default: 0.2)
  TERMITE_FLUSH_LINES      output lines to batch per message (default: 24)
  TERMITE_SEND_EXIT        errors, always, or never (default: errors)
  TERMITE_AUTH_IDLE_EXIT   auth bootstrap idle exit (default: 3s)
  TERMITE_AUTH_MAX_MESSAGES auth bootstrap message cap (default: 1)
  TERMITE_SYNC_MAX_MESSAGES live sync cap, 0 is unlimited (default: 0)
  TERMITE_SYNC_MAX_DB_SIZE live DB size cap, 0 is unlimited (default: 0)
  TERMITE_ALLOW_GROUPS     allow linking group chats, 0 or 1 (default: 0)
  TERMITE_IGNORE_SLASH_COMMANDS ignore /commands, 0 or 1 (default: 1)
  TERMITE_SEND_CONNECTED  send connected notice on daemon start, 0 or 1 (default: 1)
  TERMITE_TYPING_INDICATOR send WhatsApp typing indicator while command runs (default: 1)
  TERMITE_BACKGROUND_MODE terminal or launchd (default: terminal)
  TERMITE_SCREEN_SESSION detached screen name for terminal mode (default: termite)
  TERMITE_CAFFEINATE_LABEL launchd label for caffeinate helper (default: sh.termite.caffeinate)

Flow:
  1. Run ./$APP_NAME once to install and start the background daemon.
  2. Scan the QR if prompted.
  3. Message yourself "pwd", "ls -la", etc.
  4. Use ./$APP_NAME quit to stop the daemon.
EOF
}

die() {
  printf '%s\n' "error: $*" >&2
  exit 1
}

log() {
  printf '%s\n' "$*" >&2
}

ensure_dirs() {
  mkdir -p "$STATE_DIR" "$STORE"
  chmod 700 "$STATE_DIR" 2>/dev/null || true
  chmod 700 "$STORE" 2>/dev/null || true
}

require_bin() {
  command -v "$1" >/dev/null 2>&1 || die "missing dependency: $1"
}

wacli_cmd() {
  WACLI_SYNC_MAX_MESSAGES="$SYNC_MAX_MESSAGES" \
    WACLI_SYNC_MAX_DB_SIZE="$SYNC_MAX_DB_SIZE" \
    wacli --store "$STORE" "$@"
}

wacli_raw() {
  WACLI_SYNC_MAX_MESSAGES="$SYNC_MAX_MESSAGES" \
    WACLI_SYNC_MAX_DB_SIZE="$SYNC_MAX_DB_SIZE" \
    wacli --store "$STORE" "$@"
}

check_deps() {
  require_bin wacli
  require_bin sqlite3
  require_bin cksum
  require_bin awk
  require_bin jq
  require_bin node
  require_bin launchctl
}

launch_domain() {
  printf 'gui/%s\n' "$(id -u)"
}

plist_escape() {
  sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g' <<<"$1"
}

write_launch_agent() {
  mkdir -p "$HOME/Library/LaunchAgents"
  cp "$SCRIPT_PATH" "$DAEMON_SCRIPT"
  chmod 700 "$DAEMON_SCRIPT"
  local escaped_script escaped_log escaped_err escaped_path escaped_shell escaped_command_home
  escaped_script="$(plist_escape "$DAEMON_SCRIPT")"
  escaped_log="$(plist_escape "$STATE_DIR/daemon.log")"
  escaped_err="$(plist_escape "$STATE_DIR/daemon.err")"
  escaped_path="$(plist_escape "$PATH")"
  escaped_shell="$(plist_escape "$COMMAND_SHELL")"
  escaped_command_home="$(plist_escape "$COMMAND_HOME")"
  apply_launch_plist "$escaped_script" "$escaped_log" "$escaped_err" "$escaped_path" "$escaped_shell" "$escaped_command_home"
}

apply_launch_plist() {
  local escaped_script="$1"
  local escaped_log="$2"
  local escaped_err="$3"
  local escaped_path="$4"
  local escaped_shell="$5"
  local escaped_command_home="$6"
  tee "$LAUNCH_PLIST" >/dev/null <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$LAUNCH_LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$escaped_script</string>
    <string>daemon</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key>
    <string>$escaped_path</string>
    <key>TERMITE_CMD_NAME</key>
    <string>termite</string>
    <key>TERMITE_SHELL</key>
    <string>$escaped_shell</string>
    <key>TERMITE_COMMAND_HOME</key>
    <string>$escaped_command_home</string>
  </dict>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardOutPath</key>
  <string>$escaped_log</string>
  <key>StandardErrorPath</key>
  <string>$escaped_err</string>
</dict>
</plist>
EOF
  chmod 600 "$LAUNCH_PLIST"
}

service_running() {
  launchctl print "$(launch_domain)/$LAUNCH_LABEL" >/dev/null 2>&1
}

caffeinate_service_running() {
  launchctl print "$(launch_domain)/$CAFFEINATE_LABEL" >/dev/null 2>&1
}

daemon_running() {
  [[ -f "$DAEMON_PID_FILE" ]] || return 1
  local pid
  pid="$(sed -n '1p' "$DAEMON_PID_FILE")"
  [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null
}

stop_daemon_process() {
  if command -v screen >/dev/null 2>&1; then
    screen -S "$SCREEN_SESSION" -X quit >/dev/null 2>&1 || true
  fi
  if daemon_running; then
    local pid
    pid="$(sed -n '1p' "$DAEMON_PID_FILE")"
    kill "$pid" 2>/dev/null || true
  fi
  rm -f "$DAEMON_PID_FILE"
}

start_terminal_daemon() {
  cp "$SCRIPT_PATH" "$DAEMON_SCRIPT"
  chmod 700 "$DAEMON_SCRIPT"
  rm -f "$DAEMON_PID_FILE"
  if command -v screen >/dev/null 2>&1; then
    screen -S "$SCREEN_SESSION" -X quit >/dev/null 2>&1 || true
    (
      cd "$COMMAND_HOME" 2>/dev/null || cd "$HOME"
      TERMITE_CMD_NAME="termite" \
        TERMITE_SHELL="$COMMAND_SHELL" \
        TERMITE_COMMAND_HOME="$COMMAND_HOME" \
        TERMITE_BACKGROUND_MODE="$BACKGROUND_MODE" \
        screen -dmS "$SCREEN_SESSION" /bin/bash -lc \
          'exec "$0" daemon >>"$1" 2>>"$2"' \
          "$DAEMON_SCRIPT" "$STATE_DIR/daemon.log" "$STATE_DIR/daemon.err"
    )
  else
    (
      cd "$COMMAND_HOME" 2>/dev/null || cd "$HOME"
      TERMITE_CMD_NAME="termite" \
        TERMITE_SHELL="$COMMAND_SHELL" \
        TERMITE_COMMAND_HOME="$COMMAND_HOME" \
        TERMITE_BACKGROUND_MODE="$BACKGROUND_MODE" \
        nohup "$DAEMON_SCRIPT" daemon </dev/null >>"$STATE_DIR/daemon.log" 2>>"$STATE_DIR/daemon.err" &
    )
  fi
  local i pid
  for i in {1..50}; do
    pid="$(sed -n '1p' "$DAEMON_PID_FILE" 2>/dev/null || true)"
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      return 0
    fi
    sleep 0.1
  done
  tail -n 20 "$STATE_DIR/daemon.err" >&2 2>/dev/null || true
  die "termite daemon failed to stay running"
}

caffeinate_running() {
  caffeinate_service_running
}

write_caffeinate_agent() {
  mkdir -p "$HOME/Library/LaunchAgents"
  local escaped_out escaped_err
  escaped_out="$(plist_escape "$STATE_DIR/caffeinate.log")"
  escaped_err="$(plist_escape "$STATE_DIR/caffeinate.err")"
  tee "$CAFFEINATE_PLIST" >/dev/null <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$CAFFEINATE_LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/bin/caffeinate</string>
    <string>-dim</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardOutPath</key>
  <string>$escaped_out</string>
  <key>StandardErrorPath</key>
  <string>$escaped_err</string>
</dict>
</plist>
EOF
  chmod 600 "$CAFFEINATE_PLIST"
}

start_caffeinate_service() {
  write_caffeinate_agent
  rm -f "$CAFFEINATE_PID_FILE"
  if caffeinate_service_running; then
    launchctl kickstart -k "$(launch_domain)/$CAFFEINATE_LABEL" >/dev/null 2>&1 || true
    return
  fi
  launchctl bootstrap "$(launch_domain)" "$CAFFEINATE_PLIST"
  launchctl enable "$(launch_domain)/$CAFFEINATE_LABEL" >/dev/null 2>&1 || true
  launchctl kickstart -k "$(launch_domain)/$CAFFEINATE_LABEL" >/dev/null 2>&1 || true
}

stop_caffeinate_service() {
  if caffeinate_service_running; then
    launchctl bootout "$(launch_domain)/$CAFFEINATE_LABEL" >/dev/null 2>&1 || true
  fi
  rm -f "$CAFFEINATE_PID_FILE" "$CAFFEINATE_PLIST"
}

wait_service_unloaded() {
  local i
  for i in {1..50}; do
    service_running || return 0
    sleep 0.1
  done
  return 1
}

auth_status_json() {
  wacli_cmd auth status --json 2>/dev/null || printf '{"success":false}\n'
}

is_authenticated() {
  auth_status_json | jq -e '.success == true and .data.authenticated == true' >/dev/null
}

self_jid() {
  auth_status_json | jq -r '.data.linked_jid // empty'
}

sqlite() {
  sqlite3 -cmd ".timeout 2000" -cmd "PRAGMA query_only=ON" -separator $'\x1f' "$DB" "$@"
}

max_rowid() {
  if [[ ! -f "$DB" ]]; then
    printf '0\n'
    return
  fi
  sqlite 'SELECT COALESCE(MAX(rowid), 0) FROM messages;' 2>/dev/null || printf '0\n'
}

read_cursor() {
  local cursor current_max
  current_max="$(max_rowid)"
  if [[ -f "$CURSOR_FILE" ]]; then
    cursor="$(sed -n '1p' "$CURSOR_FILE")"
    if [[ "$cursor" =~ ^[0-9]+$ ]] && (( cursor <= current_max )); then
      printf '%s\n' "$cursor"
    else
      printf '%s\n' "$current_max"
    fi
  else
    printf '%s\n' "$current_max"
  fi
}

write_cursor() {
  printf '%s\n' "$1" >"$CURSOR_FILE"
}

save_chat() {
  printf '%s\n' "$1" >"$CHAT_FILE"
  chmod 600 "$CHAT_FILE" 2>/dev/null || true
}

allowed_chat() {
  [[ -f "$CHAT_FILE" ]] && sed -n '1p' "$CHAT_FILE"
}

is_group_chat() {
  [[ "$1" == *@g.us ]]
}

shell_quote() {
  printf "%q" "$1"
}

shell_name() {
  basename "$COMMAND_SHELL"
}

run_user_command() {
  local cwd="$1"
  local command_text="$2"
  local cwd_next="$3"
  local shell
  shell="$(shell_name)"

  case "$shell" in
    zsh)
      TERMITE_CWD="$cwd" TERMITE_COMMAND="$command_text" TERMITE_CWD_NEXT="$cwd_next" \
        TERMITE_STARTUP_LOG="$SHELL_STARTUP_LOG" TERM="${TERMITE_TERM:-xterm-256color}" \
        SHELL_SESSION_DID_INIT=1 SHELL_SESSIONS_DISABLE=1 \
        "$COMMAND_SHELL" -f -i -c '
          [[ -r "${ZDOTDIR:-$HOME}/.zshenv" ]] && source "${ZDOTDIR:-$HOME}/.zshenv" 2>>"$TERMITE_STARTUP_LOG"
          [[ -r "${ZDOTDIR:-$HOME}/.zprofile" ]] && source "${ZDOTDIR:-$HOME}/.zprofile" 2>>"$TERMITE_STARTUP_LOG"
          [[ -r "${ZDOTDIR:-$HOME}/.zshrc" ]] && source "${ZDOTDIR:-$HOME}/.zshrc" 2>>"$TERMITE_STARTUP_LOG"
          cd "$TERMITE_CWD" || exit $?
          eval "$TERMITE_COMMAND"
          rc=$?
          pwd > "$TERMITE_CWD_NEXT"
          exit "$rc"
        '
      ;;
    bash)
      TERMITE_CWD="$cwd" TERMITE_COMMAND="$command_text" TERMITE_CWD_NEXT="$cwd_next" \
        TERMITE_STARTUP_LOG="$SHELL_STARTUP_LOG" TERM="${TERMITE_TERM:-xterm-256color}" \
        "$COMMAND_SHELL" --noprofile --norc -i -c '
          shopt -s expand_aliases
          [[ -r "$HOME/.bash_profile" ]] && source "$HOME/.bash_profile" 2>>"$TERMITE_STARTUP_LOG"
          [[ -r "$HOME/.bash_login" ]] && source "$HOME/.bash_login" 2>>"$TERMITE_STARTUP_LOG"
          [[ -r "$HOME/.profile" ]] && source "$HOME/.profile" 2>>"$TERMITE_STARTUP_LOG"
          [[ -r "$HOME/.bashrc" ]] && source "$HOME/.bashrc" 2>>"$TERMITE_STARTUP_LOG"
          cd "$TERMITE_CWD" || exit $?
          eval "$TERMITE_COMMAND"
          rc=$?
          pwd > "$TERMITE_CWD_NEXT"
          exit "$rc"
        '
      ;;
    fish)
      TERMITE_CWD="$cwd" TERMITE_COMMAND="$command_text" TERMITE_CWD_NEXT="$cwd_next" \
        "$COMMAND_SHELL" -ic 'cd "$TERMITE_CWD"; or exit $status; eval "$TERMITE_COMMAND"; set rc $status; pwd > "$TERMITE_CWD_NEXT"; exit $rc'
      ;;
    *)
      TERMITE_CWD="$cwd" TERMITE_COMMAND="$command_text" TERMITE_CWD_NEXT="$cwd_next" \
        "$COMMAND_SHELL" -lc 'cd "$TERMITE_CWD" || exit $?; eval "$TERMITE_COMMAND"; rc=$?; pwd > "$TERMITE_CWD_NEXT"; exit "$rc"'
      ;;
  esac
}

send_text() {
  local to="$1"
  local text="$2"
  local len start chunk restart_sync send_rc

  if [[ -z "$text" ]]; then
    text=" "
  fi

  restart_sync=0
  if [[ "$SYNC_STARTED" == "1" && "$SYNC_PAUSED_FOR_SEND" == "0" ]]; then
    restart_sync=1
    SYNC_PAUSED_FOR_SEND=1
    stop_sync
  fi

  len=${#text}
  start=0
  send_rc=0
  while (( start < len )); do
    chunk="${text:start:MAX_MESSAGE_CHARS}"
    set +e
    wacli_raw send text --to "$to" --message "$chunk" --post-send-wait 0 >/dev/null
    send_rc=$?
    set -e
    if [[ "$send_rc" != "0" ]]; then
      break
    fi
    cleanup_stale_store_lock
    remember_sent "$to" "$chunk"
    start=$((start + MAX_MESSAGE_CHARS))
  done

  if [[ "$restart_sync" == "1" ]]; then
    SYNC_PAUSED_FOR_SEND=0
    start_sync
  fi

  if [[ "$send_rc" != "0" ]]; then
    log "warning: failed to send WhatsApp message to $to"
  fi
  return 0
}

begin_send_batch() {
  if [[ "$SYNC_STARTED" == "1" && "$SYNC_PAUSED_FOR_SEND" == "0" ]]; then
    SYNC_PAUSED_FOR_SEND=1
    stop_sync
  fi
}

end_send_batch() {
  if [[ "$SYNC_PAUSED_FOR_SEND" == "1" ]]; then
    SYNC_PAUSED_FOR_SEND=0
    start_sync
  fi
}

send_typing_indicator() {
  local to="$1"
  [[ "$TYPING_INDICATOR" == "1" ]] || return 0
  wacli_raw presence typing --to "$to" >/dev/null 2>&1 || true
}

flush_output_buffer() {
  local chat="$1"
  local buffer_file="$2"
  local text
  [[ -s "$buffer_file" ]] || return 0
  text="$(<"$buffer_file")"
  text="${text%$'\n'}"
  [[ -n "$text" ]] && send_text "$chat" "$text"
  : >"$buffer_file"
}

message_key() {
  local chat="$1"
  local text="$2"
  local normalized
  normalized="$(normalize_message_text "$text")"
  printf '%s\0%s' "$chat" "$normalized" | cksum | awk '{print $1 ":" $2}'
}

normalize_message_text() {
  local text="$1"
  text="${text//$'\r'/}"
  text="${text//$'\x1e'/$'\n'}"
  text="${text//^^/$'\n'}"
  printf '%s' "$text"
}

remember_sent() {
  local chat="$1"
  local text="$2"
  local key
  key="$(message_key "$chat" "$text")"
  printf '%s\n' "$key" >>"$SENT_FILE"
  tail -n 500 "$SENT_FILE" >"$SENT_FILE.tmp" && mv "$SENT_FILE.tmp" "$SENT_FILE"
  chmod 600 "$SENT_FILE" 2>/dev/null || true
}

was_sent_by_termite() {
  local chat="$1"
  local text="$2"
  local key
  [[ -f "$SENT_FILE" ]] || return 1
  key="$(message_key "$chat" "$text")"
  grep -Fqx "$key" "$SENT_FILE"
}

start_sync() {
  cleanup_stale_store_lock
  if [[ -f "$SYNC_PID_FILE" ]]; then
    local pid
    pid="$(sed -n '1p' "$SYNC_PID_FILE")"
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      log "wacli sync already running as pid $pid"
      SYNC_STARTED=0
      return
    fi
  fi

  log "starting wacli sync --follow for $STORE"
  local sync_args=(sync --follow)
  if [[ -f "$WEBHOOK_PORT_FILE" ]]; then
    local port
    port="$(sed -n '1p' "$WEBHOOK_PORT_FILE")"
    if [[ -n "$port" ]]; then
      sync_args+=(--webhook "http://127.0.0.1:$port/" --webhook-allow-private)
    fi
  fi
  if [[ "$SYNC_MAX_MESSAGES" != "0" ]]; then
    sync_args+=(--max-messages "$SYNC_MAX_MESSAGES")
  fi
  if [[ "$SYNC_MAX_DB_SIZE" != "0" ]]; then
    sync_args+=(--max-db-size "$SYNC_MAX_DB_SIZE")
  fi
  (
    WACLI_SYNC_MAX_MESSAGES="$SYNC_MAX_MESSAGES" \
      WACLI_SYNC_MAX_DB_SIZE="$SYNC_MAX_DB_SIZE" \
      exec wacli --store "$STORE" "${sync_args[@]}"
  ) >>"$STATE_DIR/wacli-sync.log" 2>&1 &
  echo $! >"$SYNC_PID_FILE"
  sleep 0.2
  local pid
  pid="$(sed -n '1p' "$SYNC_PID_FILE")"
  if [[ -z "$pid" ]] || ! kill -0 "$pid" 2>/dev/null; then
    tail -n 20 "$STATE_DIR/wacli-sync.log" >&2 2>/dev/null || true
    die "wacli sync failed to stay running"
  fi
  SYNC_STARTED=1
}

write_webhook_server() {
  cat >"$WEBHOOK_SCRIPT" <<'NODE'
import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';

const eventDir = process.env.TERMITE_WEBHOOK_EVENTS;
const portFile = process.env.TERMITE_WEBHOOK_PORT_FILE;

fs.mkdirSync(eventDir, { recursive: true, mode: 0o700 });

let seq = 0;
const server = http.createServer((req, res) => {
  if (req.method !== 'POST') {
    res.writeHead(204);
    res.end();
    return;
  }

  const chunks = [];
  req.on('data', (chunk) => chunks.push(chunk));
  req.on('end', () => {
    const body = Buffer.concat(chunks).toString('utf8');
    const name = `${Date.now()}-${process.pid}-${seq++}.json`;
    fs.writeFileSync(path.join(eventDir, name), body, { mode: 0o600 });
    res.writeHead(204);
    res.end();
  });
});

server.listen(0, '127.0.0.1', () => {
  const address = server.address();
  fs.writeFileSync(portFile, String(address.port), { mode: 0o600 });
});
NODE
  chmod 700 "$WEBHOOK_SCRIPT"
}

start_webhook() {
  rm -rf "$WEBHOOK_EVENTS"
  mkdir -p "$WEBHOOK_EVENTS"
  rm -f "$WEBHOOK_PORT_FILE"
  write_webhook_server
  TERMITE_WEBHOOK_EVENTS="$WEBHOOK_EVENTS" TERMITE_WEBHOOK_PORT_FILE="$WEBHOOK_PORT_FILE" \
    node "$WEBHOOK_SCRIPT" >>"$STATE_DIR/webhook-server.log" 2>&1 &
  WEBHOOK_PID="$!"

  local i
  for i in {1..50}; do
    [[ -s "$WEBHOOK_PORT_FILE" ]] && return 0
    sleep 0.1
  done
  die "webhook server failed to start"
}

stop_webhook() {
  if [[ -n "${WEBHOOK_PID:-}" ]] && kill -0 "$WEBHOOK_PID" 2>/dev/null; then
    kill "$WEBHOOK_PID" 2>/dev/null || true
  fi
  rm -f "$WEBHOOK_PORT_FILE"
}

stop_sync() {
  if [[ -f "$SYNC_PID_FILE" ]]; then
    local pid
    pid="$(sed -n '1p' "$SYNC_PID_FILE")"
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
    fi
    rm -f "$SYNC_PID_FILE"
  fi
  cleanup_stale_store_lock
}

cleanup_stale_store_lock() {
  [[ -f "$STORE_LOCK" ]] || return 0
  local lock_pid
  lock_pid="$(sed -n 's/^pid=//p' "$STORE_LOCK" | head -n 1)"
  if [[ -n "$lock_pid" ]] && kill -0 "$lock_pid" 2>/dev/null; then
    return 0
  fi
  rm -f "$STORE_LOCK"
}

query_new_messages() {
  local cursor="$1"
  sqlite <<SQL
SELECT rowid,
       chat_jid,
       COALESCE(sender_jid, ''),
       from_me,
       ts,
       replace(replace(COALESCE(display_text, text, media_caption, ''), char(10), char(30)), char(13), '')
FROM messages
WHERE rowid > $cursor
ORDER BY rowid ASC
LIMIT 100;
SQL
}

extract_webhook_message() {
  local file="$1"
  jq -r '
    def first_path($paths):
      reduce $paths[] as $p (null; if . == null then try getpath($p) catch null else . end);
    def clean:
      tostring | gsub("\u001f"; " ") | gsub("\r"; "") | gsub("\n"; "\u001e");
    [
      (first_path([["rowid"], ["message", "rowid"], ["data", "rowid"], ["data", "message", "rowid"]]) // 0 | clean),
      (first_path([["chat_jid"], ["chatJID"], ["chat"], ["jid"], ["message", "chat_jid"], ["message", "chatJID"], ["data", "chat_jid"], ["data", "chatJID"], ["data", "message", "chat_jid"], ["data", "message", "chatJID"]]) // "" | clean),
      (first_path([["sender_jid"], ["senderJID"], ["sender"], ["message", "sender_jid"], ["message", "senderJID"], ["data", "sender_jid"], ["data", "senderJID"], ["data", "message", "sender_jid"], ["data", "message", "senderJID"]]) // "" | clean),
      (first_path([["from_me"], ["fromMe"], ["message", "from_me"], ["message", "fromMe"], ["data", "from_me"], ["data", "fromMe"], ["data", "message", "from_me"], ["data", "message", "fromMe"]]) // false | if . == true or . == 1 then "1" else "0" end),
      (first_path([["ts"], ["timestamp"], ["time"], ["message", "ts"], ["message", "timestamp"], ["data", "ts"], ["data", "timestamp"], ["data", "message", "ts"], ["data", "message", "timestamp"]]) // now | floor | clean),
      (first_path([["display_text"], ["displayText"], ["text"], ["body"], ["message", "display_text"], ["message", "displayText"], ["message", "text"], ["message", "body"], ["data", "display_text"], ["data", "displayText"], ["data", "text"], ["data", "body"], ["data", "message", "display_text"], ["data", "message", "displayText"], ["data", "message", "text"], ["data", "message", "body"]]) // "" | clean)
    ] | join("\u001f")
  ' "$file"
}

process_webhook_events() {
  local event rowid chat sender from_me ts text
  shopt -s nullglob
  for event in "$WEBHOOK_EVENTS"/*.json; do
    IFS=$'\x1f' read -r rowid chat sender from_me ts text < <(extract_webhook_message "$event" 2>>"$STATE_DIR/webhook-server.log" || true)
    rm -f "$event"
    [[ -n "${chat:-}" ]] || continue
    handle_message "${rowid:-0}" "$chat" "${sender:-}" "${from_me:-0}" "${ts:-$(date +%s)}" "${text:-}" || true
    if [[ "${rowid:-}" =~ ^[0-9]+$ ]] && (( rowid > 0 )); then
      write_cursor "$rowid"
    fi
  done
  shopt -u nullglob
}

init_workdir() {
  if [[ ! -f "$WORKDIR_FILE" ]]; then
    printf '%s\n' "$COMMAND_HOME" >"$WORKDIR_FILE"
  fi
}

current_workdir() {
  init_workdir
  local cwd
  cwd="$(sed -n '1p' "$WORKDIR_FILE")"
  if [[ -z "$cwd" || ! -d "$cwd" || ! -x "$cwd" || ! -r "$cwd" ]]; then
    printf '%s\n' "$COMMAND_HOME" >"$WORKDIR_FILE"
    printf '%s\n' "$COMMAND_HOME"
    return
  fi
  cwd="$(cd "$cwd" 2>/dev/null && pwd -P || true)"
  if [[ -z "$cwd" ]]; then
    printf '%s\n' "$COMMAND_HOME" >"$WORKDIR_FILE"
    printf '%s\n' "$COMMAND_HOME"
    return
  fi
  printf '%s\n' "$cwd"
}

execute_command() {
  local chat="$1"
  local command_text="$2"
  local cwd cwd_next rc_file had_output_file buffer_file had_output rc line_count

  init_workdir
  cwd="$(current_workdir)"
  cwd_next="$(mktemp "${TMPDIR:-/tmp}/termite-cwd.XXXXXX")"
  rc_file="$(mktemp "${TMPDIR:-/tmp}/termite-rc.XXXXXX")"
  had_output_file="$(mktemp "${TMPDIR:-/tmp}/termite-output.XXXXXX")"
  buffer_file="$(mktemp "${TMPDIR:-/tmp}/termite-buffer.XXXXXX")"
  had_output=0
  line_count=0
  # Only pause sync for the typing send itself. Keeping sync alive while the
  # command runs lets later WhatsApp messages queue for the next loop pass.
  begin_send_batch
  send_typing_indicator "$chat"
  end_send_batch

  {
    set +e
    run_user_command "$cwd" "$command_text" "$cwd_next"
    printf '%s\n' "$?" >"$rc_file"
  } 2>&1 | while IFS= read -r line || [[ -n "$line" ]]; do
    printf '1\n' >"$had_output_file"
    if (( ${#line} + 1 > MAX_MESSAGE_CHARS )); then
      flush_output_buffer "$chat" "$buffer_file"
      send_text "$chat" "$line"
      line_count=0
      continue
    fi

    if (( $(wc -c <"$buffer_file") + ${#line} + 1 > MAX_MESSAGE_CHARS )); then
      flush_output_buffer "$chat" "$buffer_file"
      line_count=0
    fi

    printf '%s\n' "$line" >>"$buffer_file"
    line_count=$((line_count + 1))
    if (( line_count >= FLUSH_LINES )); then
      flush_output_buffer "$chat" "$buffer_file"
      line_count=0
    fi
  done
  flush_output_buffer "$chat" "$buffer_file"

  rc="$(sed -n '1p' "$rc_file" 2>/dev/null || printf '1')"
  [[ -s "$had_output_file" ]] && had_output=1
  if [[ -s "$cwd_next" ]]; then
    mv "$cwd_next" "$WORKDIR_FILE"
  else
    rm -f "$cwd_next"
  fi
  rm -f "$rc_file" "$had_output_file" "$buffer_file"

  if [[ "$SEND_EXIT" == "always" ]]; then
    send_text "$chat" "[exit $rc]"
  elif [[ "$SEND_EXIT" == "errors" && "$rc" != "0" ]]; then
    send_text "$chat" "[exit $rc]"
  elif [[ "$had_output" == "0" && "$SEND_EXIT" != "never" ]]; then
    send_text "$chat" "[exit $rc, no output]"
  fi
}

handle_message() {
  local rowid="$1"
  local chat="$2"
  local sender="$3"
  local from_me="$4"
  local ts="$5"
  local text="$6"
  local bound_chat command_text

  text="${text//$'\x1e'/$'\n'}"
  bound_chat="$(allowed_chat || true)"

  if [[ -z "$bound_chat" ]]; then
    if [[ "$text" == "$LINK_PHRASE" ]]; then
      if [[ "$ALLOW_GROUPS" != "1" ]] && is_group_chat "$chat"; then
        log "refusing to link group chat $chat; set TERMITE_ALLOW_GROUPS=1 to override"
        return
      fi
      save_chat "$chat"
      send_text "$chat" "termite linked to this chat. Send ${PREFIX}<command> to run commands."
      log "linked $chat at rowid $rowid"
    fi
    return
  fi

  [[ "$chat" == "$bound_chat" ]] || return
  [[ "$from_me" == "1" && -z "$sender" ]] && return
  [[ "$ts" =~ ^[0-9]+$ ]] || return
  (( ts >= RUN_STARTED_TS )) || return
  was_sent_by_termite "$chat" "$text" && return
  [[ "$text" == "$LINK_PHRASE" ]] && return
  [[ "$IGNORE_SLASH_COMMANDS" == "1" && "$text" == /* ]] && return

  if [[ "$text" == "$PREFIX"* ]]; then
    command_text="${text#"$PREFIX"}"
  elif [[ "$REQUIRE_PREFIX" == "1" ]]; then
    return
  else
    command_text="$text"
  fi

  [[ -n "$command_text" ]] || return
  log "exec rowid=$rowid chat=$chat command=$(shell_quote "$command_text")"
  execute_command "$chat" "$command_text"
}

serve_loop() {
  local replay="$1"
  local cursor line rowid chat sender from_me ts text

  [[ -f "$DB" ]] || die "wacli database not found at $DB; run ./termite.sh auth first"
  RUN_STARTED_TS="$(date +%s)"
  start_webhook
  start_sync
  trap '[[ "$SYNC_STARTED" == "1" ]] && stop_sync; stop_webhook' EXIT
  trap '[[ "$SYNC_STARTED" == "1" ]] && stop_sync; stop_webhook; exit 130' INT TERM

  if [[ "$replay" == "0" && ! -f "$CURSOR_FILE" ]]; then
    write_cursor "$(max_rowid)"
  fi
  cursor="$(read_cursor)"
  log "watching WhatsApp messages after rowid $cursor"

  while true; do
    process_webhook_events
    cursor="$(read_cursor)"
    while IFS=$'\x1f' read -r rowid chat sender from_me ts text; do
      [[ -n "${rowid:-}" ]] || continue
      handle_message "$rowid" "$chat" "$sender" "$from_me" "$ts" "$text" || true
      write_cursor "$rowid"
      cursor="$rowid"
    done < <(query_new_messages "$cursor" 2>/dev/null || true)
    sleep "$POLL_INTERVAL"
  done
}

cmd_auth() {
  check_deps
  ensure_dirs
  if is_authenticated; then
    local jid
    jid="$(self_jid)"
    [[ -n "$jid" ]] && save_chat "$jid"
    printf 'WhatsApp already linked: %s\n' "${jid:-unknown}"
    printf 'Run "%s" to start listening for self-chat commands.\n' "$APP_NAME"
    return
  fi
  WACLI_SYNC_MAX_MESSAGES="$AUTH_MAX_MESSAGES" \
    WACLI_SYNC_MAX_DB_SIZE="${TERMITE_AUTH_MAX_DB_SIZE:-1MB}" \
    wacli --store "$STORE" auth --idle-exit "$AUTH_IDLE_EXIT" "$@"
}

cmd_daemon() {
  check_deps
  ensure_dirs
  printf '%s\n' "$$" >"$DAEMON_PID_FILE"
  trap 'rm -f "$DAEMON_PID_FILE"' EXIT

  if ! is_authenticated; then
    log "WhatsApp is not linked yet; starting QR auth."
    cmd_auth "$@" || true
    is_authenticated || die "WhatsApp auth did not complete"
  fi

  local jid
  jid="$(self_jid)"
  [[ -n "$jid" ]] || die "could not read linked WhatsApp JID; run $APP_NAME auth again"
  save_chat "$jid"
  write_cursor "$(max_rowid)"
  log "linked self chat: $jid"
  if [[ "$SEND_CONNECTED" == "1" ]]; then
    send_text "$jid" "termite connected. Send commands here."
  fi
  log "message yourself a command; for example: pwd"
  serve_loop 0
}

cmd_start() {
  check_deps
  ensure_dirs
  cleanup_stale_store_lock
  local was_caffeinated=0
  if caffeinate_running; then
    was_caffeinated=1
    stop_caffeinate_service
  fi

  if ! is_authenticated; then
    log "WhatsApp is not linked yet; starting QR auth."
    cmd_auth "$@" || true
    is_authenticated || die "WhatsApp auth did not complete"
  fi

  local jid
  jid="$(self_jid)"
  [[ -n "$jid" ]] && save_chat "$jid"

  if service_running; then
    launchctl bootout "$(launch_domain)/$LAUNCH_LABEL" >/dev/null 2>&1 || true
    wait_service_unloaded || die "timed out waiting for existing termite service to stop"
  fi
  stop_daemon_process

  case "$BACKGROUND_MODE" in
    terminal)
      start_terminal_daemon
      ;;
    launchd)
      write_launch_agent
      launchctl bootstrap "$(launch_domain)" "$LAUNCH_PLIST"
      launchctl enable "$(launch_domain)/$LAUNCH_LABEL" >/dev/null 2>&1 || true
      launchctl kickstart -k "$(launch_domain)/$LAUNCH_LABEL" >/dev/null 2>&1 || true
      ;;
    *)
      die "TERMITE_BACKGROUND_MODE must be terminal or launchd"
      ;;
  esac

  if [[ "$was_caffeinated" == "1" ]]; then
    start_caffeinate_service
  fi

  printf 'termite is running in the background.\n'
  printf 'background mode: %s\n' "$BACKGROUND_MODE"
  printf 'linked chat: %s\n' "${jid:-unknown}"
  printf 'stop with: %s quit\n' "$APP_NAME"
}

cmd_quit() {
  ensure_dirs
  cmd_uncaffeinate >/dev/null 2>&1 || true
  if service_running; then
    launchctl bootout "$(launch_domain)/$LAUNCH_LABEL" >/dev/null 2>&1 || true
  fi
  stop_sync
  stop_webhook
  stop_daemon_process
  cleanup_stale_store_lock
  rm -f "$SYNC_PID_FILE" "$WEBHOOK_PORT_FILE"
  printf 'termite stopped.\n'
}

cmd_caffeinate() {
  check_deps
  require_bin caffeinate
  ensure_dirs
  if ! daemon_running; then
    cmd_start >/dev/null
  fi

  if caffeinate_running; then
    printf 'termite caffeinate already running.\n'
    return
  fi

  start_caffeinate_service
  printf 'termite caffeinate running.\n'
  printf 'stop with: %s uncaffeinate or %s quit\n' "$APP_NAME" "$APP_NAME"
}

cmd_uncaffeinate() {
  ensure_dirs
  stop_caffeinate_service
  printf 'termite caffeinate stopped.\n'
}

cmd_link() {
  check_deps
  ensure_dirs
  rm -f "$CHAT_FILE"
  write_cursor "$(max_rowid)"
  log "send \"$LINK_PHRASE\" from the WhatsApp chat that should control this terminal"
  serve_loop 1
}

cmd_run() {
  check_deps
  ensure_dirs
  local replay=0
  if [[ "${1:-}" == "--replay" ]]; then
    replay=1
  fi
  if [[ ! -f "$CHAT_FILE" ]]; then
    local jid
    jid="$(self_jid)"
    [[ -n "$jid" ]] || die "no linked chat; run $APP_NAME or $APP_NAME link first"
    save_chat "$jid"
    log "auto-linked self chat: $jid"
  fi
  serve_loop "$replay"
}

cmd_send() {
  check_deps
  ensure_dirs
  local chat
  chat="$(allowed_chat || true)"
  [[ -n "$chat" ]] || die "no linked chat; run ./termite.sh link first"
  [[ $# -gt 0 ]] || die "send requires a message"
  send_text "$chat" "$*"
}

cmd_status() {
  check_deps
  ensure_dirs
  printf 'store: %s\n' "$STORE"
  printf 'db: %s\n' "$DB"
  printf 'state: %s\n' "$STATE_DIR"
  printf 'launch label: %s\n' "$LAUNCH_LABEL"
  printf 'launch plist: %s\n' "$LAUNCH_PLIST"
  printf 'caffeinate label: %s\n' "$CAFFEINATE_LABEL"
  printf 'caffeinate plist: %s\n' "$CAFFEINATE_PLIST"
  printf 'daemon script: %s\n' "$DAEMON_SCRIPT"
  printf 'background mode: %s\n' "$BACKGROUND_MODE"
  printf 'screen session: %s\n' "$SCREEN_SESSION"
  if service_running; then
    printf 'background service: loaded\n'
  else
    printf 'background service: not loaded\n'
  fi
  if daemon_running; then
    printf 'daemon: running pid %s\n' "$(sed -n '1p' "$DAEMON_PID_FILE")"
  else
    printf 'daemon: not running\n'
  fi
  if caffeinate_running; then
    printf 'caffeinate: loaded\n'
  else
    printf 'caffeinate: not running\n'
  fi
  printf 'shell: %s\n' "$COMMAND_SHELL"
  printf 'command home: %s\n' "$COMMAND_HOME"
  printf 'current workdir: %s\n' "$(current_workdir)"
  printf 'shell startup log: %s\n' "$SHELL_STARTUP_LOG"
  printf 'prefix: %s\n' "$PREFIX"
  printf 'require prefix: %s\n' "$REQUIRE_PREFIX"
  printf 'link phrase: %s\n' "$LINK_PHRASE"
  printf 'poll interval: %s\n' "$POLL_INTERVAL"
  printf 'flush lines: %s\n' "$FLUSH_LINES"
  printf 'auth idle exit: %s\n' "$AUTH_IDLE_EXIT"
  printf 'auth max messages: %s\n' "$AUTH_MAX_MESSAGES"
  printf 'sync max messages: %s\n' "$SYNC_MAX_MESSAGES"
  printf 'sync max db size: %s\n' "$SYNC_MAX_DB_SIZE"
  printf 'allow groups: %s\n' "$ALLOW_GROUPS"
  printf 'ignore slash commands: %s\n' "$IGNORE_SLASH_COMMANDS"
  printf 'send connected: %s\n' "$SEND_CONNECTED"
  printf 'typing indicator: %s\n' "$TYPING_INDICATOR"
  printf 'linked chat: %s\n' "$(allowed_chat || printf '<none>')"
  printf 'cursor: %s\n' "$(read_cursor)"
  if [[ -f "$SYNC_PID_FILE" ]]; then
    local pid
    pid="$(sed -n '1p' "$SYNC_PID_FILE")"
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      printf 'wacli sync: running pid %s\n' "$pid"
    else
      printf 'wacli sync: stale pid %s\n' "$pid"
      rm -f "$SYNC_PID_FILE"
    fi
  else
    printf 'wacli sync: not managed by termite\n'
  fi
}

cmd_reset() {
  ensure_dirs
  cmd_quit >/dev/null 2>&1 || true
  stop_sync
  rm -f "$CHAT_FILE" "$CURSOR_FILE" "$WORKDIR_FILE"
  rm -f "$SENT_FILE"
  rm -f "$DAEMON_SCRIPT"
  rm -f "$LAUNCH_PLIST" "$CAFFEINATE_PLIST" "$CAFFEINATE_PID_FILE"
  log "reset termite state in $STATE_DIR"
}

main() {
  local cmd="${1:-}"
  shift || true

  case "$cmd" in
    start) cmd_start "$@" ;;
    daemon) cmd_daemon "$@" ;;
    auth) cmd_auth "$@" ;;
    link) cmd_link "$@" ;;
    run) cmd_run "$@" ;;
    quit) cmd_quit "$@" ;;
    caffeinate) cmd_caffeinate "$@" ;;
    uncaffeinate) cmd_uncaffeinate "$@" ;;
    send) cmd_send "$@" ;;
    status) cmd_status "$@" ;;
    reset) cmd_reset "$@" ;;
    help|-h|--help) usage ;;
    "") cmd_start "$@" ;;
    *) die "unknown command: $cmd" ;;
  esac
}

main "$@"
