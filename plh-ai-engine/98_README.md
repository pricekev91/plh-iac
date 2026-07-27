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

## Architecture Overview

```mermaid
graph TD
    subgraph HOST["CachyOS Laptop (Alienware M17 R2)"]
        OPS[deploy-plh-ai-engine.sh]
        subgraph LXC["LXD Containers"]
            ENG[engine LXC<br/>Lemonade Server + CUDA<br/>Port 13305 Web UI<br/>Port 5000 API]
        end
        OPS --> ENG
        MODELS[/srv/ai/models<br/>GGUF Models/]
        MODELS -->|bind mount| ENG
    end

    subgraph GPU["NVIDIA RTX 2060M (sm_75 Turing)"]
        CUDA[CUDA / libnvidia]
        GPU_DEV[/dev/nvidia*]
    end

    ENG --> GPU
```

## Quick Start

```bash
# 1. Bootstrap the CachyOS host
./bootstrap/bootstrap-lxd-host.sh

# 2. Deploy the AI engine (one command)
./deploy-plh-ai-engine.sh
```

## Repository Boundary

**Owns:**
- LXD host bootstrap (LXD daemon, network, storage pool, GPU drivers)
- LXD container lifecycle (create, nuke, rebuild)
- AI inference runtime (Lemonade Server via PPA)
- GPU passthrough configuration (NVIDIA profiles)
- Model management and deployment

**Does not own:**
- Application business logic (TrashPanda, BrickCipher, VoxChimera)
- Proxmox infrastructure (that is `iac-hlh`)
- Docker host management (that is `hlh-docker`)

## Endpoints

| Service | Port | Description |
|---------|------|-------------|
| Lemonade Web UI | 13305 | Chat, model management, settings |
| Lemonade API | 13305 | OpenAI-compatible API (`/api/v1/`) |
| Lemonade API (alt) | 5000 | OpenAI-compatible API (`/v1/`) |
