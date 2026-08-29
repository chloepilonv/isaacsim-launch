#!/usr/bin/env bash
# Nebius: security group (incl. UDP 47998) -> L40S VM -> bootstrap -> streaming URL.
. "$(dirname "$0")/common.sh"

need nebius "https://docs.nebius.com/cli/install"
need jq     "brew install jq"
[ -f "$SSH_PUB" ] || die "no ssh public key at $SSH_PUB (ssh-keygen -t ed25519)"
resolve_cidr

# ---------------------------------------------------------------- project / network
PROJECT_ID="${NEBIUS_PROJECT_ID:-}"
if [ -z "$PROJECT_ID" ]; then
  PROJECT_ID="$(awk '/parent-id:/{print $2; exit}' "$HOME/.nebius/config.yaml" 2>/dev/null || true)"
fi
[ -n "$PROJECT_ID" ] || die "could not resolve NEBIUS_PROJECT_ID — set it in .env (nebius iam project list --parent-id <tenant-id>)"
log "project: $PROJECT_ID"

# fail early on a platform/preset that does not exist in this project's region
if ! nebius compute platform list --parent-id "$PROJECT_ID" --format json \
     | jq -e --arg p "$NEBIUS_PLATFORM" --arg r "$NEBIUS_PRESET" \
       '.items[] | select(.metadata.name==$p) | .spec.presets[] | select(.name==$r)' >/dev/null; then
  warn "$NEBIUS_PLATFORM / $NEBIUS_PRESET is not offered in this project. Available GPU options:"
  nebius compute platform list --parent-id "$PROJECT_ID" --format json \
    | jq -r '.items[] | select(.metadata.name|startswith("gpu")) | "  " + .metadata.name + ": " + ([.spec.presets[].name]|join(", "))'
  die "fix NEBIUS_PLATFORM / NEBIUS_PRESET in .env"
fi

NETWORK_ID="$(nebius vpc network list --parent-id "$PROJECT_ID" --format json | jq -r '.items[0].metadata.id')"
SUBNET_ID="${NEBIUS_SUBNET_ID:-$(nebius vpc subnet list --parent-id "$PROJECT_ID" --format json | jq -r '.items[0].metadata.id')}"
[ -n "$SUBNET_ID" ] && [ "$SUBNET_ID" != "null" ] || die "could not resolve a subnet — set NEBIUS_SUBNET_ID in .env"
log "network: $NETWORK_ID   subnet: $SUBNET_ID"

# ---------------------------------------------------------------- security group
SG_NAME="${INSTANCE_NAME}-stream-sg"
SG_ID="$(nebius vpc security-group list --parent-id "$PROJECT_ID" --format json \
        | jq -r --arg n "$SG_NAME" '.items[]? | select(.metadata.name==$n) | .metadata.id' | head -1)"

if [ -z "$SG_ID" ]; then
  log "creating security group $SG_NAME"
  SG_ID="$(nebius vpc security-group create --parent-id "$PROJECT_ID" --name "$SG_NAME" \
            --network-id "$NETWORK_ID" --format json | jq -r '.metadata.id')"

  rule() { # rule <name> <tcp|udp> <port> <priority>
    log "  ingress $2/$3 from $ALLOW_CIDR"
    nebius vpc security-rule create --parent-id "$SG_ID" --name "$1" \
      --access allow --type stateful --priority "$4" --protocol "$2" \
      --ingress-source-cidrs "$ALLOW_CIDR" --ingress-destination-ports "$3" >/dev/null
  }
  rule ssh          tcp 22     100
  rule web-viewer   tcp 8210   110
  rule webrtc-sig   tcp 49100  120
  rule webrtc-media udp 47998  130   # <-- the one every TCP-only cloud gets wrong

  log "  egress allow-all"
  nebius vpc security-rule create --parent-id "$SG_ID" --name egress-all \
    --access allow --type stateful --priority 200 --protocol any \
    --egress-destination-cidrs "0.0.0.0/0" >/dev/null
else
  log "reusing security group $SG_ID"
fi

# ---------------------------------------------------------------- cloud-init
USER_DATA="$(cat <<CI
#cloud-config
users:
  - name: ubuntu
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    ssh_authorized_keys:
      - $(cat "$SSH_PUB")
CI
)"

# ---------------------------------------------------------------- VM
NIC_WITH_SG=$(jq -nc --arg s "$SUBNET_ID" --arg g "$SG_ID" \
  '[{name:"eth0",subnet_id:$s,ip_address:{},public_ip_address:{},security_groups:[{id:$g}]}]')
NIC_PLAIN=$(jq -nc --arg s "$SUBNET_ID" \
  '[{name:"eth0",subnet_id:$s,ip_address:{},public_ip_address:{}}]')

create_vm() { # $1 = network-interfaces json
  nebius compute instance create \
    --parent-id "$PROJECT_ID" \
    --name "$INSTANCE_NAME" \
    --resources-platform "$NEBIUS_PLATFORM" \
    --resources-preset "$NEBIUS_PRESET" \
    --boot-disk-managed-disk-name "${INSTANCE_NAME}-boot" \
    --boot-disk-managed-disk-type network_ssd \
    --boot-disk-managed-disk-size-gibibytes "$NEBIUS_DISK_GIB" \
    --boot-disk-managed-disk-source-image-family-image-family "$NEBIUS_IMAGE_FAMILY" \
    --boot-disk-attach-mode READ_WRITE \
    --cloud-init-user-data "$USER_DATA" \
    --network-interfaces "$1" \
    --format json
}

log "creating $NEBIUS_PLATFORM / $NEBIUS_PRESET VM"
VM_ERR="$(mktemp)"
if ! VM_JSON="$(create_vm "$NIC_WITH_SG" 2>"$VM_ERR")"; then
  warn "creating with the security group attached failed:"; tail -5 "$VM_ERR"
  warn "retrying without it — you must then attach $SG_ID to the VM in the Nebius console"
  VM_JSON="$(create_vm "$NIC_PLAIN")"
fi
VM_ID="$(printf '%s' "$VM_JSON" | jq -r '.metadata.id')"
log "vm: $VM_ID"

log "waiting for a public IP"
HOST=""
for _ in $(seq 1 40); do
  HOST="$(nebius compute instance get --id "$VM_ID" --format json \
          | jq -r '.status.network_interfaces[0].public_ip_address.address // empty' | cut -d/ -f1)"
  [ -n "$HOST" ] && break
  sleep 10
done
[ -n "$HOST" ] || die "VM never got a public IP"
log "public IP: $HOST"

SSH_TARGET="ubuntu@$HOST"
save_state "PROVIDER=nebius" "HOST=$HOST" "SSH_TARGET=$SSH_TARGET" "VM_ID=$VM_ID" "SG_ID=$SG_ID" "PROJECT_ID=$PROJECT_ID"
wait_for_ssh "$SSH_TARGET"

# ---------------------------------------------------------------- ship + boot
log "uploading bootstrap + workspace"
rsync -az -e "ssh ${SSH_OPTS[*]}" "$ROOT/deploy/remote/" "$SSH_TARGET:~/remote/"
ssh "${SSH_OPTS[@]}" "$SSH_TARGET" "chmod +x ~/remote/*.sh"
"$ROOT/deploy/sync.sh" || true

ssh "${SSH_OPTS[@]}" -t "$SSH_TARGET" "~/remote/bootstrap.sh '$HOST' '$ISAAC_SIM_VERSION' '$PHYSICS_BACKEND'"

echo
log "verifying the ports really are open"
"$ROOT/deploy/check-stream.sh" || true
echo
log "done.  Stop billing with: deploy/nebius-down.sh"
