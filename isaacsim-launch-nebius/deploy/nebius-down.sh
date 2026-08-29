#!/usr/bin/env bash
# Deletes the VM (billing stops).  Pass --all to also delete the security group.
. "$(dirname "$0")/common.sh"
load_state
[ "${PROVIDER:-}" = "nebius" ] || die "state file is not a Nebius deployment"
log "deleting instance $VM_ID"
nebius compute instance delete --id "$VM_ID"
if [ "${1:-}" = "--all" ] && [ -n "${SG_ID:-}" ]; then
  log "deleting security group $SG_ID"; nebius vpc security-group delete --id "$SG_ID" || true
fi
rm -f "$STATE_FILE"
log "gone"
