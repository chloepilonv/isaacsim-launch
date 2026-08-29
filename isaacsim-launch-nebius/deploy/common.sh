#!/usr/bin/env bash
# Shared config + helpers.  Sourced by every script in deploy/.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[ -d "$HOME/.nebius/bin" ] && PATH="$HOME/.nebius/bin:$PATH"
STATE_FILE="$ROOT/deploy/.state"

log()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "missing command: $1 ($2)"; }

# defaults, then .env overrides
INSTANCE_NAME=isaac-sim
ISAAC_SIM_VERSION=6.0.1
PHYSICS_BACKEND=physx
SSH_KEY=~/.ssh/id_ed25519
ALLOW_CIDR=auto
NEBIUS_PROJECT_ID=""   # blank = parent-id from ~/.nebius/config.yaml
NEBIUS_PLATFORM=gpu-rtx6000
NEBIUS_PRESET=1gpu-24vcpu-218gb
NEBIUS_DISK_GIB=512
NEBIUS_SUBNET_ID=""
NEBIUS_IMAGE_FAMILY=ubuntu24.04-cuda13.0

[ -f "$ROOT/.env" ] && . "$ROOT/.env"

SSH_KEY="${SSH_KEY/#\~/$HOME}"
SSH_PUB="${SSH_KEY}.pub"

WEB_PORT=8210
SIGNAL_PORT=49100
STREAM_PORT=47998

resolve_cidr() {
  if [ "$ALLOW_CIDR" = "auto" ]; then
    local ip; ip="$(curl -fsS --max-time 10 https://ifconfig.me)" || die "could not detect your public IP; set ALLOW_CIDR in .env"
    ALLOW_CIDR="${ip}/32"
  fi
  log "firewall will allow: $ALLOW_CIDR"
}

save_state() { printf '%s\n' "$@" > "$STATE_FILE"; }
load_state() { [ -f "$STATE_FILE" ] || die "no deploy/.state — run deploy/nebius-up.sh first"; . "$STATE_FILE"; }

wait_for_ssh() {  # $1 = ssh target
  log "waiting for SSH on $1 ..."
  for _ in $(seq 1 60); do
    ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=5 -o BatchMode=yes "$1" true 2>/dev/null && { log "SSH up"; return 0; }
    sleep 10
  done
  die "SSH never came up on $1"
}

SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR)
