#!/usr/bin/env bash
# Runs ON the GPU VM.  Idempotent: safe to re-run.
# Usage: bootstrap.sh <PUBLIC_IP> <ISAAC_SIM_VERSION> <physx|newton>
set -euo pipefail

PUBLIC_IP="${1:?public ip required}"
VERSION="${2:-6.0.1}"
BACKEND="${3:-physx}"
IMAGE="nvcr.io/nvidia/isaac-sim:${VERSION}"

HOME_DIR="$HOME"
DATA_DIR="$HOME_DIR/docker/isaac-sim"          # must be absolute: compose does not expand ~
WORKSPACE="$HOME_DIR/isaac-workspace"          # your .usd + .py land here -> /workspace in container
REPO="$HOME_DIR/IsaacSim"
OVERRIDE="$HOME_DIR/compose.override.yml"

log() { printf '\033[1;36m==>\033[0m %s\n' "$*"; }

# ---------------------------------------------------------------- 1. packages
if ! command -v docker >/dev/null; then
  log "installing docker"
  sudo apt-get update -qq
  sudo apt-get install -y -qq ca-certificates curl gnupg git rsync tcpdump jq
  curl -fsSL https://get.docker.com | sudo sh
fi
# Outside the block on purpose: the Nebius CUDA images already ship docker, so
# an install-time-only usermod never runs and every docker command needs sudo
# (and third-party tools that shell out to `docker` fail with
# "permission denied ... /var/run/docker.sock"). Takes effect at next login.
sudo usermod -aG docker "$USER" || true
sudo apt-get install -y -qq git rsync tcpdump jq >/dev/null

if ! sudo docker compose version >/dev/null 2>&1; then
  log "installing docker compose v2 plugin"
  sudo apt-get install -y -qq docker-compose-plugin
fi

if ! command -v nvidia-ctk >/dev/null; then
  log "installing NVIDIA Container Toolkit"
  curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
    | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
  curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
    | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
    | sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list >/dev/null
  sudo apt-get update -qq
  sudo apt-get install -y -qq nvidia-container-toolkit
  sudo nvidia-ctk runtime configure --runtime=docker
  sudo systemctl restart docker
fi

nvidia-smi -L || { echo "no GPU visible — wrong image or driver missing"; exit 1; }

# ---------------------------------------------------------------- 1b. Vulkan userspace
# Nebius's ubuntu24.04-cuda* images ship a COMPUTE-ONLY driver: CUDA and
# nvidia-smi work, but there is no libGLX_nvidia, no libnvidia-rtcore, no
# libnvoptix and no Vulkan ICD. Isaac Sim's RTX renderer then dies with
#   vkCreateInstance failed / ERROR_INCOMPATIBLE_DRIVER
#   Failed to create any GPU devices
# never creates a viewport, never starts the livestream server, and hangs
# forever in await_viewport -- while the compose healthcheck cheerfully reports
# "healthy" because it greps the log for AppReady and matches the unrelated
# line "kEventAppReady event was delayed by:". Symptom you would actually see:
# tcp/49100 never opens and check-stream.sh blames the firewall.
#
# apt cannot fix this: Nebius pins every libnvidia-gl-* / EGL package to
# Pin-Priority: -1, and the Ubuntu-origin package needs a virtual dep only
# Ubuntu's own driver stack provides, so satisfying it means swapping the whole
# driver userspace on a running GPU host. Instead we install just the userspace
# half of the EXACT matching driver version from NVIDIA's .run installer:
# --no-kernel-modules leaves the running kernel module and dpkg's compute
# packages untouched, and --no-check-for-alternate-installs is required because
# Nebius marks /usr/lib/nvidia/alternate-install-present.
if [ ! -f /etc/vulkan/icd.d/nvidia_icd.json ]; then
  DRV="$(nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -1 | tr -d '[:space:]')"
  log "compute-only driver detected; installing graphics/Vulkan userspace $DRV"
  curl -fsSL -o /tmp/nv.run "https://us.download.nvidia.com/tesla/${DRV}/NVIDIA-Linux-x86_64-${DRV}.run" \
    || curl -fsSL -o /tmp/nv.run "https://us.download.nvidia.com/XFree86/Linux-x86_64/${DRV}/NVIDIA-Linux-x86_64-${DRV}.run"
  sudo sh /tmp/nv.run --silent --no-kernel-modules --no-dkms --no-nvidia-modprobe \
       --no-check-for-alternate-installs
  # libGLU.so.1 is needed by the MDL/Neuray material plugin used when rendering.
  sudo apt-get install -y -qq libglu1-mesa || true
  if [ -f /etc/vulkan/icd.d/nvidia_icd.json ]; then
    log "Vulkan ICD installed"
  else
    echo "Vulkan userspace install failed — streaming will not work"; exit 1
  fi
  nvidia-smi -L >/dev/null || { echo "driver broken after userspace install"; exit 1; }
else
  log "Vulkan ICD already present"
fi

# ---------------------------------------------------------------- 2. host firewall
if command -v ufw >/dev/null && sudo ufw status | grep -q "Status: active"; then
  log "opening host firewall ports"
  sudo ufw allow 8210/tcp  comment 'Isaac web viewer'  || true
  sudo ufw allow 49100/tcp comment 'Isaac WebRTC signal' || true
  sudo ufw allow 47998/udp comment 'Isaac WebRTC media'  || true
fi

# ---------------------------------------------------------------- 3. dirs
log "preparing data dirs (uid 1234 = container user)"
mkdir -p "$DATA_DIR"/{cache/main,cache/computecache,config,data,logs,pkg} "$HOME_DIR/.cache/ov/hub" "$WORKSPACE"
sudo chown -R 1234:1234 "$DATA_DIR" "$HOME_DIR/.cache/ov/hub" "$WORKSPACE"

# ---------------------------------------------------------------- 4. repo (for docker-compose.yml + web-viewer)
if [ ! -d "$REPO/.git" ]; then
  log "cloning IsaacSim repo (compose file + web viewer source)"
  git clone --depth 1 -b "v${VERSION}" https://github.com/isaac-sim/IsaacSim.git "$REPO" 2>/dev/null \
    || git clone --depth 1 https://github.com/isaac-sim/IsaacSim.git "$REPO"
fi

# ---------------------------------------------------------------- 5. image
log "pulling $IMAGE  (~20 GB, 8-15 min on first run)"
sudo docker pull "$IMAGE"

# ---------------------------------------------------------------- 6. compose override
# Mount the workspace, and (optionally) switch the physics backend to Newton.
# The Newton override appends kit flags to whatever the image's own entrypoint is,
# so we inspect the image instead of guessing its launch command.
ENTRYPOINT_JSON="$(sudo docker inspect --format '{{json .Config.Entrypoint}}' "$IMAGE")"
CMD_JSON="$(sudo docker inspect --format '{{json .Config.Cmd}}' "$IMAGE")"
log "image entrypoint=$ENTRYPOINT_JSON cmd=$CMD_JSON"

NEWTON_FLAGS='"--enable","isaacsim.physics.newton","--enable","isaacsim.physics.newton.tensors","--enable","isaacsim.physics.newton.ui","--/exts/isaacsim.physics.newton/auto_switch_on_startup=true"'

{
  echo "# generated by bootstrap.sh — do not edit by hand"
  echo "services:"
  echo "  isaac-sim:"
  echo "    volumes:"
  echo "      - ${WORKSPACE}:/workspace:rw"
  if [ "$BACKEND" = "newton" ]; then
    if [ "$ENTRYPOINT_JSON" != "null" ] && [ "$ENTRYPOINT_JSON" != "[]" ]; then
      # entrypoint launches the app; command becomes extra kit args
      echo "    command: [${NEWTON_FLAGS}]"
    else
      # no entrypoint: the image CMD is the launcher — reuse it and append flags
      LAUNCHER="$(printf '%s' "$CMD_JSON" | jq -r '.[0] // "./runheadless.sh"')"
      echo "    command: [\"${LAUNCHER}\",${NEWTON_FLAGS}]"
    fi
  fi
} > "$OVERRIDE"

log "compose override:"; cat "$OVERRIDE"

# ---------------------------------------------------------------- 7. launch
cd "$REPO"
log "starting Isaac Sim ${VERSION} (backend=${BACKEND}) streaming on ${PUBLIC_IP}"
sudo ISAACSIM_HOST="$PUBLIC_IP" \
     ISAAC_SIM_IMAGE="$IMAGE" \
     ISAAC_SIM_DATA="$DATA_DIR" \
     docker compose -p isim \
       -f tools/docker/docker-compose.yml \
       -f "$OVERRIDE" up --build -d

# ---------------------------------------------------------------- 8. wait for ready
log "waiting for Isaac Sim to report AppReady (first boot: 3-6 min, shader cache warm-up)"
for i in $(seq 1 60); do
  state="$(sudo docker inspect --format '{{.State.Health.Status}}' isim-isaac-sim-1 2>/dev/null || echo starting)"
  [ "$state" = "healthy" ] && break
  sleep 15
done
sudo docker compose -p isim ps

echo
echo "  Web viewer : http://${PUBLIC_IP}:8210   (Chrome / Edge only, one tab at a time)"
echo "  Workspace  : ${WORKSPACE}  ->  /workspace inside the container"
echo "  Logs       : sudo docker compose -p isim logs -f isaac-sim"
