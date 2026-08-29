# isaacsim-launch-nebius

One-command **Isaac Sim 6.0.1** GPU box on Nebius with WebRTC streaming in the browser,
plus **Isaac Lab 3.0** installed for RL training.

Cost: ~$1.80/hr on an RTX PRO 6000 (96 GB). Delete the VM when you are done.

## Fastest path: let Claude Code do it

```bash
cd isaacsim-launch-nebius
claude
> /isaac-sim-nebius
```

The repo ships a project skill (`.claude/skills/isaac-sim-nebius/`) that runs the steps below,
verifies all three ports + the stream server log, and reports the IP. The manual path follows.

## 1. Prerequisites (laptop, macOS or Linux)

| tool | install | check |
| --- | --- | --- |
| Nebius CLI | https://docs.nebius.com/cli/install then `nebius init` (browser login, picks your project) | `nebius iam whoami` |
| `jq` | `brew install jq` / `apt install jq` | `jq --version` |
| `nc`, `rsync`, `ssh` | already on macOS/Linux | |
| SSH key | `ssh-keygen -t ed25519` if `~/.ssh/id_ed25519.pub` does not exist | |
| Browser | **Chrome or Edge** (the WebRTC viewer does not work in Safari/Firefox) | |

## 2. Launch Isaac Sim (streaming)

```bash
cp .env.example .env          # defaults work; set NEBIUS_PROJECT_ID if `nebius init` did not
deploy/nebius-up.sh           # ~20 min. Ends with: Open: http://<IP>:8210
```

What it does: creates a security group (ssh + the 3 streaming ports, scoped to **your current
public IP**), creates the VM, then runs `deploy/remote/bootstrap.sh` on it (docker, NVIDIA
container toolkit, Vulkan userspace, pulls the Isaac Sim image, `docker compose up`).

Open `http://<IP>:8210` in Chrome. One tab at a time.

```bash
deploy/check-stream.sh        # proves tcp/8210, tcp/49100 and udp/47998 reach the VM
deploy/sync.sh                # push assets/ + scripts/ -> /workspace in the container
deploy/sync.sh --watch        # same, on every local change (needs fswatch)
deploy/sync.sh --down         # pull /workspace back into ./output
deploy/nebius-down.sh         # DELETE the VM + disk. Pull your data first.
```

The VM's IP / IDs are saved in `deploy/.state` (git-ignored). Every other script reads it.

## 3. Isaac Lab (RL training)

```bash
deploy/setup-isaaclab.sh      # ~20 min; can run while nebius-up.sh is still pulling the image
```

Installs Isaac Lab 3.0 + Isaac Sim **6.0.0** (pip) into `~/rl/IsaacLab/env_isaaclab` on the VM.
This is a second, independent Isaac Sim install: the Docker container is 6.0.1 for streaming,
the venv is 6.0.0 because Isaac Lab 3.0 breaks on 6.0.1. Do not "fix" the pin.

Then, on the VM:

```bash
cd ~/rl/IsaacLab
OMNI_KIT_ACCEPT_EULA=YES ./isaaclab.sh -p scripts/reinforcement_learning/rsl_rl/train.py \
  --task Isaac-Velocity-Flat-G1-v0 --headless --num_envs 4096 --max_iterations 500
```

Detach long runs with `setsid nohup ... > train.log 2>&1 < /dev/null &`. Logs, checkpoints and
`exported/policy.onnx` land in `~/rl/IsaacLab/logs/rsl_rl/` — rsync them off before teardown.
TensorBoard without a firewall change: `ssh -N -L 6006:localhost:6006 ubuntu@<IP>`.

## Ports (all three are mandatory)

| port | proto | purpose |
| --- | --- | --- |
| 8210 | TCP | web viewer |
| 49100 | TCP | WebRTC signaling |
| 47998 | **UDP** | WebRTC media — no UDP, no video |

No auth, no TLS. `ALLOW_CIDR=auto` scopes them to your public IP at launch time.

## Layout

| path | what |
| --- | --- |
| `deploy/nebius-up.sh` / `nebius-down.sh` | provision + firewall + bootstrap + verify / delete |
| `deploy/setup-isaaclab.sh` | Isaac Lab + Isaac Sim pip install on the VM (idempotent) |
| `deploy/remote/bootstrap.sh` | runs on the VM; idempotent, safe to re-run over ssh |
| `deploy/check-stream.sh` | port reachability test from your laptop |
| `deploy/sync.sh` | mirror `assets/` (`.usd`) and `scripts/` (`.py`) to `/workspace` |
| `scripts/example_newton_scene.py` | run a script inside the container, on the Newton backend |
| `.claude/skills/isaac-sim-nebius/` | Claude Code skill that drives all of the above |

Run a script in the container:

```bash
ssh ubuntu@<IP> 'sudo docker exec -it isim-isaac-sim-1 ./python.sh /workspace/scripts/your.py'
```

## PhysX vs Newton

`PHYSICS_BACKEND=physx` (default) or `newton` in `.env` before launching. Per-script:
`SimulationManager.switch_physics_engine("newton")` before the sim starts
(`scripts/example_newton_scene.py`). Newton rejects closed kinematic chains, joints outside an
articulation, zero mass/inertia, zero-size collision shapes, negative scale; MJWarp solver only.

## Troubleshooting

1. **SSH suddenly times out, VM looks dead** — your public IP changed (`ALLOW_CIDR=auto` pins one /32).
   Check `curl -4 ifconfig.me`, then add a rule:
   `nebius vpc security-rule create --parent-id <SG_ID from deploy/.state> --name ssh-newip --access allow --type stateful --priority 90 --protocol tcp --ingress-source-cidrs '<newip>/32' --ingress-destination-ports 22`
   (repeat for 8210/tcp, 49100/tcp, 47998/udp with other names/priorities).
2. **`jq: parse error` during `nebius-up.sh`** — the VM was still created. Do **not** re-run
   `nebius-up.sh` (not idempotent → second VM). `nebius compute instance delete --id <id>`, then re-run.
3. **tcp/49100 never opens, container says healthy** — Vulkan is missing on the host. `bootstrap.sh`
   installs it; confirm with `ls /etc/vulkan/icd.d/nvidia_icd.json` on the VM and
   `sudo docker compose -p isim logs isaac-sim | grep "Started primary stream server"`.
4. **Black viewport, UI responsive** — udp/47998 blocked. `deploy/check-stream.sh`.
5. **"already connected"** — another tab is streaming. Close it.
6. **Training hangs silently, GPU ~5%** — a task with `debug_vis=True`. Set it `False`; diagnose with `py-spy dump --pid`.

Container logs: `ssh ubuntu@<IP> 'sudo docker compose -p isim logs -f isaac-sim'`.
