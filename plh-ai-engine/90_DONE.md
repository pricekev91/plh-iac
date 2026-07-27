# DONE

This is what is already implemented and verified in this repository.

## Host Bootstrap

- `bootstrap/bootstrap-lxd-host.sh`: LXD host preparation
- `bootstrap-cachyos.sh`: CachyOS bootstrap wrapper (LXD + NVIDIA)
- `bootstrap/arch-lxd-bootstrap.sh`: LXD initialization script
- `bootstrap/arch-lxd-bootstrap.fish`: Fish shell variant
- `bootstrap/arch-cachyos.bash`: OS-specific bootstrap entrypoint

## Deploy Script

- `deploy-plh-ai-engine.sh`: One-command AI engine deploy
  - Creates LXD project `prod` and container `plh-ai-engine` (Ubuntu 24.04)
  - GPU passthrough via LXD `gpu` device
  - Model directory bind mount (`/srv/ai/models`)
  - Installs Lemonade Server via PPA (`lemonade-team/stable`)
  - No CUDA toolkit, no llama.cpp build — PPA bundles CUDA runtime
  - Configures `/etc/lemonade/config.json` (CUDA backend + model paths)
  - Systemd service: `lemonade-server`
  - Health check via `/live` endpoint
  - Idempotent: skips re-install if already deployed

## Documentation

- `98_README.md`: Detailed architecture documentation
- `00_BACKLOG.md`: Future items
- `10_ACTIVE.md`: In-progress items
- `CHANGELOG.md`: Version history

## Repository Layout

```text
iac-plh/
├── deploy-plh-ai-engine.sh   # One-command LXD + Lemonade deploy
├── bootstrap/                 # Host bootstrap scripts
├── 98_README.md              # Detailed architecture
├── 00_BACKLOG.md             # Future items
├── 10_ACTIVE.md              # In-progress
├── 90_DONE.md                # What's implemented
├── CHANGELOG.md              # Version history
├── SESSION_STATE.md
└── README.md                 # Quick start
```
