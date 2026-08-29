#!/usr/bin/env bash
#
# Install Isaac Lab + Isaac Sim (pip) on the GPU VM, for RL training.
# Idempotent: safe to re-run; each step is skipped if already satisfied.
#
#   deploy/setup-isaaclab.sh          # ~15-25 min, mostly downloads
#
# ---------------------------------------------------------------------------
# WHAT THIS INSTALLS, AND WHY IT IS SEPARATE FROM THE STREAMING CONTAINER
# ---------------------------------------------------------------------------
# The VM ends up with TWO unrelated Isaac Sim installs:
#
#   1. Docker  nvcr.io/nvidia/isaac-sim:6.0.1   -> the WebRTC viewer on :8210
#   2. pip venv ~/rl/IsaacLab/env_isaaclab       -> Isaac Lab RL training (this)
#
# They share nothing but the GPU driver. Their versions do NOT need to match,
# and deliberately do not: Isaac Lab 3.0.0 pins Isaac Sim **6.0.0**, and 6.0.1
# breaks it (the PhysX tensors extension fails to resolve, so every task dies
# with "No module named 'omni.physics.tensors.impl'" while creating contact
# sensors). Matching the container's 6.0.1 here is a mistake -- do not "fix"
# the pin below to 6.0.1.
#
# ---------------------------------------------------------------------------
# PREREQUISITE
# ---------------------------------------------------------------------------
# The NVIDIA graphics/Vulkan userspace must be installed on the VM. Nebius's
# CUDA image ships a compute-only driver; headless training tolerates it, but
# rendering (rendering/video capture) does not. See the Vulkan
# section in README.md.
# ---------------------------------------------------------------------------
. "$(dirname "$0")/common.sh"
load_state

# Isaac Lab release. 3.0.0-beta is the first line that supports Isaac Sim 6.0.
ISAACLAB_REF="${ISAACLAB_REF:-v3.0.0-beta}"
# MUST stay 6.0.0 -- see the note above.
ISAACSIM_VERSION="${ISAACSIM_VERSION:-6.0.0}"
TORCH_VERSION="${TORCH_VERSION:-2.10.0}"
TORCHVISION_VERSION="${TORCHVISION_VERSION:-0.25.0}"
CUDA_WHEEL="${CUDA_WHEEL:-cu128}"

log "installing Isaac Lab $ISAACLAB_REF + Isaac Sim $ISAACSIM_VERSION on $HOST"

ssh "${SSH_OPTS[@]}" "$SSH_TARGET" "bash -s" <<EOS
set -euo pipefail
export PATH="\$HOME/.local/bin:\$PATH"

mkdir -p ~/rl && cd ~/rl

# --- 1. Isaac Lab source ---------------------------------------------------
# Shallow clone: we only need the working tree, not history.
if [ ! -d IsaacLab/.git ]; then
  echo '==> cloning IsaacLab $ISAACLAB_REF'
  git clone --depth 1 -b $ISAACLAB_REF https://github.com/isaac-sim/IsaacLab.git IsaacLab
else
  echo '==> IsaacLab already cloned'
fi
cd IsaacLab

# --- 2. uv -----------------------------------------------------------------
# Isaac Lab's docs use uv; it resolves this very large dependency tree far
# faster than pip, and we need its --index-strategy flag below.
if ! command -v uv >/dev/null; then
  echo '==> installing uv'
  curl -LsSf https://astral.sh/uv/install.sh | sh
fi
export PATH="\$HOME/.local/bin:\$PATH"

# --- 3. virtualenv ---------------------------------------------------------
# Must be named env_isaaclab and live at the repo root: ./isaaclab.sh looks for
# exactly \$ISAACLAB_PATH/env_isaaclab/bin/python.
# --seed installs pip inside it, which some Isaac Sim setup steps expect.
if [ ! -d env_isaaclab ]; then
  echo '==> creating venv (python 3.12)'
  uv venv --python 3.12 --seed env_isaaclab
fi
source env_isaaclab/bin/activate

# --- 4. Isaac Sim ----------------------------------------------------------
# --index-strategy unsafe-best-match is REQUIRED. Isaac Sim's dependency tree
# spans PyPI and pypi.nvidia.com; by default uv only considers the first index
# that publishes a given package (a dependency-confusion guard), which makes
# this resolve unsatisfiable on mujoco-usd-converter. The flag lets uv pick the
# best version across both indexes. Both are trusted here.
echo '==> installing isaacsim $ISAACSIM_VERSION (large download)'
uv pip install "isaacsim[all,extscache]==$ISAACSIM_VERSION" \
  --extra-index-url https://pypi.nvidia.com --index-strategy unsafe-best-match

# --- 5. PyTorch ------------------------------------------------------------
# Installed explicitly so we get the CUDA build; the isaacsim wheels alone can
# pull a CPU-only torch, which silently makes training ~100x slower.
echo '==> installing torch $TORCH_VERSION+$CUDA_WHEEL'
uv pip install -U torch==$TORCH_VERSION torchvision==$TORCHVISION_VERSION \
  --index-url https://download.pytorch.org/whl/$CUDA_WHEEL --index-strategy unsafe-best-match

# --- 6. Isaac Lab packages -------------------------------------------------
# Editable-installs isaaclab, isaaclab_tasks, isaaclab_rl, rsl_rl, etc.
# Editable matters: it is why dropping our task package into
# source/isaaclab_tasks/.../config/<your_task>/ is picked up with no reinstall.
echo '==> ./isaaclab.sh --install'
./isaaclab.sh --install

# --- 7. verify -------------------------------------------------------------
# OMNI_KIT_ACCEPT_EULA=YES or importing isaacsim blocks on an interactive
# prompt, which over a non-tty SSH pipe fails instantly with
# "Unable to bootstrap inner kit kernel: EOF when reading a line".
echo '==> verifying imports'
OMNI_KIT_ACCEPT_EULA=YES ./env_isaaclab/bin/python -c \
  "import torch, rsl_rl; print('torch', torch.__version__, 'cuda', torch.cuda.is_available())"
echo '==> SETUP OK'
EOS

log "done.  Next: ssh in and run ./isaaclab.sh -p scripts/reinforcement_learning/rsl_rl/train.py --task <Task> --headless"
