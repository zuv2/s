#!/usr/bin/env bash
# PocketRisu Ubuntu 24.04/24.10 Docker installer (amd64/arm64)
# Download first, inspect, then execute. Do not pipe directly into bash.
set -Eeuo pipefail
umask 077

DIR="$HOME/pocketrisu"; PORT=6001; TAG=latest; IP=""; EMAIL=""; HTTPS=1; START=1; ALLOW=""; ALLOW_SET=0
IMAGE=ghcr.io/pocketrisu/pocketrisu
BR=pocketrisu0
FW=/usr/local/sbin/pocketrisu-firewall
ALLOW_FILE=/etc/pocketrisu/allow-from
HOOK=/etc/letsencrypt/renewal-hooks/deploy/pocketrisu-deploy
error() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
msg() { printf '[PocketRisu] %s\n' "$*"; }
usage() { cat <<'USAGE'
Usage: ./install.sh [options]
  --dir PATH          Installation directory (default: ~/pocketrisu)
  --port N            Public service port (default: 6001)
  --tag TAG           Container image tag (default: latest)
  --ip IPv4           Public IPv4 for Let's Encrypt IP certificate
  --email ADDRESS     Let's Encrypt contact email (optional)
  --allow-from CIDRS  Comma-separated IPv4/CIDR allowlist (default: unrestricted)
  --no-https          Explicitly allow plain HTTP
  --no-start          Prepare without starting or stopping existing service
  -h, --help          Show help
Re-running without --allow-from preserves an existing allowlist.
USAGE
}
while (($#)); do
 case "$1" in
  --dir|--port|--tag|--ip|--email|--allow-from)
    (($# >= 2)) && [[ -n "$2" ]] || error "$1 requires a value"
    case "$1" in
      --dir) DIR=$2;; --port) PORT=$2;; --tag) TAG=$2;; --ip) IP=$2;;
      --email) EMAIL=$2;; --allow-from) ALLOW=$2; ALLOW_SET=1;;
    esac; shift 2;;
  --no-https) HTTPS=0; shift;; --no-start) START=0; shift;;
  -h|--help) usage; exit 0;; *) error "Unknown option: $1";;
 esac
done
(( EUID != 0 )) || error 'Run as a regular sudo-enabled user, not root.'
command -v sudo >/dev/null || error 'sudo is required'
source /etc/os-release
[[ "$ID" == ubuntu && "$VERSION_ID" == 24.* ]] || error 'Only Ubuntu 24.x is supported'
case "$(dpkg --print-architecture)" in amd64|arm64) ;; *) error 'Only amd64 and arm64 are supported';; esac
[[ "$PORT" =~ ^[0-9]{1,5}$ ]] && ((10#$PORT >= 1 && 10#$PORT <= 65535)) || error 'Invalid port'
PORT=$((10#$PORT))
(( HTTPS == 0 || PORT != 80 )) || error 'Port 80 is reserved for certificate issuance'
[[ "$TAG" =~ ^[a-zA-Z0-9_][a-zA-Z0-9_.-]*$ ]] || error 'Invalid image tag'
[[ "$TAG" =~ ^[0-9]+(\.[0-9]+)*$ ]] && TAG="v$TAG"
[[ -z "$EMAIL" || "$EMAIL" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]] || error 'Invalid email'
DIR=$(realpath -m -- "$DIR")
case "$DIR" in /|/root|/home|/etc|/etc/*|/usr|/usr/*|/var|/var/*|/proc|/proc/*|/sys|/sys/*|/dev|/dev/*|/boot|/boot/*) error 'Unsafe install directory';; esac
[[ "$DIR" != *$'\n'* && "$DIR" != *$'\r'* ]] || error 'No newlines allowed in install path'
# To safely embed the path into root-owned shell code, disallow complex pathname characters.
[[ "$DIR" =~ ^/[A-Za-z0-9_./-]+$ ]] || error 'Install path may contain only letters, numbers, _ . / -'
valid_ip() { python3 - "$1" "$2" <<'PY'
import ipaddress,sys
try:
 a = ipaddress.ip_network(sys.argv[1],strict=False) if sys.argv[2]=='cidr' else ipaddress.ip_address(sys.argv[1])
 assert a.version==4
 if sys.argv[2]=='public': assert a.is_global
except (ValueError,AssertionError): sys.exit(1)
PY
}
[[ -z "$IP" ]] || valid_ip "$IP" public || error 'Invalid or non-public --ip address'
parse_allow() {
 local input=$1 c
 local -a entries=()
 IFS=',' read -r -a entries <<< "$input"
 ((${#entries[@]})) || error 'Empty allowlist'
 for c in "${entries[@]}"; do
  c="${c//[[:space:]]/}"
  [[ -n "$c" ]] || error 'Empty CIDR entry'
  valid_ip "$c" cidr || error "Invalid CIDR: $c"
  [[ "$c" == */* ]] || c="$c/32"
  printf '%s\n' "$c"
 done
}
# apt python3 is present on normal Ubuntu 24.04; validate before touching system.
command -v python3 >/dev/null || error 'python3 is required (standard on Ubuntu 24.04)'
if (( ALLOW_SET )); then ALLOW_CONTENT=$(parse_allow "$ALLOW"); fi
sudo -v || error 'sudo authentication failed'
LOG="$HOME/pocketrisu-install-$(date +%Y%m%d-%H%M%S).log"
: > "$LOG"; chmod 600 "$LOG"
exec > >(tee -a "$LOG") 2>&1
trap 'printf "ERROR at line %s; log: %s\n" "$LINENO" "$LOG" >&2' ERR
msg "Preparing $DIR with $IMAGE:$TAG (port $PORT)"
APT=(-y -o DPkg::Lock::Timeout=300)
sudo apt-get update -o DPkg::Lock::Timeout=300
sudo env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt-get install "${APT[@]}" ca-certificates curl gnupg iptables iproute2 openssl python3 tar gzip
# Never uninstall or migrate an existing Docker installation automatically.
if command -v docker >/dev/null 2>&1 && sudo docker compose version >/dev/null 2>&1; then
 msg 'Using existing Docker + Compose'
else
 if command -v docker >/dev/null 2>&1 || dpkg -s docker.io containerd podman-docker 2>/dev/null | grep -q '^Status: install ok installed'; then
  error 'Existing or incomplete Docker installation detected; resolve manually before installing'
 fi
 msg 'Installing Docker Engine from official Docker repository'
 sudo install -m 0755 -d /etc/apt/keyrings
 sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
 sudo chmod a+r /etc/apt/keyrings/docker.asc
 printf 'Types: deb\nURIs: https://download.docker.com/linux/ubuntu\nSuites: %s\nComponents: stable\nArchitectures: %s\nSigned-By: /etc/apt/keyrings/docker.asc\n' "${UBUNTU_CODENAME:-noble}" "$(dpkg --print-architecture)" | sudo tee /etc/apt/sources.list.d/docker.sources >/dev/null
 sudo apt-get update -o DPkg::Lock::Timeout=300
 sudo env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt-get install "${APT[@]}" docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
fi
sudo systemctl enable --now docker
sudo docker info >/dev/null
sudo docker compose version >/dev/null
# Explicitly reject native Docker nftables backend; DOCKER-USER is iptables-specific.
if sudo docker info --format '{{json .FirewallBackend}}' 2>/dev/null | grep -qi 'nftables'; then
 error 'Docker nftables backend is not supported by this installer'
fi
sudo iptables -S DOCKER-USER >/dev/null 2>&1 || error 'Docker DOCKER-USER iptables chain unavailable'
# No docker-group membership: membership is equivalent to root authority.
mkdir -p -- "$DIR/save"; chmod 700 -- "$DIR/save"
sudo install -d -o root -g root -m 700 -- "$DIR/certs"
sudo install -d -m 700 /etc/pocketrisu
if (( ALLOW_SET )); then
 printf '%s\n' "$ALLOW_CONTENT" | sudo install -m 600 /dev/stdin "$ALLOW_FILE"
elif ! sudo test -e "$ALLOW_FILE"; then
 printf '# IPv4 or CIDR, one per line; empty = allow all\n' | sudo install -m 600 /dev/stdin "$ALLOW_FILE"
fi
# Check existing allowlist contents before writing a firewall policy.
while IFS= read -r c || [[ -n "$c" ]]; do
 [[ -z "$c" || "$c" =~ ^[[:space:]]*# ]] && continue
 [[ "$c" != *[[:space:]]* ]] || error 'Allowlist must contain only one CIDR per line'
 valid_ip "$c" cidr || error "Invalid entry in $ALLOW_FILE: $c"
done < <(sudo cat "$ALLOW_FILE")
# Publish only after firewall is operational. Firewall chain is kept on restart.
# A terminal DROP rule is appended before any allow rules so a mid-update failure fails closed.
sudo tee "$FW" >/dev/null <<'FIREWALL'
#!/usr/bin/env bash
set -Eeuo pipefail
PORT=$(cat /etc/pocketrisu/port)
HTTPS=$(cat /etc/pocketrisu/https)
BR=pocketrisu0
C=POCKETRISU
ALLOW=/etc/pocketrisu/allow-from
iptables -w -S DOCKER-USER >/dev/null
# Certbot standalone requires external TCP 80 even on future renewals/reboots.
if [[ "$HTTPS" == 1 ]]; then
 iptables -w -C INPUT -p tcp --dport 80 -m comment --comment pocketrisu-certbot -j ACCEPT 2>/dev/null ||
  iptables -w -I INPUT 1 -p tcp --dport 80 -m comment --comment pocketrisu-certbot -j ACCEPT
 if command -v ufw >/dev/null 2>&1 && ufw status | grep -q '^Status: active'; then
  ufw allow 80/tcp >/dev/null
 fi
else
 iptables -w -D INPUT -p tcp --dport 80 -m comment --comment pocketrisu-certbot -j ACCEPT 2>/dev/null || true
fi
iptables -w -N "$C" 2>/dev/null || true
# First insert a fail-closed guard in DOCKER-USER while changing the target chain.
iptables -w -I DOCKER-USER 1 -o "$BR" -p tcp -m conntrack --ctstate NEW --ctorigdstport "$PORT" -j DROP
iptables -w -F "$C"
# Ensure metadata service is inaccessible to containers on this bridge.
iptables -w -A "$C" -i "$BR" -d 169.254.169.254/32 -j DROP
while IFS= read -r c || [[ -n "$c" ]]; do
 [[ -z "$c" || "$c" =~ ^[[:space:]]*# ]] && continue
 iptables -w -A "$C" -o "$BR" -p tcp -s "$c" -m conntrack --ctstate NEW --ctorigdstport "$PORT" -j RETURN
done < "$ALLOW"
# An empty allowlist explicitly permits everyone on the configured port.
if ! grep -qE '^[[:space:]]*[^#[:space:]]' "$ALLOW"; then
 iptables -w -A "$C" -o "$BR" -p tcp -m conntrack --ctstate NEW --ctorigdstport "$PORT" -j RETURN
fi
iptables -w -A "$C" -o "$BR" -p tcp -m conntrack --ctstate NEW --ctorigdstport "$PORT" -j DROP
iptables -w -C DOCKER-USER -j "$C" 2>/dev/null || iptables -w -I DOCKER-USER 1 -j "$C"
# Remove the guard added at the start, leaving the validated target chain linked.
iptables -w -D DOCKER-USER -o "$BR" -p tcp -m conntrack --ctstate NEW --ctorigdstport "$PORT" -j DROP
FIREWALL
sudo chmod 755 "$FW"
# Port and allowlist are root-owned, and only reset after a new policy can be applied.
# Prevent accidental concurrent use of a single global POCKETRISU chain with a different install.
if sudo test -s /etc/pocketrisu/port && [[ "$(sudo cat /etc/pocketrisu/port)" != "$PORT" ]]; then
 error 'Port changed: existing firewall configuration uses another port; manual migration required'
fi
printf '%s\n' "$PORT" | sudo install -m 600 /dev/stdin /etc/pocketrisu/port
printf '%s\n' "$HTTPS" | sudo install -m 600 /dev/stdin /etc/pocketrisu/https
sudo tee /etc/systemd/system/pocketrisu-firewall.service >/dev/null <<'UNIT'
[Unit]
Description=PocketRisu Docker firewall
Requires=docker.service
After=docker.service
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/pocketrisu-firewall
ExecReload=/usr/local/sbin/pocketrisu-firewall
[Install]
WantedBy=multi-user.target
UNIT
sudo systemctl daemon-reload
sudo systemctl enable pocketrisu-firewall.service
sudo systemctl restart pocketrisu-firewall.service || error 'Firewall setup failed: refusing to publish port'
sudo iptables -C DOCKER-USER -j POCKETRISU || error 'Firewall not linked'
# Keep existing compose untouched on --no-start; all generated operational files are otherwise replaced only when changed.
write_file() {
 local dest=$1 mode=$2 tmp
 tmp=$(mktemp)
 cat > "$tmp"
 if [[ -f "$dest" ]] && cmp -s "$tmp" "$dest"; then rm -f "$tmp"; return; fi
 if [[ -e "$dest" ]]; then cp -p "$dest" "$dest.bak.$(date +%Y%m%d-%H%M%S%N)"; fi
 install -m "$mode" "$tmp" "$dest"; rm -f "$tmp"
}
# Inspect the image before installing TLS files. Docker bind mounts retain host POSIX
# permissions, so a non-root container must be granted access to the private key.
# Do not expose the key world-readable as a workaround.
sudo docker pull "$IMAGE:$TAG"
IMAGE_USER=$(sudo docker image inspect --format '{{.Config.User}}' "$IMAGE:$TAG")
CERT_UID=0
CERT_GID=0
if [[ -n "$IMAGE_USER" && "$IMAGE_USER" != 0 && "$IMAGE_USER" != 0:0 ]]; then
 case "$IMAGE_USER" in
  *:*) CERT_UID=${IMAGE_USER%%:*}; CERT_GID=${IMAGE_USER#*:} ;;
  *) CERT_UID=$IMAGE_USER; CERT_GID=$IMAGE_USER ;;
 esac
 [[ "$CERT_UID" =~ ^[0-9]+$ && "$CERT_GID" =~ ^[0-9]+$ ]] ||
  error "Image USER '$IMAGE_USER' is not numeric; cannot safely assign certificate key ownership. Inspect the image and adjust the installer."
fi
# Explicit group permissions allow a non-root workload to read its TLS key without
# granting any permissions to unrelated host or container users.
sudo chown root:"$CERT_GID" "$DIR/certs"
sudo chmod 750 "$DIR/certs"
# Certificate acquisition precedes generating the HTTP/HTTPS compose file. Never fall back to HTTP implicitly.
if (( HTTPS )); then
 if [[ -z "$IP" ]]; then
  IP=$(curl -4fsS --max-time 8 https://api.ipify.org || true)
 fi
 valid_ip "$IP" public || error 'Could not detect public IPv4; specify --ip or explicitly choose --no-https'
 msg "Acquiring/using HTTPS IP certificate for $IP"
 if ! command -v snap >/dev/null; then
  sudo env DEBIAN_FRONTEND=noninteractive apt-get install "${APT[@]}" snapd
 fi
 if ! sudo snap list certbot >/dev/null 2>&1; then sudo snap install certbot --classic; fi
 CERTBOT=/snap/bin/certbot
 [[ -x "$CERTBOT" ]] || error 'Certbot snap not available'
 "$CERTBOT" --help all 2>/dev/null | grep -- '--ip-address' >/dev/null || error 'Certbot version does not support IP address certificates'
 # Only the certificate for this install is deployed; avoids touching other Certbot lineages.
 sudo install -d -m 755 /etc/letsencrypt/renewal-hooks/deploy
 sudo tee "$HOOK" >/dev/null <<HOOKSCRIPT
#!/usr/bin/env bash
set -Eeuo pipefail
[[ "\${RENEWED_LINEAGE:-}" == "/etc/letsencrypt/live/$IP" ]] || exit 0
install -d -o root -g "$CERT_GID" -m 750 "$DIR/certs"
install -m 640 -o root -g "$CERT_GID" "\$RENEWED_LINEAGE/privkey.pem" "$DIR/certs/server.key"
install -m 644 "\$RENEWED_LINEAGE/fullchain.pem" "$DIR/certs/server.crt"
if [[ "\$(docker inspect -f '{{.State.Running}}' pocketrisu 2>/dev/null || true)" == true ]]; then
 docker restart pocketrisu
fi
HOOKSCRIPT
 sudo chmod 755 "$HOOK"
 LIVE="/etc/letsencrypt/live/$IP"
 if sudo test -s "$LIVE/fullchain.pem" && sudo test -s "$LIVE/privkey.pem" && sudo openssl x509 -in "$LIVE/fullchain.pem" -noout -checkend 86400 >/dev/null 2>&1; then
  msg 'Existing IP certificate found'
 else
  [[ -z "$(sudo ss -ltnH 'sport = :80')" ]] || error 'TCP 80 is in use; standalone certificate challenge cannot run'
  MAIL=(--register-unsafely-without-email)
  [[ -z "$EMAIL" ]] || MAIL=(--email "$EMAIL" --no-eff-email)
  sudo "$CERTBOT" certonly --standalone --preferred-profile shortlived --ip-address "$IP" --cert-name "$IP" --non-interactive --agree-tos "${MAIL[@]}" || error 'HTTPS certificate issuance failed; refusing HTTP fallback'
 fi
 sudo env RENEWED_LINEAGE="$LIVE" "$HOOK"
 sudo test -s "$DIR/certs/server.key" && sudo test -s "$DIR/certs/server.crt" || error 'Certificate deployment failed'
 # Renew hook applies to future renewals even when certificate was already present.
 if ! systemctl list-timers --all --no-legend | grep -q 'snap.certbot.renew'; then
  error 'Certbot auto-renewal timer not found; refusing unattended short-lived certificate use'
 fi
else
 # Clear only generated certificate deployment hook for this directory, do not delete existing certs.
 msg 'Explicit HTTP mode requested; certificate will not be mounted'
 if sudo test -f "$HOOK" && sudo grep -qF "$DIR/certs" "$HOOK"; then sudo rm -f "$HOOK"; fi
fi
# Prevent takeover of an uninitialized public deployment. Existing password is never reset.
PWFILE="$DIR/save/__password"
if [[ ! -s "$PWFILE" ]] && ! sudo test -s "$PWFILE"; then
 [[ -t 0 ]] || error 'No password set and no interactive terminal; run interactively to set one'
 read -rsp 'Set PocketRisu admin password (12+ characters): ' PW1; printf '\n'
 read -rsp 'Repeat password: ' PW2; printf '\n'
 [[ "$PW1" == "$PW2" && ${#PW1} -ge 12 ]] || error 'Passwords do not match or are shorter than 12 characters'
 HASH=$(printf '%s' "$PW1" | sha256sum | cut -d' ' -f1)
 unset PW1 PW2
 printf '%s' "$HASH" | sudo install -m 600 /dev/stdin "$PWFILE"
 sudo chown "$(id -u):$(id -g)" "$PWFILE"
fi
# Avoid unexpectedly replacing a different Compose project's settings.
if [[ -f "$DIR/docker-compose.yml" ]] && ! grep -q '^name: pocketrisu$' "$DIR/docker-compose.yml"; then
 error 'Existing Compose file was not generated by this installer; back up/migrate manually'
fi
if (( HTTPS )); then CERT_MOUNT='      - ./certs:/app/server/node/ssl/certificate:ro'; else CERT_MOUNT=''; fi
# Always generate a reviewable Compose file. No automatic destructive compose down.
write_file "$DIR/docker-compose.yml" 644 <<COMPOSE
name: pocketrisu
services:
  pocketrisu:
    container_name: pocketrisu
    image: $IMAGE:$TAG
    restart: unless-stopped
    ports:
      - "0.0.0.0:$PORT:6001"
    volumes:
      - ./save:/app/save
$CERT_MOUNT
    security_opt:
      - no-new-privileges:true
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
networks:
  default:
    driver_opts:
      com.docker.network.bridge.name: $BR
COMPOSE
# The generated helper always runs docker via sudo and never changes docker group.
write_file "$DIR/run.sh" 755 <<'RUN'
#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$(realpath "$0")")"
[[ -s save/__password ]] || sudo test -s save/__password || { echo 'Set an admin password before starting' >&2; exit 1; }
sudo systemctl restart pocketrisu-firewall.service
sudo docker compose up -d "$@"
sudo docker compose ps
RUN
write_file "$DIR/stop.sh" 755 <<'STOP'
#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$(realpath "$0")")"
sudo docker compose stop -t 30
STOP
write_file "$DIR/update.sh" 755 <<'UPDATE'
#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$(realpath "$0")")"
sudo docker compose pull
./run.sh
UPDATE
write_file "$DIR/password.sh" 700 <<'PASSWORD'
#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$(realpath "$0")")"
[[ -t 0 ]] || { echo 'Interactive terminal required' >&2; exit 1; }
read -rsp 'New password (12+ characters): ' p1; echo
read -rsp 'Repeat: ' p2; echo
[[ "$p1" == "$p2" && ${#p1} -ge 12 ]] || { echo 'Password mismatch/too short' >&2; exit 1; }
printf '%s' "$p1" | sha256sum | cut -d' ' -f1 | tr -d '\n' | sudo install -m 600 /dev/stdin save/__password
sudo chown "$(id -u):$(id -g)" save/__password
unset p1 p2
if [[ "$(sudo docker inspect -f '{{.State.Running}}' pocketrisu 2>/dev/null || true)" == true ]]; then sudo docker restart pocketrisu; fi
PASSWORD
write_file "$DIR/backup.sh" 755 <<'BACKUP'
#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$(realpath "$0")")"
mkdir -p backups; chmod 700 backups
out="backups/save-$(date +%Y%m%d-%H%M%S).tgz"
echo 'WARNING: For application-consistent backup, stop the container first (./stop.sh).'
sudo tar -czf "$out" save
sudo chown "$(id -u):$(id -g)" "$out"
chmod 600 "$out"
tar -tzf "$out" >/dev/null
echo "Backup: $out"
BACKUP
( cd "$DIR" && sudo docker compose config --quiet ) || error 'Generated Compose configuration invalid'
msg "Compose ready: $DIR/docker-compose.yml"
if (( START )); then
 (cd "$DIR" && ./run.sh)
else
 msg '--no-start: existing container was not stopped or recreated'
fi
if (( HTTPS )); then URL="https://$IP:$PORT"; else URL="http://SERVER_IP:$PORT"; fi
msg "Done. URL: $URL"
msg "Directory: $DIR | log: $LOG"
msg 'Keep host TCP 80 unoccupied by nginx/apache/etc. for unattended Certbot standalone renewal.'
msg 'Cloud firewall/security group must allow your service port and TCP 80 for HTTPS renewal.'
msg 'Manage: run.sh, stop.sh, update.sh, password.sh, backup.sh'
