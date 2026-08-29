#!/usr/bin/env bash
# Push assets/ and scripts/ to the VM (-> /workspace in the container).
#   deploy/sync.sh            one-shot push
#   deploy/sync.sh --watch    push on every local change (needs fswatch: brew install fswatch)
#   deploy/sync.sh --down     pull the VM's workspace back into ./output
. "$(dirname "$0")/common.sh"
load_state

REMOTE_WS="isaac-workspace"

push() {
  # NOTE: --info=stats1 does not exist in rsync 2.6.9, which is what macOS
  # still ships. Use --stats, which works on both old and new rsync.
  rsync -az --delete --stats \
    -e "ssh ${SSH_OPTS[*]}" \
    "$ROOT/assets" "$ROOT/scripts" \
    "$SSH_TARGET:~/$REMOTE_WS/"
  # container runs as uid 1234 and must be able to read (and write outputs)
  ssh "${SSH_OPTS[@]}" "$SSH_TARGET" "sudo chown -R 1234:1234 ~/$REMOTE_WS"
  echo "synced -> $SSH_TARGET:~/$REMOTE_WS  (= /workspace in the container)"
}

case "${1:-}" in
  --down)
    mkdir -p "$ROOT/output"
    rsync -az -e "ssh ${SSH_OPTS[*]}" "$SSH_TARGET:~/$REMOTE_WS/" "$ROOT/output/"
    echo "pulled -> $ROOT/output" ;;
  --watch)
    need fswatch "brew install fswatch"
    push
    echo "watching assets/ scripts/ — Ctrl+C to stop"
    fswatch -o "$ROOT/assets" "$ROOT/scripts" | while read -r _; do push; done ;;
  *) push ;;
esac
