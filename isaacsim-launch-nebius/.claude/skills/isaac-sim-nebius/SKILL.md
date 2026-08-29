---
name: isaac-sim-nebius
description: 'Launch a Nebius GPU instance running Isaac Sim 6.0.1 with WebRTC streaming and Isaac Lab 3.0 ready for RL training. Prints the server IP and the three required ports. Use when asked to spin up / launch / provision an Isaac Sim, Isaac Lab, or humanoid-RL box on Nebius.'
license: MIT
metadata:
  tags: "isaac-sim, isaac-lab, nebius, gpu, webrtc, robotics, rl"
  category: "infrastructure"
---

# Launch Isaac Sim + Isaac Lab on Nebius

Provision a GPU VM on Nebius running **Isaac Sim 6.0.1** with WebRTC streaming
**and** **Isaac Lab 3.0** installed for RL training. Takes ~40 min, most of it
downloads.

## Required output

When finished, report exactly:

```
Server IP : <ip>
Web viewer: http://<ip>:8210      TCP   (Chrome/Edge only, one tab at a time)
Signaling : <ip>:49100            TCP
Media     : <ip>:47998            UDP   <-- no UDP, no video
```

Do not report success until **all three ports** are verified reachable AND the
kit log contains `Started primary stream server`. Container health is NOT proof
(see pitfall 2).

## Procedure

Run from the `isaacsim-launch-nebius/` directory (`deploy/nebius-up.sh`, `deploy/common.sh`,
`deploy/setup-isaaclab.sh`). Preconditions: `nebius` CLI
authenticated (`nebius init`, then `nebius profile list`), `jq`, an SSH key at `~/.ssh/id_ed25519`.

1. **`cp .env.example .env`** if absent. Defaults (`gpu-rtx6000`,
   `1gpu-24vcpu-218gb`, `ubuntu24.04-cuda13.0`) are correct. `ALLOW_CIDR=auto`
   pins your current public IPv4 as a `/32`.
2. **`deploy/nebius-up.sh`** (~15 min) — security group, VM, bootstrap, port check.
3. **`deploy/setup-isaaclab.sh`** (~20 min) — Isaac Lab + Isaac Sim pip.
   **Run it in parallel with step 2's image pull**: one is network/CPU-bound, the
   other GPU/disk-bound, saving ~15 min.
4. **Verify** both, then report the block above.

## Verification (do all four)

```bash
deploy/check-stream.sh                       # all three ports
ssh ubuntu@<ip> "sudo grep -h 'Started primary stream server' \
  ~/docker/isaac-sim/logs/Kit/*/*/kit_*.log | tail -1"
ssh ubuntu@<ip> "sudo grep -hc 'vkCreateInstance failed' \
  ~/docker/isaac-sim/logs/Kit/*/*/kit_*.log"      # must be 0
ssh ubuntu@<ip> "OMNI_KIT_ACCEPT_EULA=YES ~/rl/IsaacLab/env_isaaclab/bin/python \
  -c 'import torch;print(torch.__version__, torch.cuda.is_available())'"
```

Best end-to-end check for Isaac Lab is 3 training iterations, not an import:
`./isaaclab.sh -p scripts/reinforcement_learning/rsl_rl/train.py --task
Isaac-Velocity-Flat-G1-v0 --headless --num_envs 64 --max_iterations 3`

## Pitfalls that cost hours

1. **Nebius CUDA images ship a COMPUTE-ONLY driver.** No `libGLX_nvidia`, no
   Vulkan ICD. Isaac Sim's RTX renderer fails `vkCreateInstance`, never makes a
   viewport, never starts the livestream server, and hangs in `await_viewport`
   forever. `deploy/remote/bootstrap.sh` now installs the userspace half of the
   matching driver automatically:
   `sh NVIDIA-<ver>.run --silent --no-kernel-modules --no-dkms
   --no-nvidia-modprobe --no-check-for-alternate-installs`
   `<ver>` must equal `nvidia-smi --query-gpu=driver_version`. **apt cannot do
   this** — Nebius pins every `libnvidia-gl-*` to `Pin-Priority: -1`.
2. **The container healthcheck lies.** It greps the log for `AppReady` and
   false-matches `kEventAppReady event was delayed by:`, so it reports
   **healthy** while the app is hung. Trust `Started primary stream server`.
3. **Isaac Lab 3.0 needs Isaac Sim 6.0.0, NOT 6.0.1.** Matching the container's
   6.0.1 is the intuitive move and breaks every task with
   `No module named 'omni.physics.tensors.impl'`. The two installs are unrelated.
4. **`OMNI_KIT_ACCEPT_EULA=YES`** or importing isaacsim blocks on an interactive
   prompt and dies over SSH with `EOF when reading a line`.
5. **uv needs `--index-strategy unsafe-best-match`** — Isaac Sim's deps span PyPI
   and pypi.nvidia.com and uv will not mix indexes by default.
6. **`debug_vis=True` hangs headless training forever, silently.** Set
   `cmd.debug_vis = False` in any custom task. Diagnose with `py-spy dump --pid`.
7. **SSH timing out later usually means your public IP changed**, not a dead VM
   (`ALLOW_CIDR=auto` pinned one `/32`). Check
   `nebius compute instance get --id <id>` first, then `curl -4 ifconfig.me`
   (the `-4` matters — plain output may be IPv6). Re-open with
   `nebius vpc security-rule create --parent-id <sg> ... --ingress-source-cidrs <newip>/32`.
8. **Never `pkill -f train.py` in the same SSH command that launches it** — the
   pattern matches the wrapper's own command line and kills the session. Use a
   separate call, or a bracket pattern like `'[t]rain.py'`.

## Cost and teardown

~$1.80/hr for the RTX PRO 6000. **`deploy/nebius-down.sh` deletes the instance
AND its boot disk** — pull artifacts first (`deploy/sync.sh --down`, and rsync `~/rl/IsaacLab/logs/` if you trained).
To pause instead and keep everything:
`nebius compute instance stop --id <id>` / `... start --id <id>` (~2-3 min to
resume, disk billing only). The public IP may change on restart, and
`ISAACSIM_HOST` is baked into the web-viewer at build time, so re-run
`~/remote/bootstrap.sh <newip> 6.0.1 physx` after a restart.
