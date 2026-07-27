# iac-plh

Infrastructure-as-Code for the PLH (Personal Lab Hardware) laptop environment.
Brings the same IaC patterns from iac-hlh to a CachyOS laptop with LXD.

## Executive Summary

`iac-plh` provides reproducible AI inference infrastructure on a laptop using
LXD containers. It mirrors the `iac-hlh` architecture but targets a mobile
workstation with an NVIDIA RTX 2060M GPU.

- Host: Alienware M17 R2, CachyOS (Arch Linux)
- Virtualization: LXD system containers
- GPU: NVIDIA RTX 2060M (CUDA passthrough)
- AI Stack: **Lemonade Server** (PPA, CUDA backend) — no llama.cpp build, no CUDA toolkit

## Quick Start

```bash
# 1. Bootstrap the CachyOS host
./bootstrap/bootstrap-lxd-host.sh

# 2. Deploy the AI engine (one command)
./deploy-plh-ai-engine.sh
```

## Endpoints

| Service | Port | Description |
|---------|------|-------------|
| Lemonade Web UI | 13305 | Chat, model management, settings |
| Lemonade API | 13305 | OpenAI-compatible API (`/api/v1/`) |

## Architecture

```
Host (CachyOS) ─── LXD Container (Ubuntu 24.04) ─── GPU (RTX 2060M)
  │                    │
  │  deploy-plh-ai     │  lemonade-server (PPA)
  │  -lxd-project      │  - CUDA backend
  │  -gpu-passthrough  │  - /etc/lemonade/config.json
  │  -model-mount      │  - port 13305
  │                    │  /srv/ai/models (bind mount)
  └─── /srv/ai/models──┘
```

## Repository Structure

```text
iac-plh/
├── deploy-plh-ai-engine.sh   # One-command deploy (Lemonade PPA)
├── bootstrap/                # Host bootstrap (LXD init)
├── docs/
│   └── architecture.md
├── 98_README.md              # Detailed architecture doc
├── 00_BACKLOG.md             # Future items
├── 10_ACTIVE.md              # In-progress items
├── 90_DONE.md                # What's implemented
└── CHANGELOG.md              # Version history
```

## Key Artifacts

| Artifact | Purpose |
|----------|---------|
| `deploy-plh-ai-engine.sh` | One-command LXD container deploy (Lemonade) |
| `bootstrap/` | Host bootstrap scripts (LXD init, GPU drivers) |
| `docs/architecture.md` | Full architecture documentation |

## Model Management

Models placed in `/srv/ai/models` on the host are bind-mounted into the
container at `/srv/ai/models`. Lemonade auto-discovers them via
`~/.config/lemonade/config.json` (`models.path`).

Inside the container:
```bash
# List available models
lemonade list

# Pull/download a model (auto-downloads from HuggingFace)
lemonade pull Gemma-4-E2B-it-GGUF

# Check which backends are available
lemonade backends

# Run a model directly
lemonade run Gemma-4-E2B-it-GGUF
```

## API Usage

```bash
# OpenAI-compatible chat
curl http://127.0.0.1:13305/api/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"gpt-4o","messages":[{"role":"user","content":"hello"}]}'

# List models
curl http://127.0.0.1:13305/api/v1/models
```
