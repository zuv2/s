#!/usr/bin/env bash
# claude-ping installer for Ubuntu 24.04 (amd64/arm64), e.g. an Oracle Cloud instance.
#
# Sends a tiny prompt ("Reply with just: ok") through Claude Code CLI at exact wall-clock
# times, driven by a systemd user timer, so that a Claude subscription's usage window starts
# when you want it to.
#
# Download first, inspect, then execute. Do not pipe directly into bash:
#   curl -fsSLO <raw URL of this file>
#   less setup_claude.sh
#   bash setup_claude.sh
#
# Security model, in short:
#   - Runs as a regular user. sudo is used only to install missing base packages and to
#     enable lingering (so the user timer keeps running while nobody is logged in).
#   - The OAuth token is read from the terminal without echo, never passed as a command-line
#     argument, never written to the install log, and stored only in a mode-600 file.
#   - A new token is tested before it replaces the stored one.
#
# Re-running is the supported way to recover from an interrupted run, to replace the token
# (--reset-token) or to change settings: each step detects what is already in place.
#
# Files created:
#   ~/.config/claude-ping/env          CLAUDE_CODE_OAUTH_TOKEN=... (mode 600)
#   ~/.config/claude-ping/settings     times / timezone / model, reused by re-runs
#   ~/.config/claude-ping/ping.sh      the job itself
#   ~/.config/claude-ping/logs/        install logs (no secrets)
#   ~/.config/claude-ping/backup/      previous versions of generated files
#   ~/.config/systemd/user/claude-ping.{service,timer}
#   Claude Code CLI under ~/.local (official native installer), only if not already present
set -Eeuo pipefail
umask 077

# ── Defaults and fixed names ────────────────────────────────────────────────────────────────
NAME=claude-ping
USER=${USER:-$(id -un)}
CONF_DIR="$HOME/.config/$NAME"
ENV_FILE="$CONF_DIR/env"
SETTINGS="$CONF_DIR/settings"
PING="$CONF_DIR/ping.sh"
BACKUP_DIR="$CONF_DIR/backup"
UNIT_DIR="$HOME/.config/systemd/user"
SERVICE="$NAME.service"
TIMER="$NAME.timer"
CLI_INSTALLER=https://claude.ai/setup_claude.sh
PROMPT='Reply with just: ok'
DEFAULT_TIMES=00:00,01:00,05:00,06:00,09:00,10:00,14:00,15:00,19:00,20:00
DEFAULT_TZ=Asia/Seoul
DEFAULT_MODEL=haiku
TIMES=""; TZNAME=""; MODEL=""; RESET_TOKEN=0; TEST=1; ACTION=install
TOKEN=""; TOKEN_SRC=""; CLAUDE=""; OUT=""; RC=0

msg()   { printf '[claude-ping] %s\n' "$*"; }
warn()  { printf '[claude-ping] WARNING: %s\n' "$*" >&2; }
error() { printf '[claude-ping] ERROR: %s\n' "$*" >&2; exit 1; }

usage() { cat <<'USAGE'
Usage: bash setup_claude.sh [options]
  --times LIST     Comma-separated HH:MM run times
                   (default: 00:00,01:00,05:00,06:00,09:00,10:00,14:00,15:00,19:00,20:00)
  --tz ZONE        Timezone the times are in (default: Asia/Seoul; see timedatectl list-timezones)
  --model NAME     Model for the ping (default: haiku)
  --reset-token    Ask for a new OAuth token even if a stored one exists
  --no-test        Skip the final test run of the scheduled service
  --status         Show timer, recent runs and settings, then exit
  --uninstall      Remove the timer, service and stored token, then exit
  -h, --help       Show help
Re-running without --times/--tz/--model keeps the previously saved values.
USAGE
}

# ── Troubleshooting guides ──────────────────────────────────────────────────────────────────
guide_auth() { cat >&2 <<'G'
  How to fix: the token was rejected (invalid, expired, revoked, or copied incompletely).
   1. Create a new token while signed in to the Claude account that has your subscription:
        claude setup-token        (on this server, or on any PC with Claude Code installed)
      Open the printed URL in a browser, approve, and paste the code back into the terminal.
   2. Copy the whole token: one string starting with sk-ant-oat01-. If the terminal wrapped
      it over several lines, copy all of them; this installer joins the pieces.
   3. Re-run:  bash setup_claude.sh --reset-token
G
}
guide_format() { cat >&2 <<'G'
  How to fix: a subscription token starts with sk-ant-oat01- and is printed by
  'claude setup-token'. An API key (sk-ant-api...) or the one-time browser code will not work.
G
}
guide_net() { cat >&2 <<'G'
  How to fix: this instance cannot reach Anthropic's servers.
   - DNS:    getent hosts api.anthropic.com
   - HTTPS:  curl -sSI https://api.anthropic.com | head -1   (any HTTP status means reachable)
   - Oracle Cloud: the subnet's route table needs 0.0.0.0/0 -> Internet Gateway (public subnet)
     or NAT Gateway (private subnet), and the security list / NSG needs an EGRESS rule
     allowing TCP 443 to 0.0.0.0/0.
   - Host firewall: check outbound rules with  sudo iptables -S OUTPUT
  Fix it, then re-run this installer; completed steps are skipped.
G
}
guide_region() { cat >&2 <<'G'
  How to fix: Anthropic does not serve the country this instance's public IP is in.
  Use an instance in a supported region. https://www.anthropic.com/supported-countries
G
}
guide_limit() { cat >&2 <<'G'
  Note: nothing to fix. The token works, but your usage limit is reached right now.
  Scheduled pings will succeed again once the limit resets.
G
}
guide_other() { cat >&2 <<'G'
  How to fix: update the CLI and try again:
    ~/.local/bin/claude update && bash setup_claude.sh
  If it keeps failing, re-run with --reset-token, or open an issue with the log (it holds no secrets).
G
}
guide_userbus() { cat >&2 <<'G'
  How to fix: the per-user systemd manager is not reachable from this shell.
   - Log in over SSH directly as this user (not through 'sudo su' or 'su -').
   - If lingering was just enabled, log out and back in (or reboot once), then re-run.
G
}

# Classifies Claude CLI output. Patterns are matched case-insensitively.
RE_LIMIT='(usage|rate|session|weekly)[ -]?limit|limit (reached|exceeded)|resets (at|in) '
RE_REGION='not available in your (region|country)|unsupported.country|supported-countries'
RE_AUTH='not logged in|/login|401|unauthori[sz]ed|invalid[^.]*(token|key|credential|bearer)|oauth|token[^.]*(expired|revoked)|authentication'
RE_NET='enotfound|eai_again|econnrefused|econnreset|etimedout|enetunreach|ehostunreach|getaddrinfo|network|socket hang up|fetch failed|unable to connect|connection (error|refused|reset)|certificate|tls'
# Exit code 0 alone is not trusted: an empty reply or an error text printed with status 0 is not
# a success. Auth is checked before the usage-limit pattern, so a rejected token can never be
# mistaken for "authenticated but limited".
classify() {
 local rc=$1 o=${2,,}
 if (( rc == 124 )); then echo timeout
 elif [[ $o =~ $RE_AUTH ]]; then echo auth
 elif [[ $o =~ $RE_REGION ]]; then echo region
 elif [[ $o =~ $RE_LIMIT ]]; then echo limit
 elif (( rc == 0 )) && [[ -n ${o//[[:space:]]/} && ${#o} -le 200 ]]; then echo ok
 elif (( rc == 0 )); then echo other
 elif [[ $o =~ $RE_NET ]]; then echo network
 else echo other; fi
}

# ── Helpers ─────────────────────────────────────────────────────────────────────────────────
have_tty() { { : </dev/tty; } 2>/dev/null; }

# Reads a secret from the terminal without echo. A long token copied from a wrapped terminal
# line arrives as several lines in one paste, so lines arriving right after the first are joined.
read_token() {
 local line="" buf=""
 printf '%s' "$1" >/dev/tty
 IFS= read -rs line </dev/tty || true
 buf=$line
 while :; do
  line=""
  if IFS= read -rs -t 0.5 line </dev/tty; then buf+=$line; else buf+=$line; break; fi
 done
 printf '\n' >/dev/tty
 buf=${buf//[[:space:]]/}; buf=${buf//\"/}; buf=${buf//\'/}
 TOKEN=${buf#CLAUDE_CODE_OAUTH_TOKEN=}
}

stored_token() {
 [[ -f $ENV_FILE ]] || return 0
 local v
 v=$(grep -m1 '^CLAUDE_CODE_OAUTH_TOKEN=' "$ENV_FILE" || true)
 v=${v#CLAUDE_CODE_OAUTH_TOKEN=}; v=${v//[[:space:]]/}; v=${v//\"/}; v=${v//\'/}
 printf '%s' "$v"
}

check_token_format() {
 if [[ $TOKEN =~ ^sk-ant-oat01-[A-Za-z0-9_-]{40,}$ ]]; then return 0; fi
 if [[ $TOKEN == sk-ant-api* ]]; then warn 'That is an API key (billed per request), not a subscription token.'
 elif [[ -n $TOKEN ]]; then warn "That does not look like a complete token (${#TOKEN} characters, starts with '${TOKEN:0:12}')."
 else warn 'No token entered.'; fi
 guide_format
 return 1
}

find_claude() {
 local c
 for c in "$HOME/.local/bin/claude" "$(command -v claude 2>/dev/null || true)"; do
  if [[ -n $c && -x $c ]]; then CLAUDE=$c; return 0; fi
 done
 return 1
}

# Sends one prompt with $TOKEN. The token reaches the CLI through the environment only.
test_token() {
 OUT=$(
  export CLAUDE_CODE_OAUTH_TOKEN="$TOKEN"
  unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN
  cd "$HOME" || exit 1
  timeout 150 "$CLAUDE" -p "$PROMPT" --model "$MODEL" --max-turns 1 </dev/null 2>&1 || exit $?
 ) && RC=0 || RC=$?
 OUT=$(printf '%s' "$OUT" | tr '\n' ' ' | sed -E 's/sk-ant-[A-Za-z0-9_-]+/sk-ant-***/g' | cut -c1-400 || true)
}

# Replaces a generated file only when its content changed; the previous copy goes to backup/.
write_file() {
 local dest=$1 mode=$2 tmp
 tmp=$(mktemp)
 cat > "$tmp"
 if [[ -f $dest ]] && cmp -s "$tmp" "$dest"; then rm -f "$tmp"; return 0; fi
 if [[ -e $dest ]]; then
  mkdir -p "$BACKUP_DIR"
  cp -p "$dest" "$BACKUP_DIR/$(basename "$dest").$(date +%Y%m%d-%H%M%S)"
  # Keep the newest 5 copies per file.
  find "$BACKUP_DIR" -maxdepth 1 -name "$(basename "$dest").*" -printf '%T@ %p\n' | sort -rn | tail -n +6 | cut -d' ' -f2- | xargs -r rm -f --
 fi
 install -m "$mode" "$tmp" "$dest"; rm -f "$tmp"
}

user_bus() {
 export XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}
 local i
 for i in {1..30}; do
  if [[ -S $XDG_RUNTIME_DIR/bus ]]; then break; fi
  sleep 0.5
 done
 systemctl --user show-environment >/dev/null 2>&1
}

normalize_times() {
 local in=${1//[[:space:]]/} t h m
 local -a arr=() out=()
 IFS=',' read -r -a arr <<< "$in"
 for t in "${arr[@]}"; do
  [[ -n $t ]] || continue
  [[ $t =~ ^([0-9]{1,2})(:([0-9]{2}))?$ ]] || error "Invalid time '$t' (use HH:MM, e.g. 09:00)"
  h=$((10#${BASH_REMATCH[1]})); m=$((10#${BASH_REMATCH[3]:-0}))
  if (( h > 23 || m > 59 )); then error "Invalid time '$t'"; fi
  out+=("$(printf '%02d:%02d' "$h" "$m")")
 done
 (( ${#out[@]} )) || error '--times is empty'
 printf '%s\n' "${out[@]}" | sort -u | paste -sd, -
}

load_settings() {
 [[ -f $SETTINGS ]] || return 0
 local k v
 while IFS='=' read -r k v || [[ -n $k ]]; do
  case $k in
   TIMES) [[ -n $TIMES ]] || TIMES=$v ;;
   TZ) [[ -n $TZNAME ]] || TZNAME=$v ;;
   MODEL) [[ -n $MODEL ]] || MODEL=$v ;;
  esac
 done < "$SETTINGS"
}

# ── --status / --uninstall ──────────────────────────────────────────────────────────────────
show_status() {
 user_bus || { guide_userbus; error 'systemd user manager not reachable'; }
 echo '── Timer'; systemctl --user list-timers "$TIMER" --all --no-pager || true
 echo '── Last runs'; journalctl --user -u "$SERVICE" -n 20 --no-pager -o short-iso || true
 echo '── Settings'; cat "$SETTINGS" 2>/dev/null || echo '(none)'
 local t; t=$(stored_token)
 if [[ -n $t ]]; then echo "token: stored (${t:0:13}...)"; else echo 'token: not stored'; fi
}

do_uninstall() {
 if have_tty; then
  local a=""
  printf 'Remove the claude-ping timer, service and stored token? [y/N] ' >/dev/tty
  IFS= read -r a </dev/tty || true
  [[ $a == [yY]* ]] || { msg 'Cancelled'; exit 0; }
 fi
 if user_bus; then
  systemctl --user disable --now "$TIMER" >/dev/null 2>&1 || true
  systemctl --user stop "$SERVICE" >/dev/null 2>&1 || true
  systemctl --user clean --what=state "$TIMER" >/dev/null 2>&1 || true
 fi
 rm -f -- "$UNIT_DIR/$SERVICE" "$UNIT_DIR/$TIMER"
 systemctl --user daemon-reload >/dev/null 2>&1 || true
 rm -rf -- "$CONF_DIR"
 msg 'Removed timer, service, settings and the stored token.'
 msg 'Left in place: Claude Code CLI (~/.local/bin/claude, ~/.local/share/claude) and lingering'
 msg "  (disable with: sudo loginctl disable-linger $USER, if nothing else needs it)."
 msg 'To revoke the token itself, sign out of that session from your Claude account settings.'
}

# ── Argument parsing ────────────────────────────────────────────────────────────────────────
while (($#)); do
 case "$1" in
  --times|--tz|--model)
   (($# >= 2)) && [[ -n "$2" ]] || error "$1 requires a value"
   case "$1" in --times) TIMES=$2;; --tz) TZNAME=$2;; --model) MODEL=$2;; esac
   shift 2;;
  --reset-token) RESET_TOKEN=1; shift;;
  --no-test) TEST=0; shift;;
  --status) ACTION=status; shift;;
  --uninstall) ACTION=uninstall; shift;;
  -h|--help) usage; exit 0;;
  *) usage >&2; error "Unknown option: $1";;
 esac
done

(( EUID != 0 )) || error 'Run as a regular user (e.g. ubuntu), not root. sudo is used only where needed.'
[[ -d /run/systemd/system ]] || error 'systemd is not running on this host'
case $ACTION in
 status) show_status; exit 0;;
 uninstall) do_uninstall; exit 0;;
esac

# ── Environment and input validation (no system changes yet) ────────────────────────────────
source /etc/os-release
[[ "${ID:-}" == ubuntu ]] || error 'Only Ubuntu is supported'
[[ "${VERSION_ID:-}" == 24.04 ]] || warn "Tested on Ubuntu 24.04 only; this is $VERSION_ID"
case "$(dpkg --print-architecture)" in amd64|arm64) ;; *) error 'Only amd64 and arm64 are supported';; esac

load_settings
TIMES=$(normalize_times "${TIMES:-$DEFAULT_TIMES}")
TZNAME=${TZNAME:-$DEFAULT_TZ}
MODEL=${MODEL:-$DEFAULT_MODEL}
[[ $TZNAME =~ ^[A-Za-z0-9_+-]+(/[A-Za-z0-9_+-]+)*$ && -f /usr/share/zoneinfo/$TZNAME ]] ||
 error "Unknown timezone '$TZNAME' (list: timedatectl list-timezones)"
[[ $MODEL =~ ^[A-Za-z0-9._-]+$ ]] || error "Invalid model name '$MODEL'"
IFS=',' read -r -a TIME_LIST <<< "$TIMES"
for t in "${TIME_LIST[@]}"; do
 systemd-analyze calendar "*-*-* $t:00 $TZNAME" >/dev/null 2>&1 || error "systemd rejects time '$t $TZNAME'"
done

# Exact timing depends on a synchronized clock.
if [[ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null || true)" != yes ]]; then
 warn 'System clock is not NTP-synchronized; runs may drift. Fix: sudo timedatectl set-ntp true'
fi

# sudo is needed only for missing packages or lingering, so re-runs usually do not ask for it.
MISSING=()
command -v curl >/dev/null || MISSING+=(curl)
[[ -s /etc/ssl/certs/ca-certificates.crt ]] || MISSING+=(ca-certificates)
command -v flock >/dev/null || MISSING+=(util-linux)
NEED_LINGER=0
[[ -e /var/lib/systemd/linger/$USER ]] || NEED_LINGER=1
if (( ${#MISSING[@]} || NEED_LINGER )); then
 command -v sudo >/dev/null || error 'sudo is required for the first run'
 # Not 'sudo -v': cloud images often have no user password, which makes -v fail.
 sudo true || error 'sudo is not usable for this user'
fi

# ── Token prompt (before logging starts, so nothing typed here can reach the log) ───────────
if (( ! RESET_TOKEN )); then
 TOKEN=$(stored_token)
 if [[ -n $TOKEN ]]; then TOKEN_SRC=stored; fi
fi
if [[ -z $TOKEN ]]; then
 have_tty || error 'No stored token and no terminal to ask for one; run this installer interactively'
 msg 'A Claude subscription OAuth token is needed (created with: claude setup-token).'
 read_token 'Paste the token (hidden), or press Enter to create one after the CLI is installed: '
 TOKEN_SRC=new
 if [[ -n $TOKEN ]] && ! check_token_format; then
  read_token 'Paste the token again (hidden), or press Enter to create one later: '
  if [[ -n $TOKEN ]] && ! check_token_format; then error 'Invalid token format'; fi
 fi
fi

# ── Logging ─────────────────────────────────────────────────────────────────────────────────
mkdir -p "$CONF_DIR/logs"; chmod 700 "$CONF_DIR" "$CONF_DIR/logs"
LOG="$CONF_DIR/logs/install-$(date +%Y%m%d-%H%M%S).log"
: > "$LOG"; chmod 600 "$LOG"
exec > >(tee -a "$LOG") 2>&1
trap 'printf "[claude-ping] ERROR at line %s. Log: %s\n[claude-ping] Fix the problem above and re-run; completed steps are skipped.\n" "$LINENO" "$LOG" >&2' ERR
msg "Times: $TIMES ($TZNAME) | model: $MODEL"

# ── Base packages ───────────────────────────────────────────────────────────────────────────
if (( ${#MISSING[@]} )); then
 msg "Installing missing packages: ${MISSING[*]}"
 # Wait up to 5 minutes for the apt lock: unattended-upgrades often holds it right after first boot.
 if ! { sudo apt-get update -o DPkg::Lock::Timeout=300 &&
        sudo env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a \
         apt-get install -y -o DPkg::Lock::Timeout=300 "${MISSING[@]}"; }; then
  guide_net
  error 'apt failed (network problem, or apt still locked by another process)'
 fi
fi

# ── Network check ───────────────────────────────────────────────────────────────────────────
NET_BAD=0
for h in claude.ai api.anthropic.com; do
 if ! getent ahosts "$h" >/dev/null 2>&1; then warn "DNS lookup failed: $h"; NET_BAD=1; continue; fi
 code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 15 "https://$h/" 2>/dev/null || true)
 if [[ -z $code || $code == 000 ]]; then warn "HTTPS connection failed: $h"; NET_BAD=1; fi
done
if (( NET_BAD )); then guide_net; error 'Network check failed'; fi
msg 'Network OK'

# ── Claude Code CLI ─────────────────────────────────────────────────────────────────────────
if find_claude; then
 msg "Using existing Claude Code CLI: $CLAUDE"
else
 msg 'Installing Claude Code CLI with the official native installer'
 TMP=$(mktemp)
 DL_OK=0
 for i in 1 2 3; do
  if curl -fsSL --max-time 60 "$CLI_INSTALLER" -o "$TMP" && [[ "$(head -c 2 "$TMP")" == '#!' ]]; then DL_OK=1; break; fi
  warn "Download attempt $i failed; retrying in 5 seconds"; sleep 5
 done
 if (( ! DL_OK )); then rm -f "$TMP"; guide_net; error "Could not download $CLI_INSTALLER"; fi
 if ! bash "$TMP" </dev/null; then rm -f "$TMP"; guide_net; error 'Claude Code installer failed (see output above)'; fi
 rm -f "$TMP"
 find_claude || error "Installer finished but 'claude' was not found in ~/.local/bin"
fi
VERSION=$("$CLAUDE" --version 2>/dev/null | head -1 || true)
[[ -n $VERSION ]] || error "'$CLAUDE --version' failed; remove ~/.local/share/claude and re-run"
msg "Claude Code CLI: $VERSION"

# ── Token: obtain if needed, then test it ───────────────────────────────────────────────────
generate_token() {
 msg "Starting 'claude setup-token'. Open the URL it shows in a browser signed in to your"
 msg 'Claude account, approve, and paste the code back here.'
 # Its output goes straight to the terminal, bypassing the install log, because it shows the token.
 "$CLAUDE" setup-token </dev/tty >/dev/tty 2>&1 || warn "'claude setup-token' exited with an error"
}
TOKEN_OK=0
for _ in 1 2 3; do
 if [[ -z $TOKEN ]]; then
  have_tty || { guide_auth; error 'No usable token and no terminal to ask for one'; }
  read_token 'Paste the token (hidden), or press Enter to create one now: '
  if [[ -z $TOKEN ]]; then
   generate_token
   read_token 'Paste the token printed above (hidden): '
  fi
  TOKEN_SRC=new
 fi
 if ! check_token_format; then TOKEN=""; continue; fi
 msg "Testing the ${TOKEN_SRC} token with one request (up to 2.5 minutes)"
 test_token
 case "$(classify "$RC" "$OUT")" in
  ok) msg "Token OK (reply: $OUT)"; TOKEN_OK=1; break;;
  limit)
   # Anthropic returns a usage-limit error only after the token has been authenticated
   # (an invalid token gets 401 first), and auth patterns were ruled out above.
   warn "Token authenticated, but usage is limited right now: $OUT"; guide_limit; TOKEN_OK=1; break;;
  auth)
   warn "Token rejected: $OUT"; guide_auth
   if [[ $TOKEN_SRC == stored ]]; then msg 'The stored token no longer works; enter a new one.'; fi
   TOKEN="";;
  region) warn "$OUT"; guide_region; error 'Region not supported';;
  network|timeout) warn "Request failed (rc=$RC): $OUT"; guide_net; error 'Network problem while testing the token';;
  *) warn "Unexpected result (rc=$RC): $OUT"; guide_other; error 'Token test failed';;
 esac
done
(( TOKEN_OK )) || error 'No working token after 3 attempts; re-run with --reset-token when you have one'

# ── Generated files ─────────────────────────────────────────────────────────────────────────
mkdir -p "$UNIT_DIR"
# printf is a shell builtin, so the token never appears in a process argument list.
# Written to a temp file in the same directory, then renamed: the old token stays intact until
# the new file is complete (rename within one filesystem is atomic).
if [[ "$(stored_token)" != "$TOKEN" ]]; then
 ENV_TMP=$(mktemp "$CONF_DIR/.env.XXXXXX")
 if printf 'CLAUDE_CODE_OAUTH_TOKEN=%s\n' "$TOKEN" > "$ENV_TMP" && chmod 600 "$ENV_TMP" && mv -f "$ENV_TMP" "$ENV_FILE"; then
  msg 'Token saved'
 else
  rm -f "$ENV_TMP"; error "Could not write $ENV_FILE (disk full or permissions?); the previous token was kept"
 fi
fi
chmod 600 "$ENV_FILE"
unset TOKEN

printf 'TIMES=%s\nTZ=%s\nMODEL=%s\n' "$TIMES" "$TZNAME" "$MODEL" | write_file "$SETTINGS" 600

{
 printf '#!/usr/bin/env bash\n# Generated by the claude-ping installer; re-run the installer to change settings.\n'
 printf 'CLAUDE=%q\nMODEL=%q\nPROMPT=%q\n' "$CLAUDE" "$MODEL" "$PROMPT"
 cat <<'BODY'
set -uo pipefail
NETRE='enotfound|eai_again|econnrefused|econnreset|etimedout|enetunreach|ehostunreach|getaddrinfo|network|socket hang up|fetch failed|unable to connect|connection (error|refused|reset)'
# Never run two pings at once (e.g. a catch-up run after boot overlapping a scheduled one).
exec 9>"${XDG_RUNTIME_DIR:-/tmp}/claude-ping.lock"
flock -n 9 || { echo 'previous ping still running; skipped'; exit 0; }
if [[ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]]; then
 echo 'CLAUDE_CODE_OAUTH_TOKEN is missing; re-run the installer with --reset-token'; exit 2
fi
[[ -x $CLAUDE ]] || CLAUDE=$(command -v claude || echo "$CLAUDE")
unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN
cd "$HOME" || exit 1
rc=1
for attempt in 1 2 3; do
 out=$(timeout 120 "$CLAUDE" -p "$PROMPT" --model "$MODEL" --max-turns 1 </dev/null 2>&1); rc=$?
 out=$(printf '%s' "$out" | tr '\n' ' ' | sed -E 's/sk-ant-[A-Za-z0-9_-]+/sk-ant-***/g' | cut -c1-300)
 # Status 0 with an auth error or an empty reply is not a success.
 if (( rc == 0 )) && { [[ -z ${out//[[:space:]]/} ]] || [[ ${out,,} =~ not\ logged\ in|/login|unauthori ]]; }; then rc=3; fi
 echo "attempt=$attempt rc=$rc out=$out"
 (( rc == 0 )) && exit 0
 # Only transient-looking failures are retried; an auth error will not fix itself.
 if (( rc == 124 )) || [[ ${out,,} =~ $NETRE ]]; then sleep 20; continue; fi
 break
done
if [[ ${out,,} =~ not\ logged\ in|/login|401|unauthori|oauth|authentication ]]; then
 echo 'Token rejected. Create a new one (claude setup-token) and re-run the installer with --reset-token.'
fi
exit "$rc"
BODY
} | write_file "$PING" 700

write_file "$UNIT_DIR/$SERVICE" 644 <<'UNIT'
[Unit]
Description=Claude quota ping

[Service]
Type=oneshot
EnvironmentFile=%h/.config/claude-ping/env
ExecStart=%h/.config/claude-ping/ping.sh
TimeoutStartSec=10min
UNIT

{
 printf '[Unit]\nDescription=Claude quota ping timer\n\n[Timer]\n'
 for t in "${TIME_LIST[@]}"; do printf 'OnCalendar=*-*-* %s:00 %s\n' "$t" "$TZNAME"; done
 # AccuracySec defaults to 1 minute; 1s makes the runs start on the second.
 # Persistent=false: a run missed while the instance was down is skipped, not fired late at boot,
 # because a ping at an unscheduled time would shift the usage window.
 printf 'AccuracySec=1s\nRandomizedDelaySec=0\nPersistent=false\n\n[Install]\nWantedBy=timers.target\n'
} | write_file "$UNIT_DIR/$TIMER" 644

# ── systemd user timer ──────────────────────────────────────────────────────────────────────
# Without lingering the user's timers stop as soon as the last SSH session closes.
if (( NEED_LINGER )); then
 msg "Enabling lingering for $USER so the timer runs while you are logged out"
 sudo loginctl enable-linger "$USER"
fi
user_bus || { guide_userbus; error 'systemd user manager not reachable'; }
systemctl --user daemon-reload
# Drop the last-run stamp an older Persistent=true version may have left behind.
systemctl --user stop "$TIMER" >/dev/null 2>&1 || true
systemctl --user clean --what=state "$TIMER" >/dev/null 2>&1 || true
systemctl --user enable "$TIMER" >/dev/null 2>&1
# restart recomputes the next run from the (possibly changed) schedule.
systemctl --user restart "$TIMER"
systemctl --user is-active --quiet "$TIMER" || error 'Timer failed to start; see: systemctl --user status claude-ping.timer'

# ── Test the scheduled path once (same unit, environment file and script the timer uses) ────
if (( TEST )); then
 msg 'Running the service once the way the timer will'
 if systemctl --user start "$SERVICE"; then
  msg 'Service run OK'
 else
  sleep 1
  LAST=$(journalctl --user -u "$SERVICE" -n 4 --no-pager -o cat 2>/dev/null | tr '\n' ' ' || true)
  warn "Service run failed: $LAST"
  case "$(classify 1 "$LAST")" in
   limit) guide_limit;;
   auth) guide_auth;;
   region) guide_region;;
   network|timeout) guide_net;;
   *) guide_other;;
  esac
  error 'The scheduled service does not work yet'
 fi
 journalctl --user -u "$SERVICE" -n 2 --no-pager -o cat 2>/dev/null || true
fi

# ── Summary ─────────────────────────────────────────────────────────────────────────────────
echo
systemctl --user list-timers "$TIMER" --no-pager || true
echo
msg 'Done.'
msg "Schedule: $TIMES ($TZNAME), model $MODEL"
msg 'Status and recent runs:   bash setup_claude.sh --status'
msg 'Replace the token:        bash setup_claude.sh --reset-token'
msg 'Change the schedule:      bash setup_claude.sh --times 08:00,13:00 --tz Asia/Seoul'
msg 'Remove:                   bash setup_claude.sh --uninstall'
msg "Install log (no secrets): $LOG"
msg 'If another scheduler (e.g. a claude.ai scheduled task) sends the same ping, turn it off to avoid duplicates.'
